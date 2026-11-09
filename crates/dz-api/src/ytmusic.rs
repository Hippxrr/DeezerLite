//! Paroles de secours via YouTube Music (paroles fournies par LyricFind, sous licence), pour les titres sans paroles chez Deezer.
//! Interroge directement l'API interne du site music.youtube.com, sans intermédiaire : recherche du titre, puis ses paroles.
//! Ce qui part chez YouTube : le titre et l'artiste recherchés. Aucun compte, aucun cookie.
//! Ce n'est pas une API publique : si YouTube la modifie, la fonction renvoie simplement « pas de paroles ».

use serde::Deserialize;
use serde_json::{json, Value};

use crate::catalog::{LyricLine, Lyrics};
use crate::{DeezerClient, Result};

const BASE: &str = "https://music.youtube.com/youtubei/v1/";
/// Filtre de recherche « Titres » (sans vidéos, albums ni playlists).
const SONGS_FILTER: &str = "EgWKAQIIAWoKEAoQAxAEEAkQBQ==";

/// Morceau dont on cherche les paroles.
#[derive(Debug, Clone, Deserialize)]
pub struct LyricsQuery {
    pub title: String,
    pub artist: String,
    #[serde(default)]
    pub album: String,
    #[serde(default)]
    pub duration_s: u64,
}

/// Résultat de recherche : identifiant de la vidéo, titre, ligne « artistes • album • durée ».
#[derive(Debug, Clone, PartialEq)]
struct Candidate {
    video_id: String,
    title: String,
    subtitle: String,
}

impl DeezerClient {
    /// Paroles d'un morceau sur YouTube Music. `Ok(None)` : morceau introuvable, ou sans paroles.
    pub async fn lyrics_ytmusic(&self, q: &LyricsQuery) -> Result<Option<Lyrics>> {
        let query = format!("{} {}", clean_title(&q.title), main_artist(&q.artist));
        let found = self.ytm("search", json!({ "query": query, "params": SONGS_FILTER })).await?;
        let Some(c) = pick(candidates(&found), q) else { return Ok(None) };
        let next = self.ytm("next", json!({ "videoId": c.video_id })).await?;
        // Onglet « Paroles » du lecteur : absent si YouTube n'a pas de paroles pour ce titre.
        let Some(browse_id) = walk(&next, "browseId").into_iter().filter_map(Value::as_str).find(|b| b.starts_with("MPLYt")).map(str::to_owned)
        else {
            return Ok(None);
        };
        let page = self.ytm("browse", json!({ "browseId": browse_id })).await?;
        Ok(walk(&page, "musicDescriptionShelfRenderer").into_iter().next().and_then(to_lyrics))
    }

    async fn ytm(&self, endpoint: &str, mut body: Value) -> Result<Value> {
        body["context"] = json!({ "client": { "clientName": "WEB_REMIX", "clientVersion": "1.20250101.01.00", "hl": "fr", "gl": "FR" } });
        Ok(self
            .http()
            .post(format!("{BASE}{endpoint}?prettyPrint=false"))
            .header(reqwest::header::ORIGIN, "https://music.youtube.com")
            .header(reqwest::header::REFERER, "https://music.youtube.com/")
            .json(&body)
            .timeout(std::time::Duration::from_secs(10))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?)
    }
}

/// Toutes les valeurs portant la clé `key`, à n'importe quelle profondeur (la structure exacte des réponses change souvent).
fn walk<'a>(v: &'a Value, key: &str) -> Vec<&'a Value> {
    let mut out = Vec::new();
    fn go<'a>(v: &'a Value, key: &str, out: &mut Vec<&'a Value>) {
        match v {
            Value::Object(m) => {
                for (k, x) in m {
                    if k == key {
                        out.push(x);
                    }
                    go(x, key, out);
                }
            }
            Value::Array(a) => a.iter().for_each(|x| go(x, key, out)),
            _ => {}
        }
    }
    go(v, key, &mut out);
    out
}

fn runs(v: Option<&Value>) -> String {
    v.and_then(|t| t.get("runs")).and_then(Value::as_array)
        .map(|r| r.iter().filter_map(|x| x.get("text").and_then(Value::as_str)).collect())
        .unwrap_or_default()
}

fn candidates(search: &Value) -> Vec<Candidate> {
    walk(search, "musicResponsiveListItemRenderer")
        .into_iter()
        .filter_map(|it| {
            let video_id = it.pointer("/playlistItemData/videoId").and_then(Value::as_str)?.to_owned();
            let cols = it.get("flexColumns").and_then(Value::as_array)?;
            let col = |i: usize| runs(cols.get(i).and_then(|c| c.pointer("/musicResponsiveListItemFlexColumnRenderer/text")));
            Some(Candidate { video_id, title: col(0), subtitle: col(1) })
        })
        .collect()
}

/// Premier résultat qui est vraiment le bon morceau : même titre, artiste crédité, durée proche (à 5 s près).
/// Rien plutôt qu'un autre morceau du même artiste.
fn pick(cands: Vec<Candidate>, q: &LyricsQuery) -> Option<Candidate> {
    let want_title = norm(&clean_title(&q.title));
    let want_artist = norm(&main_artist(&q.artist));
    cands.into_iter().take(8).find(|c| {
        let t = norm(&clean_title(&c.title));
        let title_ok = !t.is_empty() && (t == want_title || t.starts_with(&want_title) || want_title.starts_with(&t));
        let artist_ok = want_artist.is_empty() || norm(&c.subtitle).contains(&want_artist);
        let duration_ok = match (q.duration_s, duration_of(&c.subtitle)) {
            (0, _) | (_, None) => true,
            (want, Some(got)) => want.abs_diff(got) <= 5,
        };
        title_ok && artist_ok && duration_ok
    })
}

/// Dernière durée « m:ss » de la ligne « artistes • album • 3:18 ».
fn duration_of(subtitle: &str) -> Option<u64> {
    let last = subtitle.rsplit('•').next()?.trim();
    let (m, s) = last.split_once(':')?;
    Some(m.trim().parse::<u64>().ok()? * 60 + s.trim().parse::<u64>().ok()?)
}

fn to_lyrics(shelf: &Value) -> Option<Lyrics> {
    let text = runs(shelf.get("description"));
    if text.trim().is_empty() {
        return None;
    }
    let credit = runs(shelf.get("footer")); // « Source : LyricFind »
    let lines = text.lines().map(|t| LyricLine { ms: 0, text: t.to_owned() }).collect();
    Some(Lyrics { synced: false, lines, copyright: credit, source: "youtube" })
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

    fn q(title: &str, artist: &str, dur: u64) -> LyricsQuery {
        LyricsQuery { title: title.into(), artist: artist.into(), album: String::new(), duration_s: dur }
    }
    fn c(id: &str, title: &str, sub: &str) -> Candidate {
        Candidate { video_id: id.into(), title: title.into(), subtitle: sub.into() }
    }

    #[test]
    fn the_right_track_is_picked_and_lookalikes_rejected() {
        // Cas réel : la recherche « Bracelet Heuss » renvoie aussi d'autres titres de Heuss.
        let list = vec![
            c("a", "G.M.T.B", "Heuss L'enfoiré • En esprit • 3:01"),
            c("b", "Bracelet", "Heuss L'enfoiré et Timar • AVANT LA SAISIE • 3:18"),
        ];
        assert_eq!(pick(list.clone(), &q("Bracelet", "Heuss L'enfoiré, Timar", 197)).unwrap().video_id, "b");
        // Mauvaise durée (autre version) ou autre artiste : rien.
        assert!(pick(list.clone(), &q("Bracelet", "Heuss L'enfoiré", 240)).is_none());
        assert!(pick(list, &q("Bracelet", "Ninho", 197)).is_none());
        // Accents, « (feat. …) » et casse n'empêchent pas la correspondance.
        let one = vec![c("x", "Centre Commercial", "Ninho et Heuss L'enfoire • Comme prévu • 3:05")];
        assert!(pick(one, &q("Centre commercial (feat. Heuss L'enfoiré)", "Ninho", 185)).is_some());
    }

    #[test]
    fn duration_and_names_are_read_from_the_result_line() {
        assert_eq!(duration_of("Heuss L'enfoiré et Timar • AVANT LA SAISIE • 3:18"), Some(198));
        assert_eq!(duration_of("Daft Punk • Discovery"), None);
        assert_eq!(norm("Heuss L'Enfoiré"), "heusslenfoire");
        assert_eq!(main_artist("Heuss L'enfoiré, Timar"), "Heuss L'enfoiré");
        assert_eq!(clean_title("Song - Remastered 2011"), "Song");
    }

    #[test]
    fn lyrics_shelf_becomes_plain_lyrics_with_the_credit() {
        let shelf = json!({ "description": { "runs": [{ "text": "ligne un\nligne deux" }] }, "footer": { "runs": [{ "text": "Source : LyricFind" }] } });
        let l = to_lyrics(&shelf).unwrap();
        assert!(!l.synced);
        assert_eq!(l.lines.len(), 2);
        assert_eq!((l.copyright.as_str(), l.source), ("Source : LyricFind", "youtube"));
        assert!(to_lyrics(&json!({ "description": { "runs": [] } })).is_none());
    }

    /// Appel réel (réseau) : `cargo test -p dz-api ytmusic_live -- --ignored`.
    #[tokio::test]
    #[ignore]
    async fn ytmusic_live() {
        let cl = DeezerClient::new().unwrap();
        let l = cl.lyrics_ytmusic(&q("Bracelet", "Heuss L'enfoiré, Timar", 197)).await.unwrap().expect("paroles trouvées");
        assert!(l.lines.len() > 20 && l.source == "youtube");
    }
}
