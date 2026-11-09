//! Bridge async (tokio/reqwest) -> sync (`Read + Seek` pour symphonia).
//!
//! Une tâche tokio télécharge le flux, le découpe en blocs de 2048 octets, passe chaque
//! bloc à un [`ChunkDecryptor`], puis l'ajoute au buffer partagé. Le thread de décodage
//! (thread std dédié, JAMAIS un worker tokio) lit via `Read`/`Seek` et se bloque sur une
//! `Condvar` tant que les octets demandés ne sont pas arrivés.

use std::io::{self, Read, Seek, SeekFrom};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

use futures_util::StreamExt;
use symphonia::core::io::MediaSource;
use tokio::runtime::Handle;

pub mod cache;

/// Taille de bloc du protocole de chiffrement par blocs.
pub const CHUNK: usize = 2048;

/// Reprises successives sans aucune donnée reçue entre deux : au-delà, le titre est abandonné.
const MAX_RESUMES: u32 = 3;

#[derive(Debug, thiserror::Error)]
pub enum StreamError {
    #[error("http: {0}")]
    Http(#[from] reqwest::Error),
    #[error("buffer partagé empoisonné")]
    Poisoned,
    #[error("flux interrompu avant la fin")]
    Truncated,
}

/// Déchiffrement d'un bloc de [`CHUNK`] octets, indexé par sa position dans le flux
/// (permet l'accès aléatoire / seek sans état).
///
/// L'implémentation BF_CBC_STRIPE de Deezer est fournie par `dz-decrypt`.
pub trait ChunkDecryptor: Send + Sync + 'static {
    fn decrypt_chunk(&self, index: u64, chunk: &mut [u8]);
}

/// Flux non chiffré (ou déjà déchiffré en amont).
pub struct Passthrough;
impl ChunkDecryptor for Passthrough {
    fn decrypt_chunk(&self, _index: u64, _chunk: &mut [u8]) {}
}

/// Tampon du titre téléchargé. Il est sur DISQUE (fichier temporaire supprimé à la fermeture) : un titre FLAC fait
/// ~30 Mo et le titre suivant est préchargé, donc les garder en mémoire doublait l'occupation en arrière-plan.
/// Repli sur la mémoire si le fichier ne peut pas être créé.
enum Store {
    Disk { file: std::fs::File, len: u64 },
    Mem(Vec<u8>),
}

static STORE_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

impl Store {
    fn new() -> Self {
        match Self::open_temp() {
            Ok(file) => Store::Disk { file, len: 0 },
            Err(_) => Store::Mem(Vec::new()),
        }
    }

    fn open_temp() -> io::Result<std::fs::File> {
        use std::fs::OpenOptions;
        let n = STORE_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("deezer-lite-stream-{}-{n}.tmp", std::process::id()));
        let mut opts = OpenOptions::new();
        opts.read(true).write(true).create_new(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            opts.custom_flags(0x0400_0000); // FILE_FLAG_DELETE_ON_CLOSE : supprimé à la fermeture, même après un plantage
        }
        let file = opts.open(&path)?;
        #[cfg(not(windows))]
        let _ = std::fs::remove_file(&path); // Unix : le fichier disparaît dès qu'il est fermé
        Ok(file)
    }

    fn len(&self) -> u64 {
        match self {
            Store::Disk { len, .. } => *len,
            Store::Mem(v) => v.len() as u64,
        }
    }

    fn append(&mut self, buf: &[u8]) -> io::Result<()> {
        match self {
            Store::Mem(v) => {
                v.extend_from_slice(buf);
                Ok(())
            }
            Store::Disk { file, len } => {
                write_all_at(file, buf, *len)?;
                *len += buf.len() as u64;
                Ok(())
            }
        }
    }

    fn read_at(&self, pos: u64, out: &mut [u8]) -> io::Result<usize> {
        match self {
            Store::Mem(v) => {
                let start = (pos as usize).min(v.len());
                let n = out.len().min(v.len() - start);
                out[..n].copy_from_slice(&v[start..start + n]);
                Ok(n)
            }
            Store::Disk { file, len } => {
                let n = out.len().min(len.saturating_sub(pos) as usize);
                read_exact_at(file, &mut out[..n], pos)?;
                Ok(n)
            }
        }
    }
}

#[cfg(windows)]
fn write_all_at(f: &std::fs::File, mut buf: &[u8], mut off: u64) -> io::Result<()> {
    use std::os::windows::fs::FileExt;
    while !buf.is_empty() {
        let n = f.seek_write(buf, off)?;
        if n == 0 {
            return Err(io::Error::from(io::ErrorKind::WriteZero));
        }
        buf = &buf[n..];
        off += n as u64;
    }
    Ok(())
}
#[cfg(windows)]
fn read_exact_at(f: &std::fs::File, mut buf: &mut [u8], mut off: u64) -> io::Result<()> {
    use std::os::windows::fs::FileExt;
    while !buf.is_empty() {
        let n = f.seek_read(buf, off)?;
        if n == 0 {
            return Err(io::Error::from(io::ErrorKind::UnexpectedEof));
        }
        buf = &mut buf[n..];
        off += n as u64;
    }
    Ok(())
}
#[cfg(unix)]
fn write_all_at(f: &std::fs::File, buf: &[u8], off: u64) -> io::Result<()> {
    std::os::unix::fs::FileExt::write_all_at(f, buf, off)
}
#[cfg(unix)]
fn read_exact_at(f: &std::fs::File, buf: &mut [u8], off: u64) -> io::Result<()> {
    std::os::unix::fs::FileExt::read_exact_at(f, buf, off)
}

struct State {
    data: Store,
    total: Option<u64>,
    /// Les en-têtes HTTP sont arrivés (ou la requête a échoué) : `total` est définitif.
    headers: bool,
    done: bool,
    closed: bool,
    /// Lecture annulée par le lecteur (titre suivant, arrêt) : `read` rend la main tout de suite (voir `StreamCancel`).
    cancelled: bool,
    err: Option<String>,
}

impl Default for State {
    fn default() -> Self {
        Self { data: Store::new(), total: None, headers: false, done: false, closed: false, cancelled: false, err: None }
    }
}

struct Inner {
    state: Mutex<State>,
    cv: Condvar,
    /// Tâche de téléchargement, arrêtée tout de suite à l'annulation (sans attendre le paquet suivant).
    task: Mutex<Option<tokio::task::AbortHandle>>,
}

/// Message de l'erreur renvoyée par `read` après une annulation : le lecteur la reconnaît et ne l'affiche pas.
pub const CANCELLED: &str = "lecture du flux annulée";

/// Annule la lecture d'un flux depuis un autre thread. Le moteur audio décode et reçoit ses commandes (titre suivant,
/// arrêt) sur le même thread : bloqué dans `read` en attendant des octets (coupure réseau, saut loin devant), il ne
/// voyait plus rien passer pendant des dizaines de secondes. Une annulation le débloque aussitôt.
/// Ne garde pas le flux en vie (référence faible) : sans effet si le lecteur a déjà été fermé.
#[derive(Clone)]
pub struct StreamCancel(std::sync::Weak<Inner>);

impl StreamCancel {
    pub fn cancel(&self) {
        let Some(inner) = self.0.upgrade() else { return };
        if let Ok(mut st) = inner.state.lock() {
            st.cancelled = true;
            st.closed = true;
            // Plus rien à attendre : `total_when_known` rend la main aussi.
            st.headers = true;
        }
        if let Some(task) = inner.task.lock().ok().and_then(|mut t| t.take()) {
            task.abort();
        }
        inner.cv.notify_all();
    }
}

/// Fin de la tâche de téléchargement, quelle qu'en soit la cause (fin normale, erreur, annulation, panique, arrêt du
/// runtime) : le lecteur est toujours débloqué. Avant, une tâche disparue le laissait attendre pour toujours.
struct TaskEnd(Arc<Inner>);

impl Drop for TaskEnd {
    fn drop(&mut self) {
        let mut st = match self.0.state.lock() {
            Ok(st) => st,
            Err(poisoned) => poisoned.into_inner(),
        };
        st.done = true;
        st.headers = true;
        drop(st);
        self.0.cv.notify_all();
    }
}

impl Inner {
    fn lock(&self) -> Result<MutexGuard<'_, State>, StreamError> {
        self.state.lock().map_err(|_| StreamError::Poisoned)
    }
    fn lock_io(&self) -> io::Result<MutexGuard<'_, State>> {
        self.state.lock().map_err(|_| io::Error::other("buffer partagé empoisonné"))
    }
}

/// Lecteur synchrone alimenté par une tâche réseau asynchrone.
pub struct StreamReader {
    inner: Arc<Inner>,
    pos: u64,
}

impl StreamReader {
    /// Démarre le téléchargement sur le runtime `rt` et renvoie immédiatement.
    ///
    /// TODO(seek lointain) : si `pos` dépasse largement `downloaded`, relancer la requête avec
    /// `Range: bytes=<aligné sur CHUNK>-` plutôt que d'attendre. Le déchiffreur indexé par
    /// bloc rend ça possible sans état.
    pub fn spawn(
        rt: &Handle,
        http: reqwest::Client,
        url: String,
        dec: Arc<dyn ChunkDecryptor>,
    ) -> Self {
        let inner = Arc::new(Inner { state: Mutex::new(State::default()), cv: Condvar::new(), task: Mutex::new(None) });
        let task_inner = inner.clone();
        let handle = rt.spawn(async move {
            let _end = TaskEnd(task_inner.clone());
            if let Err(e) = pump(&task_inner, http, &url, dec).await {
                if let Ok(mut st) = task_inner.lock() {
                    st.err = Some(e.to_string());
                }
            }
        });
        if let Ok(mut task) = inner.task.lock() {
            *task = Some(handle.abort_handle());
        }
        Self { inner, pos: 0 }
    }

    /// Poignée pour annuler la lecture de ce flux depuis un autre thread (voir `StreamCancel`).
    pub fn cancel_handle(&self) -> StreamCancel {
        StreamCancel(Arc::downgrade(&self.inner))
    }

    /// Attend que la taille totale soit connue. Appelé depuis le thread audio (jamais un worker tokio) :
    /// symphonia interroge `is_seekable`/`byte_len` dès l'ouverture, avant l'arrivée des en-têtes.
    fn total_when_known(&self) -> Option<u64> {
        let mut st = self.inner.lock().ok()?;
        while !st.headers {
            st = self.inner.cv.wait(st).ok()?;
        }
        st.total
    }

    /// Octets déjà disponibles (pour piloter le préchargement / la jauge de buffer).
    pub fn buffered(&self) -> u64 {
        self.inner.lock().map(|s| s.data.len()).unwrap_or(0)
    }
}

async fn pump(
    inner: &Inner,
    http: reqwest::Client,
    url: &str,
    dec: Arc<dyn ChunkDecryptor>,
) -> Result<(), StreamError> {
    let resp = http.get(url).send().await?.error_for_status()?;
    {
        let mut st = inner.lock()?;
        st.total = resp.content_length();
        st.headers = true;
    }
    inner.cv.notify_all();

    let mut stream = resp.bytes_stream().boxed();
    let mut pending: Vec<u8> = Vec::with_capacity(CHUNK * 4);
    let mut index = 0u64;
    let mut resumes = 0u32;

    loop {
        let failure: StreamError = match stream.next().await {
            Some(Ok(bytes)) => {
                pending.extend_from_slice(&bytes);
                let full = pending.len() / CHUNK * CHUNK;
                if full == 0 {
                    continue;
                }
                // Déchiffrement HORS du verrou.
                let mut ready: Vec<u8> = pending.drain(..full).collect();
                for chunk in ready.chunks_exact_mut(CHUNK) {
                    dec.decrypt_chunk(index, chunk);
                    index += 1;
                }
                let mut st = inner.lock()?;
                if st.closed {
                    return Ok(());
                }
                if let Err(e) = st.data.append(&ready) {
                    st.err = Some(format!("tampon du flux : {e}"));
                    drop(st);
                    inner.cv.notify_all();
                    return Ok(());
                }
                drop(st);
                inner.cv.notify_all();
                // Des données sont arrivées : les coupures précédentes ne comptent plus.
                resumes = 0;
                continue;
            }
            Some(Err(e)) => e.into(),
            None => {
                // Fin du flux : complète, ou connexion fermée proprement avant la fin (le titre s'arrêtait alors
                // en plein milieu, sans erreur ni reprise).
                let stored = inner.lock()?.data.len();
                let received = stored + pending.len() as u64;
                let total = inner.lock()?.total;
                if total.is_some_and(|t| received < t) {
                    StreamError::Truncated
                } else {
                    break;
                }
            }
        };

        // Coupure en cours de route : on reprend là où on en était (requête partielle) au lieu de tout recommencer.
        // Ce qui est déjà stocké est toujours aligné sur CHUNK : le déchiffrement reprend au bon bloc.
        resumes += 1;
        let (have, total, closed) = {
            let st = inner.lock()?;
            (st.data.len(), st.total, st.closed)
        };
        if closed {
            return Ok(());
        }
        if resumes > MAX_RESUMES || total.is_none() {
            return Err(failure);
        }
        tokio::time::sleep(std::time::Duration::from_millis(500 * u64::from(resumes))).await;
        match resume_from(&http, url, have, total).await {
            Some(s) => {
                stream = s;
                pending.clear();
                index = have / CHUNK as u64;
            }
            None => return Err(failure),
        }
    }

    // Dernier bloc partiel : laissé tel quel (non aligné sur CHUNK). Un seul verrou : avant, un second `lock()`
    // dans la branche d'erreur attendait le premier, encore tenu, et bloquait la tâche pour toujours.
    if !pending.is_empty() {
        let mut st = inner.lock()?;
        if !st.closed {
            if let Err(e) = st.data.append(&pending) {
                st.err = Some(format!("tampon du flux : {e}"));
            }
        }
    }
    Ok(())
}

type ByteStream = futures_util::stream::BoxStream<'static, reqwest::Result<bytes::Bytes>>;

/// Relance le téléchargement à partir de l'octet `from`. `None` si le serveur ne sait pas reprendre ou ne repart pas de
/// l'octet demandé (le son serait alors décalé et le déchiffrement faux). Un serveur qui ignore la demande et renvoie
/// tout le fichier (réponse 200 de la bonne taille : certains CDN et proxys) est accepté : les `from` premiers octets,
/// déjà reçus, sont sautés. Avant, le titre s'arrêtait là et tout était retéléchargé depuis le début.
async fn resume_from(http: &reqwest::Client, url: &str, from: u64, total: Option<u64>) -> Option<ByteStream> {
    let resp = http.get(url).header(reqwest::header::RANGE, format!("bytes={from}-")).send().await.ok()?;
    if resp.status() == reqwest::StatusCode::OK {
        if total.is_none() || resp.content_length() != total {
            return None;
        }
        return Some(skip_prefix(resp.bytes_stream().boxed(), from));
    }
    if resp.status() != reqwest::StatusCode::PARTIAL_CONTENT {
        return None;
    }
    // `Content-Range: bytes <début>-<fin>/<total>` : le début doit être celui demandé.
    if let Some(range) = resp.headers().get(reqwest::header::CONTENT_RANGE) {
        let start = range
            .to_str()
            .ok()
            .and_then(|r| r.strip_prefix("bytes "))
            .and_then(|r| r.split('-').next())
            .and_then(|s| s.trim().parse::<u64>().ok());
        if start != Some(from) {
            return None;
        }
    }
    Some(resp.bytes_stream().boxed())
}

/// Le même flux, sans ses `skip` premiers octets.
fn skip_prefix(stream: ByteStream, mut skip: u64) -> ByteStream {
    stream
        .filter_map(move |item| {
            let out = match item {
                Ok(bytes) if skip >= bytes.len() as u64 => {
                    skip -= bytes.len() as u64;
                    None
                }
                Ok(bytes) => {
                    let rest = bytes.slice(skip as usize..);
                    skip = 0;
                    Some(Ok(rest))
                }
                Err(e) => Some(Err(e)),
            };
            futures_util::future::ready(out)
        })
        .boxed()
}

impl Read for StreamReader {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if out.is_empty() {
            return Ok(0);
        }
        let mut st = self.inner.lock_io()?;
        loop {
            // Annulée : rend la main tout de suite. Pas `Interrupted` (`read_exact` réessaierait sans fin).
            if st.cancelled {
                return Err(io::Error::other(CANCELLED));
            }
            let avail = st.data.len();
            if self.pos < avail {
                let n = st.data.read_at(self.pos, out)?;
                self.pos += n as u64;
                return Ok(n);
            }
            if let Some(e) = &st.err {
                return Err(io::Error::other(e.clone()));
            }
            if st.done {
                return Ok(0);
            }
            st = self.inner.cv.wait(st).map_err(|_| io::Error::other("condvar empoisonnée"))?;
        }
    }
}

impl Seek for StreamReader {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        let new = match to {
            SeekFrom::Start(n) => n as i128,
            SeekFrom::Current(d) => self.pos as i128 + d as i128,
            SeekFrom::End(d) => {
                let t = self.total_when_known().ok_or_else(|| io::Error::from(io::ErrorKind::Unsupported))?;
                t as i128 + d as i128
            }
        };
        if new < 0 {
            return Err(io::Error::from(io::ErrorKind::InvalidInput));
        }
        // Un seek au-delà de la zone téléchargée est permis : `read` attendra les octets.
        self.pos = new as u64;
        Ok(self.pos)
    }
}

impl MediaSource for StreamReader {
    fn is_seekable(&self) -> bool {
        self.total_when_known().is_some()
    }
    fn byte_len(&self) -> Option<u64> {
        self.total_when_known()
    }
}

impl Drop for StreamReader {
    fn drop(&mut self) {
        if let Ok(mut st) = self.inner.lock() {
            st.closed = true;
        }
        // Lecteur fermé : le téléchargement s'arrête tout de suite (avant : au paquet suivant, jusqu'à 20 s si le
        // serveur ne répondait plus), ce qui libère aussitôt la connexion et le fichier temporaire.
        if let Some(task) = self.inner.task.lock().ok().and_then(|mut t| t.take()) {
            task.abort();
        }
        self.inner.cv.notify_all();
    }
}
