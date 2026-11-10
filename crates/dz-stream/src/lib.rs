//! Bridge async (tokio/reqwest) -> sync (`Read + Seek` pour symphonia).
//!
//! Une tâche tokio télécharge le flux, le découpe en blocs de 2048 octets, passe chaque
//! bloc à un [`ChunkDecryptor`], puis l'ajoute au buffer partagé. Le thread de décodage
//! (thread std dédié, JAMAIS un worker tokio) lit via `Read`/`Seek` et se bloque sur une
//! `Condvar` tant que les octets demandés ne sont pas arrivés.

use std::io::{self, Read, Seek, SeekFrom};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

use futures_util::{FutureExt, StreamExt};
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

    /// Écrit `buf` à la position `pos` (n'importe où : après un saut, le titre arrive par morceaux).
    fn write_at(&mut self, pos: u64, buf: &[u8]) -> io::Result<()> {
        let end = pos + buf.len() as u64;
        match self {
            Store::Mem(v) => {
                if (v.len() as u64) < end {
                    v.resize(end as usize, 0);
                }
                v[pos as usize..end as usize].copy_from_slice(buf);
                Ok(())
            }
            Store::Disk { file, len } => {
                write_all_at(file, buf, pos)?;
                *len = (*len).max(end);
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
    /// Plages déjà reçues et déchiffrées `[début, fin)`, triées et disjointes. Le titre peut arriver par morceaux :
    /// un saut loin devant relance le téléchargement à cet endroit, les trous sont comblés ensuite.
    ranges: Vec<(u64, u64)>,
    /// Position où le téléchargement en cours écrit (alignée sur CHUNK).
    cursor: u64,
    /// Position demandée par le lecteur (saut loin devant, ou dans un trou), à télécharger tout de suite.
    want: Option<u64>,
    /// Position vers laquelle le téléchargement est en train d'être relancé.
    seeking_to: Option<u64>,
    /// Le serveur ne sait pas reprendre au milieu : plus de saut, on attend le téléchargement dans l'ordre.
    no_seek: bool,
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
        Self {
            data: Store::new(),
            ranges: Vec::new(),
            cursor: 0,
            want: None,
            seeking_to: None,
            no_seek: false,
            total: None,
            headers: false,
            done: false,
            closed: false,
            cancelled: false,
            err: None,
        }
    }
}

/// Saut plus proche que ça de l'endroit en cours de téléchargement : on attend qu'il y arrive, c'est plus rapide qu'une
/// nouvelle requête.
const NEAR: u64 = 512 * 1024;

impl State {
    /// Octets disponibles d'un seul tenant à partir de `pos`.
    fn available_at(&self, pos: u64) -> u64 {
        self.ranges.iter().find(|(start, end)| *start <= pos && pos < *end).map_or(0, |(_, end)| end - pos)
    }

    /// Enregistre `[start, end)` comme reçu, en fusionnant avec les plages voisines. Renvoie la fin de la plage
    /// fusionnée qui contient `start`.
    fn add_range(&mut self, start: u64, end: u64) -> u64 {
        let (mut start, mut end) = (start, end);
        self.ranges.retain(|&(s, e)| {
            if e < start || s > end {
                true
            } else {
                start = start.min(s);
                end = end.max(e);
                false
            }
        });
        let at = self.ranges.partition_point(|&(s, _)| s < start);
        self.ranges.insert(at, (start, end));
        end
    }

    /// Premier octet pas encore reçu (`None` : titre complet).
    fn first_gap(&self, total: u64) -> Option<u64> {
        let mut expected = 0;
        for &(start, end) in &self.ranges {
            if start > expected {
                return Some(expected);
            }
            expected = expected.max(end);
        }
        (expected < total).then_some(expected)
    }
}

struct Inner {
    state: Mutex<State>,
    cv: Condvar,
    /// Réveille la tâche de téléchargement (le lecteur demande un saut).
    wake: tokio::sync::Notify,
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
    /// Un saut loin devant (ou dans un trou) relance le téléchargement à cet endroit (`Range: bytes=<aligné sur
    /// CHUNK>-`, déchiffrement repris au bloc `position / CHUNK`) au lieu d'attendre que tout ce qui précède arrive.
    pub fn spawn(
        rt: &Handle,
        http: reqwest::Client,
        url: String,
        dec: Arc<dyn ChunkDecryptor>,
    ) -> Self {
        let inner = Arc::new(Inner {
            state: Mutex::new(State::default()),
            cv: Condvar::new(),
            wake: tokio::sync::Notify::new(),
            task: Mutex::new(None),
        });
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
        self.inner.lock().map(|s| s.available_at(0)).unwrap_or(0)
    }
}

/// Ce qui réveille la boucle de téléchargement.
enum Event {
    Data(Option<reqwest::Result<bytes::Bytes>>),
    Switched(Option<ByteStream>),
    Wake,
}

async fn pump(
    inner: &Inner,
    http: reqwest::Client,
    url: &str,
    dec: Arc<dyn ChunkDecryptor>,
) -> Result<(), StreamError> {
    let resp = http.get(url).send().await?.error_for_status()?;
    let total = resp.content_length();
    {
        let mut st = inner.lock()?;
        st.total = total;
        st.headers = true;
    }
    inner.cv.notify_all();

    let mut stream: Option<ByteStream> = Some(resp.bytes_stream().boxed());
    // Position du flux en cours de réception (toujours alignée sur CHUNK : seuls des blocs complets sont écrits).
    let mut cursor = 0u64;
    let mut pending: Vec<u8> = Vec::with_capacity(CHUNK * 4);
    let mut resumes = 0u32;
    // Relance en cours ailleurs dans le titre : (position, demandée par le lecteur ?, requête). Le flux en cours continue
    // pendant ce temps : rien n'est perdu si le serveur répond lentement.
    let mut switching: Option<(u64, bool, futures_util::future::BoxFuture<'static, Option<ByteStream>>)> = None;

    loop {
        // Saut demandé par le lecteur : relance là-bas (remplace une relance interne en cours).
        if let Some(target) = take_want(inner)? {
            if total.is_some() && switching.as_ref().is_none_or(|(t, _, _)| *t != target) {
                switching = Some((target, true, resume_from(http.clone(), url.to_owned(), target, total, false).boxed()));
            }
        }
        let event = tokio::select! {
            biased;
            r = async { (&mut switching.as_mut().expect("relance").2).await }, if switching.is_some() => Event::Switched(r),
            _ = inner.wake.notified() => Event::Wake,
            item = async { stream.as_mut().expect("flux").next().await }, if stream.is_some() => Event::Data(item),
        };
        let failure: StreamError = match event {
            Event::Wake => continue,
            Event::Switched(Some(next)) => {
                let (target, _, _) = switching.take().expect("relance");
                stream = Some(next);
                cursor = target;
                pending.clear();
                resumes = 0;
                let mut st = inner.lock()?;
                st.cursor = target;
                st.seeking_to = None;
                continue;
            }
            Event::Switched(None) => {
                let (_, asked, _) = switching.take().expect("relance");
                {
                    let mut st = inner.lock()?;
                    st.seeking_to = None;
                    // Le serveur ne sait pas reprendre au milieu : le lecteur attendra le téléchargement dans l'ordre.
                    if asked {
                        st.no_seek = true;
                    }
                }
                inner.cv.notify_all();
                if stream.is_some() {
                    continue;
                }
                StreamError::Truncated
            }
            Event::Data(Some(Ok(bytes))) => {
                pending.extend_from_slice(&bytes);
                let full = pending.len() / CHUNK * CHUNK;
                if full == 0 {
                    continue;
                }
                // Déchiffrement HORS du verrou, en place, avec le numéro de bloc de cette position dans le titre.
                let first = cursor / CHUNK as u64;
                for (i, chunk) in pending[..full].chunks_exact_mut(CHUNK).enumerate() {
                    dec.decrypt_chunk(first + i as u64, chunk);
                }
                let reached = {
                    let mut st = inner.lock()?;
                    if st.closed {
                        return Ok(());
                    }
                    if let Err(e) = st.data.write_at(cursor, &pending[..full]) {
                        st.err = Some(format!("tampon du flux : {e}"));
                        drop(st);
                        inner.cv.notify_all();
                        return Ok(());
                    }
                    let reached = st.add_range(cursor, cursor + full as u64);
                    st.cursor = cursor + full as u64;
                    reached
                };
                inner.cv.notify_all();
                pending.drain(..full);
                cursor += full as u64;
                // Des données sont arrivées : les coupures précédentes ne comptent plus.
                resumes = 0;
                // Arrivé sur une partie déjà reçue (après un saut) : on passe à la suivante qui manque.
                if reached > cursor && switching.is_none() {
                    if let Some(total) = total {
                        let next = if reached >= total { inner.lock()?.first_gap(total) } else { Some(reached) };
                        match next {
                            Some(next) => switching = Some(start_switch(inner, &http, url, next, total)?),
                            None => return finish(inner),
                        }
                    }
                }
                continue;
            }
            Event::Data(Some(Err(e))) => e.into(),
            Event::Data(None) => {
                // Fin du flux : complète, ou connexion fermée proprement avant la fin (le titre s'arrêtait alors
                // en plein milieu, sans erreur ni reprise).
                let received = cursor + pending.len() as u64;
                if total.is_some_and(|t| received < t) {
                    StreamError::Truncated
                } else {
                    // Dernier bloc partiel : laissé tel quel (non aligné sur CHUNK).
                    if !pending.is_empty() {
                        let mut st = inner.lock()?;
                        if st.closed {
                            return Ok(());
                        }
                        if let Err(e) = st.data.write_at(cursor, &pending) {
                            st.err = Some(format!("tampon du flux : {e}"));
                            drop(st);
                            inner.cv.notify_all();
                            return Ok(());
                        }
                        st.add_range(cursor, received);
                        drop(st);
                        inner.cv.notify_all();
                        pending.clear();
                    }
                    stream = None;
                    // Fin du titre atteinte après un saut : on revient combler ce qui manque avant.
                    let gap = match total {
                        Some(total) => inner.lock()?.first_gap(total).map(|gap| (gap, total)),
                        None => None,
                    };
                    match gap {
                        Some((gap, total)) => {
                            if switching.is_none() {
                                switching = Some(start_switch(inner, &http, url, gap, total)?);
                            }
                            continue;
                        }
                        None => return finish(inner),
                    }
                }
            }
        };

        // Coupure en cours de route : on reprend là où on en était (requête partielle) au lieu de tout recommencer.
        // La position est toujours alignée sur CHUNK : le déchiffrement reprend au bon bloc.
        stream = None;
        // Une relance est déjà en route (saut) : elle prend le relais.
        if switching.is_some() {
            continue;
        }
        resumes += 1;
        if inner.lock()?.closed {
            return Ok(());
        }
        if resumes > MAX_RESUMES || total.is_none() {
            return Err(failure);
        }
        tokio::time::sleep(std::time::Duration::from_millis(500 * u64::from(resumes))).await;
        match resume_from(http.clone(), url.to_owned(), cursor, total, true).await {
            Some(s) => {
                stream = Some(s);
                pending.clear();
            }
            None => return Err(failure),
        }
    }
}

/// Saut demandé par le lecteur, s'il y en a un (aligné sur CHUNK).
fn take_want(inner: &Inner) -> Result<Option<u64>, StreamError> {
    let mut st = inner.lock()?;
    let want = st.want.take().map(|pos| pos / CHUNK as u64 * CHUNK as u64);
    if want.is_some() {
        st.seeking_to = want;
    }
    Ok(want)
}

/// Relance interne (combler un trou) vers `target`.
fn start_switch(
    inner: &Inner,
    http: &reqwest::Client,
    url: &str,
    target: u64,
    total: u64,
) -> Result<(u64, bool, futures_util::future::BoxFuture<'static, Option<ByteStream>>), StreamError> {
    inner.lock()?.seeking_to = Some(target);
    Ok((target, false, resume_from(http.clone(), url.to_owned(), target, Some(total), true).boxed()))
}

/// Titre entièrement reçu.
fn finish(inner: &Inner) -> Result<(), StreamError> {
    inner.lock()?.seeking_to = None;
    inner.cv.notify_all();
    Ok(())
}

type ByteStream = futures_util::stream::BoxStream<'static, reqwest::Result<bytes::Bytes>>;

/// Relance le téléchargement à partir de l'octet `from`. `None` si le serveur ne sait pas reprendre ou ne repart pas de
/// l'octet demandé (le son serait alors décalé et le déchiffrement faux). Un serveur qui ignore la demande et renvoie
/// tout le fichier (réponse 200 de la bonne taille : certains CDN et proxys) est accepté : les `from` premiers octets,
/// déjà reçus, sont sautés. Avant, le titre s'arrêtait là et tout était retéléchargé depuis le début.
/// `allow_full` : accepter un serveur qui renvoie tout le fichier (utile après une coupure ; inutile pour un saut, qui
/// serait alors aussi long que d'attendre).
async fn resume_from(http: reqwest::Client, url: String, from: u64, total: Option<u64>, allow_full: bool) -> Option<ByteStream> {
    let resp = http.get(&url).header(reqwest::header::RANGE, format!("bytes={from}-")).send().await.ok()?;
    if resp.status() == reqwest::StatusCode::OK {
        if !allow_full || total.is_none() || resp.content_length() != total {
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
            let avail = st.available_at(self.pos);
            if avail > 0 {
                let len = out.len().min(avail as usize);
                let n = st.data.read_at(self.pos, &mut out[..len])?;
                self.pos += n as u64;
                return Ok(n);
            }
            if st.total.is_some_and(|total| self.pos >= total) {
                return Ok(0);
            }
            if let Some(e) = &st.err {
                return Err(io::Error::other(e.clone()));
            }
            if st.done {
                // Taille inconnue : fin du flux. Sinon, le téléchargement s'est arrêté avant d'arriver ici.
                return if st.total.is_none() { Ok(0) } else { Err(io::Error::other("flux interrompu avant la fin")) };
            }
            // Loin de l'endroit en cours de téléchargement (saut loin devant, ou dans un trou) : relancé ici tout de
            // suite, au lieu d'attendre que tout ce qui précède arrive.
            let aligned = self.pos / CHUNK as u64 * CHUNK as u64;
            let near = st.cursor <= self.pos && self.pos < st.cursor + NEAR;
            if st.total.is_some() && !st.no_seek && !near && st.want.is_none() && st.seeking_to != Some(aligned) {
                st.want = Some(self.pos);
                self.inner.wake.notify_one();
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
        // Un seek au-delà de la zone téléchargée est permis : `read` relancera le téléchargement à cet endroit.
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
