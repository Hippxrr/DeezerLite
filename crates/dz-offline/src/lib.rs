use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use dz_api::{Cipher, DeezerClient, Quality, TrackInfo};
use dz_stream::{ChunkDecryptor, Passthrough, CHUNK};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[derive(Debug, thiserror::Error)]
pub enum DownloadError {
    #[error(transparent)]
    Api(#[from] dz_api::DeezerError),
    #[error("http: {0}")]
    Http(#[from] reqwest::Error),
    #[error("stockage : {0}")]
    Io(#[from] io::Error),
    #[error("téléchargement annulé")]
    Cancelled,
    #[error("téléchargement incomplet")]
    Incomplete,
    #[error("contenu audio téléchargé invalide")]
    InvalidAudio,
    #[error("format chiffré non pris en charge : {0}")]
    Cipher(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OfflineTrack {
    pub info: TrackInfo,
    pub ext: String,
    pub bytes: u64,
    pub downloaded_at: u64,
    cover: Option<String>,
    #[serde(default)]
    cover_version: u8,
    /// Téléchargé pour lui-même (pas seulement comme titre d'une playlist, d'un album ou des Titres aimés) : il reste
    /// quand ces collections sont supprimées ou qu'il en est retiré.
    #[serde(default)]
    pub pinned: bool,
    /// Vérifications de pochette ratées d'affilée (aucune vraie image trouvée) et date (secondes Unix) avant laquelle
    /// on ne réessaie pas : une pochette introuvable n'est plus redemandée à chaque lancement (voir `cover_retry_delay`).
    #[serde(default)]
    cover_tries: u8,
    #[serde(default)]
    cover_retry_at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingDownload {
    pub info: TrackInfo,
    pub url: String,
    pub stream_id: i64,
    pub ext: String,
    pub encrypted: bool,
    /// Demandé pour lui-même, hors de toute collection téléchargée (voir `OfflineTrack::pinned`).
    #[serde(default)]
    pub pinned: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OfflineCollection {
    pub kind: String,
    pub id: u64,
    pub owned: bool,
    pub title: String,
    pub subtitle: String,
    pub cover_url: Option<String>,
    pub track_ids: Vec<i64>,
    pub downloaded_at: u64,
    cover: Option<String>,
}

impl OfflineCollection {
    pub fn new(kind: String, id: u64, owned: bool, title: String, subtitle: String, cover_url: Option<String>, track_ids: Vec<i64>) -> Self {
        let downloaded_at = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
        Self { kind, id, owned, title, subtitle, cover_url, track_ids, downloaded_at, cover: None }
    }

    pub fn key(&self) -> String {
        collection_key(&self.kind, self.id)
    }
}

/// Écoute pas encore signalée à Deezer (réseau absent au moment de l'envoi), gardée jusqu'au retour du réseau.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingListen {
    pub track_id: i64,
    /// Format du rapport (`FLAC`, `MP3_320`…).
    pub format: String,
    /// Début de l'écoute (secondes Unix) : l'heure réelle, même si le rapport part plus tard.
    pub started_at: u64,
    pub listened_s: u64,
    /// Compte (ou profil) qui a écouté ; 0 = inconnu (app lancée sans réseau).
    #[serde(default)]
    pub user_id: u64,
}

/// Écoutes en attente, plus l'écoute en cours mise de côté à la dernière pause (comptée au prochain lancement si l'app
/// a été fermée entre-temps).
#[derive(Debug, Default, Serialize, Deserialize)]
struct ListensFile {
    #[serde(default)]
    queue: Vec<PendingListen>,
    #[serde(default)]
    open: Option<PendingListen>,
}

/// Écoutes gardées au plus (les plus anciennes sont oubliées au-delà).
const MAX_PENDING_LISTENS: usize = 1000;

/// Une ligne de paroles gardée sur le téléphone ; `ms` = instant d'affichage (0 si non synchronisées).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredLyricLine {
    pub ms: u64,
    pub text: String,
}

/// Paroles Deezer d'un titre téléchargé, gardées pour les afficher hors ligne.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredLyrics {
    pub synced: bool,
    pub lines: Vec<StoredLyricLine>,
    pub copyright: String,
}

/// Fichier `lyrics/{id}.json` : `lyrics` vide = Deezer n'avait pas de paroles pour ce titre. `checked` : jour de la
/// dernière demande (absent dans les fichiers d'avant : 0). Sans paroles synchronisées, on redemande chaque semaine :
/// Deezer en ajoute régulièrement (avant, une absence gardée l'était pour toujours).
#[derive(Debug, Serialize, Deserialize)]
struct LyricsFile {
    lyrics: Option<StoredLyrics>,
    #[serde(default)]
    checked: u64,
}

/// Jours entre deux demandes pour un titre téléchargé sans paroles synchronisées.
const LYRICS_RECHECK_DAYS: u64 = 7;
/// Titres revérifiés au plus à chaque ouverture de session (le reste à la suivante) : pas de rafale de requêtes.
const LYRICS_RECHECK_MAX: usize = 300;

fn today() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs() / 86_400)
}

/// Résultat d'une demande de paroles pour un titre téléchargé.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LyricsFetch {
    /// Paroles (ou absence de paroles) enregistrées sur le téléphone.
    Stored,
    /// Pas de réseau ou pas de session : on arrête, ce sera pour le prochain lancement.
    Offline,
    /// Autre échec pour ce titre seulement : réessayé au prochain lancement.
    Failed,
}

/// Image vide du serveur d'images de Deezer (md5 d'un texte vide) : il redirige vers elle quand il n'a pas l'image
/// demandée (pochette supprimée par Deezer, ou taille indisponible). C'est un vrai JPEG, tout blanc : jamais gardé.
const EMPTY_PICTURE: &str = "d41d8cd98f00b204e9800998ecf8427e";

/// Version des pochettes gardées. 2 : image vide refusée, pochette supprimée remplacée par celle de l'album.
/// 3 : réparée titre par titre (album retiré : la pochette de la sortie vers laquelle Deezer redirige ce titre), et
/// vérifiée à partir de l'adresse d'origine chez Deezer. Une version 2 a pu garder la réparation d'un autre titre
/// du même album retiré (Chanel / Jr Vini) : les titres en version < 3 sont revérifiés une fois (`repair_covers`).
const COVER_VERSION: u8 = 3;

/// Résultat de la vérification de la pochette d'un titre téléchargé.
#[derive(Debug, Clone, PartialEq, Eq)]
struct CoverUpdate {
    id: i64,
    /// Nouvelle image gardée (`None` : celle déjà gardée est bonne).
    cover: Option<String>,
    /// Nouvelle adresse Deezer de la pochette (pochette supprimée remplacée par celle de l'album).
    url: Option<String>,
    /// Aucune vraie image trouvée : rien ne change, le prochain essai est repoussé.
    failed: bool,
}

/// Délai avant de revérifier une pochette introuvable, selon le nombre d'essais ratés : 1 jour, 7 jours, puis 30 jours.
fn cover_retry_delay(tries: u8) -> u64 {
    const DAY: u64 = 24 * 3600;
    match tries {
        0 => 0,
        1 => DAY,
        2 => 7 * DAY,
        _ => 30 * DAY,
    }
}

fn now_s() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
}

/// Journal des titres ajoutés depuis la dernière réécriture complète de `downloads.json` : un titre téléchargé n'y
/// ajoute qu'une ligne (au lieu de réécrire tout le manifest, ~400 Ko pour 1000 titres, à chaque titre). Relu et fondu
/// dans `downloads.json` au lancement, et toutes les `JOURNAL_MAX` lignes.
const JOURNAL: &str = "downloads.log";
const JOURNAL_MAX: usize = 100;

/// Une seule vérification des pochettes à la fois (voir `repair_covers`).
static REPAIRING_COVERS: AtomicBool = AtomicBool::new(false);

/// Une seule récupération des paroles manquantes à la fois (ouverture de session et connexion peuvent se suivre).
static REPAIRING_LYRICS: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone)]
pub struct LocalTrack {
    pub info: TrackInfo,
    pub path: PathBuf,
    pub ext: String,
}

#[derive(Clone)]
pub struct OfflineStore {
    root: Arc<PathBuf>,
    entries: Arc<RwLock<BTreeMap<i64, OfflineTrack>>>,
    pending: Arc<RwLock<BTreeMap<i64, PendingDownload>>>,
    collections: Arc<RwLock<BTreeMap<String, OfflineCollection>>>,
    listens: Arc<RwLock<ListensFile>>,
    /// Une seule écriture de manifest à la fois : deux écritures parallèles se disputaient le même fichier temporaire,
    /// et un instantané plus ancien pouvait être écrit en dernier (titre perdu, puis son audio effacé comme orphelin).
    persist_lock: Arc<Mutex<()>>,
    /// Incrémenté par `clear()` (déconnexion) : écoutes et compte (voir `generation()`).
    generation: Arc<AtomicU64>,
    /// Incrémenté par chaque effacement des téléchargements (déconnexion ou « Tout effacer ») : un téléchargement
    /// commencé avant n'est pas enregistré après.
    wipes: Arc<AtomicU64>,
    /// Lignes du journal depuis la dernière réécriture de `downloads.json` (voir `JOURNAL`), sous `persist_lock`.
    journal_len: Arc<AtomicU64>,
}

/// Titres ajoutés par le journal, dans l'ordre. Une ligne illisible (coupure pendant l'écriture) est ignorée : ce titre
/// n'avait pas été confirmé, il est retéléchargé.
fn read_journal(path: &Path) -> Vec<OfflineTrack> {
    let Ok(bytes) = std::fs::read(path) else { return Vec::new() };
    bytes.split(|b| *b == b'\n').filter(|line| !line.is_empty()).filter_map(|line| serde_json::from_slice(line).ok()).collect()
}

fn read_manifest<T>(path: &Path) -> io::Result<T>
where
    T: for<'de> Deserialize<'de> + Default,
{
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|error| {
            io::Error::new(io::ErrorKind::InvalidData, format!("manifest {} illisible : {error}", path.display()))
        }),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(T::default()),
        Err(error) => Err(error),
    }
}

/// Liste illisible (abîmée, ou d'un format que cette version ne comprend pas) : renommée en `.corrupt`, sans rien
/// effacer, et remplacée par une liste vide. Avant, l'app ne démarrait plus du tout (même pour écouter en streaming)
/// jusqu'à sa réinstallation. `damaged` passe à vrai dans ce cas.
fn read_or_set_aside<T>(path: &Path, damaged: &mut bool) -> io::Result<T>
where
    T: for<'de> Deserialize<'de> + Default,
{
    match read_manifest(path) {
        Err(error) if error.kind() == io::ErrorKind::InvalidData => {
            *damaged = true;
            std::fs::rename(path, path.with_extension("json.corrupt"))?;
            Ok(T::default())
        }
        other => other,
    }
}

/// Fichier temporaire écrit jusqu'au disque, puis renommé : jamais de manifest vide ou à moitié écrit après une coupure.
fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    write_replace(path, bytes, true)
}

/// Comme `write_atomic`, avec ou sans attendre l'écriture physique sur le disque (`sync`). Sans : toujours remplacé
/// d'un bloc (jamais à moitié écrit), mais une coupure de courant peut faire perdre la dernière version.
fn write_replace(path: &Path, bytes: &[u8], sync: bool) -> io::Result<()> {
    use std::io::Write as _;
    let tmp = path.with_extension("json.tmp");
    let result = (|| {
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        if sync {
            file.sync_all()?;
        }
        drop(file);
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        // Disque plein : le fichier temporaire à moitié écrit ne doit pas garder la place qui manque.
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// Garde la première erreur d'une suite d'étapes toutes tentées.
fn keep_first(first: &mut Option<io::Error>, result: io::Result<()>) {
    if let Err(error) = result {
        first.get_or_insert(error);
    }
}

fn is_remote(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("http://")
}

fn remove_orphans(root: &Path, entries: &BTreeMap<i64, OfflineTrack>, collections: &BTreeMap<String, OfflineCollection>) {
    let audio: BTreeSet<PathBuf> = entries.keys().map(|id| root.join("audio").join(format!("{id}.{}", entries[id].ext))).collect();
    let covers: BTreeSet<PathBuf> = entries
        .values()
        .filter_map(|entry| entry.cover.as_ref())
        .chain(collections.values().filter_map(|collection| collection.cover.as_ref()))
        .map(|cover| root.join(cover))
        .collect();
    let lyrics: BTreeSet<PathBuf> = entries.keys().map(|id| lyrics_path(root, *id)).collect();
    for (folder, keep) in [("audio", &audio), ("covers", &covers), ("lyrics", &lyrics)] {
        if let Ok(files) = std::fs::read_dir(root.join(folder)) {
            for path in files.flatten().map(|file| file.path()) {
                if !keep.contains(&path) {
                    let _ = std::fs::remove_file(path);
                }
            }
        }
    }
}

fn stored_bytes(root: &Path) -> u64 {
    let mut total = 0;
    if let Ok(entries) = std::fs::read_dir(root) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                total += stored_bytes(&path);
            } else if path.is_file() {
                total += entry.metadata().map(|metadata| metadata.len()).unwrap_or(0);
            }
        }
    }
    total
}

impl OfflineStore {
    pub fn open(root: PathBuf) -> io::Result<Self> {
        std::fs::create_dir_all(root.join("audio"))?;
        std::fs::create_dir_all(root.join("covers"))?;
        std::fs::create_dir_all(root.join("lyrics"))?;
        let mut damaged = false;
        let mut entries: BTreeMap<i64, OfflineTrack> = read_or_set_aside(&root.join("downloads.json"), &mut damaged)?;
        let journal = read_journal(&root.join(JOURNAL));
        let mut changed = !journal.is_empty();
        for entry in journal {
            entries.insert(entry.info.id, entry);
        }
        let before = entries.len();
        entries.retain(|id, entry| audio_path(&root, *id, &entry.ext).metadata().is_ok_and(|m| m.len() == entry.bytes));
        changed |= entries.len() != before;
        // File des téléchargements illisible : on repart d'une file vide plutôt que d'empêcher l'app de démarrer
        // (les téléchargements en cours sont redemandés par l'app, qui garde sa propre liste).
        let mut pending: BTreeMap<i64, PendingDownload> = read_manifest(&root.join("pending.json")).unwrap_or_default();
        // Titre enregistré mais retiré de la file sans pouvoir la réécrire (disque plein) : il n'est plus attendu.
        pending.retain(|id, _| !entries.contains_key(id));
        let collections: BTreeMap<String, OfflineCollection> = read_or_set_aside(&root.join("collections.json"), &mut damaged)?;
        // Titres hors de toute collection (téléchargés seuls, y compris avant l'existence de `pinned`) : gardés pour eux-mêmes.
        let grouped: BTreeSet<i64> = collections.values().flat_map(|c| c.track_ids.iter().copied()).collect();
        for (id, entry) in entries.iter_mut() {
            if !grouped.contains(id) && !entry.pinned {
                entry.pinned = true;
                changed = true;
            }
        }
        // Fichier des écoutes illisible : mis de côté (`listens.json.corrupt`, avant : écrasé à la première écriture) ;
        // on repart de zéro plutôt que d'empêcher l'app de démarrer. Sans effet sur les fichiers audio (`damaged`).
        let mut listens: ListensFile = read_or_set_aside(&root.join("listens.json"), &mut false).unwrap_or_default();
        // Écoute mise de côté à une pause, puis app fermée avant la fin du titre : elle compte maintenant.
        let reopened = listens.open.take();
        if let Some(listen) = &reopened {
            listens.queue.push(listen.clone());
        }
        // Liste illisible mise de côté : rien n'est effacé comme orphelin à ce lancement (fichiers audio intacts).
        if !damaged {
            remove_orphans(&root, &entries, &collections);
        }
        let store = Self {
            root: Arc::new(root),
            entries: Arc::new(RwLock::new(entries)),
            pending: Arc::new(RwLock::new(pending)),
            collections: Arc::new(RwLock::new(collections)),
            listens: Arc::new(RwLock::new(listens)),
            persist_lock: Arc::new(Mutex::new(())),
            generation: Arc::new(AtomicU64::new(0)),
            wipes: Arc::new(AtomicU64::new(0)),
            journal_len: Arc::new(AtomicU64::new(0)),
        };
        // Réécrit seulement si quelque chose a changé (avant : à chaque lancement). Un échec n'empêche pas de démarrer :
        // le journal reste et sera fondu plus tard.
        if changed {
            let _ = store.persist();
        }
        if reopened.is_some() {
            let _ = store.persist_listens();
        }
        Ok(store)
    }

    pub fn local(&self, id: i64) -> Option<LocalTrack> {
        let entry = self.entries.read().ok()?.get(&id)?.clone();
        let path = audio_path(&self.root, id, &entry.ext);
        path.metadata().ok()?.len().eq(&entry.bytes).then(|| LocalTrack {
            info: self.display_info(&entry),
            path,
            ext: entry.ext,
        })
    }

    pub fn contains(&self, id: i64) -> bool {
        self.local(id).is_some()
    }

    pub fn list(&self) -> Vec<OfflineTrack> {
        let mut list: Vec<_> = self.entries.read().map(|e| e.values().cloned().collect()).unwrap_or_default();
        list.sort_by_key(|e| std::cmp::Reverse(e.downloaded_at));
        list
    }

    pub fn infos(&self) -> Vec<TrackInfo> {
        self.list().iter().map(|e| self.display_info(e)).collect()
    }

    pub fn collections(&self) -> Vec<(OfflineCollection, usize)> {
        let available: BTreeSet<i64> = self.entries.read().map(|entries| entries.keys().copied().collect()).unwrap_or_default();
        let mut list: Vec<_> = self
            .collections
            .read()
            .map(|collections| {
                collections
                    .values()
                    .map(|collection| {
                        let count = collection.track_ids.iter().filter(|id| available.contains(*id)).count();
                        (self.display_collection(collection), count)
                    })
                    .collect()
            })
            .unwrap_or_default();
        list.sort_by_key(|(collection, _)| std::cmp::Reverse(collection.downloaded_at));
        list
    }

    pub fn collection(&self, kind: &str, id: u64) -> Option<(OfflineCollection, Vec<TrackInfo>)> {
        let collection = self.collections.read().ok()?.get(&collection_key(kind, id))?.clone();
        let tracks = collection.track_ids.iter().filter_map(|id| self.local(*id).map(|local| local.info)).collect();
        Some((self.display_collection(&collection), tracks))
    }

    pub fn standalone_infos(&self) -> Vec<TrackInfo> {
        let grouped: BTreeSet<i64> = self
            .collections
            .read()
            .map(|collections| collections.values().flat_map(|collection| collection.track_ids.iter().copied()).collect())
            .unwrap_or_default();
        // Titres téléchargés seuls, même s'ils sont aussi dans une collection téléchargée.
        self.list().iter().filter(|e| e.pinned || !grouped.contains(&e.info.id)).map(|e| self.display_info(e)).collect()
    }

    /// Le titre fait-il partie d'une collection téléchargée ?
    pub fn in_collection(&self, id: i64) -> bool {
        self.collections.read().is_ok_and(|collections| collections.values().any(|c| c.track_ids.contains(&id)))
    }

    /// Supprime, parmi ces titres, ceux qui ne sont plus dans aucune collection et n'ont pas été téléchargés pour
    /// eux-mêmes (titre retiré d'une playlist ou des Titres aimés). Renvoie les titres supprimés.
    fn remove_unused(&self, ids: &[i64]) -> io::Result<Vec<i64>> {
        let grouped: BTreeSet<i64> = self
            .collections
            .read()
            .map_err(|_| io::Error::other("index des playlists verrouillé"))?
            .values()
            .flat_map(|collection| collection.track_ids.iter().copied())
            .collect();
        // Un verrou à la fois : `insert_if_pending` prend `pending` puis `entries` ; les tenir ici dans l'autre ordre
        // pouvait bloquer les deux pour toujours (synchro d'une playlist pendant la fin d'un téléchargement : app figée).
        let mut pinned: BTreeSet<i64> = {
            let entries = self.entries.read().map_err(|_| io::Error::other("index des téléchargements verrouillé"))?;
            ids.iter().copied().filter(|id| entries.get(id).is_some_and(|e| e.pinned)).collect()
        };
        {
            let pending = self.pending.read().map_err(|_| io::Error::other("file des téléchargements verrouillée"))?;
            pinned.extend(ids.iter().copied().filter(|id| pending.get(id).is_some_and(|p| p.pinned)));
        }
        let unused: Vec<i64> = ids.iter().copied().filter(|id| !grouped.contains(id) && !pinned.contains(id)).collect();
        self.remove_many(&unused)?;
        Ok(unused)
    }

    /// Paroles gardées d'un titre téléchargé : `None` = rien de gardé (demander à Deezer), `Some(None)` = Deezer n'a
    /// pas de paroles pour ce titre, `Some(Some(_))` = les paroles, lisibles sans réseau.
    /// Paroles à (re)demander : jamais gardées (ou fichier abîmé), ou sans paroles synchronisées et vérifiées il y a
    /// plus d'une semaine.
    fn lyrics_due(&self, id: i64) -> bool {
        let Ok(bytes) = std::fs::read(lyrics_path(&self.root, id)) else { return true };
        let Ok(file) = serde_json::from_slice::<LyricsFile>(&bytes) else { return true };
        !file.lyrics.is_some_and(|l| l.synced) && file.checked + LYRICS_RECHECK_DAYS <= today()
    }

    /// Garde les paroles reçues pour un titre téléchargé (rien s'il ne l'est pas, ou plus).
    pub fn save_lyrics(&self, id: i64, found: Option<StoredLyrics>) -> io::Result<()> {
        if !self.entries.read().map(|e| e.contains_key(&id)).unwrap_or(false) {
            return Ok(());
        }
        let bytes = serde_json::to_vec(&LyricsFile { lyrics: found, checked: today() }).map_err(io::Error::other)?;
        write_atomic(&lyrics_path(&self.root, id), &bytes)
    }

    pub fn lyrics(&self, id: i64) -> Option<Option<StoredLyrics>> {
        if !self.entries.read().ok()?.contains_key(&id) {
            return None;
        }
        let bytes = std::fs::read(lyrics_path(&self.root, id)).ok()?;
        serde_json::from_slice::<LyricsFile>(&bytes).ok().map(|f| f.lyrics)
    }

    pub fn total_bytes(&self) -> u64 {
        stored_bytes(&self.root)
    }

    /// Un titre déjà attendu pour lui-même le reste (adresse renouvelée pendant le téléchargement d'une collection).
    pub fn save_pending(&self, mut download: PendingDownload) -> io::Result<()> {
        {
            let mut pending = self.pending.write().map_err(|_| io::Error::other("file des téléchargements verrouillée"))?;
            download.pinned |= pending.get(&download.info.id).is_some_and(|p| p.pinned);
            pending.insert(download.info.id, download);
        }
        self.persist_pending()
    }

    pub fn pending(&self, id: i64) -> Option<PendingDownload> {
        self.pending.read().ok()?.get(&id).cloned()
    }

    pub fn remove_pending(&self, id: i64) -> io::Result<()> {
        self.remove_pending_many(&[id])
    }

    pub fn remove_pending_many(&self, ids: &[i64]) -> io::Result<()> {
        if ids.is_empty() {
            return Ok(());
        }
        let mut pending = self.pending.write().map_err(|_| io::Error::other("file des téléchargements verrouillée"))?;
        for id in ids {
            pending.remove(id);
        }
        drop(pending);
        self.persist_pending()
    }

    pub fn clear_pending(&self) -> io::Result<()> {
        self.pending
            .write()
            .map_err(|_| io::Error::other("file des téléchargements verrouillée"))?
            .clear();
        self.persist_pending()
    }

    pub fn remove(&self, id: i64) -> io::Result<()> {
        self.remove_many(&[id])
    }

    /// Les fichiers sont supprimés AVANT la réécriture des manifests : disque plein, la réécriture échouait et rien
    /// n'était jamais libéré. Un manifest resté ancien ne pose pas de problème : au lancement, un titre dont l'audio
    /// manque est ignoré (voir `open`).
    fn remove_many(&self, ids: &[i64]) -> io::Result<()> {
        if ids.is_empty() {
            return Ok(());
        }
        let was_pending = {
            let mut pending = self.pending.write().map_err(|_| io::Error::other("file des téléchargements verrouillée"))?;
            ids.iter().filter(|id| pending.remove(id).is_some()).count() > 0
        };
        let removed: Vec<OfflineTrack> = {
            let mut entries = self.entries.write().map_err(|_| io::Error::other("index des téléchargements verrouillé"))?;
            ids.iter().filter_map(|id| entries.remove(id)).collect()
        };
        for entry in &removed {
            let _ = std::fs::remove_file(audio_path(&self.root, entry.info.id, &entry.ext));
            let _ = std::fs::remove_file(lyrics_path(&self.root, entry.info.id));
        }
        // Pochettes partagées entre les titres d'un album : supprimées seulement quand plus aucun titre ne s'en sert.
        let covers: Vec<String> = removed.iter().filter_map(|entry| entry.cover.clone()).collect();
        for cover in self.unused_covers(covers) {
            let _ = std::fs::remove_file(self.root.join(cover));
        }
        let mut first = None;
        if !removed.is_empty() {
            keep_first(&mut first, self.persist());
        }
        if was_pending {
            keep_first(&mut first, self.persist_pending());
        }
        first.map_or(Ok(()), Err)
    }

    /// `None` : titre absent de la collection. Sinon, les titres retirés du téléphone (vide s'il reste ailleurs).
    pub fn remove_collection_track(&self, kind: &str, id: u64, track_id: i64) -> io::Result<Option<Vec<i64>>> {
        let mut collections = self
            .collections
            .write()
            .map_err(|_| io::Error::other("index des playlists verrouillé"))?;
        let Some(collection) = collections.get_mut(&collection_key(kind, id)) else {
            return Ok(None);
        };
        let previous = collection.track_ids.len();
        collection.track_ids.retain(|candidate| *candidate != track_id);
        if collection.track_ids.len() == previous {
            return Ok(None);
        }
        drop(collections);
        let saved = self.persist_collections();
        // Retiré de la playlist (ou des Titres aimés) : plus téléchargé, sauf s'il l'a été pour lui-même ou reste ailleurs.
        let removed = self.remove_unused(&[track_id])?;
        saved?;
        Ok(Some(removed))
    }

    /// Ajoute un titre en tête d'une collection téléchargée (titre aimé : du plus récent au plus ancien).
    /// `false` si la collection n'est pas téléchargée ou contient déjà le titre.
    pub fn add_collection_track(&self, kind: &str, id: u64, track_id: i64) -> io::Result<bool> {
        let mut collections = self
            .collections
            .write()
            .map_err(|_| io::Error::other("index des playlists verrouillé"))?;
        let Some(collection) = collections.get_mut(&collection_key(kind, id)) else {
            return Ok(false);
        };
        if collection.track_ids.contains(&track_id) {
            return Ok(false);
        }
        collection.track_ids.insert(0, track_id);
        drop(collections);
        self.persist_collections()?;
        Ok(true)
    }

    pub fn remove_collection(&self, kind: &str, id: u64) -> io::Result<Vec<i64>> {
        let Some(collection) = self
            .collections
            .write()
            .map_err(|_| io::Error::other("index des playlists verrouillé"))?
            .remove(&collection_key(kind, id))
        else {
            return Ok(Vec::new());
        };
        if let Some(cover) = &collection.cover {
            let _ = std::fs::remove_file(self.root.join(cover));
        }
        // Disque plein : la réécriture peut échouer, mais les titres sont quand même supprimés (c'est ce qui libère
        // la place), puis la réécriture est retentée.
        let saved = self.persist_collections();
        // Gardés : les titres d'une autre collection téléchargée, et ceux téléchargés pour eux-mêmes.
        let mut first = None;
        let removed = match self.remove_unused(&collection.track_ids) {
            Ok(removed) => removed,
            Err(error) => {
                first = Some(error);
                Vec::new()
            }
        };
        if saved.is_err() {
            keep_first(&mut first, self.persist_collections());
        }
        first.map_or(Ok(removed), Err)
    }

    /// Change l'identifiant d'une collection téléchargée (`from` → `to`), si `to` n'existe pas déjà. Sert aux Titres
    /// aimés : téléchargés avant sous l'identifiant 0, ils sont maintenant gardés sous celui de leur profil.
    pub fn rekey_collection(&self, kind: &str, from: u64, to: u64) -> io::Result<bool> {
        let (old, new) = (collection_key(kind, from), collection_key(kind, to));
        {
            // Lecture d'abord : appelé souvent, le plus souvent pour rien.
            let collections = self.collections.read().map_err(|_| io::Error::other("index des playlists verrouillé"))?;
            if from == to || !collections.contains_key(&old) || collections.contains_key(&new) {
                return Ok(false);
            }
        }
        {
            let mut collections = self.collections.write().map_err(|_| io::Error::other("index des playlists verrouillé"))?;
            if collections.contains_key(&new) {
                return Ok(false);
            }
            let Some(mut collection) = collections.remove(&old) else { return Ok(false) };
            collection.id = to;
            collections.insert(new, collection);
        }
        self.persist_collections()?;
        Ok(true)
    }

    /// Identifiant de la collection de ce type téléchargée le plus récemment.
    pub fn latest_collection_id(&self, kind: &str) -> Option<u64> {
        let collections = self.collections.read().ok()?;
        collections.values().filter(|c| c.kind == kind).max_by_key(|c| c.downloaded_at).map(|c| c.id)
    }

    /// Numéro changé à chaque effacement complet (déconnexion). Une écoute retient celui de son début : elle n'est plus
    /// gardée après une déconnexion, même si sa fin arrive juste après (sinon elle partirait au nom du compte suivant).
    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }

    /// Garde une écoute que le réseau n'a pas permis d'envoyer. `false` : compte déconnecté depuis, rien n'est gardé.
    pub fn queue_listen(&self, listen: PendingListen, generation: u64) -> io::Result<bool> {
        {
            let mut listens = self.listens.write().map_err(|_| io::Error::other("écoutes verrouillées"))?;
            // Vérifié sous le verrou : `clear` change le numéro avant de prendre ce même verrou.
            if self.generation() != generation {
                return Ok(false);
            }
            listens.queue.push(listen);
            let excess = listens.queue.len().saturating_sub(MAX_PENDING_LISTENS);
            listens.queue.drain(..excess);
        }
        self.persist_listens()?;
        Ok(true)
    }

    /// Écoutes en attente d'envoi, de la plus ancienne à la plus récente.
    pub fn pending_listens(&self) -> Vec<PendingListen> {
        self.listens.read().map(|l| l.queue.clone()).unwrap_or_default()
    }

    /// Retire une écoute envoyée (ou refusée par Deezer) de la file.
    pub fn remove_listen(&self, listen: &PendingListen) -> io::Result<()> {
        {
            let mut listens = self.listens.write().map_err(|_| io::Error::other("écoutes verrouillées"))?;
            let Some(index) = listens.queue.iter().position(|l| l == listen) else { return Ok(()) };
            listens.queue.remove(index);
        }
        // Fichier pas réécrit (disque plein) : l'écoute n'est plus en mémoire, elle ne repart donc plus pendant cette
        // session ; la prochaine écriture réussie l'efface du fichier. Au pire, un seul renvoi au lancement suivant.
        // (La remettre en mémoire la faisait renvoyer à Deezer à chaque envoi : comptée plusieurs fois.)
        self.persist_listens()
    }

    /// Écoute en cours mise de côté (à une pause) ou oubliée (`None`, à la fin de l'écoute). Rien n'est écrit si rien
    /// ne change : appelé à chaque changement de titre, ce n'est le plus souvent qu'une lecture en mémoire.
    /// Une écoute commencée avant une déconnexion n'est pas mise de côté (voir `generation`).
    pub fn set_open_listen(&self, listen: Option<PendingListen>, generation: u64) -> io::Result<()> {
        {
            let mut listens = self.listens.write().map_err(|_| io::Error::other("écoutes verrouillées"))?;
            if listen.is_some() && self.generation() != generation {
                return Ok(());
            }
            if listens.open == listen {
                return Ok(());
            }
            listens.open = listen;
        }
        // Mise de côté répétée pendant la lecture : écrite sans attendre l'écriture physique sur le disque (moins de
        // travail pour la puce de stockage et la batterie). Un plantage de l'app ne perd rien ; seule une coupure de
        // courant pourrait perdre les dernières secondes de durée de cette écoute.
        let _guard = self.persist_lock.lock().map_err(|_| io::Error::other("écriture des manifests verrouillée"))?;
        let bytes = {
            let listens = self.listens.read().map_err(|_| io::Error::other("index verrouillé"))?;
            serde_json::to_vec(&*listens).map_err(io::Error::other)?
        };
        write_replace(&self.root.join("listens.json"), &bytes, false)
    }

    /// Fin d'une écoute, en une seule écriture : l'écoute mise de côté est oubliée et, si elle compte (`Some`), elle
    /// rejoint la file des écoutes à envoyer. Écrite sur le disque AVANT tout envoi : l'app peut être fermée juste après
    /// (titre changé puis app fermée, sans réseau) sans que l'écoute soit perdue ni comptée deux fois.
    /// `false` : rien de mis en file (écoute trop courte, ou compte déconnecté depuis son début).
    pub fn close_listen(&self, listen: Option<PendingListen>, generation: u64) -> io::Result<bool> {
        let queued = {
            let mut listens = self.listens.write().map_err(|_| io::Error::other("écoutes verrouillées"))?;
            let had_open = listens.open.take().is_some();
            let queued = match listen {
                Some(listen) if self.generation() == generation => {
                    listens.queue.push(listen);
                    let excess = listens.queue.len().saturating_sub(MAX_PENDING_LISTENS);
                    listens.queue.drain(..excess);
                    true
                }
                _ => false,
            };
            if !had_open && !queued {
                return Ok(false); // rien n'a changé : aucune écriture
            }
            queued
        };
        self.persist_listens()?;
        Ok(queued)
    }

    /// Déconnexion : téléchargements et écoutes du compte.
    pub fn clear(&self) -> io::Result<()> {
        self.generation.fetch_add(1, Ordering::AcqRel);
        // Écoutes du compte qui se déconnecte : jamais envoyées au nom du compte suivant.
        if let Ok(mut listens) = self.listens.write() {
            *listens = ListensFile::default();
        }
        self.wipe(true)
    }

    /// « Tout effacer » des téléchargements : les écoutes pas encore envoyées et celle en cours restent (avant, elles
    /// étaient effacées avec, et le titre en cours n'était jamais compté).
    pub fn clear_downloads(&self) -> io::Result<()> {
        self.wipe(false)
    }

    fn wipe(&self, with_listens: bool) -> io::Result<()> {
        // Les téléchargements en cours ne seront pas enregistrés après l'effacement (voir `insert_if_current`).
        self.wipes.fetch_add(1, Ordering::AcqRel);
        // Tout est vidé en mémoire et sur le disque AVANT d'écrire quoi que ce soit : disque plein, la première écriture
        // échouait et rien n'était effacé (les téléchargements du compte précédent restaient).
        if let Ok(mut pending) = self.pending.write() {
            pending.clear();
        }
        if let Ok(mut entries) = self.entries.write() {
            entries.clear();
        }
        if let Ok(mut collections) = self.collections.write() {
            collections.clear();
        }
        // Manifests vides écrits AVANT de supprimer les fichiers : l'app tuée entre les deux laissait sinon les
        // playlists de l'ancien compte (titres à 0/N), que la synchro retéléchargeait pour le compte suivant.
        let mut written = vec![
            ("pending.json", self.persist_pending()),
            ("downloads.json", self.persist()),
            ("collections.json", self.persist_collections()),
        ];
        if with_listens {
            written.insert(0, ("listens.json", self.persist_listens()));
        }
        let _ = std::fs::remove_file(self.root.join(JOURNAL));
        // Listes illisibles mises de côté : elles gardaient les titres et playlists du compte effacé.
        for name in ["downloads.json.corrupt", "collections.json.corrupt"] {
            let _ = std::fs::remove_file(self.root.join(name));
        }
        if with_listens {
            let _ = std::fs::remove_file(self.root.join("listens.json.corrupt"));
        }
        for folder in ["audio", "covers", "lyrics"] {
            if let Ok(files) = std::fs::read_dir(self.root.join(folder)) {
                for path in files.flatten().map(|f| f.path()) {
                    let _ = std::fs::remove_file(path);
                }
            }
        }
        // Écriture ratée (disque plein) : réessayée maintenant que la place est libérée, sinon le fichier est supprimé
        // (absent, il se lit comme vide).
        let mut first = None;
        for (name, result) in written {
            if result.is_ok() {
                continue;
            }
            let retried = match name {
                "listens.json" => self.persist_listens(),
                "pending.json" => self.persist_pending(),
                "downloads.json" => self.persist(),
                _ => self.persist_collections(),
            };
            if let Err(error) = retried {
                match std::fs::remove_file(self.root.join(name)) {
                    Ok(()) => {}
                    Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                    Err(_) => {
                        first.get_or_insert(error);
                    }
                }
            }
        }
        first.map_or(Ok(()), Err)
    }

    fn display_info(&self, entry: &OfflineTrack) -> TrackInfo {
        let mut info = entry.info.clone();
        if let Some(cover) = &entry.cover {
            let path = self.root.join(cover);
            if path.exists() {
                info.cover_url = Some(path.to_string_lossy().into_owned());
            }
        }
        info
    }

    fn display_collection(&self, collection: &OfflineCollection) -> OfflineCollection {
        let mut collection = collection.clone();
        if let Some(cover) = &collection.cover {
            let path = self.root.join(cover);
            if path.exists() {
                collection.cover_url = Some(path.to_string_lossy().into_owned());
            }
        }
        collection
    }

    /// Utilisé par les tests ; les téléchargements passent par `insert_if_current` / `insert_if_pending`.
    #[cfg(test)]
    fn insert(&self, entry: OfflineTrack) -> io::Result<()> {
        self.insert_if_current(entry, self.wipes.load(Ordering::Acquire)).map(|_| ())
    }

    /// Enregistre un titre seulement si aucun effacement complet n'a eu lieu depuis le début de son téléchargement.
    fn insert_if_current(&self, mut entry: OfflineTrack, wipes: u64) -> io::Result<bool> {
        entry.pinned |= !self.in_collection(entry.info.id);
        // Verrou des écritures pris d'abord (même ordre que `write_manifest`) : la ligne du journal ne peut pas arriver
        // après une réécriture complète qui aurait déjà retiré ce titre.
        let _guard = self.persist_lock.lock().map_err(|_| io::Error::other("écriture des manifests verrouillée"))?;
        let previous = {
            let mut entries = self.entries.write().map_err(|_| io::Error::other("index des téléchargements verrouillé"))?;
            if self.wipes.load(Ordering::Acquire) != wipes {
                return Ok(false);
            }
            entry.pinned |= entries.get(&entry.info.id).is_some_and(|old| old.pinned);
            entries.insert(entry.info.id, entry.clone())
        };
        if let Err(error) = self.journal_entry_locked(&entry) {
            // Pas enregistré sur le disque (plein) : il ne doit pas apparaître téléchargé en mémoire non plus.
            self.restore_entry(entry.info.id, previous);
            return Err(error);
        }
        Ok(true)
    }

    /// Enregistre un titre importé seulement s'il est encore attendu : annulé (ou compte déconnecté) pendant
    /// le déchiffrement, il n'est pas remis dans les téléchargements.
    fn insert_if_pending(&self, mut entry: OfflineTrack) -> io::Result<bool> {
        let guard = self.persist_lock.lock().map_err(|_| io::Error::other("écriture des manifests verrouillée"))?;
        let (job, previous) = {
            let mut pending = self.pending.write().map_err(|_| io::Error::other("file des téléchargements verrouillée"))?;
            let Some(job) = pending.remove(&entry.info.id) else {
                return Ok(false);
            };
            let mut entries = self.entries.write().map_err(|_| io::Error::other("index des téléchargements verrouillé"))?;
            entry.pinned |= job.pinned || entries.get(&entry.info.id).is_some_and(|old| old.pinned);
            let previous = entries.insert(entry.info.id, entry.clone());
            (job, previous)
        };
        if let Err(error) = self.journal_entry_locked(&entry) {
            drop(guard);
            // Pas enregistré (disque plein) : retour à l'état d'avant, le titre reste attendu.
            self.restore_entry(entry.info.id, previous);
            if let Ok(mut pending) = self.pending.write() {
                pending.entry(entry.info.id).or_insert(job);
            }
            return Err(error);
        }
        drop(guard);
        // Titre enregistré : si la file ne peut pas être réécrite, il en est retiré au prochain lancement (voir `open`).
        let _ = self.persist_pending();
        Ok(true)
    }

    /// Annule un ajout en mémoire : remet l'ancienne fiche du titre s'il y en avait une, sinon le retire.
    fn restore_entry(&self, id: i64, previous: Option<OfflineTrack>) {
        if let Ok(mut entries) = self.entries.write() {
            match previous {
                Some(old) => {
                    entries.insert(id, old);
                }
                None => {
                    entries.remove(&id);
                }
            }
        }
    }

    fn insert_collection(&self, collection: OfflineCollection) -> io::Result<()> {
        self.collections
            .write()
            .map_err(|_| io::Error::other("index des playlists verrouillé"))?
            .insert(collection.key(), collection);
        self.persist_collections()
    }

    /// Instantané pris sous le verrou d'écriture : le dernier écrit est toujours le plus récent.
    fn write_manifest<T: Serialize>(&self, name: &str, value: &RwLock<T>) -> io::Result<()> {
        let _guard = self.persist_lock.lock().map_err(|_| io::Error::other("écriture des manifests verrouillée"))?;
        let bytes = {
            let value = value.read().map_err(|_| io::Error::other("index verrouillé"))?;
            serde_json::to_vec(&*value).map_err(io::Error::other)?
        };
        write_atomic(&self.root.join(name), &bytes)
    }

    /// Réécriture complète de `downloads.json` (le journal y est alors fondu et vidé).
    fn persist(&self) -> io::Result<()> {
        let _guard = self.persist_lock.lock().map_err(|_| io::Error::other("écriture des manifests verrouillée"))?;
        self.persist_entries_locked()
    }

    /// À appeler sous `persist_lock`.
    fn persist_entries_locked(&self) -> io::Result<()> {
        let bytes = {
            let entries = self.entries.read().map_err(|_| io::Error::other("index verrouillé"))?;
            serde_json::to_vec(&*entries).map_err(io::Error::other)?
        };
        write_atomic(&self.root.join("downloads.json"), &bytes)?;
        match std::fs::remove_file(self.root.join(JOURNAL)) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            // Journal resté là : relu au lancement, ses lignes redonnent les mêmes titres (sans effet).
            Err(_) => {}
        }
        self.journal_len.store(0, Ordering::Release);
        Ok(())
    }

    /// Ajoute un titre au journal (une ligne, écrite jusqu'au disque) ; toutes les `JOURNAL_MAX` lignes, réécriture
    /// complète à la place. À appeler sous `persist_lock`, après l'avoir mis dans `entries`.
    fn journal_entry_locked(&self, entry: &OfflineTrack) -> io::Result<()> {
        use std::io::Write as _;
        if self.journal_len.load(Ordering::Acquire) >= JOURNAL_MAX as u64 {
            return self.persist_entries_locked();
        }
        // Saut de ligne AVANT aussi : une ligne coupée net (coupure de courant) ne se colle plus à la suivante, qui était
        // alors illisible (titre perdu, son audio effacé comme orphelin). Les lignes vides sont ignorées à la lecture.
        let mut line = vec![b'\n'];
        line.extend(serde_json::to_vec(entry).map_err(io::Error::other)?);
        line.push(b'\n');
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(self.root.join(JOURNAL))?;
        let start = file.metadata()?.len();
        if let Err(error) = file.write_all(&line).and_then(|()| file.sync_data()) {
            // Ligne à moitié écrite (disque plein) : retirée, sinon la suivante s'y collerait et les deux seraient perdues.
            let _ = file.set_len(start);
            return Err(error);
        }
        self.journal_len.fetch_add(1, Ordering::AcqRel);
        Ok(())
    }

    /// Pas d'écriture physique attendue : la file n'est qu'une aide (l'app garde sa propre liste des téléchargements
    /// en cours et redemande ceux qui manquent), et elle est réécrite à chaque titre.
    fn persist_pending(&self) -> io::Result<()> {
        let _guard = self.persist_lock.lock().map_err(|_| io::Error::other("écriture des manifests verrouillée"))?;
        let bytes = {
            let pending = self.pending.read().map_err(|_| io::Error::other("index verrouillé"))?;
            serde_json::to_vec(&*pending).map_err(io::Error::other)?
        };
        write_replace(&self.root.join("pending.json"), &bytes, false)
    }

    /// Parmi ces pochettes, celles qu'aucun titre ni aucune collection n'utilise plus (à supprimer du disque).
    fn unused_covers(&self, candidates: Vec<String>) -> Vec<String> {
        if candidates.is_empty() {
            return candidates;
        }
        let mut used: BTreeSet<String> =
            self.entries.read().map(|e| e.values().filter_map(|entry| entry.cover.clone()).collect()).unwrap_or_default();
        if let Ok(collections) = self.collections.read() {
            used.extend(collections.values().filter_map(|c| c.cover.clone()));
        }
        let mut seen = BTreeSet::new();
        candidates.into_iter().filter(|cover| !used.contains(cover) && seen.insert(cover.clone())).collect()
    }

    fn persist_collections(&self) -> io::Result<()> {
        self.write_manifest("collections.json", &*self.collections)
    }

    fn persist_listens(&self) -> io::Result<()> {
        self.write_manifest("listens.json", &*self.listens)
    }

    #[cfg(test)]
    fn update_cover(&self, id: i64, cover: String) -> io::Result<()> {
        self.apply_cover_updates(&[CoverUpdate { id, cover: Some(cover), url: None, failed: false }]).map(|_| ())
    }

    /// Applique un paquet de vérifications de pochettes en une seule écriture du manifest. Renvoie les anciennes
    /// images remplacées (à supprimer du disque).
    fn apply_cover_updates(&self, updates: &[CoverUpdate]) -> io::Result<Vec<String>> {
        if updates.is_empty() {
            return Ok(Vec::new());
        }
        let mut replaced = Vec::new();
        let mut changed = Vec::new();
        // Verrou des écritures d'abord (même ordre que `write_manifest`).
        let _guard = self.persist_lock.lock().map_err(|_| io::Error::other("écriture des manifests verrouillée"))?;
        {
            let mut entries = self.entries.write().map_err(|_| io::Error::other("index des téléchargements verrouillé"))?;
            for update in updates {
                // Titre supprimé pendant la vérification : rien à faire.
                let Some(entry) = entries.get_mut(&update.id) else { continue };
                changed.push(update.id);
                if let Some(cover) = &update.cover {
                    if let Some(old) = entry.cover.replace(cover.clone()).filter(|old| old != cover) {
                        replaced.push(old);
                    }
                }
                if update.failed {
                    entry.cover_tries = entry.cover_tries.saturating_add(1);
                    entry.cover_retry_at = now_s() + cover_retry_delay(entry.cover_tries);
                    continue;
                }
                if let Some(url) = &update.url {
                    entry.info.cover_url = Some(url.clone());
                }
                entry.cover_version = COVER_VERSION;
                entry.cover_tries = 0;
                entry.cover_retry_at = 0;
            }
        }
        // Peu de titres (pochette d'un titre qui vient d'être téléchargé) : une ligne de journal chacun ; un gros lot
        // (vérification de toute la bibliothèque) : une seule réécriture complète.
        if changed.len() > 10 {
            self.persist_entries_locked()?;
        } else {
            for id in changed {
                let entry = self.entries.read().ok().and_then(|e| e.get(&id).cloned());
                if let Some(entry) = entry {
                    self.journal_entry_locked(&entry)?;
                }
            }
        }
        // Une image remplacée peut servir encore à d'autres titres du même album.
        Ok(self.unused_covers(replaced))
    }

    fn update_collection_cover(&self, kind: &str, id: u64, cover: String) -> io::Result<()> {
        let mut collections = self.collections.write().map_err(|_| io::Error::other("index des playlists verrouillé"))?;
        if let Some(collection) = collections.get_mut(&collection_key(kind, id)) {
            collection.cover = Some(cover);
            drop(collections);
            self.persist_collections()?;
        }
        Ok(())
    }
}

/// Titres retirés d'une collection à la synchro au-delà desquels on soupçonne une réponse incomplète : 20, ou un quart
/// de la collection si elle est grande.
fn sync_removal_limit(previous: usize) -> usize {
    (previous / 4).max(20)
}

pub async fn store_collection(api: Arc<DeezerClient>, store: OfflineStore, collection: OfflineCollection) -> Result<OfflineCollection, DownloadError> {
    store_collection_removing(api, store, collection).await.map(|(saved, _)| saved)
}

/// Comme `store_collection`, avec les titres retirés du téléphone parce qu'ils ne sont plus dans la collection chez
/// Deezer (l'app annule leur téléchargement s'il était encore en attente).
pub async fn store_collection_removing(
    api: Arc<DeezerClient>,
    store: OfflineStore,
    mut collection: OfflineCollection,
) -> Result<(OfflineCollection, Vec<i64>), DownloadError> {
    let kind = collection.kind.clone();
    let id = collection.id;
    let previous = store.collections.read().ok().and_then(|collections| collections.get(&collection_key(&kind, id)).cloned());
    let previous_cover = previous.as_ref().and_then(|saved| {
        saved.cover.as_ref().filter(|cover| store.root.join(cover).is_file()).cloned()
    });
    // Adresse locale (copie hors ligne affichée) ou absente : on garde l'adresse Deezer déjà enregistrée,
    // sinon la pochette serait perdue puis effacée comme orpheline.
    if !collection.cover_url.as_deref().is_some_and(is_remote) {
        if let Some(saved) = &previous {
            collection.cover_url = saved.cover_url.clone();
        }
    }
    let same_url = previous.as_ref().is_some_and(|saved| saved.cover_url == collection.cover_url);
    // L'ancienne pochette reste en place pendant le téléchargement de la nouvelle (gardée si celui-ci échoue).
    collection.cover = previous_cover.clone();
    // Titres retirés de la collection chez Deezer (synchro) : plus téléchargés, sauf s'ils l'ont été pour eux-mêmes ou
    // restent dans une autre collection. Une liste bien plus courte qu'avant peut venir d'une réponse incomplète de
    // Deezer (page manquante) : rien n'est supprimé dans ce cas, mieux vaut garder des titres en trop qu'en perdre.
    // Ils restent alors dans la collection : sortis de toute collection, ils devenaient des titres téléchargés seuls,
    // gardés pour toujours (même la collection supprimée).
    let dropped: Vec<i64> = previous.as_ref().map_or_else(Vec::new, |saved| {
        let kept: BTreeSet<i64> = collection.track_ids.iter().copied().collect();
        saved.track_ids.iter().copied().filter(|id| !kept.contains(id)).collect()
    });
    let suspicious = previous.as_ref().is_some_and(|saved| dropped.len() > sync_removal_limit(saved.track_ids.len()));
    if suspicious {
        collection.track_ids.extend(dropped.iter().copied());
    }
    store.insert_collection(collection.clone())?;
    let removed = if suspicious || dropped.is_empty() { Vec::new() } else { store.remove_unused(&dropped)? };
    if !(same_url && previous_cover.is_some()) {
        if let Some(url) = collection.cover_url.as_deref().filter(|url| is_remote(url)) {
            let safe_kind: String = kind.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
            let relative = PathBuf::from("covers").join(format!("collection-{safe_kind}-{id}-v1.jpg"));
            if let Some(cover) = download_image(&api, &store.root, url, relative).await {
                store.update_collection_cover(&kind, id, cover)?;
            }
        }
    }
    Ok((store.collection(&kind, id).map(|(collection, _)| collection).unwrap_or(collection), removed))
}

pub async fn download_track(
    api: Arc<DeezerClient>,
    store: OfflineStore,
    info: TrackInfo,
    quality: Quality,
    cancelled: Arc<AtomicBool>,
    progress: impl Fn(u64, Option<u64>) + Send + Sync,
) -> Result<OfflineTrack, DownloadError> {
    let wipes = store.wipes.load(Ordering::Acquire);
    let id = info.id;
    let resolved = api.media_with_recovery(id, Some(info), quality).await?;
    let (media, stream_id, mut info) = (resolved.media, resolved.stream_id, resolved.info);
    let dec: Arc<dyn ChunkDecryptor> = match media.cipher {
        Cipher::None => Arc::new(Passthrough),
        Cipher::BlockStripe => dz_decrypt::decryptor(stream_id),
        Cipher::Other(kind) => return Err(DownloadError::Cipher(kind)),
    };
    let ext = if media.format.to_ascii_uppercase().starts_with("FLAC") { "flac" } else { "mp3" };
    info.quality = Some(dz_api::format_label(&media.format));
    info.track_token = None;

    let response = api.http().get(media.url).send().await?.error_for_status()?;
    let total = response.content_length();
    let mut stream = response.bytes_stream();
    let part = store.root.join("audio").join(format!("{id}.part"));
    let final_path = audio_path(&store.root, id, ext);
    let mut file = tokio::fs::File::create(&part).await?;
    let mut pending = Vec::with_capacity(CHUNK * 4);
    let mut index = 0u64;
    let mut written = 0u64;

    let result = async {
        while let Some(bytes) = stream.next().await {
            if cancelled.load(Ordering::Relaxed) {
                return Err(DownloadError::Cancelled);
            }
            pending.extend_from_slice(&bytes?);
            let full = pending.len() / CHUNK * CHUNK;
            if full == 0 {
                continue;
            }
            let mut ready: Vec<u8> = pending.drain(..full).collect();
            for chunk in ready.chunks_exact_mut(CHUNK) {
                dec.decrypt_chunk(index, chunk);
                index += 1;
            }
            file.write_all(&ready).await?;
            written += ready.len() as u64;
            progress(written + pending.len() as u64, total);
        }
        if cancelled.load(Ordering::Relaxed) {
            return Err(DownloadError::Cancelled);
        }
        if !pending.is_empty() {
            file.write_all(&pending).await?;
            written += pending.len() as u64;
        }
        file.flush().await?;
        file.sync_all().await?;
        if total.is_some_and(|expected| expected != written) {
            return Err(DownloadError::Incomplete);
        }
        progress(written, total);
        Ok(())
    }
    .await;

    drop(file);
    if let Err(error) = result {
        let _ = tokio::fs::remove_file(&part).await;
        return Err(error);
    }
    // Même vérification que pour les téléchargements natifs : un mauvais déchiffrement n'est pas enregistré.
    if !valid_audio(&part, ext).await? {
        let _ = tokio::fs::remove_file(&part).await;
        return Err(DownloadError::InvalidAudio);
    }
    let _ = tokio::fs::remove_file(&final_path).await;
    tokio::fs::rename(&part, &final_path).await?;

    // Enregistré tout de suite, sans attendre la pochette ni les paroles (récupérées juste après, en arrière-plan).
    let entry = OfflineTrack {
        info,
        ext: ext.into(),
        bytes: written,
        downloaded_at: SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs(),
        cover_version: 0,
        cover: None,
        pinned: false, // décidé à l'enregistrement
        cover_tries: 0,
        cover_retry_at: 0,
    };
    // Écriture sur le disque hors des deux threads du cœur (partagés avec le lecteur).
    let saving = (store.clone(), entry.clone());
    let saved = tokio::task::spawn_blocking(move || saving.0.insert_if_current(saving.1, wipes))
        .await
        .unwrap_or_else(|error| Err(io::Error::other(error)));
    match saved {
        Ok(true) => {
            fetch_extras(api, store, entry.clone());
            Ok(entry)
        }
        Ok(false) => {
            discard(&store, &final_path, entry.cover.as_deref()).await;
            Err(DownloadError::Cancelled)
        }
        Err(error) => {
            discard(&store, &final_path, entry.cover.as_deref()).await;
            Err(error.into())
        }
    }
}

/// Copie déchiffrée d'un fichier téléchargé par iOS. Synchrone : appelée dans `spawn_blocking`, pour que le
/// déchiffrement (gourmand en CPU) n'occupe pas les deux threads du runtime partagés avec le lecteur.
fn decrypt_file(source: &Path, part: &Path, dec: &dyn ChunkDecryptor) -> Result<u64, DownloadError> {
    use std::io::{Read as _, Write as _};
    let mut input = std::fs::File::open(source)?;
    let mut output = std::io::BufWriter::new(std::fs::File::create(part)?);
    let mut buffer = vec![0u8; CHUNK * 64];
    let mut tail: Vec<u8> = Vec::with_capacity(CHUNK * 65);
    let mut index = 0u64;
    let mut written = 0u64;
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        tail.extend_from_slice(&buffer[..count]);
        let full = tail.len() / CHUNK * CHUNK;
        if full == 0 {
            continue;
        }
        for chunk in tail[..full].chunks_exact_mut(CHUNK) {
            dec.decrypt_chunk(index, chunk);
            index += 1;
        }
        output.write_all(&tail[..full])?;
        written += full as u64;
        tail.drain(..full);
    }
    if written == 0 {
        return Err(DownloadError::Incomplete);
    }
    if !tail.is_empty() {
        output.write_all(&tail)?;
        written += tail.len() as u64;
    }
    let file = output.into_inner().map_err(|error| error.into_error())?;
    file.sync_all()?;
    Ok(written)
}

pub async fn import_download(
    api: Arc<DeezerClient>,
    store: OfflineStore,
    pending: PendingDownload,
    source: PathBuf,
) -> Result<OfflineTrack, DownloadError> {
    let PendingDownload { info, stream_id, ext, encrypted, .. } = pending;
    let id = info.id;
    let dec: Arc<dyn ChunkDecryptor> = if encrypted { dz_decrypt::decryptor(stream_id) } else { Arc::new(Passthrough) };
    let part = store.root.join("audio").join(format!("{id}.part"));
    let final_path = audio_path(&store.root, id, &ext);

    let blocking_part = part.clone();
    let result = tokio::task::spawn_blocking(move || decrypt_file(&source, &blocking_part, dec.as_ref()))
        .await
        .map_err(|error| DownloadError::Io(io::Error::other(error)))
        .and_then(|result| result);
    let written = match result {
        Ok(written) => written,
        Err(error) => {
            let _ = tokio::fs::remove_file(&part).await;
            return Err(error);
        }
    };
    if !valid_audio(&part, &ext).await? {
        let _ = tokio::fs::remove_file(&part).await;
        return Err(DownloadError::InvalidAudio);
    }
    let _ = tokio::fs::remove_file(&final_path).await;
    tokio::fs::rename(&part, &final_path).await?;
    // Enregistré tout de suite : avant, l'app attendait la pochette (jusqu'à une dizaine de requêtes) et les paroles
    // (jusqu'à 3 essais de 20 s) avant de considérer le titre téléchargé, titre après titre. Elles suivent en arrière-plan.
    let entry = OfflineTrack {
        info,
        ext,
        bytes: written,
        downloaded_at: SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs(),
        cover_version: 0,
        cover: None,
        pinned: false, // décidé à l'enregistrement
        cover_tries: 0,
        cover_retry_at: 0,
    };
    let saving = (store.clone(), entry.clone());
    let saved = tokio::task::spawn_blocking(move || saving.0.insert_if_pending(saving.1))
        .await
        .unwrap_or_else(|error| Err(io::Error::other(error)));
    match saved {
        Ok(true) => {
            fetch_extras(api, store, entry.clone());
            Ok(entry)
        }
        Ok(false) => {
            discard(&store, &final_path, entry.cover.as_deref()).await;
            Err(DownloadError::Cancelled)
        }
        Err(error) => {
            discard(&store, &final_path, entry.cover.as_deref()).await;
            Err(error.into())
        }
    }
}

/// Pochette et paroles d'un titre qui vient d'être enregistré, en arrière-plan. Sans réseau ou sans session, rien n'est
/// marqué : la vérification des pochettes et la récupération des paroles à l'ouverture de la session s'en chargent.
fn fetch_extras(api: Arc<DeezerClient>, store: OfflineStore, entry: OfflineTrack) {
    tokio::spawn(async move {
        let id = entry.info.id;
        let mut info = entry.info;
        let original = info.cover_url.clone();
        let cover = download_cover(&api, &store.root, &mut info).await;
        let connected = api.session().await.is_some();
        if cover.is_some() || connected {
            let url = info.cover_url.filter(|url| original.as_ref() != Some(url));
            let update = CoverUpdate { id, cover: cover.clone(), url, failed: cover.is_none() };
            if let Ok(replaced) = store.apply_cover_updates(&[update]) {
                for old in replaced {
                    let _ = tokio::fs::remove_file(store.root.join(old)).await;
                }
            }
        }
        // Titre supprimé pendant ce temps : l'image n'est plus utile.
        for unused in store.unused_covers(cover.into_iter().collect()) {
            let _ = tokio::fs::remove_file(store.root.join(unused)).await;
        }
        fetch_lyrics_if_connected(&api, &store, id).await;
    });
}

/// Fichiers d'un titre finalement non enregistré (annulé pendant son téléchargement).
async fn discard(store: &OfflineStore, audio: &Path, cover: Option<&str>) {
    let _ = tokio::fs::remove_file(audio).await;
    // Pochette partagée avec un autre titre du même album : gardée.
    for cover in store.unused_covers(cover.into_iter().map(str::to_owned).collect()) {
        let _ = tokio::fs::remove_file(store.root.join(cover)).await;
    }
}

/// Paroles d'un titre qui vient d'être téléchargé. Seulement si une session est ouverte : sinon (app lancée sans
/// réseau), elles seront récupérées par `repair_lyrics` à l'ouverture de la session. Un échec ne bloque jamais le titre.
async fn fetch_lyrics_if_connected(api: &DeezerClient, store: &OfflineStore, id: i64) {
    if api.session().await.is_some() {
        let _ = fetch_lyrics(api, store, id).await;
    }
}

/// Demande les paroles d'un titre à Deezer et les garde sur le téléphone (absence de paroles comprise).
async fn fetch_lyrics(api: &DeezerClient, store: &OfflineStore, id: i64) -> LyricsFetch {
    let found = match api.lyrics(id).await {
        Ok(found) => found,
        Err(dz_api::DeezerError::Http(e)) if e.is_connect() || e.is_timeout() => return LyricsFetch::Offline,
        Err(dz_api::DeezerError::InvalidArl | dz_api::DeezerError::SessionExpired) => return LyricsFetch::Offline,
        // Trop de requêtes : Deezer refuse tout pendant un moment, inutile de continuer avec les titres suivants.
        Err(dz_api::DeezerError::Gateway(g)) if g.to_ascii_uppercase().contains("QUOTA") => return LyricsFetch::Offline,
        Err(_) => return LyricsFetch::Failed,
    };
    // Titre supprimé pendant la demande : rien n'est gardé (voir `save_lyrics`).
    match store.save_lyrics(id, found.map(stored_lyrics)) {
        Ok(()) => LyricsFetch::Stored,
        Err(_) => LyricsFetch::Failed,
    }
}

pub fn stored_lyrics(l: dz_api::Lyrics) -> StoredLyrics {
    StoredLyrics {
        synced: l.synced,
        lines: l.lines.into_iter().map(|x| StoredLyricLine { ms: x.ms, text: x.text }).collect(),
        copyright: l.copyright,
    }
}

/// Récupère les paroles des titres téléchargés qui n'en ont pas encore (téléchargés avant cette version, ou sans réseau
/// à ce moment-là). À lancer une fois la session Deezer ouverte ; s'arrête au premier signe d'absence de réseau.
pub async fn repair_lyrics(api: Arc<DeezerClient>, store: OfflineStore) {
    if REPAIRING_LYRICS.swap(true, Ordering::AcqRel) {
        return;
    }
    struct Release;
    impl Drop for Release {
        fn drop(&mut self) {
            REPAIRING_LYRICS.store(false, Ordering::Release);
        }
    }
    let _release = Release;
    // Absentes, illisibles (fichier abîmé), ou sans paroles synchronisées depuis plus d'une semaine : redemandées.
    let ids: Vec<i64> = store.entries.read().map(|e| e.keys().copied().collect()).unwrap_or_default();
    let missing: Vec<i64> = ids.into_iter().filter(|id| store.lyrics_due(*id)).take(LYRICS_RECHECK_MAX).collect();
    // Par petits paquets : quelques requêtes à la fois, et arrêt dès que le réseau manque.
    for chunk in missing.chunks(3) {
        let results = futures_util::future::join_all(chunk.iter().map(|id| fetch_lyrics(&api, &store, *id))).await;
        if results.contains(&LyricsFetch::Offline) {
            return;
        }
    }
}

/// Vérifie une fois les pochettes des titres téléchargés en version < `COVER_VERSION`, ou dont l'image manque : une
/// pochette supprimée par Deezer avait pu être gardée comme une image toute blanche, ou réparée avec la pochette d'un
/// autre titre. À lancer une fois la session ouverte : les adresses d'origine sont redemandées à Deezer (une requête
/// pour 100 titres), puis chaque pochette est réparée titre par titre si besoin. Sans réseau ou sans session, rien
/// n'est marqué vérifié et tout reprend plus tard. Le manifest est écrit par paquets (pas une écriture par titre).
pub async fn repair_covers(api: Arc<DeezerClient>, store: OfflineStore) {
    // Lancée au démarrage puis à l'ouverture de la session : une seule à la fois.
    if REPAIRING_COVERS.swap(true, Ordering::AcqRel) {
        return;
    }
    struct Release;
    impl Drop for Release {
        fn drop(&mut self) {
            REPAIRING_COVERS.store(false, Ordering::Release);
        }
    }
    let _release = Release;
    // Pas encore de session (démarrage, ou sans réseau) : relancée à l'ouverture de la session.
    if api.session().await.is_none() {
        return;
    }
    let entries = covers_to_check(&store);
    if entries.is_empty() {
        return;
    }
    // Adresses d'origine chez Deezer (celle gardée peut être une réparation fausse) : par paquets de 100.
    let ids: Vec<i64> = entries.iter().map(|e| e.info.id).collect();
    let mut originals: BTreeMap<i64, String> = BTreeMap::new();
    for chunk in ids.chunks(100) {
        match api.tracks_info(chunk).await {
            Ok(found) => originals.extend(found.into_iter().filter_map(|t| Some((t.id, t.cover_url?)))),
            // Pas de réseau, ou Deezer ne répond pas : tout reprend plus tard.
            Err(_) => return,
        }
    }
    check_covers(&api, &store, entries, &originals).await;
}

/// Titres dont la pochette est à vérifier : jamais vérifiée dans la version actuelle, ou image absente du téléphone.
fn covers_to_check(store: &OfflineStore) -> Vec<OfflineTrack> {
    let now = now_s();
    store
        .list()
        .into_iter()
        .filter(|entry| {
            let remote = entry.info.cover_url.as_deref().is_some_and(is_remote);
            let missing = entry.cover.as_ref().is_none_or(|cover| !store.root.join(cover).exists());
            // Déjà cherchée sans succès : pas avant le délai (1 jour, 7 jours, puis 30 jours).
            let due = entry.cover_retry_at <= now;
            remote && due && (entry.cover_version < COVER_VERSION || missing)
        })
        .collect()
}

/// Vérifie un lot de pochettes, 3 à la fois, et enregistre les résultats par paquets de 30.
async fn check_covers(api: &DeezerClient, store: &OfflineStore, entries: Vec<OfflineTrack>, originals: &BTreeMap<i64, String>) {
    let mut checks = futures_util::stream::iter(entries)
        .map(|entry| {
            let original = originals.get(&entry.info.id).cloned();
            let root = store.root.clone();
            let id = entry.info.id;
            async move {
                check_cover(api, &root, entry, original).await.unwrap_or(CoverUpdate { id, cover: None, url: None, failed: true })
            }
        })
        .buffer_unordered(3)
        .ready_chunks(30);
    while let Some(batch) = checks.next().await {
        let updates: Vec<CoverUpdate> = batch;
        if let Ok(replaced) = store.apply_cover_updates(&updates) {
            for old in replaced {
                let _ = tokio::fs::remove_file(store.root.join(old)).await;
            }
        }
    }
}

/// md5 d'une adresse de pochette Deezer (`…/images/cover/<md5>/…`).
fn cover_md5(url: &str) -> Option<&str> {
    url.split("/images/cover/").nth(1)?.split('/').next()
}

/// Vérifie la pochette d'un titre téléchargé, en partant de son adresse d'origine chez Deezer (`original` ; à défaut,
/// celle gardée). `None` : rien à changer pour l'instant (pas de réseau, ou aucune vraie image trouvée : revérifiée
/// plus tard).
async fn check_cover(api: &DeezerClient, root: &Path, entry: OfflineTrack, original: Option<String>) -> Option<CoverUpdate> {
    let id = entry.info.id;
    let stored = entry.info.cover_url.clone()?;
    let has_file = entry.cover.as_ref().is_some_and(|cover| root.join(cover).is_file());
    let base = original.unwrap_or_else(|| stored.clone());
    // La bonne pochette de ce titre : celle d'origine si elle existe en entier, sinon sa réparation (album, puis
    // sortie vers laquelle Deezer redirige ce titre).
    let expected = api.repaired_track_cover(&base, entry.info.album_id, id).await.unwrap_or(base);
    // Déjà la bonne image, gardée par une version qui refusait l'image vide : notée vérifiée, sans retélécharger.
    if has_file && entry.cover_version >= 2 && cover_md5(&expected).is_some() && cover_md5(&expected) == cover_md5(&stored) {
        return Some(CoverUpdate { id, cover: None, url: None, failed: false });
    }
    // Image vide refusée : sans vraie image (pas de réseau, rien trouvé), on revérifiera plus tard.
    let cover = shared_cover(api, root, &expected, id).await?;
    let url = (expected != stored).then_some(expected);
    Some(CoverUpdate { id, cover: Some(cover), url, failed: false })
}

/// Télécharge la pochette d'un titre. Pochette supprimée par Deezer : remplacée titre par titre (pochette actuelle de
/// l'album, ou celle de la sortie vers laquelle Deezer redirige ce titre si l'album a été retiré) ; l'adresse de
/// `info` est mise à jour, pour l'affichage et les vérifications suivantes. `None` : aucune vraie image trouvée.
async fn download_cover(api: &DeezerClient, root: &Path, info: &mut TrackInfo) -> Option<String> {
    let url = info.cover_url.clone()?;
    if let Some(fixed) = api.repaired_track_cover(&url, info.album_id, info.id).await {
        info.cover_url = Some(fixed);
    }
    let url = info.cover_url.as_deref()?;
    shared_cover(api, root, url, info.id).await
}

/// Pochette d'un titre, partagée par tous les titres qui ont la même image chez Deezer (nommée d'après elle) : un album
/// de 20 titres ne la télécharge et ne la garde plus qu'une fois. Nom propre à cette version, pour qu'une image
/// remplacée ne soit pas confondue avec l'ancienne dans le cache des pochettes. Adresse sans image Deezer reconnaissable :
/// nommée d'après le titre, comme avant.
async fn shared_cover(api: &DeezerClient, root: &Path, url: &str, id: i64) -> Option<String> {
    let md5 = cover_md5(url).filter(|md5| md5.len() == 32 && md5.chars().all(|c| c.is_ascii_hexdigit()) && !is_empty_picture(md5));
    let relative = PathBuf::from("covers").join(match md5 {
        Some(md5) => format!("{md5}-v{COVER_VERSION}.jpg"),
        None => format!("{id}-v{COVER_VERSION}.jpg"),
    });
    // Déjà là (autre titre du même album) : rien à télécharger. Seulement pour une image nommée d'après Deezer : un
    // fichier nommé d'après le titre peut être une ancienne image.
    if md5.is_some() && tokio::fs::metadata(root.join(&relative)).await.is_ok_and(|m| m.is_file() && m.len() > 0) {
        return Some(relative.to_string_lossy().into_owned());
    }
    download_image(api, root, url, relative).await
}

async fn download_image(api: &DeezerClient, root: &Path, url: &str, relative: PathBuf) -> Option<String> {
    const MAX_COVER_BYTES: u64 = 20 * 1024 * 1024;
    if !is_remote(url) {
        return None;
    }
    let large = large_cover_url(url);
    for candidate in [large.as_str(), url] {
        let Ok(response) = api.http().get(candidate).send().await else { continue };
        let Ok(response) = response.error_for_status() else { continue };
        // Redirigé vers l'image vide (pochette supprimée, ou taille indisponible) : ce n'est pas la pochette. La grande
        // taille refusée, on essaie la taille d'origine.
        if is_empty_picture(response.url().as_str()) {
            continue;
        }
        if response.content_length().is_some_and(|size| size > MAX_COVER_BYTES) {
            continue;
        }
        let mut bytes = Vec::new();
        let mut stream = response.bytes_stream();
        let mut complete = true;
        while let Some(chunk) = stream.next().await {
            let Ok(chunk) = chunk else {
                complete = false;
                break;
            };
            if bytes.len() as u64 + chunk.len() as u64 > MAX_COVER_BYTES {
                complete = false;
                break;
            }
            bytes.extend_from_slice(&chunk);
        }
        if !complete || bytes.len() < 3 || !bytes.starts_with(&[0xff, 0xd8, 0xff]) {
            continue;
        }
        // Nom de travail unique : deux titres du même album peuvent écrire la même pochette en même temps.
        static PART_SEQ: AtomicU64 = AtomicU64::new(0);
        let n = PART_SEQ.fetch_add(1, Ordering::Relaxed);
        let part = root.join(&relative).with_extension(format!("{n}.part"));
        if tokio::fs::write(&part, bytes).await.is_err() {
            let _ = tokio::fs::remove_file(&part).await;
            return None;
        }
        let final_path = root.join(&relative);
        // `rename` remplace d'un coup : jamais de moment sans fichier pour un titre qui l'affiche déjà.
        if tokio::fs::rename(&part, &final_path).await.is_err() {
            // Windows ne remplace pas un fichier existant : on retire l'ancien, puis on réessaie.
            let _ = tokio::fs::remove_file(&final_path).await;
            if tokio::fs::rename(&part, &final_path).await.is_err() {
                let _ = tokio::fs::remove_file(&part).await;
                return None;
            }
        }
        return Some(relative.to_string_lossy().into_owned());
    }
    None
}

async fn valid_audio(path: &Path, ext: &str) -> io::Result<bool> {
    let mut header = [0; 4];
    let count = tokio::fs::File::open(path).await?.read(&mut header).await?;
    Ok(match ext {
        "flac" => count == header.len() && &header == b"fLaC",
        _ => count >= 3 && (&header[..3] == b"ID3" || header[0] == 0xff && header[1] & 0xe0 == 0xe0),
    })
}

/// Adresse de l'image vide du serveur d'images de Deezer.
fn is_empty_picture(url: &str) -> bool {
    url.contains(EMPTY_PICTURE)
}

fn large_cover_url(url: &str) -> String {
    let Some(slash) = url.rfind('/') else { return url.to_owned() };
    let suffix = &url[slash + 1..];
    let Some(dash) = suffix.find('-') else { return url.to_owned() };
    let dimensions = &suffix[..dash];
    let valid = dimensions.split_once('x').is_some_and(|(width, height)| {
        !width.is_empty() && !height.is_empty() && width.chars().all(|c| c.is_ascii_digit()) && height.chars().all(|c| c.is_ascii_digit())
    });
    if valid { format!("{}/1000x1000-{}", &url[..slash], &suffix[dash + 1..]) } else { url.to_owned() }
}

fn collection_key(kind: &str, id: u64) -> String {
    format!("{kind}:{id}")
}

fn lyrics_path(root: &Path, id: i64) -> PathBuf {
    root.join("lyrics").join(format!("{id}.json"))
}

fn audio_path(root: &Path, id: i64, ext: &str) -> PathBuf {
    root.join("audio").join(format!("{id}.{ext}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root(name: &str) -> PathBuf {
        let n = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        std::env::temp_dir().join(format!("dz-offline-{name}-{}-{n}", std::process::id()))
    }

    fn info(id: i64) -> TrackInfo {
        TrackInfo {
            id,
            title: "Titre".into(),
            artist: "Artiste".into(),
            album: "Album".into(),
            duration_s: 100,
            cover_url: Some("https://example.test/cover.jpg".into()),
            track_token: Some("secret".into()),
            quality: Some("MP3 320".into()),
            added_at: None,
            release_date: None,
            fallback_id: None,
            restricted: false,
            artist_id: 1,
            album_id: 2,
            artists: vec![],
        }
    }

    fn insert_file(store: &OfflineStore, id: i64) {
        let path = audio_path(&store.root, id, "mp3");
        std::fs::write(&path, b"audio").unwrap();
        store.insert(OfflineTrack { info: info(id), ext: "mp3".into(), bytes: 5, downloaded_at: 1, cover: None, cover_version: 0, pinned: false, cover_tries: 0, cover_retry_at: 0 }).unwrap();
    }

    fn audio_bytes(store: &OfflineStore) -> u64 {
        store.list().iter().map(|entry| entry.bytes).sum()
    }

    fn native_pending(root: &Path) -> (PendingDownload, PathBuf, Vec<u8>) {
        let source = root.join("native.encrypted");
        let mut bytes: Vec<u8> = (0..CHUNK + 17).map(|n| (n % 251) as u8).collect();
        bytes[..3].copy_from_slice(b"ID3");
        std::fs::write(&source, &bytes).unwrap();
        let mut info = info(42);
        info.cover_url = None;
        info.track_token = None;
        let pending = PendingDownload { info, url: "https://example.test/audio".into(), stream_id: 42, ext: "mp3".into(), encrypted: false, pinned: false };
        (pending, source, bytes)
    }

    /// Simule un disque plein : toute réécriture de ces manifests échoue (supprimer des fichiers marche toujours).
    fn block_writes(root: &Path, names: &[&str]) {
        for name in names {
            std::fs::create_dir_all(root.join(format!("{name}.tmp"))).unwrap();
        }
    }

    fn unblock_writes(root: &Path, names: &[&str]) {
        for name in names {
            std::fs::remove_dir_all(root.join(format!("{name}.tmp"))).unwrap();
        }
    }

    #[test]
    fn full_disk_removal_still_frees_the_audio_and_stays_removed() {
        let root = root("full-remove");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 42);
        insert_file(&store, 43);
        let (mut job, _, _) = native_pending(&root);
        job.info.id = 42;
        store.save_pending(job).unwrap();
        block_writes(&root, &["downloads.json", "pending.json"]);

        assert!(store.remove(42).is_err(), "l'échec d'écriture est signalé");
        assert!(!audio_path(&root, 42, "mp3").exists(), "la place est libérée quand même");
        assert!(!store.contains(42) && store.pending(42).is_none());
        assert!(store.contains(43));

        // Relancé sans avoir pu réécrire les manifests : le titre ne revient pas.
        drop(store);
        unblock_writes(&root, &["downloads.json", "pending.json"]);
        let reopened = OfflineStore::open(root.clone()).unwrap();
        assert!(!reopened.contains(42));
        assert!(reopened.contains(43));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn full_disk_clear_erases_everything_of_the_previous_account() {
        let root = root("full-clear");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 42);
        store.insert_collection(OfflineCollection::new("playlist".into(), 7, true, "P".into(), String::new(), None, vec![42])).unwrap();
        let (job, _, _) = native_pending(&root);
        store.save_pending(job).unwrap();
        let all = ["downloads.json", "pending.json", "collections.json", "listens.json"];
        block_writes(&root, &all);

        store.clear().unwrap();
        assert!(store.list().is_empty() && store.collections().is_empty() && store.pending(42).is_none());
        assert!(!audio_path(&root, 42, "mp3").exists());

        drop(store);
        unblock_writes(&root, &all);
        let reopened = OfflineStore::open(root.clone()).unwrap();
        assert!(reopened.list().is_empty());
        assert!(reopened.collections().is_empty());
        assert!(reopened.pending(42).is_none());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn failed_save_does_not_leave_a_ghost_download_in_memory() {
        let root = root("full-insert");
        let store = OfflineStore::open(root.clone()).unwrap();
        std::fs::create_dir_all(root.join(JOURNAL)).unwrap(); // journal impossible à écrire
        let entry = OfflineTrack { info: info(42), ext: "mp3".into(), bytes: 5, downloaded_at: 1, cover: None, cover_version: 0, pinned: false, cover_tries: 0, cover_retry_at: 0 };
        assert!(store.insert_if_current(entry.clone(), store.wipes.load(Ordering::Acquire)).is_err());
        assert!(store.list().is_empty());

        let (job, _, _) = native_pending(&root);
        store.save_pending(job).unwrap();
        assert!(store.insert_if_pending(entry).is_err());
        assert!(store.list().is_empty());
        assert!(store.pending(42).is_some(), "toujours attendu, pour réessayer");
        std::fs::remove_dir_all(root.join(JOURNAL)).unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn pending_job_of_an_already_saved_track_is_dropped_at_launch() {
        let root = root("pending-saved");
        let store = OfflineStore::open(root.clone()).unwrap();
        let (job, _, _) = native_pending(&root);
        store.save_pending(job).unwrap();
        insert_file(&store, 42); // enregistré, mais la file n'a pas pu être réécrite
        drop(store);
        let reopened = OfflineStore::open(root.clone()).unwrap();
        assert!(reopened.contains(42));
        assert!(reopened.pending(42).is_none());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn sets_corrupt_manifest_aside_without_deleting_anything() {
        let root = root("corrupt-manifest");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 42);
        drop(store);
        std::fs::write(root.join("downloads.json"), b"{broken").unwrap();

        // L'app démarre quand même, la liste abîmée est gardée à part, le fichier audio n'est pas effacé, et le titre est
        // retrouvé grâce au journal des ajouts.
        let store = OfflineStore::open(root.clone()).expect("une liste abîmée ne doit plus empêcher l'ouverture");
        assert!(store.contains(42));
        assert_eq!(std::fs::read(root.join("downloads.json.corrupt")).unwrap(), b"{broken");
        assert!(audio_path(&root, 42, "mp3").exists());
        drop(store);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn restores_complete_downloads_without_tokens() {
        let root = root("restore");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 42);
        drop(store);

        let restored = OfflineStore::open(root.clone()).unwrap();
        let local = restored.local(42).unwrap();
        assert_eq!(local.info.title, "Titre");
        assert_eq!(local.info.track_token, None);
        assert_eq!(std::fs::read(local.path).unwrap(), b"audio");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn concurrent_inserts_are_all_persisted() {
        let root = root("concurrent");
        let store = OfflineStore::open(root.clone()).unwrap();
        let threads: Vec<_> = (0..8i64)
            .map(|t| {
                let store = store.clone();
                std::thread::spawn(move || {
                    for i in 0..10i64 {
                        insert_file(&store, t * 100 + i);
                    }
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
        drop(store);

        let restored = OfflineStore::open(root.clone()).unwrap();
        assert_eq!(restored.list().len(), 80);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn ignores_partial_and_incomplete_files() {
        let root = root("partial");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 42);
        std::fs::write(audio_path(&store.root, 42, "mp3"), b"x").unwrap();
        std::fs::write(store.root.join("audio/43.part"), b"partial").unwrap();
        drop(store);

        let restored = OfflineStore::open(root.clone()).unwrap();
        assert!(restored.local(42).is_none());
        assert!(!root.join("audio/43.part").exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn removes_audio_and_manifest_entry() {
        let root = root("remove");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 42);
        let path = audio_path(&store.root, 42, "mp3");
        store.remove(42).unwrap();

        assert!(!path.exists());
        assert!(store.list().is_empty());
        assert_eq!(audio_bytes(&store), 0);
        assert_eq!(store.total_bytes(), stored_bytes(&root));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn removes_track_from_collection_without_deleting_audio() {
        let root = root("remove-collection-track");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 42);
        let collection = OfflineCollection::new("playlist".into(), 10, true, "Ma playlist".into(), String::new(), None, vec![42]);
        store_collection(Arc::new(DeezerClient::new().unwrap()), store.clone(), collection).await.unwrap();

        assert!(store.remove_collection_track("playlist", 10, 42).unwrap().is_some());
        assert!(store.remove_collection_track("playlist", 10, 42).unwrap().is_none());
        assert!(store.collection("playlist", 10).unwrap().1.is_empty());
        assert!(store.local(42).is_some());
        assert!(audio_path(&store.root, 42, "mp3").exists());
        assert_eq!(store.standalone_infos().iter().map(|track| track.id).collect::<Vec<_>>(), vec![42]);
        std::fs::remove_dir_all(root).unwrap();
    }

    fn api() -> Arc<DeezerClient> {
        Arc::new(DeezerClient::new().unwrap())
    }

    fn playlist(id: u64, tracks: Vec<i64>) -> OfflineCollection {
        OfflineCollection::new("playlist".into(), id, true, "Ma playlist".into(), String::new(), None, tracks)
    }

    #[tokio::test]
    async fn groups_existing_tracks_and_preserves_shared_audio() {
        let root = root("collections");
        let store = OfflineStore::open(root.clone()).unwrap();
        // Playlist enregistrée avant ses titres (comme dans l'app), puis un titre téléchargé seul.
        store_collection(api(), store.clone(), playlist(10, vec![3, 1, 2])).await.unwrap();
        for id in [1, 2, 3, 4] {
            insert_file(&store, id);
        }

        assert_eq!(store.collection("playlist", 10).unwrap().1.iter().map(|track| track.id).collect::<Vec<_>>(), vec![3, 1, 2]);
        assert_eq!(store.standalone_infos().iter().map(|track| track.id).collect::<Vec<_>>(), vec![4]);
        assert_eq!(store.collections()[0].1, 3);

        let second = OfflineCollection::new("loved".into(), 0, false, "Titres aimés".into(), String::new(), None, vec![1, 4]);
        store_collection(api(), store.clone(), second).await.unwrap();
        for id in [1, 2] {
            store.save_pending(PendingDownload { info: info(id), url: String::new(), stream_id: id, ext: "mp3".into(), encrypted: false, pinned: false }).unwrap();
        }
        let removed = store.remove_collection("playlist", 10).unwrap();
        assert_eq!(removed, vec![3, 2]);
        assert!(store.pending(1).is_some());
        assert!(store.pending(2).is_none());
        assert!(store.local(1).is_some());
        assert!(store.local(2).is_none());
        assert!(store.local(3).is_none());
        assert!(store.local(4).is_some());
        assert_eq!(audio_bytes(&store), 10);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn a_track_downloaded_alone_survives_its_playlist() {
        let root = root("pinned");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 5); // téléchargé seul
        store_collection(api(), store.clone(), playlist(10, vec![5, 6])).await.unwrap();
        insert_file(&store, 6); // téléchargé avec la playlist
        assert_eq!(store.standalone_infos().iter().map(|t| t.id).collect::<Vec<_>>(), vec![5], "toujours dans « Titres »");

        assert_eq!(store.remove_collection("playlist", 10).unwrap(), vec![6]);
        assert!(store.local(5).is_some());
        assert!(store.local(6).is_none());
        assert_eq!(store.standalone_infos().iter().map(|t| t.id).collect::<Vec<_>>(), vec![5]);

        // Survit aussi à un redémarrage.
        drop(store);
        let store = OfflineStore::open(root.clone()).unwrap();
        store_collection(api(), store.clone(), playlist(11, vec![5])).await.unwrap();
        store.remove_collection("playlist", 11).unwrap();
        assert!(store.local(5).is_some());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_track_requested_alone_stays_pinned_when_its_address_is_renewed() {
        let root = root("pinned-pending");
        let store = OfflineStore::open(root.clone()).unwrap();
        let job = |pinned| PendingDownload { info: info(8), url: String::new(), stream_id: 8, ext: "mp3".into(), encrypted: false, pinned };
        store.save_pending(job(true)).unwrap();
        store.save_pending(job(false)).unwrap();
        assert!(store.pending(8).unwrap().pinned);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn unliked_or_removed_track_is_no_longer_downloaded_unless_pinned() {
        let root = root("unlike");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 1); // seul
        let loved = OfflineCollection::new("loved".into(), 0, false, "Titres aimés".into(), String::new(), None, vec![1, 2, 3]);
        store_collection(api(), store.clone(), loved).await.unwrap();
        store_collection(api(), store.clone(), playlist(10, vec![3])).await.unwrap();
        insert_file(&store, 2);
        insert_file(&store, 3);

        assert!(store.remove_collection_track("loved", 0, 2).unwrap().is_some());
        assert!(store.local(2).is_none(), "retiré des Titres aimés : plus téléchargé");
        assert!(!audio_path(&root, 2, "mp3").exists());
        assert!(store.remove_collection_track("loved", 0, 1).unwrap().is_some());
        assert!(store.local(1).is_some(), "téléchargé seul : gardé");
        assert!(store.remove_collection_track("loved", 0, 3).unwrap().is_some());
        assert!(store.local(3).is_some(), "encore dans une playlist téléchargée");
        assert!(store.standalone_infos().iter().all(|t| t.id != 3));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn sync_removes_dropped_tracks_but_not_after_a_suspiciously_short_answer() {
        let root = root("sync");
        let store = OfflineStore::open(root.clone()).unwrap();
        let all: Vec<i64> = (1..=40).collect();
        store_collection(api(), store.clone(), playlist(10, all.clone())).await.unwrap();
        for id in &all {
            insert_file(&store, *id);
        }
        // Un titre retiré chez Deezer : supprimé du téléphone, et signalé (son téléchargement en attente est annulé).
        let (_, removed) = store_collection_removing(api(), store.clone(), playlist(10, (1..=39).collect())).await.unwrap();
        assert_eq!(removed, vec![40]);
        assert!(store.local(40).is_none());
        assert!(store.local(39).is_some());
        // Réponse tronquée (page manquante) : 34 titres en moins d'un coup, rien n'est supprimé, et ils restent dans la
        // collection (pas des titres téléchargés seuls, gardés pour toujours).
        let (_, removed) = store_collection_removing(api(), store.clone(), playlist(10, (1..=5).collect())).await.unwrap();
        assert!(removed.is_empty());
        assert!((1..=39).all(|id| store.local(id).is_some()));
        assert_eq!(store.collection("playlist", 10).unwrap().0.track_ids.len(), 39);
        assert!((1..=39).all(|id| store.in_collection(id)));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn tracks_outside_any_collection_are_pinned_at_launch() {
        let root = root("pinned-migration");
        let store = OfflineStore::open(root.clone()).unwrap();
        store_collection(api(), store.clone(), playlist(10, vec![9])).await.unwrap();
        insert_file(&store, 9);
        drop(store);
        // Ancienne version : la collection a disparu sans supprimer le titre (orphelin), il est visible dans « Titres ».
        std::fs::remove_file(root.join("collections.json")).unwrap();
        let store = OfflineStore::open(root.clone()).unwrap();
        store_collection(api(), store.clone(), playlist(11, vec![9])).await.unwrap();
        store.remove_collection("playlist", 11).unwrap();
        assert!(store.local(9).is_some());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn upgrades_deezer_cover_resolution() {
        let url = "https://cdn-images.dzcdn.net/images/cover/abc/250x250-000000-80-0-0.jpg";
        assert_eq!(large_cover_url(url), "https://cdn-images.dzcdn.net/images/cover/abc/1000x1000-000000-80-0-0.jpg");
        assert_eq!(large_cover_url("https://example.test/image.jpg"), "https://example.test/image.jpg");
    }

    // --- Pochettes : un petit serveur d'images qui se comporte comme celui de Deezer.

    const GOOD_JPEG: &[u8] = &[0xff, 0xd8, 0xff, 0xe0, b'g', b'o', b'o', b'd'];
    const SMALL_JPEG: &[u8] = &[0xff, 0xd8, 0xff, 0xe0, b's', b'm', b'a', b'l', b'l'];
    const WHITE_JPEG: &[u8] = &[0xff, 0xd8, 0xff, 0xe0, b'w', b'h', b'i', b't', b'e'];
    const OTHER_JPEG: &[u8] = &[0xff, 0xd8, 0xff, 0xe0, b'o', b't', b'h', b'e', b'r'];

    /// `good` : pochette normale ; `gone` : supprimée (redirige vers l'image vide) ; `nolarge` : la taille 1000x1000
    /// n'existe pas (redirige vers l'image vide) mais la taille d'origine oui.
    fn image_server() -> String {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    continue;
                }
                // En-têtes ignorés.
                let mut header = String::new();
                while reader.read_line(&mut header).is_ok_and(|n| n > 2) {
                    header.clear();
                }
                let mut parts = line.split_whitespace();
                let method = parts.next().unwrap_or("").to_owned();
                let path = parts.next().unwrap_or("").to_owned();
                let empty = format!("/images/cover/{EMPTY_PICTURE}/1000x1000-000000-80-0-0.jpg");
                let (status, location, body): (&str, Option<String>, &[u8]) = if path.contains(EMPTY_PICTURE) {
                    ("200 OK", None, WHITE_JPEG)
                } else if path.contains("/gone/") || (path.contains("/nolarge/") && path.contains("1000x1000")) {
                    ("302 Found", Some(empty), &[])
                } else if path.contains("/nolarge/") {
                    ("200 OK", None, SMALL_JPEG)
                } else if path.contains("/good/") {
                    ("200 OK", None, GOOD_JPEG)
                } else if path.contains("/other/") {
                    ("200 OK", None, OTHER_JPEG)
                } else {
                    ("404 Not Found", None, &[])
                };
                let mut out = stream;
                let mut head = format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n", body.len());
                if let Some(location) = location {
                    head.push_str(&format!("Location: {location}\r\n"));
                }
                head.push_str("\r\n");
                let _ = out.write_all(head.as_bytes());
                if method != "HEAD" {
                    let _ = out.write_all(body);
                }
            }
        });
        base
    }

    fn cover_url(base: &str, md5: &str) -> String {
        format!("{base}/images/cover/{md5}/250x250-000000-80-0-0.jpg")
    }

    fn track_with_cover(id: i64, url: String) -> TrackInfo {
        let mut t = info(id);
        t.cover_url = Some(url);
        t.album_id = 0; // pas de recherche de la pochette de l'album dans ces tests (API publique de Deezer)
        t
    }

    #[tokio::test]
    async fn new_downloads_never_keep_the_white_image() {
        let base = image_server();
        let root = root("cover-download");
        std::fs::create_dir_all(root.join("covers")).unwrap();
        let api = DeezerClient::new().unwrap();

        // Pochette normale : la grande taille est gardée.
        let mut t = track_with_cover(1, cover_url(&base, "good"));
        let cover = download_cover(&api, &root, &mut t).await.unwrap();
        assert_eq!(cover, "covers/1-v3.jpg");
        assert_eq!(std::fs::read(root.join(&cover)).unwrap(), GOOD_JPEG);

        // Grande taille indisponible : la taille d'origine est gardée (avant : l'image blanche).
        let mut t = track_with_cover(2, cover_url(&base, "nolarge"));
        let cover = download_cover(&api, &root, &mut t).await.unwrap();
        assert_eq!(std::fs::read(root.join(&cover)).unwrap(), SMALL_JPEG);

        // Pochette supprimée, rien de mieux trouvé : aucune image gardée (avant : l'image blanche).
        let mut t = track_with_cover(3, cover_url(&base, "gone"));
        assert_eq!(download_cover(&api, &root, &mut t).await, None);
        assert!(!root.join("covers/3-v3.jpg").exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    fn downloaded(store: &OfflineStore, id: i64, url: String, image: &[u8], version: u8) {
        std::fs::write(audio_path(&store.root, id, "mp3"), b"audio").unwrap();
        let cover = format!("covers/{id}-v{version}.jpg");
        std::fs::write(store.root.join(&cover), image).unwrap();
        store
            .insert(OfflineTrack { info: track_with_cover(id, url), ext: "mp3".into(), bytes: 5, downloaded_at: 1, cover: Some(cover), cover_version: version, pinned: false, cover_tries: 0, cover_retry_at: 0 })
            .unwrap();
    }

    #[tokio::test]
    async fn already_downloaded_covers_are_rechecked_from_the_original_address() {
        let base = image_server();
        let root = root("cover-repair");
        let store = OfflineStore::open(root.clone()).unwrap();
        // 1 : vérifiée par la version précédente, et bonne : seulement notée vérifiée.
        downloaded(&store, 1, cover_url(&base, "good"), GOOD_JPEG, 2);
        // 2 : image blanche gardée à la place de la grande taille, jamais vérifiée.
        downloaded(&store, 2, cover_url(&base, "nolarge"), WHITE_JPEG, 1);
        // 3 : pochette supprimée, rien de mieux trouvé.
        downloaded(&store, 3, cover_url(&base, "gone"), WHITE_JPEG, 1);
        // 4 : « réparée » par la version précédente avec la pochette d'un autre titre (Chanel / Jr Vini) : l'adresse
        //     gardée est une vraie image, mais pas la sienne. Son adresse d'origine chez Deezer donne la bonne.
        downloaded(&store, 4, cover_url(&base, "good"), GOOD_JPEG, 2);
        let originals: BTreeMap<i64, String> = [
            (1, cover_url(&base, "good")),
            (2, cover_url(&base, "nolarge")),
            (3, cover_url(&base, "gone")),
            (4, cover_url(&base, "other")),
        ]
        .into_iter()
        .collect();

        let api = DeezerClient::new().unwrap();
        check_covers(&api, &store, covers_to_check(&store), &originals).await;
        let entry = |id: i64| store.entries.read().unwrap().get(&id).cloned().unwrap();

        assert_eq!(entry(1).cover.as_deref(), Some("covers/1-v2.jpg"), "bonne : pas retéléchargée");
        assert_eq!(entry(1).cover_version, COVER_VERSION);

        assert_eq!(entry(2).cover.as_deref(), Some("covers/2-v3.jpg"));
        assert_eq!(std::fs::read(root.join("covers/2-v3.jpg")).unwrap(), SMALL_JPEG, "la vraie image, plus la blanche");
        assert!(!root.join("covers/2-v1.jpg").exists(), "l'image blanche est supprimée");

        assert!(entry(3).cover_version < COVER_VERSION, "rien trouvé : revérifiée plus tard");

        assert_eq!(std::fs::read(root.join(entry(4).cover.unwrap())).unwrap(), OTHER_JPEG, "sa propre pochette");
        assert_eq!(entry(4).info.cover_url, Some(cover_url(&base, "other")));
        assert!(!root.join("covers/4-v2.jpg").exists());

        // Lancement suivant : le titre 3 n'est pas redemandé tout de suite (un jour d'attente, puis 7, puis 30)…
        assert_eq!(entry(3).cover_tries, 1);
        assert!(covers_to_check(&store).is_empty());
        // … puis, le délai passé, c'est le seul à revérifier.
        store.entries.write().unwrap().get_mut(&3).unwrap().cover_retry_at = 1;
        assert_eq!(covers_to_check(&store).iter().map(|e| e.info.id).collect::<Vec<_>>(), vec![3]);
        check_covers(&api, &store, covers_to_check(&store), &originals).await;
        assert_eq!(entry(3).cover_tries, 2);
        assert!(entry(3).cover_retry_at >= now_s() + 6 * 24 * 3600);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// Serveur d'images qui compte les téléchargements (GET).
    fn counting_image_server() -> (String, Arc<AtomicU64>) {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let gets = Arc::new(AtomicU64::new(0));
        let counter = gets.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    continue;
                }
                let mut header = String::new();
                while reader.read_line(&mut header).is_ok_and(|n| n > 2) {
                    header.clear();
                }
                let get = line.starts_with("GET");
                if get {
                    counter.fetch_add(1, Ordering::SeqCst);
                }
                let mut out = stream;
                let _ = out.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", GOOD_JPEG.len()).as_bytes());
                if get {
                    let _ = out.write_all(GOOD_JPEG);
                }
            }
        });
        (base, gets)
    }

    #[tokio::test]
    async fn tracks_of_one_album_share_a_single_cover_file() {
        let (base, gets) = counting_image_server();
        let root = root("shared-cover");
        let store = OfflineStore::open(root.clone()).unwrap();
        let api = DeezerClient::new().unwrap();
        let md5 = "0123456789abcdef0123456789abcdef";
        let url = cover_url(&base, md5);
        let mut covers = Vec::new();
        for id in [1, 2, 3] {
            let mut t = track_with_cover(id, url.clone());
            let cover = download_cover(&api, &root, &mut t).await.unwrap();
            std::fs::write(audio_path(&root, id, "mp3"), b"audio").unwrap();
            store.insert(OfflineTrack { info: t, ext: "mp3".into(), bytes: 5, downloaded_at: 1, cover: Some(cover.clone()), cover_version: COVER_VERSION, pinned: false, cover_tries: 0, cover_retry_at: 0 }).unwrap();
            covers.push(cover);
        }
        assert!(covers.iter().all(|c| *c == format!("covers/{md5}-v3.jpg")), "{covers:?}");
        assert_eq!(gets.load(Ordering::SeqCst), 1, "téléchargée une seule fois");
        // Supprimée seulement avec le dernier titre qui l'utilise.
        store.remove(1).unwrap();
        store.remove(2).unwrap();
        assert!(root.join(&covers[0]).exists());
        assert!(store.local(3).unwrap().info.cover_url.unwrap().ends_with(".jpg"));
        store.remove(3).unwrap();
        assert!(!root.join(&covers[0]).exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn downloads_are_journaled_then_folded_into_the_manifest() {
        let root = root("journal");
        let store = OfflineStore::open(root.clone()).unwrap();
        for id in [1, 2, 3] {
            insert_file(&store, id);
        }
        // Une ligne par titre, sans réécrire tout le manifest.
        let journal = std::fs::read_to_string(root.join(JOURNAL)).unwrap();
        assert_eq!(journal.lines().filter(|l| !l.is_empty()).count(), 3);
        assert!(!root.join("downloads.json").exists());
        // Coupure pendant l'écriture d'une ligne : elle est ignorée, les autres restent.
        std::io::Write::write_all(&mut std::fs::OpenOptions::new().append(true).open(root.join(JOURNAL)).unwrap(), b"{\"info\":{\"id\":4").unwrap();
        drop(store);

        let store = OfflineStore::open(root.clone()).unwrap();
        assert_eq!(store.list().len(), 3);
        assert!(!root.join(JOURNAL).exists(), "fondu dans downloads.json au lancement");
        let written = std::fs::metadata(root.join("downloads.json")).unwrap().modified().unwrap();
        drop(store);
        // Rien de changé : plus de réécriture à chaque lancement.
        std::thread::sleep(std::time::Duration::from_millis(20));
        let store = OfflineStore::open(root.clone()).unwrap();
        assert_eq!(std::fs::metadata(root.join("downloads.json")).unwrap().modified().unwrap(), written);

        // Au-delà de `JOURNAL_MAX` lignes, réécriture complète et journal vidé.
        for id in 10..10 + JOURNAL_MAX as i64 + 1 {
            insert_file(&store, id);
        }
        assert!(std::fs::read_to_string(root.join(JOURNAL)).map_or(0, |j| j.lines().filter(|l| !l.is_empty()).count()) <= 1);
        drop(store);
        assert_eq!(OfflineStore::open(root.clone()).unwrap().list().len(), 3 + JOURNAL_MAX + 1);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn loved_tracks_of_each_profile_are_kept_apart() {
        let root = root("loved-profiles");
        let store = OfflineStore::open(root.clone()).unwrap();
        let loved = |owner: u64, tracks: Vec<i64>| OfflineCollection::new("loved".into(), owner, false, "Titres aimés".into(), String::new(), None, tracks);
        // Version précédente : une seule collection, identifiant 0. Attribuée au premier profil vu.
        store_collection(api(), store.clone(), loved(0, vec![1, 2])).await.unwrap();
        assert!(store.rekey_collection("loved", 0, 100).unwrap());
        assert!(!store.rekey_collection("loved", 0, 200).unwrap(), "déjà attribuée");
        assert_eq!(store.collection("loved", 100).unwrap().0.track_ids, vec![1, 2]);
        // Le profil 200 télécharge les siens : ceux de 100 ne bougent pas.
        store_collection(api(), store.clone(), loved(200, vec![3])).await.unwrap();
        assert_eq!(store.collection("loved", 100).unwrap().0.track_ids, vec![1, 2]);
        assert_eq!(store.collection("loved", 200).unwrap().0.track_ids, vec![3]);
        assert!(store.latest_collection_id("loved").is_some());
        drop(store);
        let store = OfflineStore::open(root.clone()).unwrap();
        assert!(store.collection("loved", 100).is_some() && store.collection("loved", 200).is_some());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unreadable_pending_file_does_not_block_the_app() {
        let root = root("pending-corrupt");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 1);
        drop(store);
        std::fs::write(root.join("pending.json"), b"{abim").unwrap();
        let store = OfflineStore::open(root.clone()).expect("l'app démarre");
        assert!(store.contains(1));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn covers_wait_for_the_session_before_being_checked() {
        let root = root("cover-no-session");
        let store = OfflineStore::open(root.clone()).unwrap();
        downloaded(&store, 1, "https://cdn-images.dzcdn.net/images/cover/abc/250x250-000000-80-0-0.jpg".into(), WHITE_JPEG, 1);
        // Démarrage : pas encore de session (lancement sans réseau) : rien n'est fait ni marqué vérifié.
        repair_covers(Arc::new(DeezerClient::new().unwrap()), store.clone()).await;
        let entry = store.entries.read().unwrap().get(&1).cloned().unwrap();
        assert_eq!(entry.cover_version, 1);
        assert_eq!(entry.cover.as_deref(), Some("covers/1-v1.jpg"));
        // Et la vérification suivante peut démarrer (pas de verrou resté pris).
        assert!(!REPAIRING_COVERS.load(Ordering::Acquire));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn nothing_is_marked_checked_without_network() {
        let root = root("cover-offline");
        let store = OfflineStore::open(root.clone()).unwrap();
        // Adresse injoignable (port fermé) : comme sans réseau.
        let unreachable = "http://127.0.0.1:9/images/cover/x/250x250-000000-80-0-0.jpg".to_string();
        downloaded(&store, 1, unreachable.clone(), WHITE_JPEG, 1);
        let originals: BTreeMap<i64, String> = [(1, unreachable)].into_iter().collect();
        check_covers(&DeezerClient::new().unwrap(), &store, covers_to_check(&store), &originals).await;
        let entry = store.entries.read().unwrap().get(&1).cloned().unwrap();
        assert_eq!(entry.cover_version, 1, "revérifiée plus tard, avec du réseau");
        assert_eq!(entry.cover.as_deref(), Some("covers/1-v1.jpg"));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn removes_orphans_and_counts_all_stored_files() {
        let root = root("orphans");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 42);
        let cover = "covers/42-v1.jpg";
        std::fs::write(root.join(cover), [0xff, 0xd8, 0xff, 0xd9]).unwrap();
        store.update_cover(42, cover.into()).unwrap();
        std::fs::write(root.join("audio/43.mp3"), b"orphan").unwrap();
        std::fs::write(root.join("covers/orphan.jpg"), b"orphan").unwrap();
        std::fs::create_dir_all(root.join("Incoming")).unwrap();
        std::fs::write(root.join("Incoming/44.download"), b"incoming").unwrap();
        std::fs::write(root.join("native-jobs.json"), b"[]").unwrap();
        drop(store);

        let restored = OfflineStore::open(root.clone()).unwrap();
        assert!(!root.join("audio/43.mp3").exists());
        assert!(!root.join("covers/orphan.jpg").exists());
        assert!(root.join(cover).exists());
        assert!(root.join("Incoming/44.download").exists());
        assert_eq!(restored.total_bytes(), stored_bytes(&root));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn preserves_collection_cover_when_refresh_fails() {
        let root = root("collection-cover");
        let store = OfflineStore::open(root.clone()).unwrap();
        let original_url = "https://example.test/original.jpg".to_string();
        let original = OfflineCollection::new("playlist".into(), 10, true, "Ma playlist".into(), String::new(), Some(original_url.clone()), vec![]);
        store.insert_collection(original).unwrap();
        let relative = "covers/collection-playlist-10-v1.jpg";
        std::fs::write(root.join(relative), [0xff, 0xd8, 0xff, 0xd9]).unwrap();
        store.update_collection_cover("playlist", 10, relative.into()).unwrap();
        let api = Arc::new(DeezerClient::new().unwrap());

        let unchanged = OfflineCollection::new("playlist".into(), 10, true, "Ma playlist".into(), String::new(), Some(original_url), vec![]);
        let saved = store_collection(api.clone(), store.clone(), unchanged).await.unwrap();
        assert_eq!(saved.cover_url.as_deref(), root.join(relative).to_str());

        let changed = OfflineCollection::new("playlist".into(), 10, true, "Ma playlist".into(), String::new(), Some("http://127.0.0.1:9/unavailable.jpg".into()), vec![]);
        let saved = store_collection(api, store.clone(), changed).await.unwrap();
        assert_eq!(saved.cover_url.as_deref(), root.join(relative).to_str());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn offline_copy_keeps_collection_cover_and_remote_url() {
        let root = root("collection-offline-copy");
        let store = OfflineStore::open(root.clone()).unwrap();
        let original_url = "https://example.test/original.jpg".to_string();
        let original = OfflineCollection::new("playlist".into(), 10, true, "Ma playlist".into(), String::new(), Some(original_url.clone()), vec![]);
        store.insert_collection(original).unwrap();
        let relative = "covers/collection-playlist-10-v1.jpg";
        std::fs::write(root.join(relative), [0xff, 0xd8, 0xff, 0xd9]).unwrap();
        store.update_collection_cover("playlist", 10, relative.into()).unwrap();

        // Fiche venue de la copie hors ligne : adresse de pochette locale.
        let local = root.join(relative).to_string_lossy().into_owned();
        let copy = OfflineCollection::new("playlist".into(), 10, true, "Ma playlist".into(), String::new(), Some(local.clone()), vec![]);
        let saved = store_collection(Arc::new(DeezerClient::new().unwrap()), store.clone(), copy).await.unwrap();
        assert_eq!(saved.cover_url.as_deref(), Some(local.as_str()));
        let stored = store.collections.read().unwrap().get("playlist:10").unwrap().cover_url.clone();
        assert_eq!(stored, Some(original_url));
        assert!(root.join(relative).exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn rejects_invalid_native_audio() {
        let root = root("invalid-native");
        let store = OfflineStore::open(root.clone()).unwrap();
        let source = root.join("native.encrypted");
        std::fs::write(&source, vec![b'x'; CHUNK + 17]).unwrap();
        let mut info = info(42);
        info.cover_url = None;
        info.track_token = None;
        let pending = PendingDownload { info, url: "https://example.test/audio".into(), stream_id: 42, ext: "mp3".into(), encrypted: false, pinned: false };
        store.save_pending(pending.clone()).unwrap();

        let result = import_download(Arc::new(DeezerClient::new().unwrap()), store.clone(), pending, source).await;
        assert!(matches!(result, Err(DownloadError::InvalidAudio)));
        assert!(store.local(42).is_none());
        assert!(store.pending(42).is_some());
        assert!(!audio_path(&root, 42, "mp3").exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn imports_native_download_and_clears_pending_entry() {
        let root = root("native");
        let store = OfflineStore::open(root.clone()).unwrap();
        let (pending, source, bytes) = native_pending(&root);
        store.save_pending(pending.clone()).unwrap();

        import_download(Arc::new(DeezerClient::new().unwrap()), store.clone(), pending, source).await.unwrap();
        assert_eq!(std::fs::read(store.local(42).unwrap().path).unwrap(), bytes);
        assert!(store.pending(42).is_none());
        std::fs::remove_dir_all(root).unwrap();
    }

    fn listen(track_id: i64, started_at: u64) -> PendingListen {
        PendingListen { track_id, format: "FLAC".into(), started_at, listened_s: 120, user_id: 7 }
    }

    #[test]
    fn pending_listens_survive_restart_and_are_removed_once_sent() {
        let root = root("listens");
        let store = OfflineStore::open(root.clone()).unwrap();
        store.queue_listen(listen(1, 100), 0).unwrap();
        store.queue_listen(listen(2, 200), 0).unwrap();
        drop(store);

        let restored = OfflineStore::open(root.clone()).unwrap();
        assert_eq!(restored.pending_listens(), vec![listen(1, 100), listen(2, 200)]);
        restored.remove_listen(&listen(1, 100)).unwrap();
        assert_eq!(restored.pending_listens(), vec![listen(2, 200)]);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn open_listen_counts_after_the_app_was_closed() {
        let root = root("open-listen");
        let store = OfflineStore::open(root.clone()).unwrap();
        // Mise de côté à une pause, puis app fermée sans que le titre se termine.
        store.set_open_listen(Some(listen(5, 500)), 0).unwrap();
        drop(store);

        let restored = OfflineStore::open(root.clone()).unwrap();
        assert_eq!(restored.pending_listens(), vec![listen(5, 500)]);
        drop(restored);
        // Comptée une seule fois : pas de nouveau doublon au lancement suivant.
        assert_eq!(OfflineStore::open(root.clone()).unwrap().pending_listens().len(), 1);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn finished_listen_is_not_counted_twice() {
        let root = root("open-listen-done");
        let store = OfflineStore::open(root.clone()).unwrap();
        store.set_open_listen(Some(listen(5, 500)), 0).unwrap();
        // Le titre se termine normalement : l'écoute mise de côté est oubliée.
        store.set_open_listen(None, 0).unwrap();
        drop(store);
        assert!(OfflineStore::open(root.clone()).unwrap().pending_listens().is_empty());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn logout_forgets_pending_listens_and_corrupt_file_is_ignored() {
        let root = root("listens-clear");
        let store = OfflineStore::open(root.clone()).unwrap();
        store.queue_listen(listen(1, 100), 0).unwrap();
        store.set_open_listen(Some(listen(2, 200)), 0).unwrap();
        store.clear().unwrap();
        assert!(store.pending_listens().is_empty());
        drop(store);
        assert!(OfflineStore::open(root.clone()).unwrap().pending_listens().is_empty());

        std::fs::write(root.join("listens.json"), b"{broken").unwrap();
        assert!(OfflineStore::open(root.clone()).unwrap().pending_listens().is_empty());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn torn_journal_line_does_not_lose_the_next_download() {
        let root = root("journal-torn");
        let store = OfflineStore::open(root.clone()).unwrap();
        // Ligne coupée net par une coupure de courant (pas de saut de ligne final).
        std::fs::write(root.join(JOURNAL), b"{\"info\":{\"id\":4").unwrap();
        insert_file(&store, 42);
        drop(store);
        assert!(OfflineStore::open(root.clone()).unwrap().local(42).is_some());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unreadable_listens_file_is_set_aside() {
        let root = root("listens-corrupt");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("listens.json"), b"{broken").unwrap();
        let store = OfflineStore::open(root.clone()).unwrap();
        assert!(store.pending_listens().is_empty());
        assert_eq!(std::fs::read(root.join("listens.json.corrupt")).unwrap(), b"{broken");
        store.clear().unwrap();
        assert!(!root.join("listens.json.corrupt").exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn clearing_downloads_keeps_listens_waiting_to_be_sent() {
        let root = root("downloads-clear");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 42);
        let (gen, wipes) = (store.generation(), store.wipes.load(Ordering::Acquire));
        store.queue_listen(listen(1, 100), gen).unwrap();
        store.set_open_listen(Some(listen(2, 200)), gen).unwrap();
        store.clear_downloads().unwrap();
        assert!(store.list().is_empty() && !audio_path(&root, 42, "mp3").exists());
        // Téléchargement commencé avant l'effacement : pas enregistré après.
        let entry = OfflineTrack { info: info(43), ext: "mp3".into(), bytes: 5, downloaded_at: 1, cover: None, cover_version: 0, pinned: false, cover_tries: 0, cover_retry_at: 0 };
        assert!(!store.insert_if_current(entry, wipes).unwrap());
        // Le titre qui jouait pendant l'effacement est toujours compté à sa fin.
        assert!(store.close_listen(Some(listen(2, 200)), gen).unwrap());
        drop(store);
        assert_eq!(OfflineStore::open(root.clone()).unwrap().pending_listens(), vec![listen(1, 100), listen(2, 200)]);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn listen_started_before_logout_is_never_kept() {
        let root = root("listens-generation");
        let store = OfflineStore::open(root.clone()).unwrap();
        // Écoute commencée sur le compte A…
        let before = store.generation();
        store.clear().unwrap(); // … déconnexion pendant qu'elle se termine…
        // … sa fin arrive après : ni gardée, ni mise de côté pour le compte suivant.
        assert!(!store.queue_listen(listen(1, 100), before).unwrap());
        store.set_open_listen(Some(listen(1, 100)), before).unwrap();
        drop(store);
        assert!(OfflineStore::open(root.clone()).unwrap().pending_listens().is_empty());
        // Une écoute du nouveau compte, elle, est bien gardée.
        let store = OfflineStore::open(root.clone()).unwrap();
        assert!(store.queue_listen(listen(2, 200), store.generation()).unwrap());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn finished_listen_is_written_before_any_send_and_replaces_the_saved_one() {
        let root = root("listens-close");
        let store = OfflineStore::open(root.clone()).unwrap();
        let gen = store.generation();
        // Écoute mise de côté pendant la lecture, puis titre changé (en mode avion) : elle passe dans la file, et
        // l'écoute mise de côté disparaît dans la même écriture.
        store.set_open_listen(Some(listen(1, 100)), gen).unwrap();
        assert!(store.close_listen(Some(listen(1, 100)), gen).unwrap());
        drop(store); // app fermée aussitôt, avant tout envoi

        // Relancée avec du réseau : l'écoute est là, une seule fois.
        let store = OfflineStore::open(root.clone()).unwrap();
        assert_eq!(store.pending_listens(), vec![listen(1, 100)]);
        // Écoute trop courte : rien en file, l'écoute mise de côté est seulement oubliée.
        store.set_open_listen(Some(listen(2, 200)), gen).unwrap();
        assert!(!store.close_listen(None, gen).unwrap());
        // Commencée avant une déconnexion : jamais mise en file.
        store.clear().unwrap();
        assert!(!store.close_listen(Some(listen(3, 300)), gen).unwrap());
        drop(store);
        assert!(OfflineStore::open(root.clone()).unwrap().pending_listens().is_empty());
        std::fs::remove_dir_all(root).unwrap();
    }

    fn write_lyrics(root: &Path, id: i64, lyrics: Option<StoredLyrics>) {
        std::fs::write(lyrics_path(root, id), serde_json::to_vec(&LyricsFile { lyrics, checked: today() }).unwrap()).unwrap();
    }

    #[test]
    fn missing_or_unsynced_lyrics_are_asked_again_after_a_week() {
        let root = root("lyrics-due");
        let store = OfflineStore::open(root.clone()).unwrap();
        for id in [1, 2, 3, 4] {
            insert_file(&store, id);
        }
        write_lyrics(&root, 1, Some(sample_lyrics())); // synchronisées : jamais redemandées
        write_lyrics(&root, 2, None); // absence vérifiée aujourd'hui : pas encore
        // Fichier d'avant cette version (sans date) : absence redemandée.
        std::fs::write(lyrics_path(&root, 3), br#"{"lyrics":null}"#).unwrap();
        assert!(!store.lyrics_due(1) && !store.lyrics_due(2) && store.lyrics_due(3) && store.lyrics_due(4));
        assert_eq!(store.lyrics(3), Some(None), "l'ancien fichier se lit toujours");
        // Paroles arrivées : gardées, et lues sans réseau.
        store.save_lyrics(3, Some(sample_lyrics())).unwrap();
        assert_eq!(store.lyrics(3), Some(Some(sample_lyrics())));
        assert!(!store.lyrics_due(3));
        std::fs::remove_dir_all(root).unwrap();
    }

    fn sample_lyrics() -> StoredLyrics {
        StoredLyrics {
            synced: true,
            lines: vec![StoredLyricLine { ms: 1200, text: "Première ligne".into() }, StoredLyricLine { ms: 4800, text: "Deuxième".into() }],
            copyright: "© Éditeur".into(),
        }
    }

    #[test]
    fn lyrics_of_downloaded_tracks_are_read_offline() {
        let root = root("lyrics-read");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 1);
        insert_file(&store, 2);
        insert_file(&store, 3);
        write_lyrics(&root, 1, Some(sample_lyrics()));
        write_lyrics(&root, 2, None); // Deezer n'a pas de paroles pour ce titre
        assert_eq!(store.lyrics(1), Some(Some(sample_lyrics())));
        assert_eq!(store.lyrics(2), Some(None), "absence connue : pas besoin de redemander");
        assert_eq!(store.lyrics(3), None, "pas encore gardées : à demander");
        // Fichier abîmé : considéré comme absent (sera redemandé).
        std::fs::write(lyrics_path(&root, 3), b"{broken").unwrap();
        assert_eq!(store.lyrics(3), None);
        // Titre non téléchargé : rien, même si un fichier traîne.
        write_lyrics(&root, 99, Some(sample_lyrics()));
        assert_eq!(store.lyrics(99), None);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn lyrics_are_removed_with_the_track_and_on_logout() {
        let root = root("lyrics-remove");
        let store = OfflineStore::open(root.clone()).unwrap();
        // Le titre 2 est téléchargé avec sa playlist (enregistrée avant lui).
        let collection = OfflineCollection::new("playlist".into(), 10, true, "P".into(), String::new(), None, vec![2]);
        store_collection(Arc::new(DeezerClient::new().unwrap()), store.clone(), collection).await.unwrap();
        for id in [1, 2, 3] {
            insert_file(&store, id);
            write_lyrics(&root, id, Some(sample_lyrics()));
        }
        // Supprimé seul, ou avec sa playlist : ses paroles partent aussi.
        store.remove(1).unwrap();
        assert!(!lyrics_path(&root, 1).exists());
        store.remove_collection("playlist", 10).unwrap();
        assert!(!lyrics_path(&root, 2).exists());
        assert!(lyrics_path(&root, 3).exists());
        // Déconnexion : plus rien.
        store.clear().unwrap();
        assert!(std::fs::read_dir(root.join("lyrics")).unwrap().next().is_none());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn orphan_lyrics_are_cleaned_at_startup() {
        let root = root("lyrics-orphans");
        let store = OfflineStore::open(root.clone()).unwrap();
        insert_file(&store, 1);
        write_lyrics(&root, 1, Some(sample_lyrics()));
        write_lyrics(&root, 2, Some(sample_lyrics())); // titre plus téléchargé
        std::fs::write(root.join("lyrics/1.json.tmp"), b"partiel").unwrap(); // écriture interrompue
        drop(store);
        let store = OfflineStore::open(root.clone()).unwrap();
        assert!(lyrics_path(&root, 1).exists());
        assert!(!lyrics_path(&root, 2).exists());
        assert!(!root.join("lyrics/1.json.tmp").exists());
        assert_eq!(store.lyrics(1), Some(Some(sample_lyrics())));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn pending_listens_are_capped() {
        let root = root("listens-cap");
        let store = OfflineStore::open(root.clone()).unwrap();
        for i in 0..(MAX_PENDING_LISTENS as u64 + 5) {
            store.queue_listen(listen(1, i), 0).unwrap();
        }
        let list = store.pending_listens();
        assert_eq!(list.len(), MAX_PENDING_LISTENS);
        assert_eq!(list[0].started_at, 5, "les plus anciennes sont oubliées");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn imported_track_is_saved_before_its_cover_which_follows_in_background() {
        let (base, _) = counting_image_server();
        let root = root("import-cover-later");
        let store = OfflineStore::open(root.clone()).unwrap();
        let (mut pending, source, _) = native_pending(&root);
        pending.info.cover_url = Some(cover_url(&base, "0123456789abcdef0123456789abcdef"));
        pending.info.album_id = 0;
        store.save_pending(pending).unwrap();
        let pending = store.pending(42).unwrap();
        let entry = import_download(api(), store.clone(), pending, source).await.unwrap();
        // Rendu sans attendre la pochette.
        assert_eq!(entry.cover, None);
        assert!(store.contains(42));
        // Elle arrive juste après.
        let mut cover = None;
        for _ in 0..100 {
            cover = store.entries.read().unwrap().get(&42).and_then(|e| e.cover.clone());
            if cover.is_some() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        let cover = cover.expect("pochette enregistrée en arrière-plan");
        assert_eq!(std::fs::read(root.join(&cover)).unwrap(), GOOD_JPEG);
        assert_eq!(store.entries.read().unwrap()[&42].cover_version, COVER_VERSION);
        // Gardée aussi après une relance.
        drop(store);
        assert!(OfflineStore::open(root.clone()).unwrap().local(42).unwrap().info.cover_url.unwrap().ends_with(".jpg"));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn cancelled_native_import_is_not_stored() {
        let root = root("native-cancelled");
        let store = OfflineStore::open(root.clone()).unwrap();
        let (pending, source, _) = native_pending(&root);
        store.save_pending(pending.clone()).unwrap();
        // Annulé (ou compte déconnecté) pendant le déchiffrement.
        store.remove_pending(42).unwrap();

        let result = import_download(Arc::new(DeezerClient::new().unwrap()), store.clone(), pending, source).await;
        assert!(matches!(result, Err(DownloadError::Cancelled)));
        assert!(store.local(42).is_none());
        assert!(!audio_path(&root, 42, "mp3").exists());
        std::fs::remove_dir_all(root).unwrap();
    }
}
