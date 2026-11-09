//! Pont entre le cœur Rust (`dz-core`) et l'app iOS, généré par UniFFI.
//!
//! Aucun son ne traverse ce pont : `dz-audio` écrit le PCM directement dans le tampon de sortie
//! de RemoteIO. Ici ne passent que des commandes, des fiches à afficher et des événements rares
//! (changement de titre, play/pause/seek), jamais la position à chaque seconde.

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use dz_api::{Card as ApiCard, Collection as ApiCollection, DeezerClient, Quality, TrackInfo};
use dz_core::{spawn_player, CoreEvent, PlayerCmd, PlayerHandle, QueueEdit, RepeatMode};
use dz_offline::{DownloadError, OfflineCollection, OfflineStore, PendingDownload};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use tokio::runtime::Runtime;

uniffi::setup_scaffolding!();

// Même trousseau que la version bureau.
const SERVICE: &str = "deezer-lite";
const USER: &str = "arl";
/// Fiches de titres gardées côté Rust (Swift n'a que les identifiants) ; au-delà, les plus anciennes sont oubliées.
const MAX_TRACKS: usize = 5000;
/// Écart toléré entre la position extrapolée par Swift et la vraie avant de renvoyer un état.
const DRIFT_MS: u64 = 1500;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("{0}")]
    Api(String),
    #[error("trousseau : {0}")]
    Keychain(String),
    #[error("lecteur indisponible")]
    Player,
    #[error("titre inconnu : recharge la page")]
    UnknownTrack,
}

impl From<dz_api::DeezerError> for CoreError {
    fn from(e: dz_api::DeezerError) -> Self {
        // Même message lisible que pour le lecteur (réseau trop faible, etc.).
        let raw = e.to_string();
        Self::Api(friendly_error(&raw).unwrap_or(raw))
    }
}

impl From<DownloadError> for CoreError {
    fn from(e: DownloadError) -> Self {
        let raw = e.to_string();
        Self::Api(friendly_error(&raw).unwrap_or(raw))
    }
}

/// Un profil d'un compte Deezer Famille (ou le compte lui-même, pour un compte solo).
#[derive(Debug, Clone, uniffi::Record)]
pub struct Profile {
    pub id: u64,
    pub name: String,
    pub picture_url: Option<String>,
    /// Profil enfant (Deezer Kids).
    pub kid: bool,
    /// Titulaire du compte.
    pub main: bool,
    /// Profil ouvert en ce moment.
    pub current: bool,
}

impl From<dz_api::Profile> for Profile {
    fn from(p: dz_api::Profile) -> Self {
        Self { id: p.id, name: p.name, picture_url: p.picture_url, kid: p.kid, main: p.main, current: p.current }
    }
}

/// « Mon mois » : récap mensuel officiel de Deezer (My Deezer Month).
#[derive(Debug, Clone, uniffi::Record)]
pub struct MonthStats {
    pub year: u32,
    pub month: u32,
    pub minutes: u32,
    pub average_minutes: u32,
    pub previous_minutes: Option<u32>,
    pub streams: u32,
    pub tracks: u32,
    pub artists: u32,
    pub discovered: u32,
    pub top_artists: Vec<StatArtist>,
    pub top_tracks: Vec<StatTrack>,
    pub top_genres: Vec<StatGenre>,
    /// « morning », « afternoon », « evening » ou « night ».
    pub period: Option<String>,
    /// Mois disponibles, du plus récent au plus ancien.
    pub months: Vec<StatMonth>,
}

/// Pochette à remplacer dans une page (voir `check_covers`).
#[derive(Debug, Clone, uniffi::Record)]
pub struct CoverFix {
    pub id: i64,
    pub cover_url: String,
}

/// Une écoute de l'historique officiel de Deezer (celles qui comptent dans les statistiques).
#[derive(Debug, Clone, uniffi::Record)]
pub struct RecentListen {
    pub track_id: i64,
    pub title: String,
    pub artist: String,
    pub cover_url: Option<String>,
    /// Début de l'écoute (secondes Unix).
    pub listened_at: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct StatMonth {
    pub year: u32,
    pub month: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct StatArtist {
    pub id: u64,
    pub name: String,
    pub picture_url: Option<String>,
    pub minutes: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct StatTrack {
    pub id: i64,
    pub title: String,
    pub artist: String,
    pub album_id: u64,
    pub cover_url: Option<String>,
    pub streams: u32,
    pub minutes: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct StatGenre {
    pub name: String,
    pub minutes: u32,
}

impl From<dz_api::MonthStats> for MonthStats {
    fn from(s: dz_api::MonthStats) -> Self {
        Self {
            year: s.year,
            month: s.month,
            minutes: s.minutes,
            average_minutes: s.average_minutes,
            previous_minutes: s.previous_minutes,
            streams: s.streams,
            tracks: s.tracks,
            artists: s.artists,
            discovered: s.discovered,
            top_artists: s.top_artists.into_iter().map(|a| StatArtist { id: a.id, name: a.name, picture_url: a.picture_url, minutes: a.minutes }).collect(),
            top_tracks: s
                .top_tracks
                .into_iter()
                .map(|t| StatTrack { id: t.id, title: t.title, artist: t.artist, album_id: t.album_id, cover_url: t.cover_url, streams: t.streams, minutes: t.minutes })
                .collect(),
            top_genres: s.top_genres.into_iter().map(|g| StatGenre { name: g.name, minutes: g.minutes }).collect(),
            period: s.period,
            months: s.months.into_iter().map(|(year, month)| StatMonth { year, month }).collect(),
        }
    }
}

/// Un artiste crédité sur un titre (principal ou feat).
#[derive(Debug, Clone, uniffi::Record)]
pub struct ArtistRef {
    pub id: u64,
    pub name: String,
}

/// Ce que l'interface affiche d'un titre. Le reste (jeton, remplacements) reste dans Rust.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Track {
    pub id: i64,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_s: u64,
    pub cover_url: Option<String>,
    pub quality: Option<String>,
    pub artist_id: u64,
    pub album_id: u64,
    /// Ajout aux titres aimés (secondes Unix), pour le tri.
    pub added_at: Option<u64>,
    /// Sortie « AAAA-MM-JJ », pour le tri.
    pub release_date: Option<String>,
    /// Tous les artistes crédités, dans l'ordre de Deezer (pour « Aller à l'artiste » sur un feat).
    pub artists: Vec<ArtistRef>,
}

impl From<&TrackInfo> for Track {
    fn from(t: &TrackInfo) -> Self {
        Self {
            id: t.id,
            title: t.title.clone(),
            // Avec les feats quand Deezer les donne, comme sur le bureau.
            artist: if t.artists.len() > 1 { t.artists.iter().map(|a| a.name.as_str()).collect::<Vec<_>>().join(", ") } else { t.artist.clone() },
            album: t.album.clone(),
            duration_s: t.duration_s,
            cover_url: t.cover_url.clone(),
            quality: t.quality.clone(),
            artist_id: t.artist_id,
            album_id: t.album_id,
            added_at: t.added_at,
            release_date: t.release_date.clone(),
            artists: t.artists.iter().filter(|a| a.id != 0).map(|a| ArtistRef { id: a.id, name: a.name.clone() }).collect(),
        }
    }
}

fn tracks(list: &[TrackInfo]) -> Vec<Track> {
    list.iter().map(Track::from).collect()
}

/// Playlist, album, artiste, mix ou genre.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct Card {
    /// "playlist" | "album" | "artist" | "mix" | "page" ...
    pub kind: String,
    pub id: u64,
    pub title: String,
    pub subtitle: String,
    pub cover_url: Option<String>,
    /// Playlist créée par l'utilisateur.
    pub owned: bool,
    /// Identifiant texte des éléments sans identifiant numérique (mixes, pages de genre).
    pub key: String,
}

impl From<ApiCard> for Card {
    fn from(c: ApiCard) -> Self {
        Self { kind: c.kind.to_owned(), id: c.id, title: c.title, subtitle: c.subtitle, cover_url: c.cover_url, owned: c.owned, key: c.key }
    }
}

fn cards(list: Vec<ApiCard>) -> Vec<Card> {
    list.into_iter().map(Card::from).collect()
}

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
/// Rangée de l'accueil (« Section » est déjà un type SwiftUI).
pub struct Shelf {
    pub kind: String,
    pub title: String,
    pub items: Vec<Card>,
}

#[derive(Debug, Clone, uniffi::Record)]
/// Page d'une playlist, d'un album, d'un artiste ou d'un mix (« Collection » est déjà un type Swift).
pub struct Detail {
    pub kind: String,
    pub id: u64,
    pub owned: bool,
    pub title: String,
    pub subtitle: String,
    pub cover_url: Option<String>,
    pub tracks: Vec<Track>,
    /// Discographie (page artiste).
    pub albums: Vec<Card>,
    pub latest: Option<Card>,
    pub related: Vec<Card>,
    /// Copie hors ligne (Deezer injoignable) : seuls les titres déjà sur le téléphone. À ne jamais réenregistrer
    /// comme collection téléchargée, sinon les titres manquants en disparaîtraient.
    #[uniffi(default = false)]
    pub offline: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchResults {
    pub tracks: Vec<Track>,
    pub albums: Vec<Card>,
    pub artists: Vec<Card>,
    pub playlists: Vec<Card>,
}

/// Une ligne de paroles ; `ms` = instant d'affichage (0 si les paroles ne sont pas synchronisées).
#[derive(Debug, Clone, uniffi::Record)]
pub struct LyricLine {
    pub ms: u64,
    pub text: String,
}

/// Paroles de Deezer (uniquement Deezer, pas de source de secours).
#[derive(Debug, Clone, uniffi::Record)]
pub struct Lyrics {
    pub synced: bool,
    pub lines: Vec<LyricLine>,
    pub copyright: String,
}

/// Qualité audio demandée (Deezer se rabat sur la meilleure disponible pour le compte).
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum AudioQuality {
    Flac,
    Mp3High,
    Mp3Low,
}

impl From<AudioQuality> for Quality {
    fn from(quality: AudioQuality) -> Self {
        match quality {
            AudioQuality::Flac => Quality::Flac,
            AudioQuality::Mp3High => Quality::Mp3320,
            AudioQuality::Mp3Low => Quality::Mp3128,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DownloadState {
    Queued,
    Downloading,
    Complete,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DownloadUpdate {
    pub id: i64,
    pub state: DownloadState,
    pub progress: f64,
    pub error: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PreparedDownload {
    pub id: i64,
    pub url: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DownloadCollection {
    pub key: String,
    pub kind: String,
    pub id: u64,
    pub owned: bool,
    pub title: String,
    pub subtitle: String,
    pub cover_url: Option<String>,
    pub downloaded: u32,
    pub total: u32,
}

/// Une ligne de crédits : un rôle (composition, production…) et les personnes.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CreditRole {
    pub role: String,
    pub names: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Credits {
    pub roles: Vec<CreditRole>,
    /// Label et date de sortie, quand Deezer les donne.
    pub label: Option<String>,
    pub release_date: Option<String>,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum Repeat {
    Off,
    All,
    One,
}

/// État de lecture lu directement dans les atomiques du moteur : aucune allocation.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Status {
    pub playing: bool,
    pub position_ms: u64,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum Event {
    /// Nouveau titre en cours (envoyé dès que l'adresse du flux est obtenue, puis quand il devient audible).
    Track { track: Track },
    /// Le titre demandé par l'utilisateur est audible : fin du chargement.
    Started,
    /// Lecture/pause, saut dans le titre, changement de titre ou position qui dérive : jamais à chaque seconde.
    State { status: Status },
    Error { message: String },
    /// Lecture arrêtée (fin de file).
    Stopped,
    /// Titre fermé, file vidée.
    Closed,
    /// Nouvelle file complète.
    Queue { tracks: Vec<Track>, index: u32 },
    /// Seul le titre en cours a changé dans la file.
    QueueIndex { index: u32 },
    /// Petites modifications : seuls les titres concernés voyagent.
    QueueInsert { at: u32, tracks: Vec<Track>, index: u32 },
    QueueRemove { at: u32, index: u32 },
    QueueMove { from: u32, to: u32, index: u32 },
    DownloadsChanged,
}

/// Implémenté en Swift. Appelé depuis un thread Rust : Swift le renvoie lui-même au thread principal.
#[uniffi::export(callback_interface)]
pub trait Listener: Send + Sync {
    fn on_event(&self, event: Event);
}

/// Fiches de titres connues, les plus anciennes oubliées en premier. Avant, tout le cache était vidé d'un coup au-delà
/// de la limite : la page ouverte (titres aimés de plusieurs milliers de titres…) renvoyait alors « titre inconnu ».
#[derive(Default)]
struct TrackCache {
    tracks: HashMap<i64, (TrackInfo, u64)>,
    order: BTreeMap<u64, i64>,
    next: u64,
}

impl TrackCache {
    fn get(&self, id: &i64) -> Option<&TrackInfo> {
        self.tracks.get(id).map(|(info, _)| info)
    }

    fn contains_key(&self, id: &i64) -> bool {
        self.tracks.contains_key(id)
    }

    fn insert(&mut self, info: TrackInfo) {
        let stamp = self.next;
        self.next += 1;
        if let Some((_, old)) = self.tracks.insert(info.id, (info.clone(), stamp)) {
            self.order.remove(&old);
        }
        self.order.insert(stamp, info.id);
    }

    fn evict(&mut self, keep: usize) {
        while self.tracks.len() > keep {
            let Some((_, id)) = self.order.pop_first() else { break };
            self.tracks.remove(&id);
        }
    }

    fn clear(&mut self) {
        *self = Self::default();
    }
}

type Known = Arc<Mutex<TrackCache>>;

/// Titre lancé par l'utilisateur, en attente de son : le lecteur l'annonce deux fois (flux obtenu, puis son audible) ;
/// la seconde annonce donne le signal `Started` à l'interface.
#[derive(Default)]
struct PendingStart {
    waiting: bool,
    tracks_seen: u8,
}

type SharedStart = Arc<Mutex<PendingStart>>;

#[derive(uniffi::Object)]
pub struct Core {
    rt: Runtime,
    api: Arc<DeezerClient>,
    player: PlayerHandle,
    known: Known,
    start: SharedStart,
    /// Demande de renvoyer l'état réel à Swift au prochain tour, même s'il n'a pas changé (voir `refresh_state`).
    force_state: Arc<AtomicBool>,
    /// Dossier Caches de l'app : dernière copie de l'accueil et de la bibliothèque, affichée dès le lancement.
    cache_dir: PathBuf,
    offline: OfflineStore,
    download_quality: Arc<RwLock<Quality>>,
    /// Pour prévenir Swift en dehors des événements du lecteur (pochettes réparées après l'ouverture de la session).
    listener: Arc<dyn Listener>,
    /// Dernier compte ou profil ouvert connu (voir `loved_owner`).
    last_user: AtomicU64,
}

#[uniffi::export]
impl Core {
    /// À créer une seule fois, après la configuration de `AVAudioSession`.
    /// `cache_dir` : dossier Caches de l'app (iOS peut le vider : ce n'est qu'une copie pour afficher plus vite).
    /// `download_dir` : stockage persistant des titres et pochettes téléchargés.
    #[uniffi::constructor]
    pub fn new(listener: Box<dyn Listener>, cache_dir: String, download_dir: String) -> Result<Arc<Self>, CoreError> {
        let cache_dir = PathBuf::from(cache_dir);
        let _ = std::fs::create_dir_all(&cache_dir);
        let offline = OfflineStore::open(PathBuf::from(download_dir)).map_err(|e| CoreError::Api(e.to_string()))?;
        // Peu de threads : 2 pour le réseau et le lecteur, 4 au maximum pour les tâches bloquantes (512 par défaut).
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .max_blocking_threads(4)
            .thread_keep_alive(Duration::from_secs(10))
            .thread_name("dz-core")
            .enable_all()
            .build()
            .map_err(|e| CoreError::Api(e.to_string()))?;
        let api = Arc::new(DeezerClient::new()?);
        // Pochettes supprimées chez Deezer et déjà remplacées : gardées d'un lancement à l'autre (dans les Caches :
        // si iOS les vide, une pochette est simplement réparée de nouveau à sa prochaine lecture).
        // Ancien fichier oublié : il pouvait donner à tous les titres d'un album retiré la pochette de l'un d'eux.
        let _ = std::fs::remove_file(cache_dir.join("cover-fixes.json"));
        api.use_cover_fixes_file(cache_dir.join("covers.json"));
        let (ev_tx, mut ev_rx) = tokio::sync::mpsc::unbounded_channel();
        let player = {
            let _guard = rt.enter();
            spawn_player(api.clone(), Some(Arc::new(|id| Some(dz_decrypt::decryptor(id)))), Some(offline.clone()), ev_tx)
        };
        let known: Known = Arc::default();
        remember(&known, offline.infos());
        let start: SharedStart = Arc::default();
        let listener: Arc<dyn Listener> = Arc::from(listener);
        let download_quality = Arc::new(RwLock::new(Quality::Flac));
        let cover_listener = listener.clone();
        let cover_store = offline.clone();
        let cover_api = api.clone();
        rt.spawn(async move {
            dz_offline::repair_covers(cover_api, cover_store).await;
            cover_listener.on_event(Event::DownloadsChanged);
        });

        // Événements du lecteur -> Swift.
        let l = listener.clone();
        let k = known.clone();
        let d = start.clone();
        rt.spawn(async move {
            while let Some(ev) = ev_rx.recv().await {
                let out = match ev {
                    CoreEvent::Track(t) => {
                        // Le lecteur annonce le titre deux fois : flux obtenu, puis son audible (`TrackStarted`).
                        let mut started = false;
                        if let Ok(mut d) = d.lock() {
                            if d.waiting {
                                d.tracks_seen += 1;
                                if d.tracks_seen >= 2 {
                                    d.waiting = false;
                                    started = true;
                                }
                            }
                        }
                        l.on_event(Event::Track { track: (&t).into() });
                        if started {
                            l.on_event(Event::Started);
                        }
                        continue;
                    }
                    // Messages techniques traduits ; échec de préparation du titre suivant : rien à dire (réessayé au moment de le jouer).
                    CoreEvent::Error(message) => match friendly_error(&message) {
                        Some(message) => Event::Error { message },
                        None => continue,
                    },
                    CoreEvent::Stopped => Event::Stopped,
                    CoreEvent::Closed => Event::Closed,
                    CoreEvent::Queue { tracks: list, index } => {
                        let out = Event::Queue { tracks: tracks(&list), index: index as u32 };
                        remember(&k, list);
                        out
                    }
                    CoreEvent::QueueIndex(index) => Event::QueueIndex { index: index as u32 },
                    CoreEvent::QueueEdit(QueueEdit::Insert { at, tracks: list, index }) => {
                        let out = Event::QueueInsert { at: at as u32, tracks: tracks(&list), index: index as u32 };
                        remember(&k, list);
                        out
                    }
                    CoreEvent::QueueEdit(QueueEdit::Remove { at, index }) => Event::QueueRemove { at: at as u32, index: index as u32 },
                    CoreEvent::QueueEdit(QueueEdit::Move { from, to, index }) => {
                        Event::QueueMove { from: from as u32, to: to as u32, index: index as u32 }
                    }
                };
                l.on_event(out);
            }
        });

        // `changed` est notifié à chaque tour du lecteur (au moins une fois par seconde) : on ne renvoie à Swift
        // que ce qu'il ne peut pas deviner. Écran verrouillé, le thread principal n'est donc pas réveillé chaque seconde.
        let changed = player.changed.clone();
        let shared = player.shared.clone();
        let force_state = Arc::new(AtomicBool::new(false));
        let force = force_state.clone();
        let kept_listener = listener.clone();
        rt.spawn(async move {
            let mut last: Option<(Status, i64, Instant)> = None;
            let notified = changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable(); // inscrit avant d'attendre : aucune notification perdue entre deux tours
            loop {
                notified.as_mut().await;
                notified.set(changed.notified());
                notified.as_mut().enable();
                let now = Status {
                    playing: shared.playing.load(Ordering::Relaxed),
                    position_ms: shared.position_ms.load(Ordering::Relaxed),
                    duration_ms: shared.duration_ms.load(Ordering::Relaxed),
                };
                let id = shared.current_id.load(Ordering::Relaxed);
                let forced = force.swap(false, Ordering::AcqRel);
                let send = forced || match last {
                    None => true,
                    Some((s, last_id, at)) => {
                        let expected = if s.playing { s.position_ms + at.elapsed().as_millis() as u64 } else { s.position_ms };
                        s.playing != now.playing
                            || last_id != id
                            || s.duration_ms != now.duration_ms
                            || now.position_ms.abs_diff(expected) > DRIFT_MS
                    }
                };
                if send {
                    last = Some((now, id, Instant::now()));
                    listener.on_event(Event::State { status: now });
                }
            }
        });

        Ok(Arc::new(Self {
            rt, api, player, known, start, force_state, cache_dir, offline, download_quality, listener: kept_listener,
            last_user: AtomicU64::new(0),
        }))
    }

    // --- Compte

    /// Rouvre la session avec l'ARL du trousseau. `false` = afficher l'écran de connexion.
    pub async fn restore_session(&self) -> Result<bool, CoreError> {
        let arl = match keyring::Entry::new(SERVICE, USER).and_then(|e| e.get_password()) {
            Ok(a) => a,
            Err(keyring::Error::NoEntry) => return Ok(false),
            Err(e) => return Err(CoreError::Keychain(e.to_string())),
        };
        self.api.set_arl(&arl)?;
        let api = self.api.clone();
        // ARL refusé = retour à l'écran de connexion ; réseau absent = erreur, l'app reste ouverte sur sa copie locale.
        match self.run(async move { api.init_session().await }).await? {
            Ok(_) => {
                // Session ouverte : les écoutes gardées sans réseau (titres téléchargés) partent maintenant.
                let _ = self.player.send(PlayerCmd::FlushListens);
                self.repair_lyrics();
                Ok(true)
            }
            Err(dz_api::DeezerError::InvalidArl) => Ok(false),
            Err(e) => Err(e.into()),
        }
    }

    /// ARL présent dans le trousseau : l'interface peut s'ouvrir tout de suite, sans attendre Deezer.
    pub fn has_saved_login(&self) -> bool {
        keyring::Entry::new(SERVICE, USER).and_then(|e| e.get_password()).is_ok()
    }

    /// Dernier accueil chargé (vide si aucun).
    pub fn cached_home(&self) -> Vec<Shelf> {
        self.restore("home.json").unwrap_or_default()
    }

    /// 0 = playlists, 1 = albums, 2 = artistes.
    pub fn cached_library(&self, tab: u8) -> Vec<Card> {
        self.restore(&format!("library-{tab}.json")).unwrap_or_default()
    }

    pub fn cached_loved_ids(&self) -> Vec<i64> {
        self.restore("loved-ids.json").unwrap_or_default()
    }

    /// Valide l'ARL auprès de Deezer, puis l'enregistre dans le trousseau.
    pub async fn login(&self, arl: String) -> Result<(), CoreError> {
        let arl = arl.trim().to_owned();
        self.api.set_arl(&arl)?;
        let api = self.api.clone();
        self.run(async move { api.init_session().await.map(|_| ()) }).await??;
        keyring::Entry::new(SERVICE, USER)
            .and_then(|e| e.set_password(&arl))
            .map_err(|e| CoreError::Keychain(e.to_string()))?;
        let _ = self.player.send(PlayerCmd::FlushListens);
        self.repair_lyrics();
        Ok(())
    }

    /// Toutes les étapes sont faites même si l'une échoue (avant, un échec d'effacement des téléchargements laissait
    /// la session et le trousseau en place) ; la première erreur est renvoyée à la fin.
    pub async fn logout(&self) -> Result<(), CoreError> {
        let mut first_error: Option<CoreError> = None;
        let _ = self.player.send(PlayerCmd::Close);
        if let Err(e) = self.offline.clear() {
            first_error.get_or_insert(CoreError::Api(e.to_string()));
        }
        // Rien du compte ne reste : fiches de titres en mémoire, copies locales, session, cookies, trousseau.
        if let Ok(mut known) = self.known.lock() {
            known.clear();
        }
        if let Ok(files) = std::fs::read_dir(&self.cache_dir) {
            for path in files.flatten().map(|f| f.path()) {
                if path.extension().is_some_and(|ext| ext == "json" || ext == "tmp") {
                    let _ = std::fs::remove_file(path);
                }
            }
        }
        let api = self.api.clone();
        if let Err(e) = self.run(async move { api.clear_session().await }).await {
            first_error.get_or_insert(e);
        }
        match keyring::Entry::new(SERVICE, USER).and_then(|e| e.delete_credential()) {
            Ok(()) | Err(keyring::Error::NoEntry) => {}
            Err(e) => {
                first_error.get_or_insert(CoreError::Keychain(e.to_string()));
            }
        }
        first_error.map_or(Ok(()), Err)
    }

    // --- Profils (compte Deezer Famille)

    /// Profil à ouvrir à la connexion (celui choisi la dernière fois ; `None` : le titulaire). À appeler avant
    /// `restore_session` / `login`.
    pub fn set_profile(&self, id: Option<u64>) {
        self.api.set_profile(id);
    }

    /// Récap mensuel officiel de Deezer : le mois demandé (`year` et `month`), ou le dernier disponible (0 et 0).
    /// `None` : pas encore de récap.
    pub async fn month_stats(&self, year: u32, month: u32) -> Result<Option<MonthStats>, CoreError> {
        let api = self.api.clone();
        let which = (year > 0 && month > 0).then_some((year, month));
        let s = self.run(async move { api.month_stats(which).await }).await??;
        Ok(s.map(MonthStats::from))
    }

    /// Vérifie les pochettes d'une page, après son affichage : renvoie celles à remplacer.
    pub async fn check_covers(&self, tracks: Vec<Track>) -> Result<Vec<CoverFix>, CoreError> {
        let api = self.api.clone();
        let items: Vec<(i64, String, u64)> = tracks.into_iter().filter_map(|t| Some((t.id, t.cover_url?, t.album_id))).collect();
        let fixes = self.run(async move { api.check_covers(items).await }).await?;
        Ok(fixes.into_iter().map(|(id, cover_url)| CoverFix { id, cover_url }).collect())
    }

    /// Les 5 dernières écoutes de l'historique officiel de Deezer (compte ou profil ouvert).
    pub async fn recent_listens(&self) -> Result<Vec<RecentListen>, CoreError> {
        let api = self.api.clone();
        let list = self.run(async move { api.recent_listens(5).await }).await??;
        Ok(list
            .into_iter()
            .map(|l| RecentListen { track_id: l.track_id, title: l.title, artist: l.artist, cover_url: l.cover_url, listened_at: l.listened_at })
            .collect())
    }

    /// Profils que l'on peut ouvrir ; compte solo : le compte seul.
    pub async fn profiles(&self) -> Result<Vec<Profile>, CoreError> {
        let api = self.api.clone();
        let list = self.run(async move { api.profiles().await }).await??;
        Ok(list.into_iter().map(Profile::from).collect())
    }

    /// Ouvre le profil `id` (bibliothèque, titres aimés, recommandations deviennent les siens). Refusé : le profil
    /// d'avant reste ouvert et l'erreur l'explique.
    pub async fn switch_profile(&self, id: u64) -> Result<(), CoreError> {
        let api = self.api.clone();
        self.run(async move { api.switch_profile(id).await.map(|_| ()) }).await??;
        // Écoutes de ce profil gardées sans réseau : elles partent maintenant qu'il est ouvert.
        let _ = self.player.send(PlayerCmd::FlushListens);
        Ok(())
    }

    /// Profil ouvert en ce moment (0 si aucune session).
    pub async fn current_profile_id(&self) -> u64 {
        self.api.session().await.map_or(0, |s| s.user_id)
    }

    // --- Catalogue

    pub async fn home(&self) -> Result<Vec<Shelf>, CoreError> {
        let api = self.api.clone();
        let (sections, loved) = self.run(async move { (api.home_sections().await, loved_id(&api).await) }).await?;
        let out: Vec<Shelf> = sections?
            .into_iter()
            .filter(|s| !s.items.is_empty())
            .map(|s| Shelf { kind: s.kind.to_owned(), title: s.title, items: mark_loved(cards(s.items), loved) })
            .collect();
        self.persist("home.json", &out);
        Ok(out)
    }

    pub async fn search(&self, query: String) -> Result<SearchResults, CoreError> {
        let api = self.api.clone();
        let r = self.run(async move { api.search_all(&query).await }).await??;
        let out = SearchResults { tracks: tracks(&r.tracks), albums: cards(r.albums), artists: cards(r.artists), playlists: cards(r.playlists) };
        remember(&self.known, r.tracks);
        Ok(out)
    }

    pub async fn my_playlists(&self) -> Result<Vec<Card>, CoreError> {
        let api = self.api.clone();
        let (list, loved) = self.run(async move { (api.user_playlists().await, loved_id(&api).await) }).await?;
        // « Coups de cœur » = les titres aimés : en tête de liste, avec l'image choisie sur Deezer ; ouvre la page Titres aimés.
        let mut out = mark_loved(cards(list?), loved);
        if let Some(i) = out.iter().position(|c| c.kind == "loved") {
            let card = out.remove(i);
            out.insert(0, card);
        }
        self.persist("library-0.json", &out);
        Ok(out)
    }

    /// Fiche de la playlist « Coups de cœur » (avec l'image choisie sur Deezer), demandée directement :
    /// elle ne dépend pas de sa présence dans la liste des playlists. `None` si le compte n'en a pas.
    pub async fn loved_card(&self) -> Result<Option<Card>, CoreError> {
        let api = self.api.clone();
        let card = self
            .run(async move {
                let id = loved_id(&api).await;
                if id == 0 {
                    return Ok(None);
                }
                // Interface du site (playlist privée comprise), puis la fiche publique en secours.
                match api.gw::<serde_json::Value>("playlist.getData", &serde_json::json!({ "playlist_id": id.to_string() })).await {
                    Ok(v) => Ok(Some(loved_from_gw(id, &v))),
                    Err(_) => api.playlist_card(id).await.map(|c| Some(Card::from(c))),
                }
            })
            .await??;
        let out = card.map(|mut c| {
            c.kind = "loved".into();
            c
        });
        if let Some(c) = &out {
            self.persist("loved-card.json", c);
        }
        Ok(out)
    }

    /// Dernière fiche « Coups de cœur » connue (affichée dès le lancement).
    pub fn cached_loved_card(&self) -> Option<Card> {
        self.restore("loved-card.json")
    }

    pub async fn my_albums(&self) -> Result<Vec<Card>, CoreError> {
        let api = self.api.clone();
        let out = cards(self.run(async move { api.user_albums().await }).await??);
        self.persist("library-1.json", &out);
        Ok(out)
    }

    pub async fn my_artists(&self) -> Result<Vec<Card>, CoreError> {
        let api = self.api.clone();
        let out = cards(self.run(async move { api.user_artists().await }).await??);
        self.persist("library-2.json", &out);
        Ok(out)
    }

    pub async fn loved(&self) -> Result<Vec<Track>, CoreError> {
        let api = self.api.clone();
        let mut list = self.run(async move { api.loved_tracks().await }).await??;
        // Du plus récent au plus ancien, comme sur le bureau.
        list.sort_by_key(|t| std::cmp::Reverse(t.added_at.unwrap_or(0)));
        let out = tracks(&list);
        self.persist("loved-ids.json", &list.iter().map(|t| t.id).collect::<Vec<_>>());
        remember(&self.known, list);
        Ok(out)
    }

    pub async fn loved_detail(&self) -> Result<Detail, CoreError> {
        match self.loved().await {
            Ok(list) => Ok(Detail {
                kind: "loved".into(),
                id: 0,
                owned: false,
                title: "Titres aimés".into(),
                subtitle: format!("{} titres", list.len()),
                cover_url: self.cached_loved_card().and_then(|card| card.cover_url),
                tracks: list,
                albums: Vec::new(),
                latest: None,
                related: Vec::new(),
                offline: false,
            }),
            Err(error) => self.offline_detail("loved".into(), 0).ok_or(error),
        }
    }

    /// Playlist, album ou artiste.
    pub async fn open_detail(&self, kind: String, id: u64) -> Result<Detail, CoreError> {
        let api = self.api.clone();
        let remote_kind = kind.clone();
        match self.run(async move { api.collection(&remote_kind, id).await }).await? {
            Ok(collection) => Ok(self.detail(collection)),
            Err(error) => self.offline_detail(kind, id).ok_or_else(|| error.into()),
        }
    }

    /// Mix ou page sans identifiant numérique (clé texte d'une carte).
    pub async fn open_mix(&self, key: String) -> Result<Detail, CoreError> {
        let api = self.api.clone();
        let c = self.run(async move { api.mix(&key).await }).await??;
        Ok(self.detail(c))
    }

    /// Ajoute un titre à une playlist de l'utilisateur.
    pub async fn playlist_add(&self, playlist_id: u64, track_id: i64) -> Result<(), CoreError> {
        let api = self.api.clone();
        self.run(async move { api.playlist_add(playlist_id, track_id).await }).await??;
        Ok(())
    }

    /// Retire un titre d'une playlist de l'utilisateur.
    pub async fn playlist_remove(&self, playlist_id: u64, track_id: i64) -> Result<(), CoreError> {
        let api = self.api.clone();
        self.run(async move { api.playlist_remove(playlist_id, track_id).await }).await??;
        Ok(())
    }

    /// Fiche légère d'une playlist (titre, pochette), sans ses titres : pour tenir à jour un épinglé.
    pub async fn playlist_card(&self, id: u64) -> Result<Card, CoreError> {
        let api = self.api.clone();
        let c = self.run(async move { api.playlist_card(id).await }).await??;
        Ok(c.into())
    }

    /// Crédits du titre selon Deezer (artistes, composition, paroles, production…).
    pub async fn credits(&self, id: i64) -> Result<Credits, CoreError> {
        let api = self.api.clone();
        let v: serde_json::Value = self.run(async move { api.gw("song.getData", &serde_json::json!({ "sng_id": id.to_string() })).await }).await??;
        Ok(parse_credits(&v))
    }

    pub fn set_quality(&self, quality: AudioQuality) -> Result<(), CoreError> {
        self.send(PlayerCmd::Quality(quality.into()))
    }

    pub fn set_download_quality(&self, quality: AudioQuality) {
        if let Ok(mut current) = self.download_quality.write() {
            *current = quality.into();
        }
    }

    pub async fn prepare_download(&self, id: i64) -> Result<PreparedDownload, CoreError> {
        if self.offline.contains(id) {
            return Err(CoreError::Api("titre déjà téléchargé".into()));
        }
        let mut info = match self.lookup(&[id]) {
            Ok(mut infos) => infos.remove(0),
            Err(CoreError::UnknownTrack) => {
                let api = self.api.clone();
                self.run(async move { api.track_info(id).await }).await??
            }
            Err(error) => return Err(error),
        };
        if info.track_token.is_none() {
            let api = self.api.clone();
            info = self.run(async move { api.track_info(id).await }).await??;
        }
        let selected = self.download_quality.read().map(|q| *q).unwrap_or(Quality::Flac);
        let api = self.api.clone();
        let resolved = self.run(async move { api.media_with_recovery(id, Some(info), selected).await }).await??;
        let (media, stream_id, mut info) = (resolved.media, resolved.stream_id, resolved.info);
        let encrypted = match media.cipher {
            dz_api::Cipher::None => false,
            dz_api::Cipher::BlockStripe => true,
            dz_api::Cipher::Other(kind) => return Err(DownloadError::Cipher(kind).into()),
        };
        let ext = if media.format.to_ascii_uppercase().starts_with("FLAC") { "flac" } else { "mp3" }.into();
        info.quality = Some(dz_api::format_label(&media.format));
        info.track_token = None;
        let url = media.url;
        // Demandé hors de toute collection téléchargée : téléchargé pour lui-même, il reste si une collection qui le
        // contient est supprimée plus tard (une collection enregistre sa liste avant de lancer ses titres).
        let pinned = !self.offline.in_collection(id);
        let pending = PendingDownload { info, url: url.clone(), stream_id, ext, encrypted, pinned };
        self.offline.save_pending(pending).map_err(|e| CoreError::Api(e.to_string()))?;
        Ok(PreparedDownload { id, url })
    }

    pub async fn finish_download(&self, id: i64, path: String) -> Result<Track, CoreError> {
        let pending = self.offline.pending(id).ok_or_else(|| CoreError::Api("téléchargement annulé".into()))?;
        let api = self.api.clone();
        let store = self.offline.clone();
        let entry = self.run(async move { dz_offline::import_download(api, store, pending, PathBuf::from(path)).await }).await??;
        remember(&self.known, vec![entry.info.clone()]);
        Ok(Track::from(&entry.info))
    }

    pub async fn download_collection(&self, detail: Detail) -> Result<(), CoreError> {
        // Copie hors ligne : la réenregistrer ferait disparaître de la collection les titres pas encore téléchargés.
        if detail.offline {
            return Ok(());
        }
        let id = self.stored_id(&detail.kind, detail.id);
        let collection = OfflineCollection::new(
            detail.kind,
            id,
            detail.owned,
            detail.title,
            detail.subtitle,
            detail.cover_url,
            detail.tracks.iter().map(|track| track.id).collect(),
        );
        let api = self.api.clone();
        let store = self.offline.clone();
        self.run(async move { dz_offline::store_collection(api, store, collection).await }).await??;
        Ok(())
    }

    pub fn download_collections(&self) -> Vec<DownloadCollection> {
        let loved = self.loved_owner();
        self.offline
            .collections()
            .into_iter()
            // Titres aimés d'un autre profil (compte Famille) ou d'un autre compte : pas ceux de ce profil.
            .filter(|(collection, _)| collection.kind != "loved" || collection.id == loved)
            .map(|(collection, available)| DownloadCollection {
                // Titres aimés : toujours l'identifiant 0 côté app (page Titres aimés).
                key: if collection.kind == "loved" { "loved:0".into() } else { collection.key() },
                id: if collection.kind == "loved" { 0 } else { collection.id },
                kind: collection.kind,
                owned: collection.owned,
                title: collection.title,
                subtitle: collection.subtitle,
                cover_url: collection.cover_url,
                downloaded: available as u32,
                total: collection.track_ids.len() as u32,
            })
            .collect()
    }

    pub fn offline_detail(&self, kind: String, id: u64) -> Option<Detail> {
        let (collection, list) = self.offline.collection(&kind, self.stored_id(&kind, id))?;
        let out = Detail {
            id: if collection.kind == "loved" { 0 } else { collection.id },
            kind: collection.kind,
            owned: collection.owned,
            title: collection.title,
            subtitle: collection.subtitle,
            cover_url: collection.cover_url,
            tracks: tracks(&list),
            albums: Vec::new(),
            latest: None,
            related: Vec::new(),
            offline: true,
        };
        remember(&self.known, list);
        Some(out)
    }

    /// Ajoute un titre à une collection téléchargée (titre aimé, ajout à une playlist), sans recharger toute la collection.
    /// `false` si la collection n'est pas téléchargée ou contient déjà le titre.
    pub fn add_download_track_to_collection(&self, kind: String, id: u64, track_id: i64) -> Result<bool, CoreError> {
        self.offline.add_collection_track(&kind, self.stored_id(&kind, id), track_id).map_err(|e| CoreError::Api(e.to_string()))
    }

    pub fn remove_download_track_from_collection(&self, kind: String, id: u64, track_id: i64) -> Result<bool, CoreError> {
        self.offline.remove_collection_track(&kind, self.stored_id(&kind, id), track_id).map_err(|e| CoreError::Api(e.to_string()))
    }

    pub fn remove_download_collection(&self, kind: String, id: u64) -> Result<Vec<i64>, CoreError> {
        self.offline.remove_collection(&kind, self.stored_id(&kind, id)).map_err(|e| CoreError::Api(e.to_string()))
    }

    pub fn cancel_download(&self, id: i64) {
        let _ = self.offline.remove_pending(id);
    }

    pub fn cancel_download_list(&self, ids: Vec<i64>) {
        let _ = self.offline.remove_pending_many(&ids);
    }

    pub fn cancel_downloads(&self) {
        let _ = self.offline.clear_pending();
    }

    pub fn remove_download(&self, id: i64) -> Result<(), CoreError> {
        self.offline.remove(id).map_err(|e| CoreError::Api(e.to_string()))
    }

    pub fn clear_downloads(&self) -> Result<(), CoreError> {
        self.offline.clear().map_err(|e| CoreError::Api(e.to_string()))
    }

    pub fn downloads(&self) -> Vec<Track> {
        tracks(&self.offline.infos())
    }

    pub fn standalone_downloads(&self) -> Vec<Track> {
        tracks(&self.offline.standalone_infos())
    }

    /// Parcourt tout le dossier des téléchargements : à appeler hors du thread principal.
    pub fn download_bytes(&self) -> u64 {
        self.offline.total_bytes()
    }

    /// Paroles du titre selon Deezer ; `None` si Deezer n'en a pas. Titre téléchargé : lues sur le téléphone (aussi
    /// hors ligne, et sans attendre le réseau) ; Deezer n'est interrogé que si elles n'y sont pas encore.
    pub async fn lyrics(&self, id: i64) -> Result<Option<Lyrics>, CoreError> {
        if let Some(stored) = self.offline.lyrics(id) {
            return Ok(stored.map(|l| Lyrics {
                synced: l.synced,
                lines: l.lines.into_iter().map(|x| LyricLine { ms: x.ms, text: x.text }).collect(),
                copyright: l.copyright,
            }));
        }
        let api = self.api.clone();
        let found = self.run(async move { api.lyrics(id).await }).await??;
        Ok(found.map(|l| Lyrics {
            synced: l.synced,
            lines: l.lines.into_iter().map(|x| LyricLine { ms: x.ms, text: x.text }).collect(),
            copyright: l.copyright,
        }))
    }

    pub async fn set_liked(&self, id: i64, liked: bool) -> Result<(), CoreError> {
        let api = self.api.clone();
        self.run(async move { if liked { api.like_track(id).await } else { api.unlike_track(id).await } }).await??;
        Ok(())
    }

    // --- Lecture

    /// Lance une file à partir d'identifiants déjà reçus (recherche, playlist...).
    pub fn play(&self, ids: Vec<i64>, index: u32) -> Result<(), CoreError> {
        let tracks = self.lookup(&ids)?;
        self.mark_play();
        self.send(PlayerCmd::PlayQueue { tracks, index: index as usize })
    }

    /// Reprend une file gardée sur le téléphone (app relancée après qu'iOS l'a fermée) : fiches redemandées à Deezer
    /// par paquets si le cœur ne les connaît plus, lecture du titre `index` à `position_ms`. Les titres devenus
    /// introuvables sont sautés ; l'index suit le titre visé.
    pub async fn restore_queue(&self, ids: Vec<i64>, index: u32, position_ms: u64) -> Result<(), CoreError> {
        let target = ids.get(index as usize).copied();
        let missing: Vec<i64> = {
            let known = self.known.lock().map_err(|_| CoreError::Player)?;
            ids.iter().copied().filter(|id| !known.contains_key(id)).collect()
        };
        // Titres hors ligne : pas besoin de Deezer (lu hors du verrou : accès disque).
        let missing: Vec<i64> = missing.into_iter().filter(|id| !self.offline.contains(*id)).collect();
        // Fiches reçues gardées ici : le cache peut en oublier une partie pendant une très longue file.
        let mut fetched: HashMap<i64, TrackInfo> = HashMap::new();
        for chunk in missing.chunks(100) {
            let api = self.api.clone();
            let chunk = chunk.to_vec();
            // Un paquet qui échoue n'empêche pas la reprise : ses titres sont sautés.
            if let Ok(Ok(found)) = self.run(async move { api.tracks_info(&chunk).await }).await {
                fetched.extend(found.iter().cloned().map(|t| (t.id, t)));
                remember(&self.known, found);
            }
        }
        let known_now: Vec<Option<TrackInfo>> = {
            let known = self.known.lock().map_err(|_| CoreError::Player)?;
            ids.iter().map(|id| fetched.get(id).cloned().or_else(|| known.get(id).cloned())).collect()
        };
        let tracks: Vec<TrackInfo> = ids
            .iter()
            .zip(known_now)
            .filter_map(|(id, info)| info.or_else(|| self.offline.local(*id).map(|local| local.info)))
            .collect();
        if tracks.is_empty() {
            return Err(CoreError::UnknownTrack);
        }
        let start = target.and_then(|t| tracks.iter().position(|x| x.id == t)).unwrap_or(0);
        let same_track = target == Some(tracks[start].id);
        self.mark_play();
        self.send(PlayerCmd::PlayQueue { tracks, index: start })?;
        // Saut envoyé juste après : le lecteur le traite une fois le titre chargé (les commandes passent dans l'ordre).
        if same_track && position_ms > 0 {
            self.send(PlayerCmd::Seek { ms: position_ms })?;
        }
        Ok(())
    }

    /// Lance un seul titre à partir de son identifiant, même inconnu de cette session (historique de recherche) :
    /// sa fiche est redemandée à Deezer si besoin.
    pub async fn play_by_id(&self, id: i64) -> Result<(), CoreError> {
        let known = self.known.lock().ok().and_then(|k| k.get(&id).cloned()).or_else(|| self.offline.local(id).map(|local| local.info));
        let info = match known {
            Some(t) => t,
            None => {
                let api = self.api.clone();
                let t = self.run(async move { api.track_info(id).await }).await??;
                remember(&self.known, vec![t.clone()]);
                t
            }
        };
        self.mark_play();
        self.send(PlayerCmd::PlayQueue { tracks: vec![info], index: 0 })
    }

    pub async fn play_flow(&self) -> Result<(), CoreError> {
        let api = self.api.clone();
        let tracks = self.run(async move { api.flow().await }).await??;
        // Seulement une fois Flow reçu : si la requête échoue, aucun `Started` parasite au titre suivant.
        self.mark_play();
        self.send(PlayerCmd::PlayFlow { tracks })
    }

    /// Lance le mix inspiré d'un titre (« Mixes inspirés par » de l'accueil).
    pub async fn play_track_mix(&self, id: i64) -> Result<(), CoreError> {
        let api = self.api.clone();
        let list = self.run(async move { api.track_mix(id).await }).await??;
        if list.is_empty() {
            return Err(CoreError::Api("Deezer n'a pas de mix pour ce titre".into()));
        }
        remember(&self.known, list.clone());
        self.mark_play();
        self.send(PlayerCmd::PlayQueue { tracks: list, index: 0 })
    }

    pub fn queue_add(&self, ids: Vec<i64>, next: bool) -> Result<(), CoreError> {
        let tracks = self.lookup(&ids)?;
        self.send(PlayerCmd::QueueAdd { tracks, next })
    }

    pub fn queue_play(&self, index: u32) -> Result<(), CoreError> {
        self.mark_play();
        self.send(PlayerCmd::QueuePlay { index: index as usize })
    }

    pub fn queue_remove(&self, index: u32) -> Result<(), CoreError> {
        self.send(PlayerCmd::QueueRemove { index: index as usize })
    }

    pub fn queue_move(&self, from: u32, to: u32) -> Result<(), CoreError> {
        self.send(PlayerCmd::QueueMove { from: from as usize, to: to as usize })
    }

    pub fn pause(&self) -> Result<(), CoreError> {
        self.player.pause().map_err(|_| CoreError::Player)
    }

    pub fn resume(&self) -> Result<(), CoreError> {
        self.player.resume().map_err(|_| CoreError::Player)
    }

    pub fn toggle(&self) -> Result<(), CoreError> {
        if self.player.shared.playing.load(Ordering::Relaxed) { self.pause() } else { self.resume() }
    }

    pub fn next(&self) -> Result<(), CoreError> {
        self.send(PlayerCmd::Next)
    }

    pub fn previous(&self) -> Result<(), CoreError> {
        self.send(PlayerCmd::Prev)
    }

    pub fn seek(&self, ms: u64) -> Result<(), CoreError> {
        self.send(PlayerCmd::Seek { ms })
    }

    pub fn set_shuffle(&self, on: bool) -> Result<(), CoreError> {
        self.send(PlayerCmd::Shuffle(on))
    }

    pub fn set_repeat(&self, mode: Repeat) -> Result<(), CoreError> {
        self.send(PlayerCmd::Repeat(match mode {
            Repeat::Off => RepeatMode::Off,
            Repeat::All => RepeatMode::All,
            Repeat::One => RepeatMode::One,
        }))
    }

    /// Égaliseur 5 bandes (60 Hz, 230 Hz, 910 Hz, 3,6 kHz, 14 kHz) en dB, de -12 à +12 ; tout à 0 = son d'origine,
    /// sans aucun calcul. Un limiteur doux évite la saturation quand une bande est relevée.
    pub fn set_eq(&self, gains: Vec<f32>) {
        self.player.set_eq_bands(&gains);
    }

    pub fn set_volume(&self, volume: f32) {
        self.player.set_volume(volume);
    }

    /// Fondu enchaîné entre deux titres, en secondes (0 = désactivé, 12 au plus) ; effet dès la prochaine transition.
    pub fn set_crossfade(&self, seconds: u32) {
        self.player.set_crossfade(u64::from(seconds.min(12)) * 1000);
    }

    /// Renvoie tout de suite l'état réel à Swift (événement `State`), même s'il n'a pas changé. Swift l'appelle quand il
    /// a affiché une lecture faite à un instant de transition (chargement d'un titre) : l'état juste suit aussitôt.
    pub fn refresh_state(&self) {
        self.force_state.store(true, Ordering::Release);
        self.player.changed.notify_waiters();
    }

    /// Lecture directe des atomiques (aucune allocation) : pour mettre l'interface à jour juste après une commande.
    pub fn status(&self) -> Status {
        let s = &self.player.shared;
        Status {
            playing: s.playing.load(Ordering::Relaxed),
            position_ms: s.position_ms.load(Ordering::Relaxed),
            duration_ms: s.duration_ms.load(Ordering::Relaxed),
        }
    }

    // --- Cycle de vie iOS

    /// Le réseau a changé (Wi-Fi <-> 4G/5G, retour du réseau) : les prochaines requêtes partent sur des connexions
    /// neuves au lieu d'attendre qu'une connexion de l'ancien réseau expire.
    pub fn network_changed(&self) {
        self.api.reset_connections();
        // Retour du réseau : les écoutes faites hors ligne partent (rien ne se passe sans session ou sans réseau).
        let _ = self.player.send(PlayerCmd::FlushListens);
    }

    /// Appel, Siri, alarme : iOS coupe la sortie.
    pub fn audio_interrupted(&self) {
        let _ = self.player.pause();
    }

    /// Fin d'interruption ou redémarrage du service audio (session déjà réactivée par Swift).
    /// La sortie est toujours rouverte : iOS a arrêté l'ancienne sans erreur, une simple reprise resterait muette.
    pub fn audio_resumed(&self, should_resume: bool) {
        let _ = self.player.send(PlayerCmd::ReopenOutput);
        if should_resume {
            let _ = self.player.resume();
        }
    }
}

impl Core {
    /// Identifiant sous lequel sont gardés les Titres aimés téléchargés du profil ouvert : celui du profil (ou du
    /// compte). La collection « loved » n'avait qu'une place, partagée par tous les profils : passer au profil B
    /// (compte Famille), ou se reconnecter avec un autre compte, montrait comme téléchargés les aimés de A, et la
    /// synchro les remplaçait par ceux de B. Chaque profil a maintenant les siens. Côté app, toujours l'identifiant 0.
    fn loved_owner(&self) -> u64 {
        let me = self
            .api
            .session_user_now()
            .inspect(|&user| self.last_user.store(user, Ordering::Release))
            // Session pas encore ouverte (lancement sans réseau) : le profil choisi, sinon le dernier connu.
            .or_else(|| self.api.wanted_profile())
            .or_else(|| Some(self.last_user.load(Ordering::Acquire)).filter(|&user| user != 0));
        match me {
            Some(me) => {
                // Téléchargés par une version précédente (identifiant 0) : attribués au profil ouvert.
                let _ = self.offline.rekey_collection("loved", 0, me);
                me
            }
            // Profil inconnu (compte sans profils, lancé sans réseau) : les derniers téléchargés.
            None => self.offline.latest_collection_id("loved").unwrap_or(0),
        }
    }

    /// Identifiant d'une collection téléchargée tel qu'il est gardé (voir `loved_owner`).
    fn stored_id(&self, kind: &str, id: u64) -> u64 {
        if kind == "loved" { self.loved_owner() } else { id }
    }

    /// Paroles des titres téléchargés qui n'en ont pas encore (téléchargés avant que les paroles soient gardées, ou
    /// sans réseau à ce moment-là) : récupérées en tâche de fond, une fois la session Deezer ouverte.
    fn repair_lyrics(&self) {
        self.rt.spawn(dz_offline::repair_lyrics(self.api.clone(), self.offline.clone()));
        // Pochettes pas encore vérifiées (app démarrée sans réseau : la vérification du démarrage n'a rien pu faire).
        let (api, store, listener) = (self.api.clone(), self.offline.clone(), self.listener.clone());
        self.rt.spawn(async move {
            dz_offline::repair_covers(api, store).await;
            listener.on_event(Event::DownloadsChanged);
        });
    }

    fn send(&self, cmd: PlayerCmd) -> Result<(), CoreError> {
        self.player.send(cmd).map_err(|_| CoreError::Player)
    }

    /// Exécute un travail réseau sur le runtime du cœur ; Swift l'attend sans bloquer son thread.
    async fn run<T: Send + 'static>(&self, fut: impl std::future::Future<Output = T> + Send + 'static) -> Result<T, CoreError> {
        self.rt.spawn(fut).await.map_err(|e| CoreError::Api(e.to_string()))
    }

    /// Écrit une copie locale en tâche de fond (fichier temporaire puis renommage : jamais de fichier à moitié écrit).
    fn persist<T: Serialize>(&self, name: &str, value: &T) {
        let Ok(bytes) = serde_json::to_vec(value) else { return };
        let path = self.cache_dir.join(name);
        self.rt.spawn_blocking(move || {
            let tmp = path.with_extension("tmp");
            if std::fs::write(&tmp, bytes).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
        });
    }

    fn restore<T: DeserializeOwned>(&self, name: &str) -> Option<T> {
        let bytes = std::fs::read(self.cache_dir.join(name)).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    fn mark_play(&self) {
        if let Ok(mut d) = self.start.lock() {
            d.waiting = true;
            d.tracks_seen = 0;
        }
    }

    /// Fiches des titres demandés ; les titres hors ligne sont lus sur le disque hors du verrou du cache.
    fn lookup(&self, ids: &[i64]) -> Result<Vec<TrackInfo>, CoreError> {
        let cached: Vec<Option<TrackInfo>> = {
            let known = self.known.lock().map_err(|_| CoreError::Player)?;
            ids.iter().map(|id| known.get(id).cloned()).collect()
        };
        ids.iter()
            .zip(cached)
            .map(|(id, info)| info.or_else(|| self.offline.local(*id).map(|local| local.info)))
            .collect::<Option<Vec<_>>>()
            .ok_or(CoreError::UnknownTrack)
    }

    fn detail(&self, c: ApiCollection) -> Detail {
        let out = Detail {
            kind: c.kind,
            id: c.id,
            owned: c.owned,
            title: c.title,
            subtitle: c.subtitle,
            cover_url: c.cover_url,
            tracks: tracks(&c.tracks),
            albums: cards(c.albums),
            latest: c.latest.map(Card::from),
            related: cards(c.related),
            offline: false,
        };
        remember(&self.known, c.tracks);
        out
    }
}

/// Garde les fiches reçues en dernier ; au-delà de la limite, les plus anciennes sont oubliées (jamais celles de `list`).
fn remember(known: &Known, list: Vec<TrackInfo>) {
    if let Ok(mut known) = known.lock() {
        let keep = MAX_TRACKS.max(list.len());
        for info in list {
            known.insert(info);
        }
        known.evict(keep);
    }
}

/// Identifiant de la playlist « Coups de cœur » du compte (0 si inconnu).
async fn loved_id(api: &DeezerClient) -> u64 {
    api.session().await.map_or(0, |s| s.loved_playlist_id)
}

/// La playlist « Coups de cœur » ouvre la page Titres aimés (même contenu, trié par date d'ajout).
fn mark_loved(mut list: Vec<Card>, loved: u64) -> Vec<Card> {
    if loved != 0 {
        for c in list.iter_mut().filter(|c| c.kind == "playlist" && c.id == loved) {
            c.kind = "loved".into();
        }
    }
    list
}

/// Rôles de `SNG_CONTRIBUTORS`, dans l'ordre d'affichage, avec leur nom en français.
const CREDIT_ROLES: &[(&str, &str)] = &[
    ("main_artist", "Artiste"),
    ("featuring", "Featuring"),
    ("composer", "Composition"),
    ("author", "Paroles"),
    ("lyricist", "Paroles"),
    ("producer", "Production"),
    ("mixer", "Mixage"),
    ("engineer", "Ingénieur du son"),
    ("mastering_engineer", "Mastering"),
    ("arranger", "Arrangement"),
    ("musicpublisher", "Édition"),
];

fn parse_credits(v: &serde_json::Value) -> Credits {
    let names = |x: &serde_json::Value| -> Vec<String> {
        x.as_array()
            .map(|a| a.iter().filter_map(|n| n.as_str()).map(str::trim).filter(|n| !n.is_empty()).map(str::to_owned).collect())
            .unwrap_or_default()
    };
    let mut roles: Vec<CreditRole> = Vec::new();
    let mut push = |role: &str, list: Vec<String>| {
        if list.is_empty() {
            return;
        }
        // Deux clés pour le même rôle (author / lyricist) : une seule ligne, sans doublon.
        if let Some(r) = roles.iter_mut().find(|r| r.role == role) {
            for n in list {
                if !r.names.contains(&n) {
                    r.names.push(n);
                }
            }
        } else {
            roles.push(CreditRole { role: role.to_owned(), names: list });
        }
    };
    if let Some(map) = v.get("SNG_CONTRIBUTORS").and_then(|c| c.as_object()) {
        for (key, label) in CREDIT_ROLES {
            if let Some(list) = map.get(*key) {
                push(label, names(list));
            }
        }
        // Rôles que l'on ne connaît pas : affichés tels quels, après les autres.
        for (key, list) in map {
            if !CREDIT_ROLES.iter().any(|(k, _)| k == key) {
                let mut label = key.replace('_', " ");
                if let Some(first) = label.get(0..1) {
                    label = first.to_uppercase() + &label[1..];
                }
                push(&label, names(list));
            }
        }
    }
    let text = |k: &str| v.get(k).and_then(|x| x.as_str()).map(str::trim).filter(|x| !x.is_empty()).map(str::to_owned);
    Credits {
        roles,
        label: text("LABEL_NAME"),
        release_date: text("PHYSICAL_RELEASE_DATE").or_else(|| text("DIGITAL_RELEASE_DATE")),
    }
}

/// Fiche « Coups de cœur » à partir de `playlist.getData` (image choisie sur Deezer comprise).
fn loved_from_gw(id: u64, v: &serde_json::Value) -> Card {
    let text = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").trim().to_owned();
    let md5 = text("PLAYLIST_PICTURE");
    let kind = Some(text("PICTURE_TYPE")).filter(|k| !k.is_empty()).unwrap_or_else(|| "playlist".into());
    let count = v.get("NB_SONG").and_then(|n| n.as_u64().or_else(|| n.as_str().and_then(|s| s.parse().ok()))).unwrap_or(0);
    Card {
        kind: "loved".into(),
        id,
        title: Some(text("TITLE")).filter(|t| !t.is_empty()).unwrap_or_else(|| "Coups de cœur".into()),
        subtitle: if count > 0 { format!("{count} titres") } else { String::new() },
        cover_url: (!md5.is_empty()).then(|| format!("https://cdn-images.dzcdn.net/images/{kind}/{md5}/500x500-000000-80-0-0.jpg")),
        owned: true,
        key: String::new(),
    }
}

/// Message d'erreur lisible. `None` : rien à afficher.
fn friendly_error(raw: &str) -> Option<String> {
    let lower = raw.to_lowercase();
    // Préparation du titre suivant (en tâche de fond) : elle sera refaite au moment de le jouer.
    if lower.starts_with("préchargement") {
        return None;
    }
    // Formulations précises de reqwest / hyper / rustls. Plus de « connect », « tls » ou « eof » seuls : ils attrapaient
    // aussi « déconnecté », « session déconnectée »… et les affichaient comme un problème de réseau.
    const NETWORK: &[&str] = &[
        "error sending request",
        "error trying to connect",
        "connection refused",
        "connection reset",
        "connection closed",
        "connection aborted",
        "timed out",
        "operation timed out",
        "dns error",
        "failed to lookup address",
        "network is unreachable",
        "host is unreachable",
        "broken pipe",
        "reset by peer",
        "tls handshake",
        "unexpected eof",
    ];
    if NETWORK.iter().any(|k| lower.contains(k)) {
        return Some("Connexion trop faible pour joindre Deezer. La lecture reprendra quand le réseau sera meilleur.".into());
    }
    Some(raw.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(id: i64) -> TrackInfo {
        TrackInfo {
            id,
            title: "Titre".into(),
            artist: "Artiste".into(),
            album: "Album".into(),
            duration_s: 100,
            cover_url: None,
            track_token: None,
            quality: None,
            added_at: None,
            release_date: None,
            fallback_id: None,
            restricted: false,
            artist_id: 1,
            album_id: 2,
            artists: vec![],
        }
    }

    #[test]
    fn credits_are_ordered_merged_and_cleaned() {
        let v = serde_json::json!({
            "SNG_CONTRIBUTORS": {
                "producer": ["Prod A"],
                "main_artist": ["Artiste"],
                "author": ["Auteur"],
                "lyricist": ["Auteur", "Autre"],
                "vocal_coach": [" Coach "],
                "composer": []
            },
            "LABEL_NAME": "Label",
            "PHYSICAL_RELEASE_DATE": "2024-01-02"
        });
        let c = parse_credits(&v);
        let roles: Vec<_> = c.roles.iter().map(|r| r.role.as_str()).collect();
        assert_eq!(roles, ["Artiste", "Paroles", "Production", "Vocal coach"]);
        assert_eq!(c.roles[1].names, ["Auteur", "Autre"]);
        assert_eq!(c.roles[3].names, ["Coach"]);
        assert_eq!(c.label.as_deref(), Some("Label"));
        assert_eq!(c.release_date.as_deref(), Some("2024-01-02"));
    }

    #[test]
    fn loved_card_uses_the_picture_chosen_on_deezer() {
        let v = serde_json::json!({ "TITLE": "Coups de cœur", "PLAYLIST_PICTURE": "abc", "PICTURE_TYPE": "playlist", "NB_SONG": "42" });
        let c = loved_from_gw(7, &v);
        assert_eq!(c.kind, "loved");
        assert_eq!(c.subtitle, "42 titres");
        assert_eq!(c.cover_url.as_deref(), Some("https://cdn-images.dzcdn.net/images/playlist/abc/500x500-000000-80-0-0.jpg"));
        assert!(loved_from_gw(7, &serde_json::json!({})).cover_url.is_none());
    }

    #[test]
    fn api_errors_are_readable() {
        let e = CoreError::from(dz_api::DeezerError::InvalidArl);
        assert!(!e.to_string().is_empty());
    }

    #[test]
    fn errors_are_readable_and_prefetch_is_silent() {
        assert_eq!(friendly_error("préchargement: http: error sending request for url (https://media.deezer.com/v1/get_url)"), None);
        assert!(friendly_error("http: error sending request for url (x)").unwrap().starts_with("Connexion trop faible"));
        assert_eq!(friendly_error("Lecture interrompue, nouvelle tentative…").as_deref(), Some("Lecture interrompue, nouvelle tentative…"));
        // Plus confondu avec un problème de réseau.
        assert_eq!(friendly_error("Session déconnectée").as_deref(), Some("Session déconnectée"));
    }

    #[test]
    fn missing_credits_give_empty_roles() {
        let c = parse_credits(&serde_json::json!({}));
        assert!(c.roles.is_empty() && c.label.is_none() && c.release_date.is_none());
    }

    #[test]
    fn track_cache_forgets_oldest_first() {
        let known: Known = Arc::default();
        remember(&known, (0..MAX_TRACKS as i64).map(info).collect());
        remember(&known, vec![info(-1), info(-2)]);
        let known = known.lock().unwrap();
        assert_eq!(known.tracks.len(), MAX_TRACKS);
        assert!(known.contains_key(&-1) && known.contains_key(&-2));
        assert!(!known.contains_key(&0) && !known.contains_key(&1));
        assert!(known.contains_key(&2));
    }

    #[test]
    fn track_cache_keeps_a_whole_large_list() {
        let known: Known = Arc::default();
        remember(&known, vec![info(-1)]);
        remember(&known, (0..(MAX_TRACKS as i64 + 100)).map(info).collect());
        let known = known.lock().unwrap();
        assert_eq!(known.tracks.len(), MAX_TRACKS + 100);
        assert!(!known.contains_key(&-1));
    }
}

// --- Sortie du son sur iPhone : fonctions C brutes appelées par AVAudioEngine (voir `AudioOutput.swift`).
// Hors UniFFI : la première est appelée sur le thread temps réel d'iOS, qui ne doit ni allouer ni attendre.

/// Remplit `frames` trames gauche et droite avec le son du moteur (silence s'il n'y a rien à jouer).
#[cfg(target_os = "ios")]
#[no_mangle]
pub extern "C" fn dz_render(left: *mut f32, right: *mut f32, frames: u32) {
    // SAFETY: AVAudioEngine fournit deux tampons de `frames` échantillons, valides pendant l'appel.
    unsafe { dz_audio::ios_render(left, right, frames) }
}

/// Fonctions Swift qui démarrent et arrêtent AVAudioEngine, appelées par le moteur (lecture, pause, nouveau titre).
#[cfg(target_os = "ios")]
#[no_mangle]
pub extern "C" fn dz_output_set_hooks(start: Option<extern "C" fn()>, stop: Option<extern "C" fn()>) {
    if let (Some(start), Some(stop)) = (start, stop) {
        dz_audio::ios_set_output_hooks(start, stop);
    }
}
