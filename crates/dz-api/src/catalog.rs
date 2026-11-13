//! Catalogue : bibliothèque de l'utilisateur, playlists, albums, artistes, Flow, favoris.
//!
//! Parsing volontairement tolérant (`serde_json::Value`) : les noms de champs viennent de
//! l'API web non documentée de Deezer et n'ont pas pu être vérifiés ici contre le service réel.

use futures_util::future::BoxFuture;
use futures_util::FutureExt;
use serde::Serialize;
use serde_json::{json, Value};

use crate::{DeezerClient, DeezerError, RawTrack, Result, TrackInfo};

/// Une ligne de paroles ; `ms` est l'instant d'affichage (0 si non synchronisée).
#[derive(Debug, Clone, Serialize)]
pub struct LyricLine {
    pub ms: u64,
    pub text: String,
}

/// Paroles d'un titre sur le service récent de Deezer : lignes synchronisées, sinon le texte seul.
const PIPE_LYRICS: &str = "query TrackLyrics($trackId: String!) { track(trackId: $trackId) { id lyrics { id text copyright synchronizedLines { line milliseconds } } } }";

/// Réponse du service récent : `None` s'il n'a pas de paroles pour ce titre.
fn lyrics_from_pipe(data: &Value) -> Option<Lyrics> {
    let l = data.pointer("/track/lyrics").filter(|v| !v.is_null())?;
    let copyright = vs(l, "copyright");
    let synced: Vec<LyricLine> = l
        .get("synchronizedLines")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter(|x| x.get("milliseconds").is_some_and(|m| !m.is_null())).map(|x| LyricLine { ms: vn(x, "milliseconds"), text: vs(x, "line") }).collect())
        .unwrap_or_default();
    if synced.iter().any(|x| !x.text.trim().is_empty()) {
        return Some(Lyrics { synced: true, lines: synced, copyright, source: "deezer" });
    }
    let text = vs(l, "text");
    if text.trim().is_empty() {
        return None;
    }
    let lines = text.lines().map(|t| LyricLine { ms: 0, text: t.to_owned() }).collect();
    Some(Lyrics { synced: false, lines, copyright, source: "deezer" })
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct Lyrics {
    /// Vrai si les lignes portent un horodatage exploitable.
    pub synced: bool,
    pub lines: Vec<LyricLine>,
    pub copyright: String,
    /// Provenance : "deezer" ou "youtube" (paroles de secours, YouTube Music).
    pub source: &'static str,
}

#[derive(Debug, Clone, Serialize)]
pub struct Card {
    /// "playlist" | "album" | "artist"
    pub kind: &'static str,
    pub id: u64,
    pub title: String,
    pub subtitle: String,
    pub cover_url: Option<String>,
    /// Playlist créée par l'utilisateur lui-même (donc supprimable).
    pub owned: bool,
    /// Date de sortie (AAAA-MM-JJ), pour les sorties d'un artiste.
    pub date: String,
    /// "album" | "single" | "compilation" | "" (discographie d'un artiste).
    pub group: &'static str,
    /// Identifiant texte pour les éléments qui n'ont pas d'identifiant numérique (mixes : « new-releases », genres : « channels/french-rap »).
    pub key: String,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct SearchResults {
    pub tracks: Vec<TrackInfo>,
    pub albums: Vec<Card>,
    pub artists: Vec<Card>,
    pub playlists: Vec<Card>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Collection {
    pub kind: String,
    pub id: u64,
    /// Playlist créée par l'utilisateur lui-même : on peut en retirer des titres.
    pub owned: bool,
    pub title: String,
    pub subtitle: String,
    pub cover_url: Option<String>,
    pub tracks: Vec<TrackInfo>,
    /// Discographie de l'artiste, de la plus récente à la plus ancienne (vide pour les autres types).
    pub albums: Vec<Card>,
    /// Albums d'autres artistes où il est en featuring (« Apparaît dans »), du plus récent au plus ancien.
    pub appears_on: Vec<Card>,
    /// Dernière sortie mise en avant (page artiste).
    pub latest: Option<Card>,
    /// Artistes similaires (page artiste).
    pub related: Vec<Card>,
}

/// 1234567 -> « 1 234 567 » (espace insécable fine).
fn group_digits(n: u64) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i) % 3 == 0 {
            out.push('\u{202f}');
        }
        out.push(c);
    }
    out
}

/// Une section de la page d'accueil (ou d'une page de genre) de Deezer.
#[derive(Debug, Clone, Serialize)]
pub struct Section {
    /// Catégorie stable (« recent », « mixes », « curated »…) : c'est elle que l'utilisateur active, masque ou réordonne,
    /// car les titres et identifiants de section changent à chaque chargement.
    pub kind: &'static str,
    pub title: String,
    pub items: Vec<Card>,
}

/// Page d'un genre ou d'une catégorie : titre + sections.
#[derive(Debug, Clone, Serialize)]
pub struct PageView {
    pub title: String,
    pub sections: Vec<Section>,
}

/// Catégorie d'une section d'après son identifiant technique (module_type + content_source).
fn section_kind(tech: &str) -> &'static str {
    let field = |name: &str| tech.split(',').find_map(|p| p.strip_prefix(name)).unwrap_or("");
    let (module, source) = (field("module_type="), field("content_source="));
    match (source, module) {
        ("recently-played", _) => "recent",
        ("user-favorites", _) => "followed",
        ("user-suggested", _) => "playlists-for-you",
        ("unmissables-new-releases", _) => "new-releases",
        ("hundred-percent", _) => "on-repeat",
        ("similar-from-user-top", _) => "similar-artists",
        ("recommendation", "smarttracklist") => "mixes",
        ("recommendation", "channel") => "genres",
        ("recommendation", "flow") => "flow",
        (_, "track") => "track-mixes",
        (_, "podcast") => "podcasts",
        _ => "curated",
    }
}

/// Convertit un élément de page Deezer en carte ; `None` pour les types non gérés (podcasts, Flow à thème…).
fn page_item_card(item: &Value, uid: u64) -> Option<Card> {
    let data = item.get("data").unwrap_or(&Value::Null);
    match vs(item, "type").as_str() {
        "album" => album_cards(std::slice::from_ref(data)).pop(),
        "artist" => artist_cards(std::slice::from_ref(data)).pop(),
        "playlist" => playlist_cards(std::slice::from_ref(data), uid).pop(),
        "smarttracklist" => {
            let key = vs(item, "id");
            if key.is_empty() {
                return None;
            }
            let cover = item.get("cover").unwrap_or(&Value::Null);
            // md5 complet : « a-a-b-c » est une mosaïque que le serveur d'images compose (le premier seul n'est que son fond uni).
            let md5 = vs(cover, "md5");
            let kind = match vs(cover, "type").as_str() { "" => "cover".to_owned(), k => k.to_owned() };
            Some(Card {
                kind: "mix",
                id: 0,
                title: vs(item, "title"),
                subtitle: Some(vs(item, "subtitle")).filter(|s| !s.is_empty()).unwrap_or_else(|| vs(item, "caption")),
                cover_url: image(&kind, &md5, 500),
                owned: false,
                date: String::new(),
                group: "",
                key,
            })
        }
        // « Mixes inspirés par » : un titre, dont l'appui lance le mix (voir `track_mix`).
        "track" => {
            let id = vs(item, "id").parse().ok().filter(|&n: &u64| n > 0)?;
            Some(Card {
                kind: "trackmix",
                id,
                title: vs(item, "title"),
                subtitle: vs(item, "subtitle"),
                cover_url: image("cover", &vs(data, "ALB_PICTURE"), 500),
                owned: false,
                date: String::new(),
                group: "",
                key: String::new(),
            })
        }
        "channel" => {
            let target = vs(item, "target");
            let path = target.trim_start_matches('/').to_owned();
            if path.is_empty() {
                return None;
            }
            let linked = item.get("image_linked_item").unwrap_or(&Value::Null);
            Some(Card {
                kind: "channel",
                id: 0,
                title: vs(item, "title"),
                subtitle: "Genre".into(),
                cover_url: image(&vs(linked, "type"), &vs(linked, "md5"), 500),
                owned: false,
                date: String::new(),
                group: "",
                key: path,
            })
        }
        _ => None,
    }
}

fn parse_sections(v: &Value, uid: u64) -> Vec<Section> {
    v.get("sections")
        .and_then(Value::as_array)
        .map(|secs| {
            secs.iter()
                .filter_map(|s| {
                    let items: Vec<Card> = s
                        .get("items")
                        .and_then(Value::as_array)
                        .map(|a| a.iter().filter_map(|i| page_item_card(i, uid)).collect())
                        .unwrap_or_default();
                    // Sections sans élément gérable (podcasts, Flow à thème…) : ignorées.
                    if items.is_empty() {
                        return None;
                    }
                    let kind = section_kind(&vs(s, "section_id"));
                    Some(Section { kind, title: vs(s, "title"), items })
                })
                .collect()
        })
        .unwrap_or_default()
}

fn vs(v: &Value, k: &str) -> String {
    match v.get(k) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

fn vi(v: &Value, k: &str) -> i64 {
    vs(v, k).parse().unwrap_or(0)
}

fn vn(v: &Value, k: &str) -> u64 {
    vs(v, k).parse().unwrap_or(0)
}

fn image(kind: &str, md5: &str, size: u32) -> Option<String> {
    (!md5.is_empty())
        .then(|| format!("https://cdn-images.dzcdn.net/images/{kind}/{md5}/{size}x{size}-000000-80-0-0.jpg"))
}

fn data<'a>(v: &'a Value, key: &str) -> &'a [Value] {
    v.get(key)
        .and_then(|x| x.get("data"))
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

/// Remarques de chargement (par ex. « playlist de 2 480 titres : seulement 2 000 reçus ») : l'application les ajoute à son journal de diagnostic.
static NOTES: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

pub(crate) fn note(msg: String) {
    if let Ok(mut n) = NOTES.lock() {
        if n.len() < 20 {
            n.push(msg);
        }
    }
}

/// Récupère (et vide) les remarques de chargement.
pub fn drain_notes() -> Vec<String> {
    NOTES.lock().map(|mut n| std::mem::take(&mut *n)).unwrap_or_default()
}

/// Complète `songs` page après page : `fetch(début)` renvoie la page suivante (`None` = indisponible).
/// Total connu : on va jusqu'à lui. Total inconnu (0) : on continue tant qu'une page n'est pas vide. `max` borne le tout.
async fn collect_pages<'a, F>(songs: &mut Vec<Value>, total: usize, max: usize, mut fetch: F)
where
    F: FnMut(usize) -> BoxFuture<'a, Option<Vec<Value>>>,
{
    let mut last = songs.len();
    while last > 0 && songs.len() < max && (total == 0 || songs.len() < total) {
        let Some(more) = fetch(songs.len()).await else { break }; // la suite est indisponible : on garde ce qui est déjà là
        last = more.len();
        songs.extend(more);
    }
}

/// Lignes d'une réponse paginée : `{ "data": [...] }` ou directement un tableau.
fn rows(v: &Value) -> Vec<Value> {
    v.get("data").and_then(Value::as_array).or_else(|| v.as_array()).cloned().unwrap_or_default()
}

fn tracks(items: &[Value]) -> Vec<TrackInfo> {
    items
        .iter()
        .filter_map(|x| serde_json::from_value::<RawTrack>(x.clone()).ok())
        .map(Into::into)
        .collect()
}

fn playlist_cards(items: &[Value], uid: u64) -> Vec<Card> {
    items
        .iter()
        .map(|p| {
            let kind = match vs(p, "PICTURE_TYPE").as_str() {
                "" => "playlist".to_owned(),
                k => k.to_owned(),
            };
            Card {
                kind: "playlist",
                id: vn(p, "PLAYLIST_ID"),
                title: vs(p, "TITLE"),
                subtitle: match vn(p, "NB_SONG") {
                    0 => "Playlist".into(),
                    n => format!("{n} titres"),
                },
                cover_url: image(&kind, &vs(p, "PLAYLIST_PICTURE"), 500),
                owned: uid != 0 && vn(p, "PARENT_USER_ID") == uid,
                date: String::new(),
                group: "",
                key: String::new(),
            }
        })
        .filter(|c| c.id != 0)
        .collect()
}

fn album_cards(items: &[Value]) -> Vec<Card> {
    items
        .iter()
        .map(|a| Card {
            kind: "album",
            id: vn(a, "ALB_ID"),
            title: vs(a, "ALB_TITLE"),
            subtitle: vs(a, "ART_NAME"),
            cover_url: image("cover", &vs(a, "ALB_PICTURE"), 500),
            owned: false,
            date: String::new(),
            group: "",
            key: String::new(),
        })
        .filter(|c| c.id != 0)
        .collect()
}

/// Place d'une sortie dans la discographie d'un artiste.
#[derive(PartialEq)]
enum ReleaseRole {
    /// Son album (seul ou en duo).
    Own,
    /// Album d'un autre artiste où il est en featuring : « Apparaît dans ».
    Featured,
    /// Compilation d'autres artistes, sortie non officielle… : pas affichée.
    Other,
}

/// `ROLE_ID` de `album.getDiscography` : 0 = artiste principal, 5 = featuring. Absent (repli sur les albums de la page
/// artiste) : sa sortie.
fn release_role(a: &Value, artist: u64) -> ReleaseRole {
    let compilation = vs(a, "TYPE") == "2" || a.pointer("/SUBTYPES/isCompilation").and_then(Value::as_bool).unwrap_or(false);
    let official = match a.get("ARTISTS_ALBUMS_IS_OFFICIAL") {
        Some(Value::Bool(b)) => *b,
        Some(v) => !matches!(v.as_str(), Some("0") | Some("false")) && v.as_u64() != Some(0),
        None => true,
    };
    let main = vn(a, "ART_ID");
    match vs(a, "ROLE_ID").as_str() {
        _ if main == artist => ReleaseRole::Own,
        "" | "0" if official && !compilation => ReleaseRole::Own,
        "5" if !compilation => ReleaseRole::Featured,
        _ => ReleaseRole::Other,
    }
}

/// Sortie d'un artiste : sous-titre « Album · 2025 », groupe et date pour le tri et le classement.
fn release_card(a: &Value) -> Option<Card> {
    let id = vn(a, "ALB_ID");
    if id == 0 {
        return None;
    }
    let date = crate::pick_release_date([Some(&vs(a, "ORIGINAL_RELEASE_DATE")), Some(&vs(a, "DIGITAL_RELEASE_DATE")), None]).unwrap_or_default();
    let compilation = a.pointer("/SUBTYPES/isCompilation").and_then(Value::as_bool).unwrap_or(false);
    let (group, label) = match vs(a, "TYPE").as_str() {
        _ if compilation => ("compilation", "Compilation"),
        "2" => ("compilation", "Compilation"),
        "0" => ("single", "Single"),
        "3" => ("single", "EP"),
        _ => ("album", "Album"),
    };
    let year = date.get(..4).unwrap_or("");
    Some(Card {
        kind: "album",
        id,
        title: vs(a, "ALB_TITLE"),
        subtitle: if year.is_empty() { label.to_owned() } else { format!("{label} · {year}") },
        cover_url: image("cover", &vs(a, "ALB_PICTURE"), 500),
        owned: false,
        date,
        group,
        key: String::new(),
    })
}

fn artist_cards(items: &[Value]) -> Vec<Card> {
    items
        .iter()
        .map(|a| Card {
            kind: "artist",
            id: vn(a, "ART_ID"),
            title: vs(a, "ART_NAME"),
            subtitle: "Artiste".into(),
            cover_url: image("artist", &vs(a, "ART_PICTURE"), 500),
            owned: false,
            date: String::new(),
            group: "",
            key: String::new(),
        })
        .filter(|c| c.id != 0)
        .collect()
}

/// Artistes d'une recherche : le plus suivi d'abord (un homonyme peu connu ne passe plus devant l'artiste cherché),
/// avec le nombre de fans en sous-titre (« 9 028 132 fans »).
fn search_artists(items: &[Value]) -> Vec<Card> {
    let mut found: Vec<(u64, Card)> = items
        .iter()
        .filter_map(|a| {
            let mut card = artist_cards(std::slice::from_ref(a)).pop()?;
            let fans = vn(a, "NB_FAN");
            if fans > 0 {
                card.subtitle = format!("{} fans", group_digits(fans));
            }
            Some((fans, card))
        })
        .collect();
    // Tri stable : à nombre de fans égal, l'ordre de Deezer est gardé.
    found.sort_by(|a, b| b.0.cmp(&a.0));
    found.into_iter().map(|(_, c)| c).collect()
}

impl DeezerClient {
    async fn user_id(&self) -> Result<u64> {
        // Session déjà ouverte, ou ouverte une seule fois même si plusieurs chargements la demandent en même temps.
        Ok(self.ensure_session().await?.user_id)
    }

    pub async fn search_all(&self, query: &str) -> Result<SearchResults> {
        let body = json!({
            "query": query, "start": 0, "nb": 24,
            "suggest": false, "artist_suggest": false, "top_tracks": false
        });
        let r: Value = self.gw("deezer.pageSearch", &body).await?;
        let uid = self.user_id().await.unwrap_or(0);
        Ok(SearchResults {
            tracks: tracks(data(&r, "TRACK")),
            albums: album_cards(data(&r, "ALBUM")),
            artists: search_artists(data(&r, "ARTIST")),
            playlists: playlist_cards(data(&r, "PLAYLIST"), uid),
        })
    }

    async fn profile_tab(&self, tab: &str) -> Result<Value> {
        let uid = self.user_id().await?;
        let r: Value = self
            .gw("deezer.pageProfile", &json!({ "user_id": uid.to_string(), "tab": tab, "nb": 500 }))
            .await?;
        Ok(r.get("TAB").and_then(|t| t.get(tab)).cloned().unwrap_or(Value::Null))
    }

    pub async fn user_playlists(&self) -> Result<Vec<Card>> {
        let t = self.profile_tab("playlists").await?;
        let uid = self.user_id().await?;
        Ok(playlist_cards(t.get("data").and_then(Value::as_array).map_or(&[][..], Vec::as_slice), uid))
    }

    pub async fn user_albums(&self) -> Result<Vec<Card>> {
        let t = self.profile_tab("albums").await?;
        Ok(album_cards(t.get("data").and_then(Value::as_array).map_or(&[][..], Vec::as_slice)))
    }

    pub async fn user_artists(&self) -> Result<Vec<Card>> {
        let t = self.profile_tab("artists").await?;
        Ok(artist_cards(t.get("data").and_then(Value::as_array).map_or(&[][..], Vec::as_slice)))
    }

    /// Appel générique `page.get` (pages « home », genres…).
    async fn page(&self, name: &str) -> Result<Value> {
        let uid = self.user_id().await?;
        let support = json!({
            "grid": ["channel", "album"],
            "horizontal-grid": ["album", "artist", "channel", "playlist", "smarttracklist"],
            "slideshow": ["album", "artist", "channel", "playlist", "smarttracklist"],
            "large-card": ["album", "playlist"],
            "horizontal-list": ["track", "song"],
            "item-highlight": [], "ads": [], "message": [], "list": []
        });
        let body = json!({ "PAGE": name, "VERSION": "2.5", "SUPPORT": support, "LANG": "fr", "OPTIONS": { "USER_ID": uid.to_string() } });
        self.gw("page.get", &body).await
    }

    /// Recommandations de la page d'accueil de Deezer, regroupées en sections catégorisées.
    pub async fn home_sections(&self) -> Result<Vec<Section>> {
        const TTL: std::time::Duration = std::time::Duration::from_secs(300);
        let uid = self.user_id().await?;
        if let Ok(g) = self.home_cache.lock() {
            if let Some((u, at, v)) = g.as_ref() {
                if *u == uid && at.elapsed() < TTL {
                    return Ok(v.clone());
                }
            }
        }
        let v = self.page("home").await?;
        let sections = parse_sections(&v, uid);
        if let Ok(mut g) = self.home_cache.lock() {
            *g = Some((uid, std::time::Instant::now(), sections.clone()));
        }
        Ok(sections)
    }

    /// Page d'un genre (« channels/french-rap »).
    pub async fn page_view(&self, path: &str) -> Result<PageView> {
        // Garde-fou : uniquement des chemins du type « channels/xxx ».
        let ok = !path.is_empty() && path.len() < 120 && path.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '-' | '_'));
        if !ok {
            return Err(DeezerError::Gateway(format!("page inconnue: {path}")));
        }
        let uid = self.user_id().await?;
        let v = self.page(path).await?;
        // Les mixes de titres ne sont affichés que sur l'accueil.
        let sections = parse_sections(&v, uid).into_iter().filter(|s| s.kind != "track-mixes").collect();
        Ok(PageView { title: vs(&v, "title"), sections })
    }

    /// Mix inspiré d'un titre (« Mixes inspirés par » de l'accueil) : ce titre, puis des titres proches choisis par Deezer.
    pub async fn track_mix(&self, id: i64) -> Result<Vec<TrackInfo>> {
        let v: Value = self.gw("song.getSearchTrackMix", &json!({ "sng_id": id.to_string(), "start_with_input_track": "true" })).await?;
        let mut list = tracks(&rows(&v));
        self.apply_cover_fixes(&mut list);
        Ok(list)
    }

    /// Un mix (« Nouveautés du vendredi », « Découverte »…) : ses titres.
    pub async fn mix(&self, key: &str) -> Result<Collection> {
        let mut c = self.mix_raw(key).await?;
        self.apply_cover_fixes(&mut c.tracks);
        Ok(c)
    }

    async fn mix_raw(&self, key: &str) -> Result<Collection> {
        let ok = !key.is_empty() && key.len() < 80 && key.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'));
        if !ok {
            return Err(DeezerError::Gateway(format!("mix inconnu: {key}")));
        }
        let r: Value = self.gw("deezer.pageSmartTracklist", &json!({ "smarttracklist_id": key })).await?;
        let d = r.get("DATA").cloned().unwrap_or(Value::Null);
        let md5 = vs(d.get("COVER").unwrap_or(&Value::Null), "MD5");
        let cover_type = vs(d.get("COVER").unwrap_or(&Value::Null), "TYPE");
        Ok(Collection {
            owned: false,
            kind: "mix".into(),
            id: 0,
            title: vs(&d, "TITLE"),
            subtitle: format!("Mix · {}", vs(&d, "DESCRIPTION")).trim_end_matches(" · ").to_owned(),
            cover_url: image(if cover_type.is_empty() { "cover" } else { &cover_type }, &md5, 1000),
            tracks: tracks(data(&r, "SONGS")),
            albums: Vec::new(),
            latest: None,
            related: Vec::new(),
            appears_on: Vec::new(),
        })
    }

    /// Titres aimés avec leur date d'ajout : `(id, date_add)`, du plus récent au plus ancien (Deezer les renvoie du plus ancien au plus récent).
    ///
    /// Deezer renvoie les favoris par pages (2 000 au plus par demande) : on enchaîne les pages, sans plafond.
    async fn favorite_ids(&self) -> Result<Vec<(i64, u64)>> {
        const PAGE: usize = 2000;
        let first: Value = self.gw("song.getFavoriteIds", &json!({ "nb": PAGE, "start": 0 })).await?;
        let mut items = rows(&first);
        let num = |k: &str| first.get(k).and_then(|x| x.as_u64().or_else(|| x.as_str().and_then(|s| s.trim().parse().ok()))).unwrap_or(0) as usize;
        let total = num("total").max(num("count"));
        // Total connu : on va jusqu'à lui. Page pleine sans total fiable : on essaie la suite (une page vide arrête tout).
        let want = if total > items.len() { total } else if items.len() >= PAGE { usize::MAX } else { items.len() };
        let first_id = items.first().map(|x| vi(x, "SNG_ID"));
        // Page suivante en échec (réseau) : erreur plutôt qu'une liste coupée, qui serait gardée 5 min pour complète.
        let failed = std::sync::atomic::AtomicBool::new(false);
        let failed_ref = &failed;
        collect_pages(&mut items, want, 100_000, |start| {
            let body = json!({ "nb": PAGE, "start": start });
            async move {
                let page = match self.gw::<Value>("song.getFavoriteIds", &body).await {
                    Ok(v) => rows(&v),
                    Err(_) => {
                        failed_ref.store(true, std::sync::atomic::Ordering::Relaxed);
                        return None;
                    }
                };
                // Un serveur qui ignorerait « start » renverrait encore la première page : on s'arrête plutôt que de dupliquer.
                if first_id.is_some() && page.first().map(|x| vi(x, "SNG_ID")) == first_id {
                    return Some(Vec::new());
                }
                Some(page)
            }
            .boxed()
        })
        .await;
        if failed.load(std::sync::atomic::Ordering::Relaxed) {
            return Err(DeezerError::Gateway("titres aimés incomplets (réseau), réessaie".into()));
        }
        let mut seen = std::collections::HashSet::new();
        let mut v: Vec<(i64, u64)> = items
            .iter()
            .map(|x| (vi(x, "SNG_ID"), vn(x, "DATE_FAVORITE").max(vn(x, "DATE_ADD"))))
            .filter(|p| p.0 != 0 && seen.insert(p.0))
            .collect();
        v.sort_by(|a, b| b.1.cmp(&a.1));
        Ok(v)
    }

    /// Titres aimés (= la playlist « Titres aimés »), du plus récemment ajouté au plus ancien.
    ///
    /// Les détails sont demandés par lots de 100, **en parallèle** (785 titres : ~1,3 s en série,
    /// ~0,3 s en parallèle). Le résultat est gardé 5 minutes ; liker/déliker l'invalide.
    pub async fn loved_tracks(&self) -> Result<Vec<TrackInfo>> {
        const TTL: std::time::Duration = std::time::Duration::from_secs(300);
        let uid = self.user_id().await?;
        if let Ok(g) = self.loved_cache.lock() {
            if let Some((u, at, v)) = g.as_ref() {
                if *u == uid && at.elapsed() < TTL {
                    let mut v = v.clone();
                    self.apply_cover_fixes(&mut v);
                    return Ok(v);
                }
            }
        }
        let mut fresh = self.fetch_loved().await?;
        self.apply_cover_fixes(&mut fresh);
        if let Ok(mut g) = self.loved_cache.lock() {
            *g = Some((uid, std::time::Instant::now(), fresh.clone()));
        }
        Ok(fresh)
    }

    /// Dates de sortie de titres dont la page (playlist, artiste, album…) ne les fournit pas : `song.getListData` par lots
    /// de 100, en parallèle, avec cache mémoire. Les titres sans date connue sont simplement absents du résultat.
    pub async fn track_dates(&self, ids: &[i64]) -> Result<std::collections::HashMap<i64, String>> {
        let mut out = std::collections::HashMap::new();
        let mut missing: Vec<i64> = Vec::new();
        if let Ok(c) = self.date_cache.lock() {
            for id in ids {
                match c.get(id) {
                    Some(d) => {
                        out.insert(*id, d.clone());
                    }
                    None => missing.push(*id),
                }
            }
        } else {
            missing = ids.to_vec();
        }
        missing.sort_unstable();
        missing.dedup();
        if missing.is_empty() {
            return Ok(out);
        }
        let lots: Vec<Vec<i64>> = missing.chunks(100).map(<[i64]>::to_vec).collect();
        let batches = lots.into_iter().map(|list| async move {
            let r: Value = self.gw("song.getListData", &json!({ "sng_ids": list })).await?;
            Ok::<_, DeezerError>(tracks(r.get("data").and_then(Value::as_array).map_or(&[][..], Vec::as_slice)))
        });
        let mut fresh: Vec<(i64, String)> = Vec::new();
        {
            use futures_util::{stream, StreamExt};
            let mut results = stream::iter(batches).buffer_unordered(8);
            while let Some(res) = results.next().await {
                if let Ok(list) = res {
                    fresh.extend(list.into_iter().filter_map(|t| t.release_date.map(|d| (t.id, d))));
                }
            }
        }
        if let Ok(mut c) = self.date_cache.lock() {
            if c.len() > 20_000 {
                c.clear();
            }
            for (id, d) in &fresh {
                c.insert(*id, d.clone());
            }
        }
        out.extend(fresh);
        Ok(out)
    }

    fn invalidate_loved(&self) {
        if let Ok(mut g) = self.loved_cache.lock() {
            *g = None;
        }
    }

    /// `song.getFavoriteIds` puis détails par lots ; à défaut, onglet du profil.
    async fn fetch_loved(&self) -> Result<Vec<TrackInfo>> {
        let ids_result = self.favorite_ids().await;
        if let Ok(ids) = &ids_result {
            let lots: Vec<Vec<i64>> = ids.chunks(100).map(|chunk| chunk.iter().map(|p| p.0).collect()).collect();
            let batches = lots.into_iter().map(|list| async move {
                let r: Value = self.gw("song.getListData", &json!({ "sng_ids": list })).await?;
                Ok::<_, DeezerError>(tracks(r.get("data").and_then(Value::as_array).map_or(&[][..], Vec::as_slice)))
            });
            let mut by_id = std::collections::HashMap::with_capacity(ids.len());
            // Au plus 8 lots en même temps : avec des milliers de favoris, tout lancer d'un coup ferait trop de requêtes.
            let batches_done: Vec<Vec<TrackInfo>> = {
                use futures_util::{stream, StreamExt, TryStreamExt};
                stream::iter(batches).buffer_unordered(8).try_collect().await?
            };
            for batch in batches_done {
                for t in batch {
                    by_id.insert(t.id, t);
                }
            }
            let out: Vec<TrackInfo> = ids
                .iter()
                .filter_map(|(id, date)| {
                    by_id.remove(id).map(|mut t| {
                        t.added_at = (*date != 0).then_some(*date);
                        t
                    })
                })
                .collect();
            if !out.is_empty() {
                return Ok(out);
            }
        }
        match self.profile_tab("loved").await {
            Ok(t) => Ok(tracks(t.get("data").and_then(Value::as_array).map_or(&[][..], Vec::as_slice))),
            Err(e) => ids_result.map(|_| Vec::new()).or(Err(e)),
        }
    }

    /// Le Flow (radio personnalisée de l'utilisateur).
    pub async fn flow(&self) -> Result<Vec<TrackInfo>> {
        let uid = self.user_id().await?;
        let r: Value = self.gw("radio.getUserRadio", &json!({ "user_id": uid.to_string() })).await?;
        let items = r.get("data").and_then(Value::as_array).or_else(|| r.as_array());
        let t = tracks(items.map_or(&[][..], Vec::as_slice));
        if t.is_empty() {
            return Err(DeezerError::EmptyResults);
        }
        Ok(t)
    }

    /// Playlist, album, artiste ou titres aimés, avec les pochettes déjà réparées (voir `repaired_cover`).
    pub async fn collection(&self, kind: &str, id: u64) -> Result<Collection> {
        let mut c = self.collection_raw(kind, id).await?;
        self.apply_cover_fixes(&mut c.tracks);
        Ok(c)
    }

    async fn collection_raw(&self, kind: &str, id: u64) -> Result<Collection> {
        let sid = id.to_string();
        match kind {
            "loved" => {
                let t = self.loved_tracks().await?;
                Ok(Collection {
                    owned: false,
                    kind: kind.into(),
                    id: 0,
                    title: "Titres aimés".into(),
                    subtitle: format!("Playlist · {} titres", t.len()),
                    cover_url: None,
                    tracks: t,
                    albums: Vec::new(),
                    latest: None,
                    related: Vec::new(),
                    appears_on: Vec::new(),
                })
            }
            "playlist" => {
                // Les titres arrivent par pages (2 000 au plus par demande) : on enchaîne jusqu'au total annoncé, sans plafond arbitraire.
                const PAGE: usize = 2000;
                const MAX_TRACKS: usize = 50_000;
                let page = |start: usize| {
                    let body = json!({ "playlist_id": sid.clone(), "lang": "fr", "nb": PAGE, "start": start, "tags": true, "header": true });
                    async move { self.gw::<Value>("deezer.pagePlaylist", &body).await }.boxed()
                };
                let r: Value = page(0).await?;
                let mut songs: Vec<Value> = data(&r, "SONGS").to_vec();
                let announced = |v: &Value| {
                    let n = |x: Option<&Value>| x.and_then(|x| x.as_u64().or_else(|| x.as_str().and_then(|s| s.trim().parse().ok()))).unwrap_or(0) as usize;
                    n(v.pointer("/SONGS/total")).max(n(v.pointer("/DATA/NB_SONG")))
                };
                let total = announced(&r);
                collect_pages(&mut songs, total, MAX_TRACKS, |start| {
                    let fut = page(start);
                    async move { fut.await.ok().map(|v| data(&v, "SONGS").to_vec()) }.boxed()
                })
                .await;
                // Deezer plafonne parfois cette méthode (2 000 titres) : la méthode « playlist.getSongs » n'a pas ce plafond.
                // Même si le total annoncé est « 2 000 » : une page pleine peut signifier un plafond, on tente la suite.
                let capped = songs.len() >= PAGE;
                if total > songs.len() || capped {
                    note(format!("playlist {id} : {} titres reçus sur {total} annoncés par deezer.pagePlaylist, essai de playlist.getSongs", songs.len()));
                    // 1) tout d'un coup (nb = -1 : « tous »)
                    match self.gw::<Value>("playlist.getSongs", &json!({ "playlist_id": sid, "nb": -1, "start": 0 })).await {
                        Ok(v) => {
                            let all = rows(&v);
                            note(format!("playlist {id} : playlist.getSongs (tout d'un coup) a fourni {} titres", all.len()));
                            if all.len() > songs.len() {
                                songs = all;
                            }
                        }
                        Err(e) => note(format!("playlist {id} : playlist.getSongs (tout d'un coup) a échoué : {e}")),
                    }
                    // 2) sinon, page par page
                    if total > songs.len() || capped {
                        let want = if capped { usize::MAX } else { total };
                        collect_pages(&mut songs, want, MAX_TRACKS, |start| {
                            let body = json!({ "playlist_id": sid.clone(), "nb": PAGE, "start": start });
                            async move { self.gw::<Value>("playlist.getSongs", &body).await.ok().map(|v| rows(&v)) }.boxed()
                        })
                        .await;
                        note(format!("playlist {id} : après playlist.getSongs par pages, {} titres sur {total}", songs.len()));
                    }
                }
                let d = r.get("DATA").cloned().unwrap_or(Value::Null);
                let uid = self.user_id().await.unwrap_or(0);
                let owned = uid != 0 && vn(&d, "PARENT_USER_ID") == uid;
                let ptype = match vs(&d, "PICTURE_TYPE").as_str() {
                    "" => "playlist".to_owned(),
                    k => k.to_owned(),
                };
                Ok(Collection {
                    owned,
                    kind: kind.into(),
                    id,
                    title: vs(&d, "TITLE"),
                    subtitle: if total > songs.len() {
                        format!("Playlist · {} · {} titres chargés sur {total}", vs(&d, "PARENT_USERNAME"), songs.len())
                    } else {
                        format!("Playlist · {}", vs(&d, "PARENT_USERNAME"))
                    },
                    cover_url: image(&ptype, &vs(&d, "PLAYLIST_PICTURE"), 1000),
                    tracks: tracks(&songs),
                    albums: Vec::new(),
                    latest: None,
                    related: Vec::new(),
                    appears_on: Vec::new(),
                })
            }
            "album" => {
                let r: Value = self
                    .gw("deezer.pageAlbum", &json!({ "alb_id": sid, "lang": "fr", "header": true, "tab": 0 }))
                    .await?;
                let d = r.get("DATA").cloned().unwrap_or(Value::Null);
                Ok(Collection {
                    owned: false,
                    kind: kind.into(),
                    id,
                    title: vs(&d, "ALB_TITLE"),
                    subtitle: format!("Album · {}", vs(&d, "ART_NAME")),
                    cover_url: image("cover", &vs(&d, "ALB_PICTURE"), 1000),
                    tracks: tracks(data(&r, "SONGS")),
                    albums: Vec::new(),
                    latest: None,
                    related: Vec::new(),
                    appears_on: Vec::new(),
                })
            }
            "artist" => {
                let page_body = json!({ "art_id": sid, "lang": "fr", "tab": 0 });
                let disco_body = json!({ "art_id": sid, "discography_mode": "all", "nb": 500, "nb_songs": 0, "start": 0 });
                let page = self.gw::<Value>("deezer.pageArtist", &page_body);
                // pageArtist ne renvoie qu'une partie des albums : la discographie complète vient d'une autre méthode.
                let disco = self.gw::<Value>("album.getDiscography", &disco_body);
                let (r, disco) = tokio::join!(page, disco);
                let r = r?;
                let d = r.get("DATA").cloned().unwrap_or(Value::Null);

                let raw: Vec<Value> = match &disco {
                    Ok(v) => v.get("data").and_then(Value::as_array).cloned().unwrap_or_default(),
                    Err(_) => data(&r, "ALBUMS").to_vec(), // repli : les albums de la page
                };
                // Ses sorties d'un côté, les albums d'autres artistes où il est en featuring de l'autre ; les
                // compilations d'autres artistes (« Hits 2024 »…) ne sont plus mélangées à sa discographie.
                let mut releases = Vec::new();
                let mut appears_on = Vec::new();
                let mut seen = std::collections::HashSet::new();
                for a in &raw {
                    if !seen.insert(vn(a, "ALB_ID")) {
                        continue;
                    }
                    match release_role(a, id) {
                        ReleaseRole::Own => releases.extend(release_card(a)),
                        ReleaseRole::Featured => appears_on.extend(release_card(a).map(|mut c| {
                            // Sous-titre : l'artiste de l'album plutôt que son type (« Ninho · 2024 »).
                            let by = vs(a, "ART_NAME");
                            if !by.is_empty() {
                                let year = c.date.get(..4).unwrap_or("").to_owned();
                                c.subtitle = if year.is_empty() { by } else { format!("{by} · {year}") };
                            }
                            c
                        })),
                        ReleaseRole::Other => {}
                    }
                }
                releases.sort_by(|a, b| b.date.cmp(&a.date));
                appears_on.sort_by(|a, b| b.date.cmp(&a.date));

                // Mise en avant : la « highlight » de Deezer si c'est un album, sinon la sortie la plus récente.
                let latest = r
                    .pointer("/HIGHLIGHT/ITEM")
                    .filter(|_| vs(r.get("HIGHLIGHT").unwrap_or(&Value::Null), "TYPE") == "album")
                    .and_then(release_card)
                    .or_else(|| releases.first().cloned());

                Ok(Collection {
                    owned: false,
                    kind: kind.into(),
                    id,
                    title: vs(&d, "ART_NAME"),
                    subtitle: match vn(&d, "NB_FAN") {
                        0 => "Artiste".into(),
                        n => format!("Artiste · {} fans", group_digits(n)),
                    },
                    cover_url: image("artist", &vs(&d, "ART_PICTURE"), 1000),
                    tracks: tracks(data(&r, "TOP")),
                    albums: releases,
                    appears_on,
                    latest,
                    related: artist_cards(data(&r, "RELATED_ARTISTS")),
                })
            }
            other => Err(DeezerError::Gateway(format!("type de collection inconnu: {other}"))),
        }
    }

    /// Carte d'une playlist publique (titre, pochette, taille) via l'API publique, sans authentification.
    pub async fn playlist_card(&self, id: u64) -> Result<Card> {
        let v: Value = self
            .http()
            .get(format!("https://api.deezer.com/playlist/{id}"))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        if v.get("error").is_some() {
            return Err(DeezerError::EmptyResults);
        }
        Ok(Card {
            kind: "playlist",
            id,
            title: vs(&v, "title"),
            subtitle: match vn(&v, "nb_tracks") {
                0 => "Playlist".into(),
                n => format!("Playlist · {n} titres"),
            },
            cover_url: Some(vs(&v, "picture_xl")).filter(|u| !u.is_empty()).map(|u| u.replace("1000x1000", "500x500")),
            owned: false,
            date: String::new(),
            group: "",
            key: String::new(),
        })
    }

    /// Paroles d'un titre. `None` : pas de paroles pour ce titre (cas courant, ce n'est pas une erreur).
    /// Paroles d'un titre. Service récent de Deezer (pipe) d'abord : les paroles ajoutées ces dernières années ne sont
    /// que là (l'ancienne méthode répondait « pas de paroles », par exemple pour « Cinéma » de No Limit, Leto et Timar).
    /// L'ancienne méthode reste en secours : service récent injoignable, ou rien chez lui.
    pub async fn lyrics(&self, id: i64) -> Result<Option<Lyrics>> {
        if let Ok(data) = self.pipe("TrackLyrics", PIPE_LYRICS, json!({ "trackId": id.to_string() })).await {
            if let Some(found) = lyrics_from_pipe(&data) {
                return Ok(Some(found));
            }
        }
        self.lyrics_gw(id).await
    }

    async fn lyrics_gw(&self, id: i64) -> Result<Option<Lyrics>> {
        let r: Value = match self.gw("song.getLyrics", &json!({ "sng_id": id.to_string() })).await {
            Ok(r) => r,
            Err(DeezerError::Gateway(m)) if m.contains("No lyrics") || m.contains("DATA_ERROR") => return Ok(None),
            Err(e) => return Err(e),
        };
        let copyright = vs(&r, "LYRICS_COPYRIGHTS");
        let synced: Vec<LyricLine> = r
            .get("LYRICS_SYNC_JSON")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter(|l| l.get("milliseconds").is_some())
                    .map(|l| LyricLine { ms: vn(l, "milliseconds"), text: vs(l, "line") })
                    .collect()
            })
            .unwrap_or_default();
        // Une ligne vide en tête ou en fin ne sert à rien ; les lignes vides au milieu marquent un silence.
        if synced.iter().any(|l| !l.text.trim().is_empty()) {
            return Ok(Some(Lyrics { synced: true, lines: synced, copyright, source: "deezer" }));
        }
        let text = vs(&r, "LYRICS_TEXT");
        if text.trim().is_empty() {
            return Ok(None);
        }
        let lines = text.lines().map(|t| LyricLine { ms: 0, text: t.to_owned() }).collect();
        Ok(Some(Lyrics { synced: false, lines, copyright, source: "deezer" }))
    }

    /// Supprime définitivement une playlist de l'utilisateur.
    pub async fn playlist_delete(&self, playlist_id: u64) -> Result<()> {
        let _: Value = self.gw("playlist.delete", &json!({ "playlist_id": playlist_id.to_string() })).await?;
        Ok(())
    }

    /// Ajoute un titre à une playlist de l'utilisateur.
    pub async fn playlist_add(&self, playlist_id: u64, track_id: i64) -> Result<()> {
        let _: Value = self
            .gw(
                "playlist.addSongs",
                &json!({ "playlist_id": playlist_id.to_string(), "songs": [[track_id.to_string(), 0]], "offset": -1 }),
            )
            .await?;
        Ok(())
    }

    /// Retire un titre d'une playlist de l'utilisateur.
    pub async fn playlist_remove(&self, playlist_id: u64, track_id: i64) -> Result<()> {
        let _: Value = self
            .gw("playlist.deleteSongs", &json!({ "playlist_id": playlist_id.to_string(), "songs": [[track_id.to_string(), 0]] }))
            .await?;
        Ok(())
    }

    /// Crée une playlist (privée) contenant éventuellement des titres ; renvoie son identifiant.
    pub async fn playlist_create(&self, title: &str, track_ids: &[i64]) -> Result<u64> {
        let songs: Vec<Value> = track_ids.iter().map(|id| json!([id.to_string(), 0])).collect();
        let r: Value = self
            .gw("playlist.create", &json!({ "title": title, "description": "", "status": 1, "songs": songs }))
            .await?;
        let id = match &r {
            Value::Number(n) => n.as_u64().unwrap_or(0),
            Value::String(s) => s.parse().unwrap_or(0),
            other => vn(other, "PLAYLIST_ID"),
        };
        if id == 0 {
            return Err(DeezerError::EmptyResults);
        }
        Ok(id)
    }

    pub async fn like_track(&self, id: i64) -> Result<()> {
        let _: Value = self.gw("favorite_song.add", &json!({ "SNG_ID": id.to_string() })).await?;
        self.invalidate_loved();
        Ok(())
    }

    pub async fn unlike_track(&self, id: i64) -> Result<()> {
        let _: Value = self.gw("favorite_song.remove", &json!({ "SNG_ID": id.to_string() })).await?;
        self.invalidate_loved();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::lyrics_from_pipe;
    use serde_json::json;

    #[test]
    fn lyrics_from_the_recent_service() {
        let synced = json!({ "track": { "lyrics": { "text": "a\r\nb", "copyright": "C", "synchronizedLines": [
            { "line": "un", "milliseconds": 1370 }, { "line": "", "milliseconds": 4000 }, { "line": "deux", "milliseconds": 5200 }
        ] } } });
        let l = lyrics_from_pipe(&synced).unwrap();
        assert!(l.synced && l.lines.len() == 3 && l.lines[2].ms == 5200 && l.copyright == "C");
        let plain = json!({ "track": { "lyrics": { "text": "a\r\nb", "copyright": null, "synchronizedLines": [] } } });
        let l = lyrics_from_pipe(&plain).unwrap();
        assert!(!l.synced && l.lines.iter().map(|x| x.text.as_str()).eq(["a", "b"]));
        assert!(lyrics_from_pipe(&json!({ "track": { "lyrics": null } })).is_none());
        assert!(lyrics_from_pipe(&json!({ "track": null })).is_none());
    }

    #[test]
    fn search_artists_most_followed_first() {
        let items = vec![
            serde_json::json!({ "ART_ID": "1", "ART_NAME": "Ninho Junior", "NB_FAN": "120" }),
            serde_json::json!({ "ART_ID": "2", "ART_NAME": "Ninho", "NB_FAN": "9028132" }),
            serde_json::json!({ "ART_ID": "0", "ART_NAME": "Sans id" }),
        ];
        let found = search_artists(&items);
        assert_eq!(found.iter().map(|c| c.id).collect::<Vec<_>>(), vec![2, 1]);
        assert_eq!(found[0].subtitle, "9\u{202f}028\u{202f}132 fans");
    }
    use super::*;

    #[tokio::test]
    async fn playlists_beyond_one_page_are_fully_loaded() {
        use serde_json::json;
        // Playlist de 4 300 titres servie par pages de 2 000 : rien ne doit être perdu ni plafonné à 2 000.
        let all: Vec<Value> = (0..4300).map(|i| json!({ "SNG_ID": i })).collect();
        let source = all.clone();
        let mut songs: Vec<Value> = all[..2000].to_vec();
        collect_pages(&mut songs, 4300, 50_000, |start| {
            let page = source.get(start..(start + 2000).min(source.len())).map(<[Value]>::to_vec);
            async move { page }.boxed()
        })
        .await;
        assert_eq!(songs.len(), 4300);
        assert_eq!(songs[4299]["SNG_ID"], 4299);
        // Serveur qui renvoie des pages plus petites que demandé (500) : on continue quand même jusqu'au total.
        let mut songs: Vec<Value> = all[..500].to_vec();
        collect_pages(&mut songs, 4300, 50_000, |start| {
            let page = source.get(start..(start + 500).min(source.len())).map(<[Value]>::to_vec);
            async move { page }.boxed()
        })
        .await;
        assert_eq!(songs.len(), 4300);
        // Total inconnu : on s'arrête à la première page vide.
        let mut songs: Vec<Value> = all[..1000].to_vec();
        collect_pages(&mut songs, 0, 50_000, |start| {
            let page = source.get(start..(start + 1000).min(source.len())).map(<[Value]>::to_vec).unwrap_or_default();
            async move { Some(page) }.boxed()
        })
        .await;
        assert_eq!(songs.len(), 4300);
        // Une page qui échoue en route : on garde ce qui est déjà chargé.
        let mut songs: Vec<Value> = all[..2000].to_vec();
        collect_pages(&mut songs, 4300, 50_000, |_| async { None }.boxed()).await;
        assert_eq!(songs.len(), 2000);
        // La limite de sécurité est respectée.
        let mut songs: Vec<Value> = all[..2000].to_vec();
        collect_pages(&mut songs, 4300, 3000, |start| {
            let page = source.get(start..(start + 2000).min(source.len())).map(<[Value]>::to_vec);
            async move { page }.boxed()
        })
        .await;
        assert!(songs.len() >= 3000 && songs.len() < 4300);
    }

    #[test]
    fn parses_cards() {
        let a = json!([{ "ALB_ID": "12", "ALB_TITLE": "Discovery", "ART_NAME": "Daft Punk", "ALB_PICTURE": "abc" }]);
        let c = album_cards(a.as_array().unwrap());
        assert_eq!((c[0].id, c[0].subtitle.as_str()), (12, "Daft Punk"));
        assert!(c[0].cover_url.as_ref().unwrap().contains("/cover/abc/"));

        let p = json!([{ "PLAYLIST_ID": 7, "TITLE": "Mix", "NB_SONG": "30", "PLAYLIST_PICTURE": "zz", "PICTURE_TYPE": "playlist" }]);
        let c = playlist_cards(p.as_array().unwrap(), 0);
        assert_eq!((c[0].id, c[0].subtitle.as_str()), (7, "30 titres"));
    }

    #[test]
    fn skips_entries_without_id() {
        let a = json!([{ "ART_NAME": "x" }]);
        assert!(artist_cards(a.as_array().unwrap()).is_empty());
    }
}

#[cfg(test)]
mod favorites_tests {
    use super::*;

    #[test]
    fn reads_date_favorite() {
        let x = json!({ "DATE_FAVORITE": 1610550096u64, "SNG_ID": "1198248042" });
        assert_eq!(vn(&x, "DATE_FAVORITE"), 1610550096);
    }
}

#[cfg(test)]
mod artist_tests {
    use super::*;

    #[test]
    fn release_types_and_dates() {
        let album = json!({ "ALB_ID": "1", "ALB_TITLE": "Sémantique", "TYPE": "1", "ORIGINAL_RELEASE_DATE": "2025-05-16", "SUBTYPES": { "isCompilation": false } });
        let single = json!({ "ALB_ID": "2", "ALB_TITLE": "Visage", "TYPE": "0", "ORIGINAL_RELEASE_DATE": "2026-10-09" });
        let compil = json!({ "ALB_ID": "3", "ALB_TITLE": "Best of", "TYPE": "1", "SUBTYPES": { "isCompilation": true }, "DIGITAL_RELEASE_DATE": "2020-01-01" });
        let a = release_card(&album).unwrap();
        assert_eq!((a.group, a.subtitle.as_str()), ("album", "Album · 2025"));
        let s = release_card(&single).unwrap();
        assert_eq!((s.group, s.subtitle.as_str()), ("single", "Single · 2026"));
        let c = release_card(&compil).unwrap();
        assert_eq!((c.group, c.date.as_str()), ("compilation", "2020-01-01"));
        assert!(release_card(&json!({ "ALB_TITLE": "sans id" })).is_none());
    }

    #[test]
    fn groups_digits() {
        assert_eq!(group_digits(490630), "490\u{202f}630");
        assert_eq!(group_digits(999), "999");
        assert_eq!(group_digits(1234567), "1\u{202f}234\u{202f}567");
    }
}

#[cfg(test)]
mod reco_tests {
    use super::*;

    #[test]
    fn categorises_sections() {
        let t = |m: &str, c: &str| format!("page_id=home,section_id=horizontal-grid,module_type={m},layout=x,content_source={c},content_source_count=3");
        assert_eq!(section_kind(&t("artist", "recently-played")), "recent");
        assert_eq!(section_kind(&t("track", "user-tops")), "track-mixes");
        assert_eq!(section_kind(&t("playlists", "user-favorites")), "followed");
        assert_eq!(section_kind(&t("playlists", "user-suggested")), "playlists-for-you");
        assert_eq!(section_kind(&t("album", "unmissables-new-releases")), "new-releases");
        assert_eq!(section_kind(&t("smarttracklist", "recommendation")), "mixes");
        assert_eq!(section_kind(&t("channel", "recommendation")), "genres");
        assert_eq!(section_kind(&t("album", "none")), "curated");
        assert_eq!(section_kind(&t("podcast", "none")), "podcasts");
    }

    #[test]
    fn converts_page_items_and_drops_unsupported() {
        let album = json!({ "type": "album", "data": { "ALB_ID": "7", "ALB_TITLE": "X", "ART_NAME": "Y", "ALB_PICTURE": "abc" } });
        let mix = json!({ "type": "smarttracklist", "id": "new-releases", "title": "Nouveautés", "caption": "CHAQUE VENDREDI",
            "cover": { "md5": "aaa-bbb-ccc", "type": "artist" } });
        let genre = json!({ "type": "channel", "target": "/channels/french-rap", "title": "Rap français", "image_linked_item": { "md5": "z", "type": "playlist" } });
        let show = json!({ "type": "show", "data": {} });
        assert_eq!(page_item_card(&album, 0).unwrap().id, 7);
        let m = page_item_card(&mix, 0).unwrap();
        assert_eq!((m.kind, m.key.as_str(), m.subtitle.as_str()), ("mix", "new-releases", "CHAQUE VENDREDI"));
        // Mosaïque : le md5 complet, c'est le serveur d'images qui la compose.
        assert!(m.cover_url.unwrap().contains("/artist/aaa-bbb-ccc/"));
        let song = json!({ "type": "track", "id": "42", "title": "Titre", "subtitle": "Artiste", "data": { "ALB_PICTURE": "pic" } });
        let c = page_item_card(&song, 0).unwrap();
        assert_eq!((c.kind, c.id, c.subtitle.as_str()), ("trackmix", 42, "Artiste"));
        assert!(c.cover_url.unwrap().contains("/cover/pic/"));
        let g = page_item_card(&genre, 0).unwrap();
        assert_eq!((g.kind, g.key.as_str()), ("channel", "channels/french-rap"));
        assert!(page_item_card(&show, 0).is_none());
        // une section qui ne contient que des éléments non gérés disparaît
        let v = json!({ "sections": [ { "title": "Podcasts", "section_id": "module_type=podcast,content_source=none", "items": [show] } ] });
        assert!(parse_sections(&v, 0).is_empty());
    }
}
