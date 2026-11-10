//! Acteur `Player` : seul propriétaire de la file d'attente et de la logique de lecture.
//! L'UI envoie des commandes ; l'état de lecture est lu via des atomiques (`Shared`).

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use dz_api::{format_label, Cipher, DeezerClient, DeezerError, Quality, TrackInfo};
use dz_audio::{Engine, EngineEvent, MediaSource, Shared};
use dz_offline::{OfflineStore, PendingListen};
use dz_stream::{ChunkDecryptor, Passthrough, StreamCancel, StreamReader};
use tokio::runtime::Handle;
use tokio::sync::mpsc::{self, UnboundedSender};
use tokio::sync::Notify;

/// État de lecture consultable à tout moment (par exemple quand la fenêtre est rouverte depuis l'icône).
#[derive(Debug, Clone, Default, Serialize)]
pub struct Snapshot {
    pub queue: Vec<TrackInfo>,
    pub index: usize,
    pub current: Option<TrackInfo>,
    /// Volume courant (0.0 à 1.0).
    pub volume: f32,
    /// Le Flow est en cours (file continue renouvelée automatiquement).
    pub flow: bool,
}

/// Mode de répétition.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RepeatMode {
    Off,
    /// Répète toute la file.
    All,
    /// Répète le titre en cours.
    One,
}

/// Identifiant des sources locales (fichier / URL de test).
pub const LOCAL_ID: i64 = i64::MAX;

/// Fournit (si disponible) le déchiffreur pour un titre. Voir `dz_stream::ChunkDecryptor`.
pub type DecryptorFactory = Arc<dyn Fn(i64) -> Option<Arc<dyn ChunkDecryptor>> + Send + Sync>;

#[derive(Debug, Clone)]
pub enum PlayerCmd {
    /// Lance une file de titres (les infos affichables voyagent avec : pas de requête par titre).
    PlayQueue { tracks: Vec<TrackInfo>, index: usize },
    /// Lance le Flow : une file « infinie » qui se renouvelle toute seule (Deezer n'en renvoie que 12 à la fois).
    PlayFlow { tracks: Vec<TrackInfo> },
    /// (interne) Nouveaux titres du Flow reçus en arrière-plan ; liste vide = la demande a échoué.
    FlowMore { tracks: Vec<TrackInfo> },
    /// (interne) Fiche complète d'un titre redemandée en arrière-plan (tous les artistes crédités).
    Enrich { info: TrackInfo },
    /// (interne) Pochette d'un titre remplacée : celle donnée par Deezer n'existait plus (voir `check_cover`).
    CoverFixed { id: i64, cover: String },
    /// Ajoute à la fin de la file, ou juste après le titre en cours (`next`).
    QueueAdd { tracks: Vec<TrackInfo>, next: bool },
    QueueRemove { index: usize },
    QueueMove { from: usize, to: usize },
    QueuePlay { index: usize },
    PlayFile { path: String },
    PlayUrl { url: String },
    Pause,
    Resume,
    Seek { ms: u64 },
    Next,
    Prev,
    Stop,
    /// Choisit le périphérique de sortie audio (`None` = celui du système).
    OutputDevice(Option<String>),
    /// Rouvre la sortie audio actuelle à la même position (iOS, après une interruption).
    ReopenOutput,
    /// Ferme le titre en cours : arrêt, file vidée, rien à reprendre (contrairement à `Stop`).
    Close,
    Volume(f32),
    /// Change la qualité ; la piste en cours est rechargée à la même position.
    /// `reload` : recharger tout de suite le titre en cours dans la nouvelle qualité (choix de l'utilisateur) ; sinon
    /// elle vaut à partir du titre suivant (changement de réseau).
    Quality { quality: Quality, reload: bool },
    Shuffle(bool),
    Repeat(RepeatMode),
    /// Envoie à Deezer les écoutes gardées faute de réseau (retour du réseau, session ouverte).
    FlushListens,
}

/// Événements pour l'UI (émis en une fois par changement de piste, pas à chaque tick).
#[derive(Debug, Clone)]
pub enum CoreEvent {
    Track(TrackInfo),
    Error(String),
    Stopped,
    /// Le titre en cours a été fermé (file vidée) : l'interface masque la barre du lecteur.
    Closed,
    /// La file a changé de contenu ou d'ordre.
    Queue { tracks: Vec<TrackInfo>, index: usize },
    /// Seul le titre en cours a changé dans la file.
    QueueIndex(usize),
    /// Petite modification de la file : seuls les titres concernés voyagent (pas toute la file, qui peut faire des milliers de titres).
    QueueEdit(QueueEdit),
}

/// Modification de la file, à appliquer telle quelle par l'interface ; `index` = position du titre en cours après coup.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum QueueEdit {
    Insert { at: usize, tracks: Vec<TrackInfo>, index: usize },
    Remove { at: usize, index: usize },
    Move { from: usize, to: usize, index: usize },
    /// Un titre de la file a changé (artistes complétés, pochette réparée) : seul lui voyage, pas toute la file.
    Update { track: TrackInfo, index: usize },
}

#[derive(Debug, thiserror::Error)]
pub enum PlayerError {
    #[error("file de commandes pleine ou player arrêté")]
    Unavailable,
}

#[derive(Debug, thiserror::Error)]
enum ResolveError {
    #[error(transparent)]
    Api(#[from] dz_api::DeezerError),
    #[error("fichier téléchargé illisible : {0}")]
    Offline(#[from] std::io::Error),
    #[error(
        "ce flux est chiffré ({0:?}) et aucun déchiffreur n'est configuré : \
         la lecture des titres Deezer n'est pas disponible dans cette version"
    )]
    Encrypted(Cipher),
}

#[derive(Clone)]
pub struct PlayerHandle {
    tx: mpsc::Sender<PlayerCmd>,
    pub shared: Arc<Shared>,
    /// Notifié sur play/pause/seek/changement de piste (pas à chaque tick).
    pub changed: Arc<Notify>,
    snapshot: Arc<std::sync::Mutex<Snapshot>>,
}

impl PlayerHandle {
    pub fn snapshot(&self) -> Snapshot {
        let mut s = self.snapshot.lock().map(|s| s.clone()).unwrap_or_default();
        s.volume = f32::from_bits(self.shared.volume.load(Ordering::Relaxed));
        s
    }

    /// Volume appliqué sans file de messages : effet immédiat sur le son.
    pub fn set_volume(&self, v: f32) {
        self.shared.volume.store(v.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed);
    }

    /// Durée du fondu enchaîné (0 = désactivé) ; effet dès la prochaine transition.
    pub fn set_crossfade(&self, ms: u64) {
        self.shared.crossfade_ms.store(ms.min(12_000), Ordering::Relaxed);
    }

    /// Gain en dB (−10 à +12 ; négatif = son plus faible) ; effet immédiat.
    pub fn set_boost_db(&self, db: f32) {
        let gain = 10f32.powf(db.clamp(-10.0, 12.0) / 20.0);
        self.shared.boost.store(gain.to_bits(), Ordering::Relaxed);
    }

    /// Égaliseur 5 bandes (60 Hz, 230 Hz, 910 Hz, 3,6 kHz, 14 kHz) : gains en dB (-12 à +12) ; effet immédiat.
    pub fn set_eq_bands(&self, gains: &[f32]) {
        for (i, slot) in self.shared.eq.iter().enumerate() {
            let db = gains.get(i).copied().unwrap_or(0.0);
            slot.store((db.clamp(-12.0, 12.0) * 10.0).round() as i32, Ordering::Relaxed);
        }
    }

    /// Description de la sortie audio ouverte (nom, fréquence, canaux) ; vide si aucune.
    pub fn output_info(&self) -> String {
        self.shared.out_info.lock().map(|s| s.clone()).unwrap_or_default()
    }

    /// Pause immédiate (le callback audio lit le drapeau), puis mise à jour de l'état côté moteur.
    pub fn pause(&self) -> Result<(), PlayerError> {
        self.shared.paused.store(true, Ordering::Relaxed);
        self.shared.playing.store(false, Ordering::Relaxed);
        self.changed.notify_waiters();
        self.send(PlayerCmd::Pause)
    }

    pub fn resume(&self) -> Result<(), PlayerError> {
        self.shared.paused.store(false, Ordering::Relaxed);
        if self.shared.current_id.load(Ordering::Relaxed) != 0 {
            self.shared.playing.store(true, Ordering::Relaxed);
        }
        self.changed.notify_waiters();
        self.send(PlayerCmd::Resume)
    }

    pub fn send(&self, cmd: PlayerCmd) -> Result<(), PlayerError> {
        self.tx.try_send(cmd).map_err(|_| PlayerError::Unavailable)
    }
}

/// À appeler depuis un contexte tokio.
pub fn spawn_player(
    api: Arc<DeezerClient>,
    decryptors: Option<DecryptorFactory>,
    offline: Option<OfflineStore>,
    events: UnboundedSender<CoreEvent>,
) -> PlayerHandle {
    let (tx, rx) = mpsc::channel(32);
    let (etx, erx) = mpsc::unbounded_channel();
    let engine = Engine::start(etx);
    let changed = Arc::new(Notify::new());
    let snapshot = Arc::new(std::sync::Mutex::new(Snapshot::default()));
    let cmd_tx = tx.clone();
    let handle = PlayerHandle { tx, shared: engine.shared.clone(), changed: changed.clone(), snapshot: snapshot.clone() };

    let actor = Actor {
        cmd_tx, flow: false, flow_fetching: false,
        api, decryptors, offline, engine, events, changed, snap: snapshot,
        quality: Quality::Flac, shuffle: false, repeat: RepeatMode::Off, original: Vec::new(), rng: seed(), prefetched_idx: None, retries: 0, recover_at: None, queue: Vec::new(), index: 0, infos: HashMap::new(), prefetched: None, enriched: std::collections::HashSet::new(), covers_checked: std::collections::HashSet::new(),
        formats: HashMap::new(), listen: None, restart: false, reload_id: None, listens_waiting: false, streams: Vec::new(),
    };
    tokio::spawn(actor.run(rx, erx));
    handle
}

struct Actor {
    /// Pour que les tâches de fond (Flow) renvoient leur résultat à l'acteur.
    cmd_tx: mpsc::Sender<PlayerCmd>,
    /// Flow en cours : la file est complétée automatiquement avant la fin.
    flow: bool,
    flow_fetching: bool,
    api: Arc<DeezerClient>,
    decryptors: Option<DecryptorFactory>,
    offline: Option<OfflineStore>,
    engine: Engine,
    events: UnboundedSender<CoreEvent>,
    changed: Arc<Notify>,
    snap: Arc<std::sync::Mutex<Snapshot>>,
    quality: Quality,
    shuffle: bool,
    repeat: RepeatMode,
    /// Ordre d'origine de la file, conservé tant que l'aléatoire est actif.
    original: Vec<i64>,
    rng: u64,
    prefetched_idx: Option<usize>,
    /// Reprises automatiques déjà tentées pour le titre en cours (coupure réseau).
    retries: u8,
    recover_at: Option<Instant>,
    queue: Vec<i64>,
    index: usize,
    infos: HashMap<i64, TrackInfo>,
    prefetched: Option<i64>,
    /// Titres dont la fiche complète a déjà été redemandée (une seule fois par session).
    enriched: std::collections::HashSet<i64>,
    /// Titres dont la pochette a déjà été vérifiée (une seule fois par session, voir `check_cover`).
    covers_checked: std::collections::HashSet<i64>,
    /// Format reçu de Deezer pour chaque titre lu en streaming (le rapport d'écoute le donne).
    formats: HashMap<i64, String>,
    /// Écoute en cours, signalée à Deezer quand elle se termine (voir `track_listen`).
    listen: Option<Listen>,
    /// Le titre audible recommence (répétition, retour au début) : c'est une nouvelle écoute.
    restart: bool,
    /// Titre rechargé à la même position (coupure réseau, changement de qualité) : la même écoute continue.
    reload_id: Option<i64>,
    /// Écoutes terminées, déjà gardées sur le disque, dont l'envoi attend le prochain échange réseau (voir `finish_listen`).
    listens_waiting: bool,
    /// Flux réseau confiés au moteur audio (titre en cours, suivant préchargé). Le moteur lit et traite les commandes
    /// sur le même thread : une lecture bloquée sur un réseau figé le rendait sourd (suivant, stop) jusqu'à ~1 min.
    /// Ils sont annulés quand ils sont remplacés ou arrêtés, ce qui rend la main au moteur tout de suite.
    streams: Vec<(i64, StreamCancel)>,
}

/// Une écoute : le titre, quand elle a commencé, combien de temps le son a réellement joué.
struct Listen {
    id: i64,
    format: String,
    started_at: u64,
    played: Duration,
    last: Instant,
    playing: bool,
    /// Génération du stockage au début de l'écoute (voir `OfflineStore::generation`) : une écoute commencée avant une
    /// déconnexion n'est jamais gardée pour le compte suivant.
    generation: u64,
    /// Dernière mise de côté sur le disque (voir `save_due`).
    saved_at: Option<Instant>,
    /// Durée du titre (secondes, 0 si inconnue) : un titre court compte s'il est écouté presque en entier.
    duration_s: u64,
    /// Compte ou profil ouvert au début de l'écoute (0 : pas encore connu) : un changement de profil en plein titre
    /// ne l'attribue pas au nouveau.
    user: u64,
    /// Position dans le titre à la dernière observation : un son bloqué (réseau lent) ne compte pas comme écouté.
    last_pos: u64,
}

/// Pendant la lecture, l'écoute en cours est mise de côté sur le disque à cet intervalle : si l'app est fermée en plein
/// titre (sans pause ni changement de titre), elle est comptée au prochain lancement, à cet intervalle près.
const LISTEN_SAVE_EVERY: Duration = Duration::from_secs(20);

/// L'écoute en cours doit-elle être mise de côté maintenant ? Seulement une fois qu'elle compte (30 s), puis à chaque
/// pause et toutes les `LISTEN_SAVE_EVERY` de lecture.
fn save_due(played: Duration, min: Duration, paused_now: bool, playing: bool, saved_at: Option<Instant>, now: Instant) -> bool {
    played >= min && (paused_now || (playing && saved_at.is_none_or(|t| now.duration_since(t) >= LISTEN_SAVE_EVERY)))
}

/// Temps d'écoute à partir duquel l'écoute compte : 30 s, ou 90 % d'un titre plus court.
fn listen_min(duration_s: u64) -> Duration {
    if duration_s > 0 { LISTEN_MIN.min(Duration::from_secs(duration_s) * 9 / 10) } else { LISTEN_MIN }
}

impl Listen {
    fn counts(&self) -> bool {
        !self.played.is_zero() && self.played >= listen_min(self.duration_s)
    }

    fn pending(&self) -> PendingListen {
        PendingListen {
            track_id: self.id,
            format: self.format.clone(),
            started_at: self.started_at,
            listened_s: self.played.as_secs(),
            user_id: if self.user != 0 { self.user } else { current_user(self.generation) },
        }
    }
}

/// Format du rapport d'écoute pour un titre téléchargé : retrouvé à partir de la qualité enregistrée au téléchargement
/// (« FLAC », « MP3 320 »… : l'inverse de `format_label`), sinon à partir de l'extension du fichier.
fn offline_format(quality: Option<&str>, ext: &str) -> String {
    match quality.map(str::trim) {
        Some(q) if q.eq_ignore_ascii_case("MP3 importé") => "MP3_MISC".into(),
        Some(q) if !q.is_empty() && !q.starts_with("Aperçu") => q.to_ascii_uppercase().replace(' ', "_"),
        _ if ext.eq_ignore_ascii_case("flac") => "FLAC".into(),
        _ => "MP3_320".into(),
    }
}

/// Le rapport n'est pas arrivé chez Deezer, ou Deezer ne l'a pas pris en compte : pas de réseau, limite de requêtes,
/// session impossible à ouvrir (ARL expiré, en attendant la reconnexion). Il peut être renvoyé plus tard sans risque de
/// compter l'écoute deux fois. Une autre erreur (délai dépassé…) a pu arriver chez Deezer : elle n'est pas renvoyée.
fn not_delivered(e: &DeezerError) -> bool {
    match e {
        // Réponse « trop de requêtes » (429) ou serveur indisponible (502, 503, 504) : Deezer n'a pas traité l'écoute,
        // on peut la renvoyer sans doublon. Pas 500 : la requête a pu être traitée en partie.
        DeezerError::Http(h) => {
            h.is_connect() || h.status().is_some_and(|s| matches!(s.as_u16(), 429 | 502 | 503 | 504))
        }
        DeezerError::Gateway(g) => g.to_ascii_uppercase().contains("QUOTA"),
        DeezerError::InvalidArl | DeezerError::SessionExpired => true,
        _ => false,
    }
}

/// Une seule vidange de la file à la fois (retour du réseau et fin d'un titre peuvent tomber ensemble).
static FLUSHING: AtomicBool = AtomicBool::new(false);

/// Compte (ou profil Famille) ouvert, relevé à chaque vidange (ouverture de session, connexion, changement de profil,
/// retour du réseau). Chaque écoute le retient à sa fin : elle n'est envoyée que sur ce profil, même si l'on change de
/// profil avant le retour du réseau. 0 = encore inconnu (app lancée sans réseau) : l'écoute part sur le profil ouvert.
static CURRENT_USER: AtomicU64 = AtomicU64::new(0);
/// Génération du stockage (voir `OfflineStore::generation`) au moment où `CURRENT_USER` a été relevé : après une
/// déconnexion, l'ancien compte n'est plus pris pour celui qui écoute (il redevient inconnu jusqu'à la vidange suivante).
static CURRENT_USER_GEN: AtomicU64 = AtomicU64::new(0);

/// Compte qui écoute, s'il est connu pour cette génération du stockage ; 0 sinon.
fn current_user(generation: u64) -> u64 {
    if CURRENT_USER_GEN.load(Ordering::Acquire) == generation { CURRENT_USER.load(Ordering::Acquire) } else { 0 }
}

/// Envoie une écoute terminée ; sans réseau, elle est gardée pour plus tard. Si elle part, celles qui attendaient suivent.
async fn send_listen(api: Arc<DeezerClient>, store: Option<OfflineStore>, mut listen: PendingListen, generation: u64) {
    // Déconnexion arrivée entre la fin du titre et cet envoi : l'écoute n'est envoyée au nom d'aucun compte.
    if store.as_ref().is_some_and(|s| s.generation() != generation) {
        return;
    }
    listen.user_id = api.session().await.map_or(0, |s| s.user_id);
    match api.log_listen(listen.track_id, &listen.format, listen.started_at, listen.listened_s).await {
        Ok(()) => {
            if let Some(store) = store {
                flush_listens(api, store).await;
            }
        }
        Err(e) if not_delivered(&e) => {
            if let Some(store) = store {
                let _ = store.queue_listen(listen, generation);
            }
        }
        // Refusée par Deezer : rien à garder.
        Err(_) => {}
    }
}

/// Envoie les écoutes gardées, de la plus ancienne à la plus récente, avec leur heure d'écoute réelle. Chacune est retirée
/// de la file dès qu'elle est partie : une coupure en route ne fait rien renvoyer deux fois. Seules celles du compte ouvert
/// (ou d'un compte inconnu, app lancée sans réseau) partent.
async fn flush_listens(api: Arc<DeezerClient>, store: OfflineStore) {
    // Profil ouvert relevé AVANT de vérifier qu'une vidange tourne déjà : après un changement de profil, celle qui suit
    // sortait tout de suite et les écoutes du nouveau profil restaient étiquetées avec l'ancien.
    if let Some(me) = api.session().await.map(|s| s.user_id) {
        remember_user(me, store.generation());
    }
    if FLUSHING.swap(true, Ordering::AcqRel) {
        return;
    }
    struct Release;
    impl Drop for Release {
        fn drop(&mut self) {
            FLUSHING.store(false, Ordering::Release);
        }
    }
    let _release = Release;
    // Relue jusqu'à ce qu'elle soit vide : une écoute ajoutée pendant l'envoi des autres part aussi. Le profil est relu
    // à chaque tour : un changement de profil pendant la vidange ne fait pas partir les écoutes de l'ancien au nom du
    // nouveau (avant, tout le lot restant partait sur le nouveau profil).
    'flush: loop {
        // Pas encore de session (lancement sans réseau) : rien à faire, la vidange est relancée à son ouverture.
        let Some(me) = api.session().await.map(|s| s.user_id) else { return };
        let generation = store.generation();
        remember_user(me, generation);
        let batch: Vec<PendingListen> = store.pending_listens().into_iter().filter(|l| l.user_id == 0 || l.user_id == me).collect();
        if batch.is_empty() {
            return;
        }
        for listen in batch {
            // Profil changé, ou déconnexion, depuis le début du lot : on repart avec le profil ouvert maintenant.
            if store.generation() != generation || api.session().await.map(|s| s.user_id) != Some(me) {
                continue 'flush;
            }
            match api.log_listen(listen.track_id, &listen.format, listen.started_at, listen.listened_s).await {
                Err(e) if not_delivered(&e) => return, // toujours pas de réseau : la suite attend
                // Envoyée, ou refusée par Deezer (inutile de la garder). Si elle ne peut pas être retirée (disque plein),
                // on s'arrête : la renvoyer en boucle la compterait plusieurs fois.
                _ => {
                    if store.remove_listen(&listen).is_err() {
                        return;
                    }
                }
            }
        }
    }
}

/// Retient le compte (ou profil) ouvert pour cette génération du stockage. Le compte d'abord, sa génération ensuite :
/// lu entre les deux, il est au pire « inconnu » (0, l'écoute part sur le profil ouvert), jamais l'ancien compte associé
/// à la nouvelle génération (l'écoute resterait bloquée).
fn remember_user(me: u64, generation: u64) {
    CURRENT_USER.store(me, Ordering::Release);
    CURRENT_USER_GEN.store(generation, Ordering::Release);
}

/// En dessous, Deezer ne compte pas l'écoute (comme dans l'app officielle, un titre passé tout de suite ne compte pas).
const LISTEN_MIN: Duration = Duration::from_secs(30);

struct Resolved {
    src: Box<dyn MediaSource>,
    ext: Option<String>,
    info: TrackInfo,
    /// Lecture limitée à l'aperçu de 30 s (flux complet chiffré, pas de déchiffreur).
    preview: bool,
    /// Annulation du flux réseau (aucune pour un fichier téléchargé), voir `Actor::streams`.
    cancel: Option<StreamCancel>,
}

/// Réveil de la boucle du lecteur en pause ou à l'arrêt : en pratique jamais (une commande ou un événement arrive avant).
const IDLE_TICK_S: u64 = 24 * 3600;

impl Actor {
    async fn run(mut self, mut rx: mpsc::Receiver<PlayerCmd>, mut erx: mpsc::UnboundedReceiver<EngineEvent>) {
        // Préchargement du titre suivant et reprise après coupure : vérifiés chaque seconde pendant la lecture. En pause
        // ou à l'arrêt, rien à préparer : plus de réveil du tout (une commande ou un événement du moteur relance la boucle).
        let mut next_tick = tokio::time::Instant::now() + Duration::from_secs(1);
        loop {
            let busy = self.recover_at.is_some() || self.engine.shared.playing.load(Ordering::Relaxed);
            let soonest = tokio::time::Instant::now() + Duration::from_secs(if busy { 1 } else { IDLE_TICK_S });
            if next_tick > soonest {
                next_tick = soonest;
            }
            tokio::select! {
                cmd = rx.recv() => match cmd {
                    Some(c) => self.on_cmd(c).await,
                    None => return,
                },
                Some(ev) = erx.recv() => self.on_engine(ev).await,
                _ = tokio::time::sleep_until(next_tick) => {
                    self.maybe_recover().await;
                    // Préparation du titre suivant (réseau, parfois lente) : une commande qui arrive pendant ce temps
                    // (suivant, saut, pause…) passe avant. La préparation est abandonnée et refaite au tour suivant.
                    // Avant, les commandes attendaient la fin de la préparation (jusqu'à une minute sur réseau faible).
                    let interrupted = tokio::select! {
                        _ = self.maybe_prefetch() => None,
                        cmd = rx.recv() => Some(cmd),
                    };
                    if let Some(cmd) = interrupted {
                        self.prefetched = None;
                        self.prefetched_idx = None;
                        match cmd {
                            Some(c) => self.on_cmd(c).await,
                            None => return,
                        }
                    }
                    let busy = self.recover_at.is_some() || self.engine.shared.playing.load(Ordering::Relaxed);
                    next_tick = tokio::time::Instant::now() + Duration::from_secs(if busy { 1 } else { IDLE_TICK_S });
                }
            }
            self.track_listen();
            // Plus rien ne joue (pause, arrêt, fin de file, erreur) : les écoutes en attente partent tout de suite.
            if self.listens_waiting && !self.engine.shared.playing.load(Ordering::Relaxed) {
                self.flush_waiting_listens();
            }
            self.changed.notify_waiters();
        }
    }

    /// Suit l'écoute en cours (appelé après chaque commande ou événement, et chaque seconde en lecture) : le temps où
    /// le son joue est additionné ; au changement de titre ou à l'arrêt, l'écoute est signalée à Deezer comme le fait
    /// l'app officielle (historique, statistiques, My Deezer Month). Titres Deezer lus en streaming ou téléchargés ;
    /// hors ligne, le rapport est gardé et envoyé au retour du réseau.
    fn track_listen(&mut self) {
        let cur = self.engine.shared.current_id.load(Ordering::Relaxed);
        let playing = self.engine.shared.playing.load(Ordering::Relaxed);
        let restart = std::mem::take(&mut self.restart);
        let pos = self.engine.shared.position_ms.load(Ordering::Relaxed);
        let now = Instant::now();
        if let Some(l) = self.listen.as_mut() {
            if l.playing {
                // Temps écoulé, mais pas plus que ce que la lecture a avancé (son bloqué) ; une avance par saut
                // (recherche) ne compte pas plus que le temps réel.
                l.played += (now - l.last).min(Duration::from_millis(pos.saturating_sub(l.last_pos)));
            }
            l.last = now;
            l.last_pos = pos;
            let paused_now = l.playing && !playing;
            l.playing = playing;
            if l.user == 0 {
                l.user = current_user(l.generation);
            }
            if l.id == cur && !restart {
                // L'app peut être fermée en plein titre (par l'utilisateur ou par iOS) : l'écoute est mise de côté sur
                // le disque à chaque pause et régulièrement pendant la lecture, et comptée au prochain lancement.
                if save_due(l.played, listen_min(l.duration_s), paused_now, playing, l.saved_at, now) {
                    if let Some(store) = &self.offline {
                        let _ = store.set_open_listen(Some(l.pending()), l.generation);
                    }
                    l.saved_at = Some(now);
                }
                return;
            }
        }
        if let Some(done) = self.listen.take() {
            self.finish_listen(done);
        }
        if let Some(format) = self.formats.get(&cur).filter(|_| cur > 0 && cur != LOCAL_ID) {
            let started_at = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
            let generation = self.offline.as_ref().map_or(0, |s| s.generation());
            let duration_s = self.infos.get(&cur).map_or(0, |i| i.duration_s);
            let user = current_user(generation);
            self.listen = Some(Listen { id: cur, format: format.clone(), started_at, played: Duration::ZERO, last: now, playing, generation, saved_at: None, duration_s, user, last_pos: pos });
        }
    }

    /// Écoute terminée : signalée si le titre a joué assez longtemps. Elle est d'abord écrite dans la file sur le disque
    /// (en remplaçant celle mise de côté, dans la même écriture), puis envoyée, et retirée de la file une fois partie :
    /// une app fermée juste après un changement de titre, sans réseau, ne perd plus l'écoute.
    fn finish_listen(&mut self, done: Listen) {
        let counts = done.counts();
        match &self.offline {
            Some(store) => {
                let queued = store.close_listen(counts.then(|| done.pending()), done.generation).unwrap_or(false);
                if queued {
                    if self.engine.shared.playing.load(Ordering::Relaxed) {
                        // La lecture continue (titre suivant) : l'écoute, déjà gardée sur le disque, part avec la
                        // préparation du titre suivant, quand la radio du téléphone est déjà allumée. Envoyée seule au
                        // changement de titre, elle la rallumait à chaque titre. Ce qui compte n'est pas changé : seul le
                        // moment de l'envoi l'est (une à quelques minutes plus tard), et elle n'est jamais perdue.
                        self.listens_waiting = true;
                    } else {
                        tokio::spawn(flush_listens(self.api.clone(), store.clone()));
                    }
                }
            }
            // Sans stockage (pas de téléchargements) : envoi direct, comme avant.
            None if counts => {
                tokio::spawn(send_listen(self.api.clone(), None, done.pending(), done.generation));
            }
            None => {}
        }
    }

    /// Envoie les écoutes gardées en attente (voir `finish_listen`).
    fn flush_waiting_listens(&mut self) {
        if std::mem::take(&mut self.listens_waiting) {
            if let Some(store) = self.offline.clone() {
                tokio::spawn(flush_listens(self.api.clone(), store));
            }
        }
    }

    fn error(&self, msg: impl ToString) {
        let _ = self.events.send(CoreEvent::Error(msg.to_string()));
    }

    async fn on_cmd(&mut self, cmd: PlayerCmd) {
        match cmd {
            PlayerCmd::PlayFlow { tracks } => {
                if tracks.is_empty() {
                    return;
                }
                Box::pin(self.on_cmd(PlayerCmd::PlayQueue { tracks, index: 0 })).await;
                self.set_flow(true); // après PlayQueue, qui remet le drapeau à zéro
            }
            PlayerCmd::Enrich { info } => {
                let id = info.id;
                let before = self.infos.get(&id).map(|i| i.artist.clone());
                self.seed_infos(vec![info]); // la liste d'artistes la plus complète l'emporte
                let Some(now) = self.infos.get(&id).cloned() else { return };
                if before.as_deref() == Some(now.artist.as_str()) {
                    return; // rien de nouveau
                }
                // Titre affiché en ce moment : le lecteur, la barre et la zone de lecture du système se mettent à jour.
                if self.engine.shared.current_id.load(Ordering::Relaxed) == id || self.queue.get(self.index) == Some(&id) {
                    if let Ok(mut s) = self.snap.lock() {
                        s.current = Some(now.clone());
                    }
                    let _ = self.events.send(CoreEvent::Track(now.clone()));
                }
                self.emit_edit(QueueEdit::Update { track: now, index: self.index });
            }
            PlayerCmd::CoverFixed { id, cover } => {
                let Some(info) = self.infos.get_mut(&id) else { return };
                info.cover_url = Some(cover);
                let now = info.clone();
                // Titre affiché en ce moment : grand lecteur, mini-lecteur et écran verrouillé prennent la bonne pochette.
                if self.engine.shared.current_id.load(Ordering::Relaxed) == id || self.queue.get(self.index) == Some(&id) {
                    if let Ok(mut s) = self.snap.lock() {
                        s.current = Some(now.clone());
                    }
                    let _ = self.events.send(CoreEvent::Track(now.clone()));
                }
                self.emit_edit(QueueEdit::Update { track: now, index: self.index });
            }
            PlayerCmd::FlowMore { tracks } => {
                self.flow_fetching = false;
                if !self.flow || tracks.is_empty() {
                    return;
                }
                // Sans doublon avec ce qui est déjà dans la file.
                let fresh: Vec<TrackInfo> = tracks.into_iter().filter(|t| !self.queue.contains(&t.id)).collect();
                if fresh.is_empty() {
                    return;
                }
                let ids: Vec<i64> = fresh.iter().map(|t| t.id).collect();
                self.seed_infos(fresh);
                let at = self.queue.len();
                self.queue.extend(ids.iter().copied());
                let added = self.infos_of(&ids);
                if !self.original.is_empty() {
                    self.original.extend(ids);
                }
                self.reset_prefetch();
                self.emit_edit(QueueEdit::Insert { at, tracks: added, index: self.index });
            }
            PlayerCmd::PlayQueue { tracks, index } => {
                if tracks.is_empty() {
                    return;
                }
                self.set_flow(false);
                self.index = index.min(tracks.len() - 1);
                self.queue = tracks.iter().map(|t| t.id).collect();
                self.forget_old_infos();
                self.seed_infos(tracks);
                self.original.clear();
                self.retries = 0;
                if self.shuffle {
                    self.apply_shuffle(true);
                }
                self.reset_prefetch();
                self.emit_queue();
                self.play_current().await;
            }
            PlayerCmd::QueueAdd { tracks, next } => {
                if tracks.is_empty() {
                    return;
                }
                if self.queue.is_empty() {
                    return Box::pin(self.on_cmd(PlayerCmd::PlayQueue { tracks, index: 0 })).await;
                }
                let ids: Vec<i64> = tracks.iter().map(|t| t.id).collect();
                self.seed_infos(tracks);
                let at = if next { (self.index + 1).min(self.queue.len()) } else { self.queue.len() };
                self.queue.splice(at..at, ids.iter().copied());
                let added = self.infos_of(&ids);
                if !self.original.is_empty() {
                    self.original.extend(ids);
                }
                self.reset_prefetch();
                self.emit_edit(QueueEdit::Insert { at, tracks: added, index: self.index });
            }
            PlayerCmd::QueueRemove { index } => {
                // Le titre en cours ne se retire pas (on passerait au suivant avec « suivant »).
                if index >= self.queue.len() || index == self.index {
                    return;
                }
                let id = self.queue.remove(index);
                if index < self.index {
                    self.index -= 1;
                }
                if let Some(p) = self.original.iter().position(|&x| x == id) {
                    self.original.remove(p);
                }
                self.reset_prefetch();
                self.emit_edit(QueueEdit::Remove { at: index, index: self.index });
            }
            PlayerCmd::QueueMove { from, to } => {
                let len = self.queue.len();
                if from >= len || to >= len || from == to {
                    return;
                }
                let id = self.queue.remove(from);
                self.queue.insert(to, id);
                // Le titre en cours reste le même : on recalcule son index.
                if from == self.index {
                    self.index = to;
                } else if from < self.index && to >= self.index {
                    self.index -= 1;
                } else if from > self.index && to <= self.index {
                    self.index += 1;
                }
                self.reset_prefetch();
                self.emit_edit(QueueEdit::Move { from, to, index: self.index });
            }
            PlayerCmd::QueuePlay { index } => {
                if index < self.queue.len() {
                    self.index = index;
                    self.retries = 0;
                    // Le bouton « suivant » de l'app passe par ici (titre visé dans la file), pas par `Next` : le titre
                    // déjà préparé y était résolu et retéléchargé une seconde fois.
                    self.play_prefetched_or_current().await;
                    self.emit_index();
                }
            }
            PlayerCmd::PlayFile { path } => {
                let p = std::path::Path::new(&path);
                let ext = p.extension().and_then(|e| e.to_str()).map(str::to_lowercase);
                match std::fs::File::open(p) {
                    Ok(f) => {
                        let title = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or(path.clone());
                        self.start_local(Box::new(f), ext, title);
                    }
                    Err(e) => self.error(format!("{path}: {e}")),
                }
            }
            PlayerCmd::PlayUrl { url } => {
                let ext = url.split(['?', '#']).next().and_then(|u| u.rsplit('.').next()).map(str::to_lowercase);
                let reader = StreamReader::spawn(&Handle::current(), self.api.http().clone(), url.clone(), Arc::new(Passthrough));
                let cancel = reader.cancel_handle();
                self.start_local(Box::new(reader), ext, url);
                self.streams.push((LOCAL_ID, cancel));
            }
            PlayerCmd::Pause => self.engine.pause(),
            PlayerCmd::Resume => {
                let sh = &self.engine.shared;
                if sh.idle.load(Ordering::Relaxed) && self.queue.get(self.index).is_some() {
                    // Plus rien dans le moteur (file terminée, titre en échec) : une simple reprise ne jouait rien. Le titre
                    // affiché est rechargé, à sa position s'il n'était pas fini, sinon depuis le début.
                    let (pos, dur) = (sh.position_ms.load(Ordering::Relaxed), sh.duration_ms.load(Ordering::Relaxed));
                    let resume_at = (pos > 1000 && pos + 2000 < dur).then_some(pos);
                    if resume_at.is_some() {
                        self.reload_id = self.queue.get(self.index).copied(); // même écoute, pas une nouvelle
                    }
                    self.retries = 0;
                    self.play_current().await;
                    if let Some(pos) = resume_at {
                        self.engine.seek(pos);
                    }
                    self.emit_index();
                } else {
                    self.engine.resume();
                }
            }
            PlayerCmd::Seek { ms } => self.engine.seek(ms),
            PlayerCmd::Volume(v) => self.engine.set_volume(v),
            PlayerCmd::Quality { quality: q, reload } => {
                if q == self.quality {
                    return;
                }
                self.quality = q;
                self.prefetched = None;
                // Suivant déjà préparé dans l'ancienne qualité : lâché, il sera refait dans la nouvelle.
                self.engine.clear_next();
                // Titre Deezer qui joue : rechargé dans la nouvelle qualité, à la même position. En pause (ou coupé par
                // un appel), il n'est pas rechargé : le rechargement relançait la musique toute seule, par exemple en
                // passant du Wi-Fi à la 4G. La nouvelle qualité vaut alors à partir du titre suivant.
                // Changement de réseau (Wi-Fi <-> 4G) : le titre en cours, en général déjà entièrement téléchargé, n'est pas
                // retéléchargé dans l'autre qualité (en 4G, c'était jusqu'à 30 Mo de données et de radio pour rien).
                let paused = self.engine.shared.paused.load(Ordering::Relaxed);
                let playing_deezer = reload && !paused && self
                    .queue
                    .get(self.index)
                    .is_some_and(|&id| {
                        self.engine.shared.current_id.load(Ordering::Relaxed) == id
                            && !self.offline.as_ref().is_some_and(|store| store.contains(id))
                    });
                if playing_deezer {
                    let pos = self.engine.shared.position_ms.load(Ordering::Relaxed);
                    self.reload_id = self.queue.get(self.index).copied();
                    self.play_current().await;
                    if pos > 1000 {
                        self.engine.seek(pos);
                    }
                }
            }
            PlayerCmd::Stop => {
                self.restart = true; // l'écoute s'arrête là
                self.engine.stop();
                self.cancel_streams();
                let _ = self.events.send(CoreEvent::Stopped);
            }
            PlayerCmd::OutputDevice(name) => self.engine.set_device(name),
            PlayerCmd::ReopenOutput => self.engine.reopen_output(),
            PlayerCmd::Close => {
                self.restart = true; // l'écoute s'arrête là
                self.set_flow(false);
                self.engine.stop();
                self.cancel_streams();
                self.queue.clear();
                self.original.clear();
                self.index = 0;
                self.prefetched = None;
                self.prefetched_idx = None;
                self.retries = 0;
                self.recover_at = None;
                self.forget_old_infos();
                if let Ok(mut s) = self.snap.lock() {
                    s.current = None;
                }
                self.emit_queue();
                let _ = self.events.send(CoreEvent::Closed);
            }
            PlayerCmd::Shuffle(on) => {
                if on != self.shuffle {
                    self.shuffle = on;
                    self.apply_shuffle(on);
                    self.reset_prefetch();
                    self.emit_queue();
                }
            }
            PlayerCmd::Repeat(mode) => {
                self.repeat = mode;
                self.reset_prefetch();
            }
            PlayerCmd::FlushListens => {
                if let Some(store) = self.offline.clone() {
                    tokio::spawn(flush_listens(self.api.clone(), store));
                }
            }
            PlayerCmd::Next => {
                // Le bouton « suivant » ignore « répéter le titre » mais respecte « répéter tout ».
                let next = if self.index + 1 < self.queue.len() {
                    Some(self.index + 1)
                } else if self.repeat == RepeatMode::All && !self.queue.is_empty() {
                    Some(0)
                } else {
                    None
                };
                if let Some(i) = next {
                    self.index = i;
                    self.play_prefetched_or_current().await;
                }
            }
            PlayerCmd::Prev => {
                // Comme la plupart des lecteurs : > 3 s => retour au début, sinon piste précédente.
                if self.engine.shared.position_ms.load(Ordering::Relaxed) > 3000 || self.index == 0 {
                    self.engine.seek(0);
                    self.restart = true;
                } else {
                    self.index -= 1;
                    self.play_current().await;
                }
            }
        }
    }

    /// Certaines listes de Deezer (Flow, mixes, accueil…) ne donnent que l'artiste principal d'un titre. Quand un titre lancé
    /// n'a qu'un artiste connu, on redemande sa fiche complète en arrière-plan (une fois par session) : un feat apparaît alors
    /// dans le lecteur sans retarder la lecture.
    /// Vérifie, une fois par titre, que sa pochette existe encore chez Deezer ; sinon la remplace par celle de l'album.
    fn check_cover(&mut self, id: i64) {
        if id <= 0 || id == LOCAL_ID || !self.covers_checked.insert(id) {
            return;
        }
        let Some((url, album)) = self.infos.get(&id).and_then(|i| Some((i.cover_url.clone()?, i.album_id))) else { return };
        let (api, tx) = (self.api.clone(), self.cmd_tx.clone());
        tokio::spawn(async move {
            if let Some(cover) = api.repaired_track_cover(&url, album, id).await {
                let _ = tx.send(PlayerCmd::CoverFixed { id, cover }).await;
            }
        });
    }

    fn maybe_enrich(&mut self, id: i64) {
        if id <= 0 || id == LOCAL_ID || self.enriched.contains(&id)
            || self.offline.as_ref().is_some_and(|store| store.contains(id))
        {
            return;
        }
        self.enriched.insert(id);
        if self.infos.get(&id).is_some_and(|i| i.artists.len() > 1) {
            return; // déjà complet
        }
        let (api, tx) = (self.api.clone(), self.cmd_tx.clone());
        tokio::spawn(async move {
            if let Ok(Ok(info)) = tokio::time::timeout(Duration::from_secs(10), api.track_info(id)).await {
                let _ = tx.send(PlayerCmd::Enrich { info }).await;
            }
        });
    }

    /// Mémorise les infos affichables de titres. Une fiche déjà connue garde ce qui a été résolu pour la lecture
    /// (jeton, qualité, titre de remplacement), et la liste d'artistes la plus complète des deux : certaines listes
    /// de Deezer ne donnent que l'artiste principal, et la première vue ne doit pas cacher un feat vu ensuite.
    fn seed_infos(&mut self, tracks: Vec<TrackInfo>) {
        for mut t in tracks {
            if let Some(old) = self.infos.get(&t.id) {
                if t.track_token.is_none() {
                    t.track_token = old.track_token.clone();
                    t.fallback_id = old.fallback_id;
                    t.restricted = old.restricted;
                }
                // Qualité du flux en cours (« FLAC »…) : seule la lecture la connaît, une fiche redemandée ne l'a pas.
                t.quality = t.quality.or_else(|| old.quality.clone());
                if old.artists.len() > t.artists.len() {
                    t.artists = old.artists.clone();
                    t.artist = old.artist.clone();
                    t.artist_id = old.artist_id;
                }
                t.release_date = t.release_date.or_else(|| old.release_date.clone());
                t.added_at = t.added_at.or_else(|| old.added_at.clone());
                t.cover_url = t.cover_url.or_else(|| old.cover_url.clone());
            }
            // Fiche venue de Deezer avec une pochette supprimée déjà réparée : la réparée reste (sinon la fiche
            // complète redemandée après le début du titre remettait la pochette blanche).
            self.api.apply_cover_fixes(std::slice::from_mut(&mut t));
            self.infos.insert(t.id, t);
        }
    }

    /// Nouvelle file : on oublie les infos des titres qui n'en font plus partie (sinon chaque playlist lancée
    /// s'ajoute en mémoire pour toute la session). Le titre audible est gardé : il est encore affiché.
    fn forget_old_infos(&mut self) {
        let keep: std::collections::HashSet<i64> = self.queue.iter().copied().collect();
        let audible = self.engine.shared.current_id.load(Ordering::Relaxed);
        self.infos.retain(|id, _| keep.contains(id) || *id == audible);
    }

    fn emit_queue(&self) {
        let tracks: Vec<TrackInfo> = self.queue.iter().filter_map(|id| self.infos.get(id).cloned()).collect();
        if let Ok(mut s) = self.snap.lock() {
            s.queue = tracks.clone();
            s.index = self.index;
        }
        let _ = self.events.send(CoreEvent::Queue { tracks, index: self.index });
    }

    fn infos_of(&self, ids: &[i64]) -> Vec<TrackInfo> {
        ids.iter().filter_map(|id| self.infos.get(id).cloned()).collect()
    }

    /// Envoie une modification de la file et l'applique à l'état consultable (même résultat qu'un `emit_queue`, sans tout recopier).
    fn emit_edit(&self, edit: QueueEdit) {
        if let Ok(mut g) = self.snap.lock() {
            let s = &mut *g;
            apply_edit(&mut s.queue, &mut s.index, &edit);
        }
        let _ = self.events.send(CoreEvent::QueueEdit(edit));
    }

    fn emit_index(&self) {
        if let Ok(mut s) = self.snap.lock() {
            s.index = self.index;
        }
        let _ = self.events.send(CoreEvent::QueueIndex(self.index));
    }

    /// Index du titre qui suit naturellement (fin de piste), selon le mode de répétition.
    fn next_index(&self) -> Option<usize> {
        let len = self.queue.len();
        if len == 0 {
            return None;
        }
        match self.repeat {
            RepeatMode::One => Some(self.index),
            RepeatMode::All => Some((self.index + 1) % len),
            RepeatMode::Off => (self.index + 1 < len).then_some(self.index + 1),
        }
    }

    /// La file ou le mode a changé : la piste suivante déjà préparée n'est plus la bonne.
    /// Flow : quand il reste 4 titres ou moins, on en demande de nouveaux en arrière-plan (sans bloquer la lecture).
    fn top_up_flow(&mut self) {
        if !self.flow || self.flow_fetching || self.queue.len().saturating_sub(self.index + 1) > 4 {
            return;
        }
        self.flow_fetching = true;
        let (api, tx) = (self.api.clone(), self.cmd_tx.clone());
        tokio::spawn(async move {
            let tracks = tokio::time::timeout(Duration::from_secs(15), api.flow()).await.ok().and_then(Result::ok).unwrap_or_default();
            let _ = tx.send(PlayerCmd::FlowMore { tracks }).await;
        });
    }

    fn reset_prefetch(&mut self) {
        self.prefetched = None;
        self.prefetched_idx = None;
        self.engine.clear_next();
    }

    fn next_random(&mut self) -> u64 {
        // xorshift64* : suffisant pour mélanger une file d'attente.
        self.rng ^= self.rng >> 12;
        self.rng ^= self.rng << 25;
        self.rng ^= self.rng >> 27;
        self.rng.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// Active (titre courant en tête, reste mélangé) ou désactive (ordre d'origine) l'aléatoire.
    fn apply_shuffle(&mut self, on: bool) {
        if self.queue.is_empty() {
            return;
        }
        let cur = self.queue[self.index.min(self.queue.len() - 1)];
        if on {
            if self.original.is_empty() {
                self.original = self.queue.clone();
            }
            let mut rest: Vec<i64> = self.queue.iter().copied().enumerate().filter(|(i, _)| *i != self.index).map(|(_, id)| id).collect();
            for i in (1..rest.len()).rev() {
                let j = (self.next_random() % (i as u64 + 1)) as usize;
                rest.swap(i, j);
            }
            self.queue = std::iter::once(cur).chain(rest).collect();
            self.index = 0;
        } else if !self.original.is_empty() {
            self.queue = std::mem::take(&mut self.original);
            self.index = self.queue.iter().position(|&q| q == cur).unwrap_or(0);
        }
    }

    /// Active ou coupe le Flow, en le notant aussi dans l'état lisible depuis l'interface.
    fn set_flow(&mut self, on: bool) {
        self.flow = on;
        if let Ok(mut s) = self.snap.lock() {
            s.flow = on;
        }
    }

    fn start_local(&mut self, src: Box<dyn MediaSource>, ext: Option<String>, title: String) {
        self.set_flow(false);
        self.queue.clear();
        self.prefetched = None;
        let info = TrackInfo {
            id: LOCAL_ID, title, artist: "Source locale".into(), album: String::new(),
            duration_s: 0, cover_url: None, track_token: None, quality: None, added_at: None, release_date: None, fallback_id: None, restricted: false, artist_id: 0, album_id: 0, artists: Vec::new(),
        };
        self.infos.insert(LOCAL_ID, info);
        self.cancel_streams();
        self.engine.load(LOCAL_ID, src, ext);
    }

    /// Annule tous les flux réseau confiés au moteur (voir `streams`).
    fn cancel_streams(&mut self) {
        for (_, c) in self.streams.drain(..) {
            c.cancel();
        }
    }

    /// Joue le titre `index` de la file. S'il est déjà préparé (à partir de 80 % du titre en cours), le moteur passe
    /// directement dessus, avec ce qui est déjà téléchargé ; sinon il est chargé normalement.
    async fn play_prefetched_or_current(&mut self) {
        let id = self.queue.get(self.index).copied();
        if id.is_some() && self.prefetched == id && self.prefetched_idx == Some(self.index) {
            self.engine.skip_next();
        } else {
            self.play_current().await;
        }
    }

    async fn play_current(&mut self) {
        let Some(&id) = self.queue.get(self.index) else { return };
        self.prefetched = None;
        match self.resolve(id).await {
            Ok(r) => {
                if r.preview {
                    self.error("Lecture complète indisponible : aperçu de 30 s (flux Deezer chiffré).");
                }
                let _ = self.events.send(CoreEvent::Track(r.info));
                self.maybe_enrich(id);
                // Annulés seulement maintenant que le nouveau titre est prêt : si sa résolution échoue, l'ancien continue.
                self.cancel_streams();
                self.streams.extend(r.cancel.map(|c| (id, c)));
                self.engine.load(id, r.src, r.ext);
            }
            Err(e) => {
                // Rechargement manqué (reprise après coupure sans réseau…) : rien ne repart, donc le prochain départ de
                // ce titre (relancé à la main plus tard) sera bien une nouvelle écoute.
                self.reload_id = None;
                // Le titre demandé n'a pas pu être chargé (réseau coupé, changement de réseau…) : si un autre titre
                // joue encore, la file revient dessus, pour que l'interface ne montre pas un titre qu'on n'entend pas.
                let playing = self.engine.shared.current_id.load(Ordering::Relaxed);
                let back = (playing != 0 && playing != id).then(|| self.queue.iter().position(|&q| q == playing)).flatten();
                if let Some(pos) = back {
                    self.index = pos;
                    self.emit_index();
                    if let Some(info) = self.infos.get(&playing) {
                        let _ = self.events.send(CoreEvent::Track(info.clone()));
                    }
                } else if playing != id {
                    // Le titre qui jouait n'est plus dans la file (autre album, recherche…) : il est arrêté, l'interface
                    // montre le titre demandé en pause, et un appui sur lecture le retente (moteur vide, voir `Resume`).
                    // Avant, l'ancien son continuait derrière la pochette du titre qui ne s'était pas lancé.
                    self.engine.stop();
                    let _ = self.events.send(CoreEvent::Stopped);
                }
                self.error(e);
            }
        }
    }

    /// Garde le format d'un titre pour son rapport d'écoute. Au-delà de 500 titres, la table est vidée sauf le titre
    /// audible et le suivant préparé : vidée en entier, le suivant perdait son format et son écoute ne démarrait jamais.
    fn remember_format(&mut self, id: i64, format: String) {
        if self.formats.len() > 500 {
            let audible = self.engine.shared.current_id.load(Ordering::Relaxed);
            let next = self.prefetched;
            self.formats.retain(|k, _| *k == audible || Some(*k) == next);
        }
        self.formats.insert(id, format);
    }

    async fn resolve(&mut self, id: i64) -> Result<Resolved, ResolveError> {
        if let Some(local) = self.offline.as_ref().and_then(|store| store.local(id)) {
            self.infos.insert(id, local.info.clone());
            // Format pour le rapport d'écoute : sans lui, un titre téléchargé n'était jamais compté (voir `track_listen`).
            self.remember_format(id, offline_format(local.info.quality.as_deref(), &local.ext));
            let file = std::fs::File::open(local.path)?;
            return Ok(Resolved { src: Box::new(file), ext: Some(local.ext), info: local.info, preview: false, cancel: None });
        }
        // Jeton gardé en mémoire depuis une lecture précédente : il peut avoir expiré (environ 24 h).
        let cached = self.infos.get(&id).filter(|i| i.track_token.is_some()).cloned();
        // Récupération rapide (essais en parallèle) si Deezer refuse le titre ; `stream_id` est celui d'un titre de remplacement
        // si Deezer en impose un (il sert à la clé de déchiffrement).
        let resolved = self.api.media_with_recovery(id, cached, self.quality).await?;
        let (media, stream_id, mut info) = (resolved.media, resolved.stream_id, resolved.info);

        // Seul le chiffrement par blocs de Deezer est connu. Un autre (nouveau format chez Deezer) recevait quand même
        // ce déchiffreur : le son était « déchiffré » à tort (bruit, ou format illisible puis 2 nouvelles tentatives).
        // Il passe maintenant par l'aperçu de 30 s, comme un flux chiffré sans déchiffreur.
        let known: Option<Arc<dyn ChunkDecryptor>> = match &media.cipher {
            Cipher::None => Some(Arc::new(Passthrough)),
            Cipher::BlockStripe => self.decryptors.as_ref().and_then(|f| f(stream_id)),
            Cipher::Other(_) => None,
        };
        let other = media.cipher.clone();
        let dec: Arc<dyn ChunkDecryptor> = match known {
            Some(d) => d,
            None => {
                // Repli : l'aperçu public de 30 s n'est pas chiffré.
                return match self.api.preview_url(id).await {
                    Ok(url) => {
                        info.quality = Some("Aperçu 30 s".into());
                        self.infos.insert(id, info.clone());
                        let reader = StreamReader::spawn(
                            &Handle::current(), self.api.http().clone(), url, Arc::new(Passthrough),
                        );
                        let cancel = Some(reader.cancel_handle());
                        Ok(Resolved { src: Box::new(reader), ext: Some("mp3".into()), info, preview: true, cancel })
                    }
                    Err(_) => Err(ResolveError::Encrypted(other)),
                };
            }
        };
        info.quality = Some(format_label(&media.format));
        self.api.apply_cover_fixes(std::slice::from_mut(&mut info));
        self.infos.insert(id, info.clone());
        self.remember_format(id, media.format.clone());
        let ext = if media.format.to_ascii_uppercase().starts_with("FLAC") { "flac" } else { "mp3" };
        let reader = StreamReader::spawn(&Handle::current(), self.api.http().clone(), media.url, dec);
        let cancel = Some(reader.cancel_handle());
        Ok(Resolved { src: Box::new(reader), ext: Some(ext.into()), info, preview: false, cancel })
    }

    async fn on_engine(&mut self, ev: EngineEvent) {
        match ev {
            EngineEvent::TrackStarted { id } => {
                // Nouveau départ du titre (y compris le même, répété) ; un rechargement à la même position n'en est pas un.
                if self.reload_id.take() != Some(id) {
                    self.restart = true;
                }
                if self.prefetched == Some(id) {
                    // Transition gapless : la file avance toute seule, jusqu'à l'index préparé.
                    if let Some(i) = self.prefetched_idx.take() {
                        self.index = i;
                    }
                    self.prefetched = None;
                } else if let Some(pos) = self.queue.iter().position(|&q| q == id) {
                    self.index = pos;
                }
                self.retries = 0;
                self.recover_at = None;
                // Flux d'un titre qui n'est plus ni joué ni préparé : le moteur les a lâchés, on oublie leur poignée.
                let next = self.prefetched;
                self.streams.retain(|(s, _)| *s == id || Some(*s) == next);
                self.emit_index();
                self.top_up_flow();
                self.maybe_enrich(id); // enchaînement automatique : même vérification des artistes
                self.check_cover(id);
                if let Some(info) = self.infos.get(&id) {
                    if let Ok(mut s) = self.snap.lock() {
                        s.current = Some(info.clone());
                    }
                    let _ = self.events.send(CoreEvent::Track(info.clone()));
                }
            }
            EngineEvent::Finished { .. } if self.recover_at.is_some() => {} // fin factice due à la coupure
            EngineEvent::Finished { .. } => {
                // Préchargement raté (ou fin de file) : on tente quand même d'enchaîner.
                if let Some(i) = self.next_index() {
                    self.index = i;
                    self.play_current().await;
                } else {
                    let _ = self.events.send(CoreEvent::Stopped);
                }
            }
            EngineEvent::StateChanged => {} // la boucle notifie `changed` après chaque événement
            // Le titre préparé n'était plus disponible dans le moteur : chargement normal du titre demandé.
            EngineEvent::SkipFailed => {
                self.prefetched = None;
                self.prefetched_idx = None;
                self.play_current().await;
            }
            EngineEvent::DeviceLost => {
                self.error("Sortie audio perdue (casque ou périphérique débranché ?). Lecture en pause : appuie sur lecture pour reprendre.");
            }
            // Flux annulé par nous (titre remplacé, arrêt) : ni erreur à afficher, ni nouvelle tentative.
            EngineEvent::Error { msg, .. } if msg.contains(dz_stream::CANCELLED) => {}
            EngineEvent::Error { id, msg } => {
                // Titre Deezer en cours interrompu (coupure réseau…) : on retente, 2 fois au plus.
                let current = self.queue.get(self.index) == Some(&id);
                if current && id > 0 && self.retries < 2 && self.recover_at.is_none() {
                    self.retries += 1;
                    self.recover_at = Some(Instant::now() + Duration::from_millis(1200));
                    self.error("Lecture interrompue, nouvelle tentative…");
                } else {
                    self.error(msg);
                }
            }
        }
    }

    /// Relance le titre en cours (nouvelle adresse de flux, jeton frais) à la position où il s'est arrêté.
    async fn maybe_recover(&mut self) {
        let Some(at) = self.recover_at else { return };
        if Instant::now() < at {
            return;
        }
        self.recover_at = None;
        let pos = self.engine.shared.position_ms.load(Ordering::Relaxed);
        self.infos.remove(&self.queue.get(self.index).copied().unwrap_or(0)).map(|mut i| {
            i.track_token = None; // force une résolution fraîche
            i
        }).map(|i| self.infos.insert(i.id, i));
        self.reload_id = self.queue.get(self.index).copied();
        self.play_current().await;
        if pos > 1000 {
            self.engine.seek(pos);
        }
    }

    /// À 80 % de la piste (ou à `fondu + 10 s` de la fin), prépare la suivante pour une transition sans coupure.
    async fn maybe_prefetch(&mut self) {
        let sh = &self.engine.shared;
        let (pos, dur) = (sh.position_ms.load(Ordering::Relaxed), sh.duration_ms.load(Ordering::Relaxed));
        let xf = sh.crossfade_ms.load(Ordering::Relaxed);
        let due = pos * 100 >= dur * 80 || (xf > 0 && dur.saturating_sub(pos) <= xf + 10_000);
        if dur == 0 || !sh.playing.load(Ordering::Relaxed) || !due {
            return;
        }
        let Some(next_i) = self.next_index() else { return };
        let Some(&next) = self.queue.get(next_i) else { return };
        if self.prefetched == Some(next) {
            return;
        }
        self.prefetched = Some(next); // même en cas d'échec : pas de boucle de retry
        self.prefetched_idx = Some(next_i);
        match self.resolve(next).await {
            Ok(r) => {
                // Un ancien préchargement (autre titre) est remplacé par celui-ci dans le moteur.
                // Gardés : le titre audible et celui de la file (chargé mais pas encore audible).
                let audible = self.engine.shared.current_id.load(Ordering::Relaxed);
                let current = self.queue.get(self.index).copied();
                self.streams.retain(|(s, c)| {
                    let keep = *s == audible || Some(*s) == current;
                    if !keep {
                        c.cancel();
                    }
                    keep
                });
                self.streams.extend(r.cancel.map(|c| (next, c)));
                self.engine.queue_next(next, r.src, r.ext);
                self.flush_waiting_listens();
                // Fiche complète (artistes) et vérification de la pochette du titre suivant : faites maintenant, pendant
                // son téléchargement, plutôt qu'au changement de titre. Les échanges réseau sont regroupés, la radio se
                // réveille moins souvent.
                self.maybe_enrich(next);
                self.check_cover(next);
            }
            Err(e) => self.error(format!("préchargement: {e}")),
        }
    }
}

/// Applique une modification à une copie de la file (l'interface fait exactement la même chose de son côté).
pub fn apply_edit(queue: &mut Vec<TrackInfo>, index: &mut usize, edit: &QueueEdit) {
    match edit {
        QueueEdit::Insert { at, tracks, index: i } => {
            let at = (*at).min(queue.len());
            queue.splice(at..at, tracks.iter().cloned());
            *index = *i;
        }
        QueueEdit::Remove { at, index: i } => {
            if *at < queue.len() {
                queue.remove(*at);
            }
            *index = *i;
        }
        QueueEdit::Move { from, to, index: i } => {
            if *from < queue.len() && *to < queue.len() {
                let t = queue.remove(*from);
                queue.insert(*to, t);
            }
            *index = *i;
        }
        QueueEdit::Update { track, index: i } => {
            for t in queue.iter_mut().filter(|t| t.id == track.id) {
                *t = track.clone();
            }
            *index = *i;
        }
    }
}

fn seed() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9E37_79B9_7F4A_7C15)
        | 1
}

#[cfg(test)]
mod tests {
    use super::*;

    fn actor(queue: Vec<i64>, index: usize) -> Actor {
        let (etx, _erx) = mpsc::unbounded_channel();
        let (ctx, _crx) = mpsc::unbounded_channel();
        let (cmd_tx, _cmd_rx) = mpsc::channel(4);
        Actor {
            cmd_tx,
            flow: false,
            flow_fetching: false,
            api: Arc::new(DeezerClient::new().unwrap()),
            decryptors: None,
            offline: None,
            engine: Engine::start(etx),
            events: ctx,
            changed: Arc::new(Notify::new()),
            snap: Arc::new(std::sync::Mutex::new(Snapshot::default())),
            quality: Quality::Flac,
            shuffle: false,
            repeat: RepeatMode::Off,
            original: Vec::new(),
            rng: seed(),
            prefetched_idx: None,
            retries: 0,
            recover_at: None,
            queue,
            index,
            infos: HashMap::new(),
            prefetched: None,
            enriched: std::collections::HashSet::new(),
            covers_checked: std::collections::HashSet::new(),
            formats: HashMap::new(),
            listen: None,
            restart: false,
            reload_id: None,
            listens_waiting: false,
            streams: Vec::new(),
        }
    }

    #[tokio::test]
    async fn next_index_follows_repeat_mode() {
        let mut a = actor(vec![1, 2, 3], 2);
        assert_eq!(a.next_index(), None); // fin de file
        a.repeat = RepeatMode::All;
        assert_eq!(a.next_index(), Some(0)); // retour au début
        a.repeat = RepeatMode::One;
        assert_eq!(a.next_index(), Some(2)); // même titre
        a.index = 0;
        a.repeat = RepeatMode::Off;
        assert_eq!(a.next_index(), Some(1));
    }

    #[tokio::test]
    async fn shuffle_keeps_current_first_and_restores_order() {
        let ids: Vec<i64> = (1..=50).collect();
        let mut a = actor(ids.clone(), 9); // titre courant : 10
        a.apply_shuffle(true);
        assert_eq!(a.queue[0], 10);
        assert_eq!(a.index, 0);
        let mut sorted = a.queue.clone();
        sorted.sort();
        assert_eq!(sorted, ids, "aucun titre perdu ni dupliqué");
        assert_ne!(a.queue, ids, "la file doit être mélangée");

        a.index = 7; // on a avancé dans la file mélangée
        let cur = a.queue[7];
        a.apply_shuffle(false);
        assert_eq!(a.queue, ids, "ordre d'origine rétabli");
        assert_eq!(a.queue[a.index], cur, "on reste sur le même titre");
    }

    fn track(id: i64) -> TrackInfo {
        TrackInfo {
            id, title: format!("t{id}"), artist: String::new(), album: String::new(), duration_s: 1, cover_url: None, track_token: None,
            quality: None, added_at: None, release_date: None, fallback_id: None, restricted: false, artist_id: 0, album_id: 0, artists: Vec::new(),
        }
    }

    #[tokio::test]
    async fn flow_more_appends_only_new_tracks_while_flow_is_active() {
        let mut a = actor(vec![1, 2, 3], 0);
        // Hors Flow : la réception tardive de titres est ignorée.
        a.on_cmd(PlayerCmd::FlowMore { tracks: vec![track(9)] }).await;
        assert_eq!(a.queue, vec![1, 2, 3]);
        // En Flow : ajout sans doublon.
        a.flow = true;
        a.flow_fetching = true;
        a.on_cmd(PlayerCmd::FlowMore { tracks: vec![track(2), track(4), track(5)] }).await;
        assert_eq!(a.queue, vec![1, 2, 3, 4, 5]);
        assert!(!a.flow_fetching, "la demande est terminée");
        // Un échec (liste vide) libère aussi le drapeau.
        a.flow_fetching = true;
        a.on_cmd(PlayerCmd::FlowMore { tracks: vec![] }).await;
        assert!(!a.flow_fetching);
        // Fermer le titre arrête le Flow.
        a.on_cmd(PlayerCmd::Close).await;
        assert!(!a.flow && a.queue.is_empty());
    }

    /// Les modifications envoyées donnent exactement la même file que l'envoi complet.
    #[tokio::test]
    async fn queue_edits_rebuild_the_same_queue_as_a_full_send() {
        let mut a = actor(vec![1, 2, 3, 4, 5, 6], 2);
        a.seed_infos((1..=6).map(track).collect());
        let mut copy: Vec<TrackInfo> = a.infos_of(&a.queue.clone());
        let mut idx = a.index;
        if let Ok(mut s) = a.snap.lock() {
            s.queue = copy.clone();
            s.index = idx;
        }
        let (tx, mut rx) = mpsc::unbounded_channel();
        a.events = tx;
        a.on_cmd(PlayerCmd::QueueMove { from: 0, to: 4 }).await;
        a.on_cmd(PlayerCmd::QueueRemove { index: 0 }).await; // avant le titre en cours : son index recule
        a.on_cmd(PlayerCmd::QueueAdd { tracks: vec![track(7), track(8)], next: true }).await;
        a.on_cmd(PlayerCmd::QueueAdd { tracks: vec![track(9)], next: false }).await;
        a.on_cmd(PlayerCmd::QueueMove { from: 5, to: 0 }).await;
        a.flow = true;
        a.on_cmd(PlayerCmd::FlowMore { tracks: vec![track(10), track(2)] }).await;
        let mut edits = 0;
        while let Ok(ev) = rx.try_recv() {
            if let CoreEvent::QueueEdit(e) = ev {
                apply_edit(&mut copy, &mut idx, &e);
                edits += 1;
            }
        }
        assert_eq!(edits, 6);
        assert_eq!(copy.iter().map(|t| t.id).collect::<Vec<_>>(), a.queue, "même file côté interface");
        assert_eq!(idx, a.index, "même titre en cours");
        let snap = a.snap.lock().unwrap().clone();
        assert_eq!(snap.queue.iter().map(|t| t.id).collect::<Vec<_>>(), a.queue, "état consultable à jour");
        assert_eq!(snap.index, a.index);
    }

    /// Cas réel (« Bracelet », Heuss L'enfoiré feat. Timar) : vu d'abord sans le feat, puis avec dans l'album.
    #[tokio::test]
    async fn richer_artist_list_wins_and_resolved_token_is_kept() {
        let mut a = actor(vec![], 0);
        let mut first = track(7);
        first.artist = "Heuss L'enfoiré".into();
        first.artists = vec![dz_api::ArtistRef { id: 1, name: "Heuss L'enfoiré".into() }];
        first.track_token = Some("jeton".into());
        a.seed_infos(vec![first]);
        let mut album_row = track(7);
        album_row.artist = "Heuss L'enfoiré, Timar".into();
        album_row.artists = vec![
            dz_api::ArtistRef { id: 1, name: "Heuss L'enfoiré".into() },
            dz_api::ArtistRef { id: 2, name: "Timar".into() },
        ];
        a.seed_infos(vec![album_row]);
        let t = &a.infos[&7];
        assert_eq!(t.artist, "Heuss L'enfoiré, Timar", "le feat apparaît");
        assert_eq!(t.track_token.as_deref(), Some("jeton"), "le jeton déjà résolu est gardé");
        // Dans l'autre sens : une liste plus pauvre vue ensuite ne fait pas disparaître le feat.
        let mut poor = track(7);
        poor.artist = "Heuss L'enfoiré".into();
        poor.artists = vec![dz_api::ArtistRef { id: 1, name: "Heuss L'enfoiré".into() }];
        a.seed_infos(vec![poor]);
        assert_eq!(a.infos[&7].artist, "Heuss L'enfoiré, Timar");
    }

    /// Cas réel : « California (feat. WIXO & LA2S) » lancé depuis une liste qui ne donnait que Ghost Killer Track.
    #[tokio::test]
    async fn enrich_adds_the_feat_to_the_track_on_screen() {
        let mut a = actor(vec![9], 0);
        let mut poor = track(9);
        poor.artist = "Ghost Killer Track".into();
        poor.artists = vec![dz_api::ArtistRef { id: 1, name: "Ghost Killer Track".into() }];
        poor.track_token = Some("jeton".into());
        poor.quality = Some("FLAC".into());
        a.seed_infos(vec![poor]);
        let (tx, mut rx) = mpsc::unbounded_channel();
        a.events = tx;
        let mut rich = track(9);
        rich.artist = "Ghost Killer Track, WIXO & LA2S".into();
        rich.artists = vec![dz_api::ArtistRef { id: 1, name: "Ghost Killer Track".into() }, dz_api::ArtistRef { id: 2, name: "WIXO & LA2S".into() }];
        a.on_cmd(PlayerCmd::Enrich { info: rich.clone() }).await;
        assert_eq!(a.infos[&9].artist, "Ghost Killer Track, WIXO & LA2S");
        assert_eq!(a.infos[&9].quality.as_deref(), Some("FLAC"), "qualité de lecture gardée");
        let mut shown = None;
        while let Ok(ev) = rx.try_recv() {
            if let CoreEvent::Track(t) = ev { shown = Some(t.artist); }
        }
        assert_eq!(shown.as_deref(), Some("Ghost Killer Track, WIXO & LA2S"), "le lecteur reçoit la fiche complète");
        // Une deuxième fois, rien de nouveau : aucun événement.
        a.on_cmd(PlayerCmd::Enrich { info: rich }).await;
        assert!(!std::iter::from_fn(|| rx.try_recv().ok()).any(|e| matches!(e, CoreEvent::Track(_))));
    }

    #[tokio::test]
    async fn new_queue_forgets_infos_of_tracks_no_longer_queued() {
        let mut a = actor(vec![1, 2, 3], 0);
        a.seed_infos(vec![track(1), track(2), track(3)]);
        a.queue = vec![2];
        a.forget_old_infos();
        assert_eq!(a.infos.len(), 1);
        assert!(a.infos.contains_key(&2));
        a.queue.clear();
        a.forget_old_infos();
        assert!(a.infos.is_empty());
    }

    #[tokio::test]
    async fn trimming_formats_keeps_the_playing_and_next_track() {
        let mut a = actor(vec![], 0);
        for id in 1..=501 {
            a.formats.insert(id, "MP3_128".into());
        }
        a.engine.shared.current_id.store(300, Ordering::Relaxed); // titre audible
        a.prefetched = Some(400); // suivant déjà préparé
        a.remember_format(9_999, "FLAC".into());
        assert_eq!(a.formats.len(), 3);
        assert!(a.formats.contains_key(&300), "le titre audible garde son format");
        assert!(a.formats.contains_key(&400), "le suivant préparé garde le sien : son écoute démarrera");
        assert_eq!(a.formats.get(&9_999).map(String::as_str), Some("FLAC"));
    }

    #[test]
    fn downloaded_tracks_get_the_listen_format_back() {
        assert_eq!(offline_format(Some("FLAC"), "flac"), "FLAC");
        assert_eq!(offline_format(Some("MP3 320"), "mp3"), "MP3_320");
        assert_eq!(offline_format(Some("MP3 128"), "mp3"), "MP3_128");
        assert_eq!(offline_format(Some("MP3 importé"), "mp3"), "MP3_MISC");
        // Qualité inconnue : déduite du fichier.
        assert_eq!(offline_format(None, "flac"), "FLAC");
        assert_eq!(offline_format(Some(" "), "mp3"), "MP3_320");
        assert_eq!(offline_format(Some("Aperçu 30 s"), "mp3"), "MP3_320");
        // Aller-retour avec le libellé affiché.
        for f in ["FLAC", "MP3_320", "MP3_256", "MP3_128", "MP3_MISC"] {
            assert_eq!(offline_format(Some(&format_label(f)), "mp3"), f);
        }
    }

    #[test]
    fn current_listen_is_saved_while_playing_so_closing_the_app_does_not_lose_it() {
        let now = Instant::now();
        let s = |n: u64| Duration::from_secs(n);
        // Moins de 30 s : ne compte pas encore, rien à garder.
        let min = LISTEN_MIN;
        assert!(!save_due(s(29), min, false, true, None, now));
        assert!(!save_due(s(29), min, true, false, None, now));
        // 30 s atteintes en pleine lecture : gardée tout de suite (app fermée sans pause : écoute comptée au relancement).
        assert!(save_due(s(30), min, false, true, None, now));
        // Puis toutes les 20 s, pas à chaque seconde.
        assert!(!save_due(s(45), min, false, true, Some(now), now + s(10)));
        assert!(save_due(s(55), min, false, true, Some(now), now + s(20)));
        // Mise en pause : gardée aussitôt, avec la durée exacte.
        assert!(save_due(s(40), min, true, false, Some(now), now + s(1)));
        // En pause, plus d'écriture.
        assert!(!save_due(s(40), min, false, false, Some(now), now + s(60)));
        // Titre de 20 s : compte (et est gardé) dès 18 s.
        assert!(save_due(s(18), listen_min(20), false, true, None, now));
    }

    #[test]
    fn listen_remembers_the_profile_that_made_it() {
        let l = Listen {
            id: 5, format: "FLAC".into(), started_at: 1000, played: Duration::from_secs(95),
            last: Instant::now(), playing: false, generation: 0, saved_at: None, duration_s: 200, user: 0, last_pos: 0,
        };
        CURRENT_USER.store(42, Ordering::Release);
        let p = l.pending();
        assert_eq!((p.track_id, p.format.as_str(), p.started_at, p.listened_s, p.user_id), (5, "FLAC", 1000, 95, 42));
        // Profil changé ensuite : l'écoute faite garde le sien (la vidange n'envoie que celles du profil ouvert).
        CURRENT_USER.store(7, Ordering::Release);
        assert_eq!(p.user_id, 42);
        // Profil connu dès le début de l'écoute : c'est lui qui compte, même si l'on change de profil avant la fin.
        let l = Listen { user: 42, ..l };
        assert_eq!(l.pending().user_id, 42);
        assert!(l.counts());
        assert!(!Listen { played: Duration::from_secs(29), format: l.format.clone(), ..l }.counts());
        assert!(Listen { played: Duration::from_secs(18), duration_s: 20, ..l }.counts());
        // Compte relevé à la génération 0, puis déconnexion (génération 1) : il n'est plus pris pour celui qui écoute.
        assert_eq!(current_user(0), 7);
        assert_eq!(current_user(1), 0, "compte précédent oublié après la déconnexion");
        let after_logout = Listen { user: 0, generation: 1, format: "FLAC".into(), ..l };
        assert_eq!(after_logout.pending().user_id, 0, "partira sur le compte ouvert à la vidange, pas sur l'ancien");
        // Vidange faite sur le nouveau compte : il est connu pour cette génération.
        CURRENT_USER_GEN.store(1, Ordering::Release);
        CURRENT_USER.store(9, Ordering::Release);
        assert_eq!(current_user(1), 9);
        CURRENT_USER_GEN.store(0, Ordering::Release);
    }

    #[test]
    fn quota_refusal_is_kept_for_later_but_other_refusals_are_not() {
        assert!(not_delivered(&DeezerError::Gateway("{\"QUOTA_ERROR\":\"Quota exceeded\"}".into())));
        assert!(!not_delivered(&DeezerError::Gateway("{\"DATA_ERROR\":\"bad\"}".into())));
        assert!(!not_delivered(&DeezerError::EmptyResults));
        // ARL expiré : gardée jusqu'à la reconnexion (Deezer ne l'a pas comptée).
        assert!(not_delivered(&DeezerError::InvalidArl));
        assert!(not_delivered(&DeezerError::SessionExpired));
    }

    #[tokio::test]
    async fn queue_edits_keep_the_current_track() {
        let mut a = actor(vec![1, 2, 3, 4, 5], 2); // en cours : 3
        a.on_cmd(PlayerCmd::QueueMove { from: 0, to: 4 }).await; // 1 passe en dernier
        assert_eq!(a.queue, vec![2, 3, 4, 5, 1]);
        assert_eq!(a.queue[a.index], 3);
        a.on_cmd(PlayerCmd::QueueMove { from: 4, to: 0 }).await; // 1 revient en tête
        assert_eq!(a.queue, vec![1, 2, 3, 4, 5]);
        assert_eq!(a.queue[a.index], 3);
        a.on_cmd(PlayerCmd::QueueMove { from: 2, to: 4 }).await; // on déplace le titre en cours
        assert_eq!(a.queue[a.index], 3);
        a.on_cmd(PlayerCmd::QueueRemove { index: a.index }).await; // impossible
        assert_eq!(a.queue.len(), 5);
        let before = a.queue[a.index];
        a.on_cmd(PlayerCmd::QueueRemove { index: 0 }).await;
        assert_eq!(a.queue.len(), 4);
        assert_eq!(a.queue[a.index], before, "retirer avant le titre en cours ne le change pas");
    }
}
