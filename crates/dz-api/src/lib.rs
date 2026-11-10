//! Client de l'API interne Deezer (`gw-light.php`) + résolution d'URL média.
//!
//! API non officielle : peut casser sans préavis et sort probablement du cadre des CGU.

use std::sync::Arc;

use reqwest::Client;
use reqwest_cookie_store::CookieStoreMutex;
use serde::{de::DeserializeOwned, Deserialize, Deserializer, Serialize};
use serde_json::{json, Value};
use tokio::sync::{Mutex, RwLock};
use url::Url;

mod catalog;
mod ytmusic;
mod cover;
mod listen;
/// Pour les crates qui lisent ou écrivent du JSON sans en dépendre elles-mêmes.
pub use serde_json;
mod stats;
pub use stats::{MonthStats, RecentListen, StatArtist, StatGenre, StatTrack};
pub use ytmusic::LyricsQuery;
pub use catalog::{drain_notes, Card, Collection, LyricLine, Lyrics, PageView, SearchResults, Section};

const GW_URL: &str = "https://www.deezer.com/ajax/gw-light.php";
const MEDIA_URL: &str = "https://media.deezer.com/v1/get_url";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

#[derive(Debug, thiserror::Error)]
pub enum DeezerError {
    #[error("http: {0}")]
    Http(#[from] reqwest::Error),
    #[error("url: {0}")]
    Url(#[from] url::ParseError),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("arl invalide ou expiré")]
    InvalidArl,
    #[error("session expirée et renouvellement impossible")]
    SessionExpired,
    #[error("erreur gateway: {0}")]
    Gateway(String),
    #[error("réponse gateway sans `results`")]
    EmptyResults,
    #[error("cookie store: {0}")]
    Cookie(String),
    #[error("aucune source média disponible pour ce titre (droits/format/DRM)")]
    NoMediaSource,
    /// Compte Famille : le profil demandé n'a pas pu être ouvert (retiré du compte, plus accessible…).
    #[error("ce profil Deezer n'est pas accessible depuis ce compte")]
    ProfileUnavailable,
    /// Deezer a répondu mais refuse ce titre : code et message de Deezer (droits, pays, jeton périmé…).
    #[error("Deezer a refusé ce titre : {0}")]
    MediaRefused(String),
    /// Licence de lecture refusée (HTTP 401/403) : le jeton de licence de la session est périmé.
    #[error("licence de lecture refusée par Deezer (session à renouveler)")]
    LicenseRejected,
}
pub type Result<T> = std::result::Result<T, DeezerError>;

/// Données de session extraites de `deezer.getUserData`.
#[derive(Debug, Clone)]
pub struct Session {
    /// Jeton CSRF (`api_token`) obligatoire pour les POST gw-light.
    pub check_form: String,
    /// Cookie `sid` posé par le serveur.
    pub sid: Option<String>,
    /// Jeton de licence pour `media.deezer.com/v1/get_url`.
    pub license_token: String,
    pub user_id: u64,
    pub hq: bool,
    /// Éligibilité FLAC (abonnement HiFi).
    pub lossless: bool,
    /// Identifiant de la playlist « Titres aimés » du compte (0 si inconnu).
    pub loved_playlist_id: u64,
    /// Nom du profil (compte solo, ou profil choisi d'un compte Famille).
    pub name: String,
    /// Photo du profil (adresse de l'image), s'il en a une.
    pub picture: Option<String>,
}

/// Un profil d'un compte Deezer Famille (ou le compte lui-même, pour un compte solo).
#[derive(Debug, Clone, Serialize)]
pub struct Profile {
    pub id: u64,
    pub name: String,
    pub picture_url: Option<String>,
    /// Profil enfant (Deezer Kids).
    pub kid: bool,
    /// Titulaire du compte (le profil ouvert par défaut).
    pub main: bool,
    /// Profil ouvert en ce moment.
    pub current: bool,
}

#[derive(Deserialize)]
struct Envelope {
    #[serde(default)]
    error: Value,
    results: Option<Value>,
}

#[derive(Deserialize)]
struct UserData {
    #[serde(rename = "checkForm")]
    check_form: String,
    #[serde(rename = "USER")]
    user: UserBlock,
}

#[derive(Deserialize)]
struct UserBlock {
    #[serde(rename = "USER_ID", default)]
    id: u64,
    #[serde(rename = "OPTIONS")]
    options: Options,
    /// Identifiant de la playlist « Titres aimés » (nombre ou texte selon les réponses).
    #[serde(rename = "LOVEDTRACKS_ID", default)]
    loved: Value,
    #[serde(rename = "BLOG_NAME", default)]
    name: String,
    #[serde(rename = "USER_PICTURE", default)]
    picture: String,
}

#[derive(Deserialize)]
struct Options {
    license_token: String,
    #[serde(default)]
    web_hq: bool,
    #[serde(default)]
    web_lossless: bool,
}

/// Qualité audio demandée. Les formats non inclus dans l'abonnement sont ignorés (repli vers le bas).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Quality {
    #[serde(rename = "flac")]
    Flac,
    #[serde(rename = "mp3_320")]
    Mp3320,
    #[serde(rename = "mp3_128")]
    Mp3128,
}

/// Libellé court affiché dans l'UI.
pub fn format_label(format: &str) -> String {
    match format.to_ascii_uppercase().as_str() {
        "FLAC" => "FLAC".into(),
        "MP3_320" => "MP3 320".into(),
        "MP3_256" => "MP3 256".into(),
        "MP3_128" => "MP3 128".into(),
        "MP3_MISC" => "MP3 importé".into(),
        other => other.replace('_', " "),
    }
}

/// Format/chiffrement demandés ou renvoyés par `get_url`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Cipher {
    None,
    /// Flux chiffré par blocs de 2048 octets, déchiffré par `dz-decrypt`
    /// via `dz_stream::ChunkDecryptor`.
    BlockStripe,
    Other(String),
}

#[derive(Debug, Clone)]
pub struct MediaSource {
    pub url: String,
    pub format: String,
    pub cipher: Cipher,
}

pub struct DeezerClient {
    /// Remplacé en entier après un changement de réseau (voir `reset_connections`) : les connexions restées sur
    /// l'ancien réseau ne sont plus réutilisées. Les cookies (dont l'arl) sont gardés.
    http: std::sync::RwLock<Client>,
    jar: Arc<CookieStoreMutex>,
    session: RwLock<Option<Session>>,
    refresh_lock: Mutex<()>,
    /// Titres aimés déjà chargés : (utilisateur, instant du chargement, titres).
    loved_cache: std::sync::Mutex<Option<(u64, std::time::Instant, Vec<TrackInfo>)>>,
    /// Dates de sortie déjà connues (une date de sortie ne change pas) : évite de les redemander.
    date_cache: std::sync::Mutex<std::collections::HashMap<i64, String>>,
    /// Recommandations d'accueil déjà chargées (5 min).
    home_cache: std::sync::Mutex<Option<(u64, std::time::Instant, Vec<catalog::Section>)>>,
    /// Compte Famille : profil à ouvrir à chaque session (`None` : celui par défaut, le titulaire).
    profile: std::sync::Mutex<Option<u64>>,
    /// Profils du compte, lus sur la session du titulaire (une session rattachée à un profil enfant ne les voit
    /// peut-être pas : sans cette liste, on ne pourrait plus changer de profil depuis un enfant). `None` : pas encore lus.
    family: std::sync::Mutex<Option<Vec<Profile>>>,
    /// Jeton d'accès des services récents (pipe), gardé quelques minutes pour le compte ou profil ouvert.
    jwt: std::sync::Mutex<Option<(u64, std::time::Instant, String)>>,
    /// Pochettes réparées (ancienne image supprimée chez Deezer → image actuelle de l'album), par md5 : remises
    /// d'office dans les listes ouvertes ensuite (voir `repaired_cover`).
    cover_fixes: std::sync::Mutex<std::collections::HashMap<String, String>>,
    /// Fichier où les pochettes réparées sont gardées d'un lancement à l'autre (voir `use_cover_fixes_file`).
    cover_fixes_file: std::sync::Mutex<Option<std::path::PathBuf>>,
}

impl DeezerClient {
    pub fn new() -> Result<Self> {
        let jar = Arc::new(CookieStoreMutex::default());
        let http = std::sync::RwLock::new(Self::build_http(jar.clone())?);
        Ok(Self { http, jar, session: RwLock::new(None), refresh_lock: Mutex::new(()), loved_cache: std::sync::Mutex::new(None), date_cache: std::sync::Mutex::new(std::collections::HashMap::new()), home_cache: std::sync::Mutex::new(None), profile: std::sync::Mutex::new(None), family: std::sync::Mutex::new(None), jwt: std::sync::Mutex::new(None), cover_fixes: std::sync::Mutex::new(std::collections::HashMap::new()), cover_fixes_file: std::sync::Mutex::new(None) })
    }

    fn build_http(jar: Arc<CookieStoreMutex>) -> Result<Client> {
        Ok(Client::builder()
            .cookie_provider(jar)
            .user_agent(UA)
            .use_rustls_tls()
            .http2_adaptive_window(true)
            .pool_max_idle_per_host(2)
            // Téléphone : la radio (4G/5G, Wi-Fi) reste allumée une dizaine de secondes après chaque échange. Une connexion
            // inactive est fermée dans ce délai, pendant que la radio est encore allumée. Gardée 60 s, elle recevait plus
            // tard un paquet de maintien (TCP) puis sa fermeture, qui réveillaient la radio pour rien entre deux titres
            // (les requêtes suivantes arrivent de toute façon des minutes plus tard, sur une connexion neuve).
            .pool_idle_timeout(std::time::Duration::from_secs(10))
            .connect_timeout(std::time::Duration::from_secs(10))
            .read_timeout(std::time::Duration::from_secs(20))
            // Changement de réseau (Wi-Fi <-> 4G/5G, mise en veille) : une connexion restée sur l'ancien réseau est
            // repérée en quelques secondes (ping HTTP/2 et keepalive TCP) au lieu d'attendre la fin du délai de lecture.
            .http2_keep_alive_interval(std::time::Duration::from_secs(15))
            .http2_keep_alive_timeout(std::time::Duration::from_secs(5))
            .http2_keep_alive_while_idle(false)
            // Plus long que la vie d'une connexion inactive (10 s) : il ne sert que pendant un long téléchargement.
            .tcp_keepalive(std::time::Duration::from_secs(75))
            .build()?)
    }

    /// Client HTTP partagé (pool + HTTP/2) à réutiliser pour le streaming. Copie légère (compteur de références).
    pub fn http(&self) -> Client {
        match self.http.read() {
            Ok(c) => c.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }

    /// Le réseau a changé (Wi-Fi <-> données mobiles…) : les prochaines requêtes partent sur des connexions neuves,
    /// au lieu d'attendre qu'une connexion de l'ancien réseau expire. Session et cookies sont gardés.
    pub fn reset_connections(&self) {
        if let Ok(fresh) = Self::build_http(self.jar.clone()) {
            match self.http.write() {
                Ok(mut c) => *c = fresh,
                Err(poisoned) => *poisoned.into_inner() = fresh,
            }
        }
    }

    /// Injecte le cookie `arl` (lu depuis le keyring ou capturé via la webview de login).
    pub fn set_arl(&self, arl: &str) -> Result<()> {
        let arl = arl.trim();
        let valid = !arl.is_empty()
            && arl.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
        if !valid {
            return Err(DeezerError::InvalidArl);
        }
        let url = Url::parse("https://www.deezer.com")?;
        let raw = format!("arl={arl}; Domain=.deezer.com; Path=/; Secure; HttpOnly");
        let cookie = reqwest_cookie_store::RawCookie::parse(raw)
            .map_err(|e| DeezerError::Cookie(e.to_string()))?;
        self.jar
            .lock()
            .map_err(|_| DeezerError::Cookie("mutex empoisonné".into()))?
            .insert_raw(&cookie, &url)
            .map_err(|e| DeezerError::Cookie(e.to_string()))?;
        Ok(())
    }

    /// Oublie tout ce qui est lié au compte : cookies (dont l'arl), session et données en cache. À la déconnexion.
    /// (Le jar de cookies n'existe qu'en mémoire : rien n'est écrit sur le disque.)
    pub async fn clear_session(&self) {
        if let Ok(mut jar) = self.jar.lock() {
            jar.clear();
        }
        *self.session.write().await = None;
        self.set_profile(None);
        if let Ok(mut f) = self.family.lock() {
            *f = None;
        }
        if let Ok(mut c) = self.loved_cache.lock() {
            *c = None;
        }
        if let Ok(mut c) = self.home_cache.lock() {
            *c = None;
        }
        if let Ok(mut c) = self.date_cache.lock() {
            c.clear();
        }
    }

    fn sid_cookie(&self) -> Option<String> {
        let store = self.jar.lock().ok()?;
        store.get("deezer.com", "/", "sid").map(|c| c.value().to_owned())
    }

    /// Compte Famille : profil à ouvrir aux prochaines sessions (`None` : le titulaire). Ne rouvre rien tout de suite
    /// (voir `switch_profile`) : à appeler avant la connexion pour retrouver le profil choisi la dernière fois.
    pub fn set_profile(&self, id: Option<u64>) {
        if let Ok(mut p) = self.profile.lock() {
            *p = id.filter(|&i| i != 0);
        }
    }

    pub fn wanted_profile(&self) -> Option<u64> {
        self.profile.lock().ok().and_then(|p| *p)
    }

    /// Oublie le cookie de session `sid` : la prochaine demande repart de l'arl seul (profil par défaut du compte).
    fn forget_sid(&self) {
        if let Ok(mut store) = self.jar.lock() {
            for domain in ["deezer.com", "www.deezer.com"] {
                store.remove(domain, "/", "sid");
            }
        }
    }

    /// Session Deezer. Compte Famille avec un profil choisi : la session est ouverte sur le titulaire, puis rattachée
    /// au profil (`user.loginMulti`) ; l'arl ne change pas. Profil devenu inaccessible : on reste sur le titulaire et le
    /// choix est oublié (l'app le voit au profil ouvert).
    pub async fn init_session(&self) -> Result<Session> {
        // Une seule ouverture à la fois (connexion au lancement, retour du réseau, renouvellement, changement de profil) :
        // deux ouvertures mêlées se volaient le cookie de session.
        let _g = self.refresh_lock.lock().await;
        self.open_session().await
    }

    /// Ouverture elle-même ; l'appelant tient `refresh_lock`.
    async fn open_session(&self) -> Result<Session> {
        let want = self.wanted_profile();
        if want.is_some() {
            // Une session déjà rattachée à un autre profil ne doit pas servir de départ. La session gardée est oubliée
            // aussi : si cette ouverture est interrompue en route (requête abandonnée, coupure), la suivante repart de
            // zéro au lieu de garder une session qui ne correspond plus aux cookies.
            *self.session.write().await = None;
            self.forget_sid();
        }
        let mut session = self.session_from(self.fetch_user_data().await?);
        // Session encore sur le titulaire : c'est le moment de lire la liste des profils (voir `family`), une seule
        // fois (pas à chaque renouvellement). Profil choisi = le titulaire lui-même : rien à lire ni à ouvrir.
        let known = self.family.lock().ok().is_some_and(|f| f.as_ref().is_some_and(|l| !l.is_empty()));
        if want.is_some_and(|id| id != session.user_id) && !known {
            self.read_family(&session.check_form).await;
        }
        if let Some(id) = want.filter(|&id| id != session.user_id) {
            match self.enter_profile(&session.check_form, id).await {
                Ok(s) => session = s,
                // Seul un refus du profil le fait oublier ; une autre erreur (réseau, limite de requêtes) est renvoyée
                // telle quelle et le choix reste, pour le prochain essai.
                Err(DeezerError::ProfileUnavailable) => {
                    // Refus d'un profil toujours dans la liste du compte (relue pour en être sûr) : refus passager, le
                    // choix reste et l'erreur est renvoyée. Pas de retour discret sur le titulaire : un profil enfant
                    // aurait reçu la bibliothèque et les recommandations du parent sans que l'app le sache.
                    self.read_family(&session.check_form).await;
                    let listed = self.family.lock().ok().is_some_and(|f| f.as_ref().is_some_and(|l| l.iter().any(|p| p.id == id)));
                    if listed {
                        self.forget_sid();
                        return Err(DeezerError::ProfileUnavailable);
                    }
                    self.forget_sid();
                    session = self.session_from(self.fetch_user_data().await?);
                    // Oublié seulement une fois le titulaire rouvert : une coupure ici ne fait pas perdre le choix.
                    self.set_profile(None);
                }
                Err(e) => return Err(e),
            }
        }
        *self.session.write().await = Some(session.clone());
        Ok(session)
    }

    /// Appel gw-light avec un jeton donné, sans passer par la session enregistrée ni la renouveler : pour les étapes de
    /// l'ouverture de session elle-même (qui tiennent déjà le verrou de renouvellement).
    async fn gw_with(&self, token: &str, method: &str, body: &Value) -> Result<Value> {
        let env: Envelope = self
            .http()
            .post(GW_URL)
            .timeout(std::time::Duration::from_secs(20))
            .query(&[("method", method), ("input", "3"), ("api_version", "1.0"), ("api_token", token)])
            .json(body)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        if let Some(e) = gw_error(&env.error) {
            return Err(DeezerError::Gateway(e));
        }
        env.results.ok_or(DeezerError::EmptyResults)
    }

    /// Profils du compte lus sur la session du titulaire et gardés (compte solo : liste vide). Réseau coupé : la liste
    /// gardée avant reste.
    async fn read_family(&self, token: &str) {
        let list = match self.gw_with(token, "deezer.getChildAccounts", &json!({})).await {
            Ok(v) => Some(parse_profiles(&v)),
            // Refus ou réponse vide : compte solo, sauf si une liste a déjà été lue (erreur passagère : elle reste).
            Err(DeezerError::Gateway(_) | DeezerError::EmptyResults) => None,
            Err(_) => return,
        };
        if let Ok(mut f) = self.family.lock() {
            match list {
                Some(list) => *f = Some(list),
                None if f.is_none() => *f = Some(Vec::new()),
                None => {}
            }
        }
    }

    /// Rattache la session en cours au profil `id` d'un compte Famille, puis relit la session (elle répond alors au
    /// nom de ce profil : bibliothèque, titres aimés, recommandations, jeton de licence).
    async fn enter_profile(&self, token: &str, id: u64) -> Result<Session> {
        // Pas de résultat utile attendu ; seule une erreur compte (`EmptyResults` n'en est pas une ici). Deezer qui
        // refuse le changement = profil inaccessible ; une coupure réseau reste une erreur réseau.
        match self.gw_with(token, "user.loginMulti", &json!({ "account_id": id })).await {
            Ok(_) | Err(DeezerError::EmptyResults) => {}
            Err(DeezerError::Gateway(e)) if !is_token_error(&e) && !e.to_ascii_uppercase().contains("QUOTA") => {
                return Err(DeezerError::ProfileUnavailable)
            }
            Err(e) => return Err(e),
        }
        let session = self.session_from(self.fetch_user_data().await?);
        if session.user_id != id {
            return Err(DeezerError::ProfileUnavailable);
        }
        Ok(session)
    }

    /// Ouvre le profil `id` du compte Famille et le retient pour les sessions suivantes. Échec : le profil ouvert
    /// avant reste ouvert, et `ProfileUnavailable` est renvoyée.
    pub async fn switch_profile(&self, id: u64) -> Result<Session> {
        let _g = self.refresh_lock.lock().await;
        let before = self.wanted_profile();
        self.set_profile(Some(id));
        let session = match self.open_session().await {
            Ok(s) => s,
            Err(e) => {
                // Coupure réseau pendant le changement : le profil d'avant reste celui à rouvrir (sinon une
                // simple reconnexion ouvrirait plus tard un profil que l'app ne connaît pas). La session gardée ne
                // correspond plus aux cookies (déjà repartis de zéro) : oubliée, la prochaine demande la rouvre proprement.
                self.set_profile(before);
                *self.session.write().await = None;
                self.forget_sid();
                return Err(e);
            }
        };
        if session.user_id == id {
            return Ok(session);
        }
        // Profil refusé (`open_session` est revenu au titulaire) : on rouvre celui d'avant.
        self.set_profile(before);
        if before.is_some() {
            if let Err(e) = self.open_session().await {
                // Réouverture de l'ancien profil coupée : la session du titulaire ne reste pas en place sous son nom.
                *self.session.write().await = None;
                self.forget_sid();
                return Err(e);
            }
        }
        Err(DeezerError::ProfileUnavailable)
    }

    /// Profils du compte Famille (seulement ceux que l'on peut ouvrir) ; compte solo : le compte lui-même, seul.
    pub async fn profiles(&self) -> Result<Vec<Profile>> {
        let me = self.ensure_session().await?;
        // Sur le titulaire (aucun profil choisi), la liste est relue ; sur un profil choisi, c'est celle lue sur la
        // session du titulaire à l'ouverture (relue ici seulement si elle manque).
        let kept = if self.wanted_profile().is_some() { self.family.lock().ok().and_then(|f| f.clone()) } else { None };
        let mut list = match kept {
            // Liste vide gardée : Deezer a pu refuser une fois au moment de la lecture ; on la redemande.
            Some(list) if !list.is_empty() => list,
            _ => {
                let list = match self.gw::<Value>("deezer.getChildAccounts", &json!({})).await {
                    Ok(v) => parse_profiles(&v),
                    // Compte solo : Deezer refuse ou ne renvoie rien ; le compte s'affiche seul.
                    Err(DeezerError::Gateway(_) | DeezerError::EmptyResults | DeezerError::Json(_)) => Vec::new(),
                    Err(e) => return Err(e),
                };
                // Gardée seulement si elle vient du titulaire : celle d'un profil enfant peut être incomplète.
                if self.wanted_profile().is_none() {
                    if let Ok(mut f) = self.family.lock() {
                        *f = Some(list.clone());
                    }
                }
                list
            }
        };
        if !list.iter().any(|p| p.id == me.user_id) {
            // Profil ouvert absent de la liste : le titulaire, si personne d'autre ne l'est.
            let main = !list.iter().any(|p| p.main);
            list.insert(0, Profile { id: me.user_id, name: me.name.clone(), picture_url: me.picture.clone(), kid: false, main, current: true });
        }
        for p in &mut list {
            p.current = p.id == me.user_id;
        }
        Ok(list)
    }

    async fn fetch_user_data(&self) -> Result<UserData> {
        let env: Envelope = self
            .http()
            .get(GW_URL)
            .query(&[
                ("method", "deezer.getUserData"),
                ("input", "3"),
                ("api_version", "1.0"),
                ("api_token", ""),
            ])
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;

        if let Some(e) = gw_error(&env.error) {
            return Err(DeezerError::Gateway(e));
        }
        let data: UserData =
            serde_json::from_value(env.results.ok_or(DeezerError::EmptyResults)?)?;

        // USER_ID == 0 => cookie arl absent/invalide (session anonyme).
        if data.user.id == 0 {
            return Err(DeezerError::InvalidArl);
        }
        Ok(data)
    }

    fn session_from(&self, data: UserData) -> Session {
        Session {
            check_form: data.check_form,
            sid: self.sid_cookie(),
            license_token: data.user.options.license_token,
            user_id: data.user.id,
            hq: data.user.options.web_hq,
            lossless: data.user.options.web_lossless,
            loved_playlist_id: data.user.loved.as_u64().or_else(|| data.user.loved.as_str().and_then(|s| s.trim().parse().ok())).unwrap_or(0),
            name: data.user.name,
            picture: user_picture(&data.user.picture),
        }
    }

    /// Ne renouvelle que si le jeton fautif est encore le jeton courant
    /// (évite N renouvellements concurrents).
    async fn refresh_if_stale(&self, stale: &str) -> Result<()> {
        let _g = self.refresh_lock.lock().await;
        let current = self.session.read().await.as_ref().map(|s| s.check_form.clone());
        if current.as_deref() == Some(stale) {
            self.open_session().await?;
        }
        Ok(())
    }

    async fn token(&self) -> Result<String> {
        Ok(self.ensure_session().await?.check_form)
    }

    /// Session courante, ou ouverte une seule fois si plusieurs chargements la demandent en même temps (démarrage).
    async fn ensure_session(&self) -> Result<Session> {
        if let Some(s) = self.session.read().await.as_ref() {
            return Ok(s.clone());
        }
        let _g = self.refresh_lock.lock().await;
        // Un autre chargement l'a peut-être ouverte pendant qu'on attendait.
        if let Some(s) = self.session.read().await.as_ref() {
            return Ok(s.clone());
        }
        self.open_session().await
    }

    pub async fn session(&self) -> Option<Session> {
        self.session.read().await.clone()
    }

    /// Compte ou profil ouvert, sans attendre : `None` sans session, ou si elle est en train de changer.
    pub fn session_user_now(&self) -> Option<u64> {
        self.session.try_read().ok()?.as_ref().map(|s| s.user_id).filter(|&user| user != 0)
    }

    /// Appel POST gw-light, avec renouvellement automatique du `checkForm` (1 retry). Une écriture (rapport d'écoute,
    /// ajout à une playlist, création…) n'est renvoyée que si elle n'a pas pu partir (connexion impossible) : après un
    /// délai dépassé, Deezer a peut-être déjà fait le travail, la refaire compterait deux fois.
    pub async fn gw<T: DeserializeOwned>(&self, method: &str, body: &Value) -> Result<T> {
        let write = Self::is_write(method);
        let mut refreshed = false;
        // 3 essais, plus un après le renouvellement du jeton s'il arrive au dernier.
        for attempt in 0..4u64 {
            if attempt == 3 && !refreshed {
                break;
            }
            let token = self.token().await?;
            let sent = self
                .http()
                .post(GW_URL)
                .timeout(std::time::Duration::from_secs(20))
                .query(&[
                    ("method", method),
                    ("input", "3"),
                    ("api_version", "1.0"),
                    ("api_token", token.as_str()),
                ])
                .json(body)
                .send()
                .await
                .and_then(|r| r.error_for_status());
            let resp = match sent {
                Ok(r) => r,
                // Coupure passagère (Wi-Fi, sortie de veille) : on réessaie avec une courte attente.
                Err(e) if attempt < 2 && (e.is_connect() || (!write && (e.is_timeout() || e.is_request()))) => {
                    tokio::time::sleep(std::time::Duration::from_millis(500 * (attempt + 1))).await;
                    continue;
                }
                Err(e) => return Err(e.into()),
            };
            let env: Envelope = match resp.json().await {
                Ok(v) => v,
                Err(e) if attempt < 2 && !write && (e.is_timeout() || e.is_body()) => continue,
                Err(e) => return Err(e.into()),
            };

            match gw_error(&env.error) {
                None => {
                    let results = env.results.ok_or(DeezerError::EmptyResults)?;
                    return Ok(serde_json::from_value(results)?);
                }
                // Jeton CSRF périmé (typiquement après une longue veille) : on renouvelle la session une fois.
                Some(e) if !refreshed && is_token_error(&e) => {
                    refreshed = true;
                    self.refresh_if_stale(&token).await?;
                }
                Some(e) => return Err(DeezerError::Gateway(e)),
            }
        }
        Err(DeezerError::SessionExpired)
    }

    /// Méthode gw-light qui modifie quelque chose chez Deezer (à ne pas envoyer deux fois).
fn is_write(method: &str) -> bool {
    let verb = method.rsplit('.').next().unwrap_or(method).to_ascii_lowercase();
    method.starts_with("log.") || ["add", "create", "delete", "remove", "update", "set", "edit", "upload"].iter().any(|v| verb.starts_with(v))
}

/// Résout l'URL de flux d'un titre via `media.deezer.com/v1/get_url`.
    ///
    /// `track_token` provient d'une réponse gw-light (ex. `song.getListData`).
    /// Les formats sont essayés dans l'ordre ; `lossless` est ignoré si le compte n'y a pas droit.
    /// Adresse du flux d'un titre. Si Deezer refuse (licence périmée, jeton refusé), la session est renouvelée une fois puis on réessaie.
    pub async fn get_media_source(&self, track_token: &str, quality: Quality) -> Result<MediaSource> {
        match self.media_once(track_token, quality).await {
            Err(DeezerError::NoMediaSource | DeezerError::MediaRefused(_) | DeezerError::LicenseRejected) => {
                self.init_session().await?; // nouvelle licence de lecture
                self.media_once(track_token, quality).await
            }
            other => other,
        }
    }

    /// Flux d'un titre avec récupération rapide : si Deezer refuse le titre, les remèdes possibles sont lancés **en même temps**
    /// (licence renouvelée, jeton du titre redemandé, titre de remplacement) et le premier qui réussit gagne.
    /// Évite d'enchaîner les essais l'un après l'autre (plus d'une seconde d'attente pour les titres concernés).
    pub async fn media_with_recovery(&self, id: i64, cached: Option<TrackInfo>, quality: Quality) -> Result<ResolvedMedia> {
        use futures_util::future::BoxFuture;
        use futures_util::stream::{FuturesUnordered, StreamExt};
        use futures_util::FutureExt;

        let started = std::time::Instant::now();
        let from_cache = cached.is_some();
        let info = match cached {
            Some(i) => i,
            None => self.track_info(id).await?,
        };
        let token = info.track_token.clone().ok_or(DeezerError::NoMediaSource)?;
        // Édition sans droits de lecture et titre de remplacement connu : on lit directement le remplaçant (aucun essai refusé, aucune attente).
        // S'il échoue, il n'est pas retenté plus bas.
        let fallback_tried = info.restricted && info.fallback_id.is_some();
        if info.restricted {
            if let Some(fb) = info.fallback_id {
                if let Ok(fb_info) = self.track_info(fb).await {
                    if let Some(t) = fb_info.track_token {
                        if let Ok(media) = self.media_once(&t, quality).await {
                            return Ok(ResolvedMedia { media, stream_id: fb, info });
                        }
                    }
                }
            }
        }
        let first = match self.media_once(&token, quality).await {
            Ok(media) => return Ok(ResolvedMedia { media, stream_id: id, info }),
            Err(e @ (DeezerError::NoMediaSource | DeezerError::MediaRefused(_) | DeezerError::LicenseRejected)) => e,
            Err(e) => return Err(e), // réseau, etc. : pas de remède propre à ce titre
        };

        type Attempt<'a> = BoxFuture<'a, (&'static str, Result<ResolvedMedia>)>;
        let mut attempts: FuturesUnordered<Attempt<'_>> = FuturesUnordered::new();
        // A) licence de lecture renouvelée, même jeton
        {
            let (token, info) = (token.clone(), info.clone());
            attempts.push(
                async move {
                    let r = match self.init_session().await {
                        Ok(_) => self.media_once(&token, quality).await.map(|media| ResolvedMedia { media, stream_id: id, info }),
                        Err(e) => Err(e),
                    };
                    ("licence renouvelée", r)
                }
                .boxed(),
            );
        }
        // B) jeton du titre redemandé (celui gardé en mémoire a peut-être expiré)
        if from_cache {
            attempts.push(
                async move {
                    let r = match self.track_info(id).await {
                        Ok(fresh) => match fresh.track_token.clone() {
                            Some(t) => self.media_once(&t, quality).await.map(|media| ResolvedMedia { media, stream_id: id, info: fresh }),
                            None => Err(DeezerError::NoMediaSource),
                        },
                        Err(e) => Err(e),
                    };
                    ("jeton redemandé", r)
                }
                .boxed(),
            );
        }
        // C) titre de remplacement proposé par Deezer
        if let Some(fb) = info.fallback_id.filter(|_| !fallback_tried) {
            let info = info.clone();
            attempts.push(
                async move {
                    let r = match self.track_info(fb).await {
                        Ok(fb_info) => match fb_info.track_token {
                            Some(t) => self.media_once(&t, quality).await.map(|media| ResolvedMedia { media, stream_id: fb, info }),
                            None => Err(DeezerError::NoMediaSource),
                        },
                        Err(e) => Err(e),
                    };
                    ("titre de remplacement", r)
                }
                .boxed(),
            );
        }
        let mut last_err = first;
        while let Some((via, result)) = attempts.next().await {
            match result {
                Ok(found) => {
                    catalog::note(format!("titre {id} : refusé au premier essai ({last_err}), récupéré via « {via} » en {} ms", started.elapsed().as_millis()));
                    return Ok(found); // les essais restants sont abandonnés
                }
                Err(e) => last_err = e,
            }
        }
        catalog::note(format!("titre {id} : tous les essais de récupération ont échoué ({last_err}) après {} ms", started.elapsed().as_millis()));
        Err(last_err)
    }

    async fn media_once(&self, track_token: &str, quality: Quality) -> Result<MediaSource> {
        let session = self.ensure_session().await?;

        // Qualité choisie puis, en repli, les qualités inférieures auxquelles le compte a droit.
        let mut formats = Vec::new();
        if quality == Quality::Flac && session.lossless {
            formats.push(json!({ "cipher": "BF_CBC_STRIPE", "format": "FLAC" }));
        }
        if quality != Quality::Mp3128 && session.hq {
            formats.push(json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_320" }));
        }
        formats.push(json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_128" }));
        // MP3 importés par l'utilisateur : servis dans un format à part.
        formats.push(json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_MISC" }));

        let body = json!({
            "license_token": session.license_token,
            "media": [{ "type": "FULL", "formats": formats }],
            "track_tokens": [track_token],
        });

        let resp = self.http().post(MEDIA_URL).json(&body).send().await?;
        if matches!(resp.status().as_u16(), 401 | 403) {
            return Err(DeezerError::LicenseRejected);
        }
        let resp: MediaResponse = resp.error_for_status()?.json().await?;
        pick_media(resp)
    }

    /// Infos d'un titre (dont `track_token`, requis par `get_url`) via `song.getListData`.
    pub async fn track_info(&self, id: i64) -> Result<TrackInfo> {
        #[derive(Deserialize)]
        struct R {
            data: Vec<RawTrack>,
        }
        let r: R = self.gw("song.getListData", &json!({ "sng_ids": [id] })).await?;
        r.data.into_iter().next().map(Into::into).ok_or(DeezerError::EmptyResults)
    }

    /// Fiches de plusieurs titres en une requête (titres introuvables absents du résultat).
    pub async fn tracks_info(&self, ids: &[i64]) -> Result<Vec<TrackInfo>> {
        #[derive(Deserialize)]
        struct R {
            data: Vec<RawTrack>,
        }
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let r: R = self.gw("song.getListData", &json!({ "sng_ids": ids })).await?;
        Ok(r.data.into_iter().map(Into::into).collect())
    }

    /// URL de l'aperçu de 30 s (API publique, non chiffré, sans authentification).
    pub async fn preview_url(&self, id: i64) -> Result<String> {
        #[derive(Deserialize)]
        struct R {
            preview: Option<String>,
        }
        let r: R = self
            .http()
            .get(format!("https://api.deezer.com/track/{id}"))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        r.preview.filter(|u| !u.is_empty()).ok_or(DeezerError::NoMediaSource)
    }

    /// Recherche de titres (`deezer.pageSearch`).
    pub async fn search_tracks(&self, query: &str, limit: u32) -> Result<Vec<TrackInfo>> {
        #[derive(Deserialize)]
        struct R {
            #[serde(rename = "TRACK")]
            track: Tracks,
        }
        #[derive(Deserialize)]
        struct Tracks {
            #[serde(default)]
            data: Vec<RawTrack>,
        }
        let body = json!({
            "query": query, "start": 0, "nb": limit,
            "suggest": false, "artist_suggest": false, "top_tracks": false
        });
        let r: R = self.gw("deezer.pageSearch", &body).await?;
        Ok(r.track.data.into_iter().map(Into::into).collect())
    }
}

/// Titre tel qu'exposé à l'UI.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackInfo {
    pub id: i64,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_s: u64,
    pub cover_url: Option<String>,
    #[serde(skip)]
    pub track_token: Option<String>,
    /// Qualité réellement jouée ("FLAC", "MP3 320", "Aperçu 30 s"...), renseignée à la lecture.
    #[serde(default)]
    pub quality: Option<String>,
    /// Date d'ajout aux favoris (secondes Unix), renseignée pour les titres aimés.
    #[serde(default)]
    pub added_at: Option<u64>,
    /// Date de sortie « AAAA-MM-JJ » (album ou titre), quand Deezer la fournit.
    #[serde(default)]
    pub release_date: Option<String>,
    /// Titre de remplacement proposé par Deezer quand l'original n'est pas lisible (autre édition du même titre).
    #[serde(skip)]
    pub fallback_id: Option<i64>,
    /// Droits de lecture absents pour cette édition du titre (champ `RIGHTS` vide chez Deezer). Si un titre de remplacement existe,
    /// c'est lui qu'il faut lire, d'emblée : c'est ce que font les applications officielles.
    #[serde(skip)]
    pub restricted: bool,
    /// Identifiants pour « Aller à l'artiste / l'album » (0 = inconnu, par ex. MP3 importé).
    #[serde(default)]
    pub artist_id: u64,
    #[serde(default)]
    pub album_id: u64,
    /// Tous les artistes du titre (artiste principal + feats), dans l'ordre de Deezer.
    #[serde(default)]
    pub artists: Vec<ArtistRef>,
}

/// Un artiste crédité sur un titre.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtistRef {
    pub id: u64,
    pub name: String,
}

#[derive(Deserialize)]
pub(crate) struct RawTrack {
    #[serde(rename = "SNG_ID", deserialize_with = "flex_i64")]
    id: i64,
    #[serde(rename = "SNG_TITLE", default)]
    title: String,
    #[serde(rename = "VERSION", default)]
    version: String,
    #[serde(rename = "ART_NAME", default)]
    artist: String,
    #[serde(rename = "ALB_TITLE", default)]
    album: String,
    #[serde(rename = "DURATION", default, deserialize_with = "flex_u64")]
    duration: u64,
    #[serde(rename = "ALB_PICTURE", default)]
    picture: String,
    #[serde(rename = "TRACK_TOKEN", default)]
    token: Option<String>,
    #[serde(rename = "ART_ID", default, deserialize_with = "flex_u64")]
    artist_id: u64,
    #[serde(rename = "ALB_ID", default, deserialize_with = "flex_u64")]
    album_id: u64,
    #[serde(rename = "FALLBACK", default)]
    fallback: Option<Value>,
    #[serde(rename = "RIGHTS", default)]
    rights: Option<Value>,
    /// Date d'ajout à la playlist : nombre (secondes Unix), chaîne numérique ou « AAAA-MM-JJ hh:mm:ss » selon la méthode.
    #[serde(rename = "DATE_ADD", default)]
    date_add: Option<Value>,
    #[serde(rename = "ORIGINAL_RELEASE_DATE", default)]
    original_date: Option<String>,
    #[serde(rename = "DIGITAL_RELEASE_DATE", default)]
    digital_date: Option<String>,
    #[serde(rename = "PHYSICAL_RELEASE_DATE", default)]
    physical_date: Option<String>,
    /// Deezer ne met que le PREMIER artiste dans ART_NAME : les feats sont dans cette liste.
    #[serde(rename = "ARTISTS", default)]
    artists: Vec<Value>,
}

/// Artistes d'un titre, dans l'ordre de Deezer, sans doublon ni artiste « factice ».
fn credited_artists(r: &RawTrack) -> Vec<ArtistRef> {
    let num = |v: &Value, k: &str| -> u64 {
        match v.get(k) {
            Some(Value::Number(n)) => n.as_u64().unwrap_or(0),
            Some(Value::String(s)) => s.trim().parse().unwrap_or(0),
            _ => 0,
        }
    };
    let mut list: Vec<(u64, ArtistRef)> = r
        .artists
        .iter()
        .filter(|a| !a.get("ARTIST_IS_DUMMY").and_then(Value::as_bool).unwrap_or(false))
        .filter_map(|a| {
            let name = a.get("ART_NAME").and_then(Value::as_str)?.trim().to_owned();
            (!name.is_empty()).then(|| (num(a, "ARTISTS_SONGS_ORDER"), ArtistRef { id: num(a, "ART_ID"), name }))
        })
        .collect();
    list.sort_by_key(|(order, _)| *order);
    let mut out: Vec<ArtistRef> = Vec::new();
    for (_, a) in list {
        if !out.iter().any(|x| x.name.eq_ignore_ascii_case(&a.name)) {
            out.push(a);
        }
    }
    if out.is_empty() && !r.artist.is_empty() {
        out.push(ArtistRef { id: r.artist_id, name: r.artist.clone() });
    }
    out
}

impl From<RawTrack> for TrackInfo {
    fn from(r: RawTrack) -> Self {
        let artists = credited_artists(&r);
        let artist = if artists.is_empty() { r.artist.clone() } else { artists.iter().map(|a| a.name.as_str()).collect::<Vec<_>>().join(", ") };
        let artist_id = artists.first().map_or(r.artist_id, |a| if a.id != 0 { a.id } else { r.artist_id });
        let title = if r.version.is_empty() { r.title } else { format!("{} {}", r.title, r.version) };
        let cover_url = (!r.picture.is_empty())
            .then(|| format!("https://cdn-images.dzcdn.net/images/cover/{}/250x250-000000-80-0-0.jpg", r.picture));
        // `RIGHTS` présent mais sans aucun droit de lecture (ni avec pub, ni avec abonnement) : édition retirée du catalogue.
        // Champ absent (autres méthodes de l'API) : on ne sait pas, donc on n'en tire rien.
        let restricted = r.rights.as_ref().and_then(Value::as_object).is_some_and(|o| {
            let ok = |k: &str| o.get(k).and_then(Value::as_bool).unwrap_or(false);
            !ok("STREAM_SUB_AVAILABLE") && !ok("STREAM_ADS_AVAILABLE")
        });
        let added_at = r.date_add.as_ref().and_then(parse_added);
        let fallback_id = r
            .fallback
            .as_ref()
            .and_then(|f| f.get("SNG_ID"))
            .and_then(|v| v.as_i64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok())))
            .filter(|fid| *fid != r.id && *fid != 0);
        // Première date valide parmi celles que Deezer peut fournir (« 0000-00-00 » = inconnue).
        let release_date = [&r.original_date, &r.digital_date, &r.physical_date]
            .into_iter()
            .flatten()
            .map(|d| d.trim())
            .find(|d| d.len() >= 4 && !d.starts_with("0000"))
            .map(str::to_owned);
        TrackInfo {
            id: r.id, title, artist, album: r.album,
            duration_s: r.duration, cover_url, track_token: r.token, quality: None, added_at, release_date, fallback_id, restricted,
            artist_id, album_id: r.album_id, artists,
        }
    }
}

/// Date d'ajout en secondes Unix : accepte un nombre, une chaîne numérique ou « AAAA-MM-JJ hh:mm:ss » (heure prise comme UTC :
/// seul l'ordre entre titres compte pour le tri). `None` si absente (0) ou illisible.
pub(crate) fn parse_added(v: &Value) -> Option<u64> {
    let secs = match v {
        Value::Number(n) => n.as_u64()?,
        Value::String(s) => {
            let s = s.trim();
            if let Ok(n) = s.parse::<u64>() {
                n
            } else {
                // « 2021-03-04 12:30:00 » (ou avec un « T »)
                let (d, t) = s.split_once([' ', 'T'])?;
                let mut dp = d.split('-').map(|x| x.parse::<i64>().ok());
                let (y, m, day) = (dp.next()??, dp.next()??, dp.next()??);
                let mut tp = t.split(':').map(|x| x.get(..2.min(x.len())).and_then(|x| x.parse::<i64>().ok()));
                let (hh, mm, ss) = (tp.next()?.unwrap_or(0), tp.next()?.unwrap_or(0), tp.next().flatten().unwrap_or(0));
                if !(1..=12).contains(&m) || !(1..=31).contains(&day) {
                    return None;
                }
                // jours depuis 1970 (algorithme de Howard Hinnant)
                let y2 = if m <= 2 { y - 1 } else { y };
                let era = y2.div_euclid(400);
                let yoe = y2 - era * 400;
                let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day - 1;
                let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
                let days = era * 146_097 + doe - 719_468;
                u64::try_from(days * 86_400 + hh * 3_600 + mm * 60 + ss).ok()?
            }
        }
        _ => return None,
    };
    (secs != 0).then_some(secs)
}

/// Flux trouvé pour un titre : l'adresse, l'identifiant du flux réellement lu (différent de celui du titre si Deezer impose un titre
/// de remplacement : c'est lui qui sert à la clé de déchiffrement) et les infos du titre à garder.
#[derive(Debug)]
pub struct ResolvedMedia {
    pub media: MediaSource,
    pub stream_id: i64,
    pub info: TrackInfo,
}

/// Les MP3 importés par l'utilisateur ont des identifiants négatifs.
fn flex_i64<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<i64, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum N {
        I(i64),
        S(String),
    }
    match N::deserialize(d)? {
        N::I(n) => Ok(n),
        N::S(s) => Ok(s.trim().parse().unwrap_or(0)),
    }
}

/// gw-light renvoie souvent les nombres sous forme de chaînes.
fn flex_u64<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<u64, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum N {
        U(u64),
        S(String),
    }
    match N::deserialize(d)? {
        N::U(n) => Ok(n),
        N::S(s) => s.trim().parse().map_err(serde::de::Error::custom),
    }
}

#[derive(Deserialize)]
struct MediaResponse {
    #[serde(default)]
    data: Vec<MediaData>,
}
#[derive(Deserialize)]
struct MediaData {
    #[serde(default)]
    media: Vec<MediaEntry>,
    /// Raisons du refus (par ex. `{ "code": 2002, "message": "…" }`).
    #[serde(default)]
    errors: Vec<Value>,
}

/// Premier flux utilisable de la réponse ; sinon l'erreur la plus précise (code et message de Deezer si présents).
fn pick_media(resp: MediaResponse) -> Result<MediaSource> {
    let mut reasons: Vec<String> = Vec::new();
    for d in resp.data {
        for e in &d.errors {
            let code = e.get("code").map(|c| c.to_string().trim_matches('"').to_owned()).unwrap_or_default();
            let msg = e.get("message").and_then(Value::as_str).unwrap_or("").trim().to_owned();
            let line = match (code.is_empty(), msg.is_empty()) {
                (false, false) => format!("code {code} : {msg}"),
                (false, true) => format!("code {code}"),
                (true, false) => msg,
                (true, true) => continue,
            };
            if !reasons.contains(&line) {
                reasons.push(line);
            }
        }
        for m in d.media {
            let Some(src) = m.sources.into_iter().next() else { continue };
            let cipher = match m.cipher.map(|c| c.kind).as_deref() {
                Some("NONE") | None => Cipher::None,
                Some("BF_CBC_STRIPE") => Cipher::BlockStripe,
                Some(other) => Cipher::Other(other.to_owned()),
            };
            return Ok(MediaSource { url: src.url, format: m.format, cipher });
        }
    }
    if reasons.is_empty() {
        Err(DeezerError::NoMediaSource)
    } else {
        Err(DeezerError::MediaRefused(reasons.join(" ; ")))
    }
}
#[derive(Deserialize)]
struct MediaEntry {
    #[serde(default)]
    format: String,
    cipher: Option<CipherField>,
    #[serde(default)]
    sources: Vec<SourceEntry>,
}
#[derive(Deserialize)]
struct CipherField {
    #[serde(rename = "type")]
    kind: String,
}
#[derive(Deserialize)]
struct SourceEntry {
    url: String,
}

/// gw-light renvoie `error: []` quand tout va bien.
/// Photo de profil Deezer (empreinte de l'image -> adresse sur le CDN), `None` sans photo.
fn user_picture(md5: &str) -> Option<String> {
    let md5 = md5.trim();
    (!md5.is_empty()).then(|| format!("https://cdn-images.dzcdn.net/images/user/{md5}/250x250-000000-80-0-0.jpg"))
}

/// Profils de `deezer.getChildAccounts` (liste directe, ou sous `data`). Champs lus avec tolérance : Deezer renvoie
/// nombres et booléens tantôt en nombres, tantôt en texte. Seuls les profils que l'on peut ouvrir sont gardés.
fn parse_profiles(v: &Value) -> Vec<Profile> {
    let items = v.as_array().or_else(|| v.get("data").and_then(Value::as_array));
    let num = |x: Option<&Value>| x.and_then(|x| x.as_u64().or_else(|| x.as_str().and_then(|s| s.trim().parse().ok()))).unwrap_or(0);
    let flag = |x: Option<&Value>| match x {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_u64().unwrap_or(0) != 0,
        Some(Value::String(s)) => matches!(s.trim(), "1" | "true"),
        _ => false,
    };
    items
        .into_iter()
        .flatten()
        .filter_map(|p| {
            let id = num(p.get("USER_ID"));
            // Champ absent : le profil est proposé (s'il ne peut pas être ouvert, le changement le dira).
            let loggable = p.get("EXTRA_FAMILY").and_then(|e| e.get("IS_LOGGABLE_AS")).is_none_or(|x| flag(Some(x)));
            if id == 0 || !loggable {
                return None;
            }
            let parent = num(p.get("PARENT_USER_ID")).max(num(p.get("PARENT_ID")));
            let name = p.get("BLOG_NAME").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).unwrap_or("Profil");
            Some(Profile {
                id,
                name: name.to_owned(),
                picture_url: user_picture(p.get("USER_PICTURE").and_then(Value::as_str).unwrap_or("")),
                kid: flag(p.get("IS_KID")),
                main: parent == 0,
                current: false,
            })
        })
        .collect()
}

fn gw_error(v: &Value) -> Option<String> {
    match v {
        Value::Null => None,
        Value::Array(a) if a.is_empty() => None,
        Value::Object(o) if o.is_empty() => None,
        other => Some(other.to_string()),
    }
}

fn is_token_error(e: &str) -> bool {
    let e = e.to_ascii_uppercase();
    e.contains("VALID_TOKEN_REQUIRED") || e.contains("INVALID CSRF") || e.contains("INVALID TOKEN")
}

#[cfg(test)]
mod tests {
    #[test]
    fn writes_are_never_sent_twice_after_a_timeout() {
        for m in ["log.listen", "playlist.create", "playlist.addSongs", "playlist.deleteSongs", "favorite_song.add", "favorite_song.remove", "playlist.delete"] {
            assert!(DeezerClient::is_write(m), "{m}");
        }
        for m in ["song.getFavoriteIds", "deezer.pageProfile", "user.loginMulti", "deezer.getUserData", "song.getListData"] {
            assert!(!DeezerClient::is_write(m), "{m}");
        }
    }

    #[test]
    fn family_profiles_are_read_tolerantly() {
        let v = serde_json::json!({ "data": [
            { "USER_ID": "11", "BLOG_NAME": "Papa", "USER_PICTURE": "abc", "PARENT_USER_ID": "0", "EXTRA_FAMILY": { "IS_LOGGABLE_AS": true } },
            { "USER_ID": 12, "BLOG_NAME": " ", "IS_KID": "1", "PARENT_USER_ID": "11", "EXTRA_FAMILY": { "IS_LOGGABLE_AS": "1" } },
            { "USER_ID": "13", "BLOG_NAME": "Caché", "EXTRA_FAMILY": { "IS_LOGGABLE_AS": false } },
            { "USER_ID": "0", "BLOG_NAME": "Sans id" }
        ] });
        let p = super::parse_profiles(&v);
        assert_eq!(p.iter().map(|p| p.id).collect::<Vec<_>>(), vec![11, 12]);
        assert!(p[0].main && !p[0].kid && p[0].picture_url.as_deref().is_some_and(|u| u.contains("/user/abc/")));
        assert!(!p[1].main && p[1].kid && p[1].name == "Profil" && p[1].picture_url.is_none());
        assert!(super::parse_profiles(&serde_json::json!([])).is_empty());
    }

    use super::*;

    #[test]
    fn empty_error_is_ok() {
        assert!(gw_error(&json!([])).is_none());
        assert!(gw_error(&json!({})).is_none());
        assert!(gw_error(&Value::Null).is_none());
    }

    #[tokio::test]
    async fn clear_session_forgets_cookies_session_and_caches() {
        let c = DeezerClient::new().unwrap();
        c.set_arl("abcDEF123_-xyz").unwrap();
        c.jar.lock().unwrap().insert_raw(
            &reqwest_cookie_store::RawCookie::parse("sid=secret; Domain=.deezer.com; Path=/").unwrap(),
            &Url::parse("https://www.deezer.com").unwrap(),
        ).unwrap();
        assert_eq!(c.sid_cookie().as_deref(), Some("secret"));
        assert!(c.jar.lock().unwrap().get("deezer.com", "/", "arl").is_some());
        c.date_cache.lock().unwrap().insert(1, "2020-01-01".into());

        c.clear_session().await;

        assert!(c.jar.lock().unwrap().get("deezer.com", "/", "arl").is_none(), "l'arl doit avoir disparu");
        assert!(c.sid_cookie().is_none(), "le sid doit avoir disparu");
        assert!(c.session.read().await.is_none());
        assert!(c.date_cache.lock().unwrap().is_empty());
    }

    #[test]
    fn media_response_gives_source_or_precise_refusal() {
        use serde_json::json;
        let ok: MediaResponse = serde_json::from_value(json!({ "data": [{ "media": [{ "format": "MP3_128", "cipher": { "type": "BF_CBC_STRIPE" }, "sources": [{ "url": "https://cdn/x" }] }] }] })).unwrap();
        let m = pick_media(ok).unwrap();
        assert_eq!((m.url.as_str(), m.format.as_str()), ("https://cdn/x", "MP3_128"));
        // Refus avec raison : le code et le message de Deezer sont conservés.
        let refused: MediaResponse = serde_json::from_value(json!({ "data": [{ "errors": [{ "code": 2002, "message": "Track not available" }], "media": [] }] })).unwrap();
        match pick_media(refused) {
            Err(DeezerError::MediaRefused(d)) => assert!(d.contains("2002") && d.contains("Track not available"), "{d}"),
            other => panic!("attendu un refus détaillé, obtenu {other:?}"),
        }
        // Réponse vide sans raison : erreur générique.
        let empty: MediaResponse = serde_json::from_value(json!({ "data": [{ "media": [] }] })).unwrap();
        assert!(matches!(pick_media(empty), Err(DeezerError::NoMediaSource)));
        // Entrée sans source puis entrée valide : la valide est choisie.
        let mixed: MediaResponse = serde_json::from_value(json!({ "data": [{ "media": [{ "format": "FLAC", "sources": [] }, { "format": "MP3_320", "sources": [{ "url": "u" }] }] }] })).unwrap();
        assert_eq!(pick_media(mixed).unwrap().format, "MP3_320");
    }

    #[test]
    fn empty_rights_mark_the_edition_as_restricted() {
        use serde_json::json;
        // Cas réel : « Location » de Werenoi (édition retirée) : RIGHTS vide + titre de remplacement qui, lui, a ses droits.
        let raw: RawTrack = serde_json::from_value(json!({ "SNG_ID": "2660543392", "RIGHTS": {}, "FALLBACK": { "SNG_ID": "3023399621" } })).unwrap();
        let t = TrackInfo::from(raw);
        assert!(t.restricted);
        assert_eq!(t.fallback_id, Some(3_023_399_621));
        let ok: RawTrack = serde_json::from_value(json!({ "SNG_ID": "1", "RIGHTS": { "STREAM_SUB_AVAILABLE": true, "STREAM_ADS_AVAILABLE": true } })).unwrap();
        assert!(!TrackInfo::from(ok).restricted);
        let sub_only: RawTrack = serde_json::from_value(json!({ "SNG_ID": "1", "RIGHTS": { "STREAM_SUB_AVAILABLE": true } })).unwrap();
        assert!(!TrackInfo::from(sub_only).restricted);
        // Champ absent : inconnu, donc jamais « restreint ».
        let none: RawTrack = serde_json::from_value(json!({ "SNG_ID": "1" })).unwrap();
        assert!(!TrackInfo::from(none).restricted);
    }

    #[test]
    fn fallback_track_id_is_read_when_different() {
        use serde_json::json;
        let raw: RawTrack = serde_json::from_value(json!({ "SNG_ID": "10", "FALLBACK": { "SNG_ID": "20" } })).unwrap();
        assert_eq!(TrackInfo::from(raw).fallback_id, Some(20));
        let same: RawTrack = serde_json::from_value(json!({ "SNG_ID": "10", "FALLBACK": { "SNG_ID": "10" } })).unwrap();
        assert_eq!(TrackInfo::from(same).fallback_id, None);
        let none: RawTrack = serde_json::from_value(json!({ "SNG_ID": "10" })).unwrap();
        assert_eq!(TrackInfo::from(none).fallback_id, None);
    }

    #[test]
    fn parses_playlist_added_dates() {
        use serde_json::json;
        assert_eq!(parse_added(&json!(1634567890)), Some(1_634_567_890));
        assert_eq!(parse_added(&json!("1634567890")), Some(1_634_567_890));
        assert_eq!(parse_added(&json!("2021-10-18 14:38:10")), Some(1_634_567_890));
        assert_eq!(parse_added(&json!("1970-01-02 00:00:00")), Some(86_400));
        assert_eq!(parse_added(&json!(0)), None);
        assert_eq!(parse_added(&json!("0")), None);
        assert_eq!(parse_added(&json!("n'importe quoi")), None);
        assert_eq!(parse_added(&json!(null)), None);
        // L'ordre entre deux ajouts est respecté.
        assert!(parse_added(&json!("2022-01-01 00:00:00")) > parse_added(&json!("2021-12-31 23:59:59")));
    }

    #[test]
    fn token_error_detected() {
        let e = gw_error(&json!({"VALID_TOKEN_REQUIRED": "Invalid CSRF token"})).unwrap();
        assert!(is_token_error(&e));
    }

    #[test]
    fn parses_string_numbers() {
        let raw: RawTrack = serde_json::from_value(json!({
            "SNG_ID": "3135556", "SNG_TITLE": "Harder", "ART_NAME": "Daft Punk",
            "DURATION": "224", "ALB_PICTURE": "abc"
        })).unwrap();
        let t: TrackInfo = raw.into();
        assert_eq!((t.id, t.duration_s), (3135556, 224));
        let up: RawTrack = serde_json::from_value(json!({ "SNG_ID": "-3173759643", "DURATION": "10" })).unwrap();
        assert_eq!(up.id, -3173759643);
        assert!(t.cover_url.unwrap().contains("/abc/"));
    }

    #[test]
    fn release_date_takes_first_valid_value() {
        let raw: RawTrack = serde_json::from_value(json!({
            "SNG_ID": "1", "ORIGINAL_RELEASE_DATE": "0000-00-00", "DIGITAL_RELEASE_DATE": "2025-05-16", "PHYSICAL_RELEASE_DATE": "2025-06-01"
        })).unwrap();
        assert_eq!(TrackInfo::from(raw).release_date.as_deref(), Some("2025-05-16"));
        let none: RawTrack = serde_json::from_value(json!({ "SNG_ID": "2" })).unwrap();
        assert_eq!(TrackInfo::from(none).release_date, None);
    }

    #[test]
    fn feat_artists_are_all_listed_in_order() {
        let raw: RawTrack = serde_json::from_value(json!({
            "SNG_ID": "1", "SNG_TITLE": "Cinéma", "ART_NAME": "No Limit", "ART_ID": "10",
            "ARTISTS": [
                { "ART_ID": "12", "ART_NAME": "Timar", "ARTISTS_SONGS_ORDER": "3", "ARTIST_IS_DUMMY": false },
                { "ART_ID": "10", "ART_NAME": "No Limit", "ARTISTS_SONGS_ORDER": "1", "ARTIST_IS_DUMMY": false },
                { "ART_ID": "11", "ART_NAME": "Leto", "ARTISTS_SONGS_ORDER": "2", "ARTIST_IS_DUMMY": false },
                { "ART_ID": "11", "ART_NAME": "leto", "ARTISTS_SONGS_ORDER": "9", "ARTIST_IS_DUMMY": false },
                { "ART_ID": "0", "ART_NAME": "Fantôme", "ARTISTS_SONGS_ORDER": "4", "ARTIST_IS_DUMMY": true }
            ]
        })).unwrap();
        let t: TrackInfo = raw.into();
        assert_eq!(t.artist, "No Limit, Leto, Timar");
        assert_eq!(t.artists.len(), 3);
        assert_eq!(t.artist_id, 10);
    }

    #[test]
    fn single_artist_falls_back_to_art_name() {
        let raw: RawTrack = serde_json::from_value(json!({ "SNG_ID": "2", "ART_NAME": "Lucci", "ART_ID": "5" })).unwrap();
        let t: TrackInfo = raw.into();
        assert_eq!((t.artist.as_str(), t.artists.len(), t.artist_id), ("Lucci", 1, 5));
    }

    #[test]
    fn rejects_bad_arl() {
        let c = DeezerClient::new().unwrap();
        assert!(matches!(c.set_arl("a; b"), Err(DeezerError::InvalidArl)));
    }
}
