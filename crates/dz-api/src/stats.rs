//! « Mon mois » : le récap mensuel de Deezer (My Deezer Month) — temps d'écoute, artistes, titres et genres les plus
//! écoutés. Ce sont les statistiques officielles du compte (ou du profil ouvert), lues comme le fait l'app Deezer.

use serde::Serialize;
use serde_json::{json, Value};

use crate::{DeezerClient, Result};

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct StatArtist {
    pub id: u64,
    pub name: String,
    pub picture_url: Option<String>,
    pub minutes: u32,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct StatTrack {
    pub id: i64,
    pub title: String,
    pub artist: String,
    pub album_id: u64,
    pub cover_url: Option<String>,
    pub streams: u32,
    pub minutes: u32,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct StatGenre {
    pub name: String,
    pub minutes: u32,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct MonthStats {
    pub year: u32,
    /// 1 à 12.
    pub month: u32,
    pub minutes: u32,
    /// Moyenne des utilisateurs de Deezer, pour comparer.
    pub average_minutes: u32,
    pub previous_minutes: Option<u32>,
    pub streams: u32,
    pub tracks: u32,
    pub artists: u32,
    pub discovered: u32,
    pub top_artists: Vec<StatArtist>,
    pub top_tracks: Vec<StatTrack>,
    pub top_genres: Vec<StatGenre>,
    /// Moment où tu écoutes le plus (« morning », « afternoon », « evening », « night »).
    pub period: Option<String>,
    /// Mois disponibles (année, mois), du plus récent au plus ancien : pour passer de l'un à l'autre.
    pub months: Vec<(u32, u32)>,
}

const MONTH_STATS: &str = "fragment S on PrivateUserMonthlyUsageStatistics { year month nbStreams listenedMinutes globalAverageListenedMinutes listenedMinutesPreviousMonth nbStreamedArtists nbStreamedTracks nbDiscoveredTracks \
mostStreamedArtists(first: 5) { listenedMinutes artist { id name picture { urls(pictureRequest: {width: 264, height: 264}) } } } \
mostStreamedTracks(first: 10) { nbStreams listenedMinutes track { id title album { id cover { urls(pictureRequest: {width: 264, height: 264}) } } contributors(first: 1) { edges { node { ... on Artist { name } } } } } } \
mostStreamedGenres(first: 3) { genre listenedMinutes } mostStreamedPeriods(first: 1) { period listenedMinutes } } \
query MonthStats($m: Int!, $y: Int!, $last: Boolean!) { me { usageStats { monthsPreviews(first: 24) { month year isMonthAvailable } \
lastMonth @include(if: $last) { ...S } month(month: $m, year: $y) @skip(if: $last) { ...S } } } }";

/// Une écoute de l'historique officiel de Deezer (celles qui comptent dans les statistiques).
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct RecentListen {
    pub track_id: i64,
    pub title: String,
    pub artist: String,
    pub cover_url: Option<String>,
    /// Début de l'écoute (secondes Unix).
    pub listened_at: u64,
}

impl DeezerClient {
    /// Les `n` dernières écoutes de l'historique officiel du compte ou du profil ouvert, de la plus récente à la plus
    /// ancienne : pour vérifier que les écoutes sont bien comptées par Deezer.
    pub async fn recent_listens(&self, n: u32) -> Result<Vec<RecentListen>> {
        let me = self.ensure_session().await?.user_id;
        let v: Value = self
            .gw("deezer.pageProfile", &json!({ "user_id": me.to_string(), "tab": "history", "nb": n }))
            .await?;
        Ok(parse_history(&v))
    }

    /// Récap d'un mois (`Some((année, mois))`), ou du dernier disponible. `None` : pas encore de récap (il faut au
    /// moins un quart d'heure d'écoute dans le mois).
    pub async fn month_stats(&self, which: Option<(u32, u32)>) -> Result<Option<MonthStats>> {
        let (y, m) = which.unwrap_or((0, 0));
        let data = self.pipe("MonthStats", MONTH_STATS, json!({ "m": m, "y": y, "last": which.is_none() })).await?;
        Ok(parse_month_stats(&data))
    }
}

fn parse_month_stats(data: &Value) -> Option<MonthStats> {
    let usage = data.pointer("/me/usageStats")?;
    let s = usage.get("lastMonth").filter(|v| !v.is_null()).or_else(|| usage.get("month")).filter(|v| !v.is_null())?;
    let n = |v: &Value, k: &str| v.get(k).and_then(Value::as_u64).unwrap_or(0) as u32;
    let id = |v: &Value| v.get("id").and_then(|i| i.as_str().and_then(|s| s.parse().ok()).or_else(|| i.as_u64()));
    let url = |v: Option<&Value>| v.and_then(|p| p.pointer("/urls/0")).and_then(Value::as_str).map(str::to_owned);
    let list = |k: &str| s.get(k).and_then(Value::as_array).cloned().unwrap_or_default();

    let top_artists = list("mostStreamedArtists")
        .iter()
        .filter_map(|e| {
            let a = e.get("artist")?;
            Some(StatArtist {
                id: id(a)?,
                name: a.get("name")?.as_str()?.to_owned(),
                picture_url: url(a.get("picture")),
                minutes: n(e, "listenedMinutes"),
            })
        })
        .collect();
    let top_tracks = list("mostStreamedTracks")
        .iter()
        .filter_map(|e| {
            let t = e.get("track")?;
            Some(StatTrack {
                id: id(t)? as i64,
                title: t.get("title")?.as_str()?.to_owned(),
                artist: t.pointer("/contributors/edges/0/node/name").and_then(Value::as_str).unwrap_or_default().to_owned(),
                album_id: t.get("album").and_then(id).unwrap_or(0),
                cover_url: url(t.pointer("/album/cover")),
                streams: n(e, "nbStreams"),
                minutes: n(e, "listenedMinutes"),
            })
        })
        .collect();
    let top_genres = list("mostStreamedGenres")
        .iter()
        .filter_map(|e| Some(StatGenre { name: e.get("genre")?.as_str()?.to_owned(), minutes: n(e, "listenedMinutes") }))
        .collect();
    let months = usage
        .get("monthsPreviews")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter(|p| p.get("isMonthAvailable").and_then(Value::as_bool) == Some(true))
                .map(|p| (n(p, "year"), n(p, "month")))
                .filter(|&(y, m)| y > 0 && (1..=12).contains(&m))
                .collect()
        })
        .unwrap_or_default();
    Some(MonthStats {
        year: n(s, "year"),
        month: n(s, "month"),
        minutes: n(s, "listenedMinutes"),
        average_minutes: n(s, "globalAverageListenedMinutes"),
        previous_minutes: s.get("listenedMinutesPreviousMonth").and_then(Value::as_u64).map(|v| v as u32),
        streams: n(s, "nbStreams"),
        tracks: n(s, "nbStreamedTracks"),
        artists: n(s, "nbStreamedArtists"),
        discovered: n(s, "nbDiscoveredTracks"),
        top_artists,
        top_tracks,
        top_genres,
        period: s.pointer("/mostStreamedPeriods/0/period").and_then(Value::as_str).map(str::to_owned),
        months,
    })
}

fn parse_history(v: &Value) -> Vec<RecentListen> {
    let text = |x: &Value, k: &str| x.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
    v.pointer("/TAB/history/data")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|x| {
                    let id = x.get("SNG_ID").and_then(|i| i.as_str().and_then(|s| s.parse().ok()).or_else(|| i.as_i64()))?;
                    let pic = text(x, "ALB_PICTURE");
                    Some(RecentListen {
                        track_id: id,
                        title: text(x, "SNG_TITLE"),
                        artist: text(x, "ART_NAME"),
                        cover_url: (!pic.is_empty()).then(|| format!("https://cdn-images.dzcdn.net/images/cover/{pic}/120x120-000000-80-0-0.jpg")),
                        listened_at: x.get("TS").and_then(|t| t.as_u64().or_else(|| t.as_str().and_then(|s| s.trim().parse().ok()))).unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn month_stats_are_read_from_the_pipe_answer() {
        let v = json!({ "me": { "usageStats": {
            "monthsPreviews": [
                { "month": 10, "year": 2026, "isMonthAvailable": true },
                { "month": 11, "year": 2026, "isMonthAvailable": false },
                { "month": 9, "year": 2026, "isMonthAvailable": true }
            ],
            "lastMonth": {
                "year": 2026, "month": 10, "nbStreams": 1357, "listenedMinutes": 3660, "globalAverageListenedMinutes": 1740,
                "listenedMinutesPreviousMonth": null, "nbStreamedArtists": 190, "nbStreamedTracks": 648, "nbDiscoveredTracks": 110,
                "mostStreamedArtists": [ { "listenedMinutes": 407, "artist": { "id": "13918545", "name": "Tiakola", "picture": { "urls": ["https://a/1.jpg"] } } } ],
                "mostStreamedTracks": [ { "nbStreams": 33, "listenedMinutes": 175, "track": { "id": "4332328782", "title": "PEACE & LOVE",
                    "album": { "id": "77", "cover": { "urls": ["https://c/1.jpg"] } }, "contributors": { "edges": [ { "node": { "name": "TIF" } } ] } } } ],
                "mostStreamedGenres": [ { "genre": "Rap & Hip Hop", "listenedMinutes": 3467 } ],
                "mostStreamedPeriods": [ { "period": "afternoon", "listenedMinutes": 1281 } ]
            }
        } } });
        let s = parse_month_stats(&v).unwrap();
        assert_eq!((s.year, s.month, s.minutes, s.average_minutes, s.previous_minutes), (2026, 10, 3660, 1740, None));
        assert_eq!(s.top_artists[0], StatArtist { id: 13918545, name: "Tiakola".into(), picture_url: Some("https://a/1.jpg".into()), minutes: 407 });
        assert_eq!((s.top_tracks[0].id, s.top_tracks[0].artist.as_str(), s.top_tracks[0].album_id), (4332328782, "TIF", 77));
        assert_eq!(s.top_genres[0].name, "Rap & Hip Hop");
        assert_eq!(s.period.as_deref(), Some("afternoon"));
        assert_eq!(s.months, vec![(2026, 10), (2026, 9)]);
        // Historique : titre, artiste, pochette et heure d'écoute.
        let h = json!({ "TAB": { "history": { "data": [
            { "SNG_ID": "4359260502", "SNG_TITLE": "Wetin Day", "ART_NAME": "Zed", "ALB_PICTURE": "abc", "TS": 1793727840 },
            { "SNG_ID": 7, "SNG_TITLE": "TS en texte", "ART_NAME": "", "ALB_PICTURE": "", "TS": "1793727000" },
            { "SNG_TITLE": "sans identifiant" }
        ] } } });
        assert_eq!(parse_history(&h), vec![RecentListen {
            track_id: 4359260502, title: "Wetin Day".into(), artist: "Zed".into(),
            cover_url: Some("https://cdn-images.dzcdn.net/images/cover/abc/120x120-000000-80-0-0.jpg".into()), listened_at: 1793727840,
        }, RecentListen { track_id: 7, title: "TS en texte".into(), artist: String::new(), cover_url: None, listened_at: 1793727000 }]);
        // Pas encore de récap : rien.
        assert_eq!(parse_month_stats(&json!({ "me": { "usageStats": { "monthsPreviews": [], "lastMonth": null } } })), None);
    }
}
