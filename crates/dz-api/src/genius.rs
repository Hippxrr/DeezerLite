//! Paroles de secours via Genius, pour les titres sans paroles chez Deezer (et seulement eux : jamais demandé avant Deezer,
//! ni sans l'accord de l'utilisateur). Genius n'a pas d'API publique pour les paroles : le titre est cherché avec la
//! recherche du site, puis les paroles sont lues dans la page du morceau (même méthode que la librairie LyricsGenius).
//! Texte simple, jamais synchronisé. Ce qui part chez Genius : le titre et l'artiste recherchés. Aucun compte, aucun cookie.
//! Si Genius change sa page, la fonction renvoie simplement « pas de paroles ».

use serde::Deserialize;
use serde_json::Value;

use crate::catalog::{LyricLine, Lyrics};
use crate::{DeezerClient, Result};

/// L'app se présente sous son propre nom : la protection de Genius refuse le navigateur imité pour Deezer.
const UA: &str = concat!("DeezerLite/", env!("CARGO_PKG_VERSION"));
const SITE: &str = "https://genius.com/";

/// Morceau dont on cherche les paroles.
#[derive(Debug, Clone, Deserialize)]
pub struct LyricsQuery {
    pub title: String,
    pub artist: String,
}

/// Résultat de recherche : titre, artistes crédités, page des paroles.
#[derive(Debug, Clone, PartialEq)]
struct Hit {
    title: String,
    artists: String,
    url: String,
}

impl DeezerClient {
    /// Paroles d'un morceau sur Genius. `Ok(None)` : morceau introuvable, instrumental ou sans paroles.
    pub async fn lyrics_genius(&self, q: &LyricsQuery) -> Result<Option<Lyrics>> {
        let query = format!("{} {}", clean_title(&q.title), main_artist(&q.artist));
        let found: Value = self
            .genius(&format!("{SITE}api/search/song"))
            .query(&[("q", query.as_str()), ("per_page", "5")])
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        let Some(hit) = pick(hits(&found), q) else { return Ok(None) };
        let page = self.genius(&hit.url).send().await?.error_for_status()?.text().await?;
        Ok(page_lyrics(&page).map(|lines| Lyrics {
            synced: false,
            lines: lines.into_iter().map(|text| LyricLine { ms: 0, text }).collect(),
            copyright: String::new(),
            source: "genius",
        }))
    }

    fn genius(&self, url: &str) -> reqwest::RequestBuilder {
        self.http().get(url).header(reqwest::header::USER_AGENT, UA).timeout(std::time::Duration::from_secs(10))
    }
}

/// Résultats de la recherche : seulement des paroles complètes (ni instrumental, ni texte pas encore publié), et des pages
/// de genius.com (l'adresse vient de la réponse : rien d'autre n'est ouvert).
fn hits(search: &Value) -> Vec<Hit> {
    let sections = search.pointer("/response/sections").and_then(Value::as_array);
    sections
        .into_iter()
        .flatten()
        .flat_map(|s| s.get("hits").and_then(Value::as_array).into_iter().flatten())
        .filter_map(|h| {
            let r = h.get("result")?;
            if r.get("instrumental").and_then(Value::as_bool) == Some(true) || r.get("lyrics_state").and_then(Value::as_str) != Some("complete") {
                return None;
            }
            let artists = r.get("artist_names").or_else(|| r.pointer("/primary_artist/name")).and_then(Value::as_str)?;
            let url = r.get("url").and_then(Value::as_str).filter(|u| u.starts_with(SITE))?;
            Some(Hit { title: r.get("title")?.as_str()?.to_owned(), artists: artists.to_owned(), url: url.to_owned() })
        })
        .collect()
}

/// Premier résultat qui est vraiment le bon morceau : même titre (sans les mentions entre parenthèses) et artiste crédité.
/// Genius ne donne pas la durée : rien plutôt qu'un autre morceau (traduction, reprise, autre titre du même artiste).
fn pick(hits: Vec<Hit>, q: &LyricsQuery) -> Option<Hit> {
    let want_title = norm(&clean_title(&q.title));
    let want_artist = norm(&main_artist(&q.artist));
    if want_title.is_empty() {
        return None;
    }
    hits.into_iter().find(|h| norm(&clean_title(&h.title)) == want_title && (want_artist.is_empty() || norm(&h.artists).contains(&want_artist)))
}

/// Paroles de la page d'un morceau, ligne par ligne (une ligne vide entre les couplets). Blocs de paroles de la page ;
/// à défaut, la copie des paroles rangée dans les données de la page.
fn page_lyrics(page: &str) -> Option<Vec<String>> {
    let mut text = String::new();
    let mut rest = page;
    while let Some(at) = rest.find("data-lyrics-container=\"true\"") {
        let Some(open_end) = rest[at..].find('>') else { break };
        let body = &rest[at + open_end + 1..];
        let used = html_text(body, &mut text);
        text.push('\n');
        rest = &body[used..];
    }
    to_lines(&text).or_else(|| {
        let mut text = String::new();
        html_text(&preloaded_lyrics_html(page)?, &mut text);
        to_lines(&text)
    })
}

/// Lignes sans espaces en trop, au plus une ligne vide d'affilée, aucune au début ni à la fin. `None` si rien.
/// Les repères de Genius (« [Couplet 1] », « [Refrain : Artiste] »…), qui ne sont pas des paroles, deviennent une
/// simple ligne vide entre les parties. Les crochets au milieu d'une ligne (« [?] », mot incertain) restent.
fn to_lines(text: &str) -> Option<Vec<String>> {
    let mut lines: Vec<String> = Vec::new();
    for l in text.lines().map(str::trim) {
        let l = if l.starts_with('[') && l.ends_with(']') { "" } else { l };
        if l.is_empty() && lines.last().map_or(true, |p| p.is_empty()) {
            continue;
        }
        lines.push(l.to_owned());
    }
    while lines.last().is_some_and(|l| l.is_empty()) {
        lines.pop();
    }
    (!lines.is_empty()).then_some(lines)
}

/// Texte d'un morceau de HTML, jusqu'au `</div>` qui ferme le bloc (ou la fin) ; renvoie la longueur lue. `<br>` = retour
/// à la ligne, entités décodées, balises enlevées. Les parties marquées `data-exclude-from-selection` (en-tête de la page,
/// nombre de contributeurs, traductions) sont sautées.
fn html_text(body: &str, out: &mut String) -> usize {
    let mut depth = 0usize; // `div` ouverts dans le bloc
    let mut skipped: Option<usize> = None; // profondeur de la partie sautée
    let mut i = 0;
    while i < body.len() {
        let rest = &body[i..];
        if let Some(tag) = rest.strip_prefix('<') {
            let Some(end) = tag.find('>') else { return body.len() };
            let tag = &tag[..end];
            i += end + 2;
            let closing = tag.starts_with('/');
            let name: String = tag.trim_start_matches('/').chars().take_while(char::is_ascii_alphanumeric).collect();
            if name.eq_ignore_ascii_case("div") {
                if closing {
                    if depth == 0 {
                        return i; // fin du bloc
                    }
                    depth -= 1;
                    if skipped == Some(depth) {
                        skipped = None;
                    }
                } else if !tag.ends_with('/') {
                    if skipped.is_none() && tag.contains("data-exclude-from-selection=\"true\"") {
                        skipped = Some(depth);
                    }
                    depth += 1;
                }
            } else if name.eq_ignore_ascii_case("br") && skipped.is_none() {
                out.push('\n');
            }
        } else {
            let next = rest.find('<').unwrap_or(rest.len());
            if skipped.is_none() {
                decode_entities(&rest[..next].replace('\n', " "), out); // retours à la ligne du code : simple mise en forme
            }
            i += next;
        }
    }
    body.len()
}

fn decode_entities(s: &str, out: &mut String) {
    let mut rest = s;
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        rest = &rest[at..];
        let decoded = rest.find(';').filter(|&e| e <= 10).and_then(|e| Some((e, entity(&rest[1..e])?)));
        match decoded {
            Some((e, c)) => {
                out.push(c);
                rest = &rest[e + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
}

fn entity(name: &str) -> Option<char> {
    match name {
        "amp" => Some('&'),
        "lt" => Some('<'),
        "gt" => Some('>'),
        "quot" => Some('"'),
        "apos" => Some('\''),
        "nbsp" => Some(' '),
        _ => {
            let n = name.strip_prefix('#')?;
            let code = match n.strip_prefix(['x', 'X']) {
                Some(hex) => u32::from_str_radix(hex, 16).ok()?,
                None => n.parse().ok()?,
            };
            char::from_u32(code)
        }
    }
}

/// Paroles (HTML) rangées dans les données de la page : `window.__PRELOADED_STATE__ = JSON.parse('…')`, une chaîne
/// JavaScript entre apostrophes qui contient du JSON.
fn preloaded_lyrics_html(page: &str) -> Option<String> {
    const START: &str = "window.__PRELOADED_STATE__ = JSON.parse('";
    let raw = &page[page.find(START)? + START.len()..];
    // Fin de la chaîne : la première apostrophe qui n'est pas échappée.
    let mut end = None;
    let mut escaped = false;
    for (i, c) in raw.char_indices() {
        match c {
            '\\' if !escaped => escaped = true,
            '\'' if !escaped => {
                end = Some(i);
                break;
            }
            _ => escaped = false,
        }
    }
    let state: Value = serde_json::from_str(&js_unescape(&raw[..end?])).ok()?;
    state.pointer("/songPage/lyricsData/body/html").and_then(Value::as_str).map(str::to_owned)
}

/// Chaîne JavaScript entre apostrophes → texte, comme le ferait le navigateur (`\'`, `\"`, `\\`, `\n`, `\uXXXX`, `\xHH`…).
fn js_unescape(s: &str) -> String {
    fn hex(chars: &mut std::str::Chars, n: usize) -> u32 {
        u32::from_str_radix(&chars.by_ref().take(n).collect::<String>(), 16).unwrap_or(0xFFFD)
    }
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        let code = match chars.next() {
            Some('n') => 0x0A,
            Some('r') => 0x0D,
            Some('t') => 0x09,
            Some('b') => 0x08,
            Some('f') => 0x0C,
            Some('0') => 0,
            Some('x') => hex(&mut chars, 2),
            Some('u') => {
                let hi = hex(&mut chars, 4);
                // Caractère hors du plan de base (emoji…) : écrit en deux moitiés `😀`.
                if (0xD800..0xDC00).contains(&hi) && chars.as_str().starts_with("\\u") {
                    chars.nth(1);
                    0x10000 + ((hi - 0xD800) << 10) + (hex(&mut chars, 4).wrapping_sub(0xDC00) & 0x3FF)
                } else {
                    hi
                }
            }
            Some(other) => other as u32,
            None => break,
        };
        out.push(char::from_u32(code).unwrap_or('\u{FFFD}'));
    }
    out
}

/// Premier artiste crédité (« Heuss L'enfoiré, Timar » → « Heuss L'enfoiré »).
fn main_artist(artist: &str) -> String {
    artist.split(", ").next().unwrap_or(artist).trim().to_owned()
}

/// Titre sans mention entre parenthèses ou crochets (« feat. », « Remastered »…), qui varie d'un catalogue à l'autre.
fn clean_title(title: &str) -> String {
    let mut out = String::with_capacity(title.len());
    let mut depth = 0u32;
    for c in title.chars() {
        match c {
            '(' | '[' => depth += 1,
            ')' | ']' => depth = depth.saturating_sub(1),
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    let t = out.split(" - ").next().unwrap_or(&out).trim().to_owned();
    if t.is_empty() { title.trim().to_owned() } else { t }
}

/// Pour comparer : minuscules, sans accents, sans ponctuation ni espaces.
fn norm(s: &str) -> String {
    s.chars()
        .flat_map(char::to_lowercase)
        .map(|c| match c {
            'à' | 'á' | 'â' | 'ä' | 'ã' => 'a',
            'é' | 'è' | 'ê' | 'ë' => 'e',
            'î' | 'ï' | 'í' | 'ì' => 'i',
            'ô' | 'ö' | 'ó' | 'ò' | 'õ' => 'o',
            'û' | 'ü' | 'ú' | 'ù' => 'u',
            'ç' => 'c',
            'ñ' => 'n',
            other => other,
        })
        .filter(|c| c.is_alphanumeric())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn q(title: &str, artist: &str) -> LyricsQuery {
        LyricsQuery { title: title.into(), artist: artist.into() }
    }
    fn hit(title: &str, artists: &str, url: &str) -> Value {
        json!({ "result": { "title": title, "artist_names": artists, "url": url, "lyrics_state": "complete", "instrumental": false } })
    }

    #[test]
    fn the_right_song_is_picked_and_lookalikes_rejected() {
        let search = json!({ "response": { "sections": [{ "hits": [
            hit("Bracelet (Traduction)", "Genius Traductions", "https://genius.com/a"),
            hit("G.M.T.B", "Heuss L'enfoiré", "https://genius.com/b"),
            hit("Bracelet", "Heuss L'enfoiré & Timar", "https://genius.com/c"),
        ] }] } });
        let found = hits(&search);
        assert_eq!(pick(found.clone(), &q("Bracelet (feat. Timar)", "Heuss L'enfoiré, Timar")).unwrap().url, "https://genius.com/c");
        // Autre artiste, ou titre seulement proche : rien.
        assert!(pick(found.clone(), &q("Bracelet", "Ninho")).is_none());
        assert!(pick(found, &q("Brace", "Heuss L'enfoiré")).is_none());
        // Instrumental, paroles pas encore publiées, ou adresse hors de genius.com : écartés.
        let odd = json!({ "response": { "sections": [{ "hits": [
            { "result": { "title": "X", "artist_names": "A", "url": "https://genius.com/x", "lyrics_state": "complete", "instrumental": true } },
            { "result": { "title": "X", "artist_names": "A", "url": "https://genius.com/y", "lyrics_state": "unreleased" } },
            { "result": { "title": "X", "artist_names": "A", "url": "https://example.com/z", "lyrics_state": "complete" } },
        ] }] } });
        assert!(hits(&odd).is_empty());
    }

    #[test]
    fn lyrics_blocks_become_lines_without_the_page_header() {
        let page = concat!(
            "<html><div id=\"lyrics-root\"><div data-lyrics-container=\"true\" class=\"c\">",
            "<div data-exclude-from-selection=\"true\"><span>12 Contributors</span><div>Translations</div>Titre Lyrics</div>",
            "[Couplet 1]<br/>Ligne <a href=\"/x\"><span>une</span></a> &amp; l&#x27;autre<br>Ligne deux<br/><br/></div>",
            "<div class=\"ad\">pub</div>",
            "<div data-lyrics-container=\"true\">[Refrain]<br/><i>Ligne trois</i></div></div></html>",
        );
        let lines = page_lyrics(page).unwrap();
        // Repères « [Couplet 1] », « [Refrain] » retirés : une ligne vide sépare les parties.
        assert_eq!(lines, ["Ligne une & l'autre", "Ligne deux", "", "Ligne trois"]);
        assert!(page_lyrics("<html><div>rien</div></html>").is_none());
    }

    #[test]
    fn embedded_page_data_is_the_backup() {
        // Données de la page : JSON dans une chaîne JavaScript (apostrophes et guillemets échappés).
        let page = r#"<script>window.__PRELOADED_STATE__ = JSON.parse('{\"songPage\":{\"lyricsData\":{\"body\":{\"html\":\"<p>L\\u00e0 c\'est<br>fini</p>\"}}}}');</script>"#;
        assert_eq!(page_lyrics(page).unwrap(), ["Là c'est", "fini"]);
    }

    #[test]
    fn names_and_titles_are_compared_loosely() {
        assert_eq!(norm("Heuss L'Enfoiré"), "heusslenfoire");
        assert_eq!(main_artist("Heuss L'enfoiré, Timar"), "Heuss L'enfoiré");
        assert_eq!(clean_title("Song - Remastered 2011"), "Song");
        let mut s = String::new();
        decode_entities("a &lt;b&gt; &#233; &unknown; &", &mut s);
        assert_eq!(s, "a <b> é &unknown; &");
    }

    /// Appel réel (réseau) : `cargo test -p dz-api genius_live -- --ignored`.
    #[tokio::test]
    #[ignore]
    async fn genius_live() {
        let cl = DeezerClient::new().unwrap();
        let l = cl.lyrics_genius(&q("Bohemian Rhapsody", "Queen")).await.unwrap().expect("paroles trouvées");
        assert!(l.lines.len() > 20 && l.source == "genius" && !l.synced);
        assert!(l.lines.iter().all(|x| !x.text.contains("Contributors")), "en-tête de la page laissé dans les paroles");
        assert!(l.lines.iter().all(|x| !x.text.starts_with('[')), "repère de partie laissé dans les paroles");
    }
}
