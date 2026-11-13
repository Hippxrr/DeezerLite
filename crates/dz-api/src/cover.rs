//! Envoi d'une pochette de playlist à Deezer, comme le fait le site avec « Modifier la playlist » :
//! 1) jeton d'accès (JWT) obtenu à partir du cookie de connexion, sur auth.deezer.com ;
//! 2) image envoyée au serveur d'images (upload.deezer.com/v2/playlist/picture) ;
//! 3) mutation GraphQL `updatePlaylist` (pipe.deezer.com) qui associe l'image envoyée à la playlist.
//! La pochette change alors partout : application Deezer, site, autres appareils.

use reqwest::header::CONTENT_TYPE;
use serde_json::{json, Value};

use crate::{DeezerClient, DeezerError, Result};

const AUTH_URL: &str = "https://auth.deezer.com/login/arl?jo=p&rto=c&i=c";
const UPLOAD_URL: &str = "https://upload.deezer.com/v2/playlist/picture";
const PIPE_URL: &str = "https://pipe.deezer.com/api";
const UPDATE_PLAYLIST: &str =
    "mutation UpdatePlaylist($input: PlaylistUpdateMutationInput!) { updatePlaylist(input: $input) { playlist { id } } }";
const RESET_COVER: &str = "mutation ResetPlaylistCover($input: ResetDefaultPlaylistCoverInput!) { resetDefaultPlaylistCover(input: $input) { __typename ... on ResetDefaultPlaylistCoverMutationError { playlistNotFound userIsNotPlaylistOwner isLovedTracksPlaylist } } }";

impl DeezerClient {
    /// Jeton d'accès des services récents de Deezer, gardé 3 minutes pour le compte ou profil ouvert (il en vaut
    /// quelques-unes) : passer d'un mois à l'autre dans « Mon mois » ne le redemande pas à chaque fois.
    async fn access_token(&self) -> Result<String> {
        let me = self.session().await.map_or(0, |s| s.user_id);
        if let Ok(g) = self.jwt.lock() {
            if let Some((u, at, t)) = g.as_ref() {
                if *u == me && at.elapsed() < std::time::Duration::from_secs(180) {
                    return Ok(t.clone());
                }
            }
        }
        let fresh = self.new_access_token().await?;
        if let Ok(mut g) = self.jwt.lock() {
            *g = Some((me, std::time::Instant::now(), fresh.clone()));
        }
        Ok(fresh)
    }

    /// Jeton refusé par Deezer (expiré plus tôt que prévu) : oublié, le prochain appel en redemande un.
    fn forget_access_token(&self) {
        if let Ok(mut g) = self.jwt.lock() {
            *g = None;
        }
    }

    async fn new_access_token(&self) -> Result<String> {
        let v: Value = self
            .http()
            .post(AUTH_URL)
            .timeout(std::time::Duration::from_secs(15))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        v.get("jwt")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .ok_or_else(|| DeezerError::Gateway("Deezer n'a pas fourni de jeton d'accès (session expirée ?)".into()))
    }

    /// Remplace la pochette d'une playlist sur le compte Deezer par une image JPEG.
    pub async fn playlist_set_picture(&self, playlist_id: u64, jpeg: Vec<u8>) -> Result<()> {
        if jpeg.len() < 4 || jpeg[..2] != [0xFF, 0xD8] {
            return Err(DeezerError::Gateway("image invalide (JPEG attendu)".into()));
        }
        let jwt = self.access_token().await?;

        // 1) Envoi de l'image (formulaire multipart, champ « file », comme le site).
        let boundary = format!(
            "----DeezerLite{:016x}",
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(0)
        );
        let body = multipart_body(&boundary, "file", "cover.jpg", "image/jpeg", &jpeg);
        let up: Value = self
            .http()
            .post(UPLOAD_URL)
            .bearer_auth(&jwt)
            .header(CONTENT_TYPE, format!("multipart/form-data; boundary={boundary}"))
            .body(body)
            .timeout(std::time::Duration::from_secs(30))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        if let Some(e) = up.get("error").filter(|e| has_content(e)) {
            return Err(DeezerError::Gateway(format!("envoi de l'image refusé : {e}")));
        }
        let picture = up
            .get("results")
            .filter(|r| has_content(r))
            .cloned()
            .ok_or_else(|| DeezerError::Gateway("le serveur d'images n'a rien renvoyé".into()))?;

        // 2) L'image envoyée devient la pochette de la playlist.
        let r: Value = self
            .http()
            .post(PIPE_URL)
            .bearer_auth(&jwt)
            .json(&json!({
                "operationName": "UpdatePlaylist",
                "query": UPDATE_PLAYLIST,
                "variables": { "input": { "playlistId": playlist_id.to_string(), "picture": picture } }
            }))
            .timeout(std::time::Duration::from_secs(20))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        if let Some(errs) = r.get("errors").and_then(Value::as_array).filter(|a| !a.is_empty()) {
            let msg: Vec<String> = errs.iter().map(|e| e.get("message").and_then(Value::as_str).unwrap_or("erreur").to_owned()).collect();
            return Err(DeezerError::Gateway(format!("Deezer a refusé la nouvelle pochette : {}", msg.join(" ; "))));
        }
        if r.pointer("/data/updatePlaylist/playlist/id").is_none() {
            return Err(DeezerError::Gateway("Deezer n'a pas confirmé le changement de pochette".into()));
        }
        Ok(())
    }
}

/// Jour actuel (jours depuis 1970), gardé avec chaque image vérifiée bonne : les plus anciennes partent en premier.
fn today() -> String {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    (secs / 86_400).to_string()
}

/// Image vide du serveur d'images de Deezer (md5 d'un texte vide) : celle vers laquelle il redirige quand il n'a pas
/// l'image demandée.
const EMPTY_PICTURE: &str = "d41d8cd98f00b204e9800998ecf8427e";

impl DeezerClient {
    /// Pochette d'un titre que le serveur d'images n'a plus, en entier ou à certaines tailles. Deezer garde parfois
    /// sur les titres l'adresse d'une image supprimée : album dont la pochette a été changée, ou album retiré et
    /// remplacé par une autre édition. Elle s'affichait toute blanche, partout ou seulement en grand / en petit.
    /// Cherche alors, dans l'ordre : la pochette actuelle de l'album (API publique de Deezer), puis celle de l'édition
    /// qui remplace le titre ; la première complète est gardée, à la même taille. `None` : la pochette est bonne, ou
    /// rien de mieux n'a été trouvé.
    pub async fn repaired_track_cover(&self, url: &str, album_id: u64, track_id: i64) -> Option<String> {
        let old = url.split("/images/cover/").nth(1)?.split('/').next()?.to_owned();
        if old == EMPTY_PICTURE || self.known_complete(&old) {
            return None;
        }
        match self.cover_complete(&old).await {
            Some(true) => {
                // Retenue : les autres titres du même album ne revérifient pas la même image (3 requêtes chacun).
                self.remember_complete(&old);
                None
            }
            Some(false) => self.repair_incomplete(url, &old, album_id, track_id).await,
            None => None, // réseau : on ne sait pas, rien n'est tenté
        }
    }

    /// Recherche d'un remplacement pour l'image `old`, déjà connue incomplète.
    async fn repair_incomplete(&self, url: &str, old: &str, album_id: u64, track_id: i64) -> Option<String> {
        const RETRY: std::time::Duration = std::time::Duration::from_secs(30 * 60);
        let missed = |key: &str| self.cover_misses.lock().is_ok_and(|m| m.get(key).is_some_and(|at| at.elapsed() < RETRY));
        let (track_key, album_key) = (format!("{old}:{track_id}"), format!("{old}:album"));
        if missed(&track_key) {
            return None;
        }
        let old = old.to_owned();
        let timeout = std::time::Duration::from_secs(10);
        // (md5, propre à ce titre) : la pochette actuelle de l'album vaut pour tous ses titres ; celle de l'édition qui
        // remplace le titre ne vaut que pour lui (deux titres d'un même album retiré peuvent être partis vers deux
        // sorties différentes, par exemple un single et une nouvelle édition de l'album).
        let mut candidates: Vec<(String, bool)> = Vec::new();
        // Réponse incomplète (réseau, limite de requêtes) : rien n'est retenu comme « sans remplacement ».
        let mut sure = true;
        let ask_album = album_id != 0 && !missed(&album_key);
        if ask_album {
            let album: Option<Value> = match self.http().get(format!("https://api.deezer.com/album/{album_id}")).timeout(timeout).send().await {
                Ok(r) => r.json().await.ok(),
                Err(_) => None,
            };
            sure &= album.is_some();
            candidates.extend(album.as_ref().and_then(|a| a.get("md5_image")).and_then(Value::as_str).map(|m| (m.to_owned(), false)));
        }
        if track_id > 0 {
            // Album retiré : l'édition qui remplace le titre (« FALLBACK ») a sa propre pochette.
            match self.gw::<Value>("song.getListData", &serde_json::json!({ "sng_ids": [track_id] })).await {
                Ok(v) => {
                    let song = v.pointer("/data/0").or_else(|| v.get(0));
                    candidates.extend(song.and_then(|s| s.pointer("/FALLBACK/ALB_PICTURE")).and_then(Value::as_str).map(|m| (m.to_owned(), true)));
                }
                Err(_) => sure = false,
            }
        }
        let mut found = None;
        for (c, own) in candidates {
            if c.is_empty() || c == old || c == EMPTY_PICTURE {
                continue;
            }
            match self.cover_complete(&c).await {
                Some(true) => {
                    found = Some((c, own));
                    break;
                }
                Some(false) => {}
                None => {
                    sure = false;
                    break;
                }
            }
        }
        let Some((md5, own)) = found else {
            if sure {
                if let Ok(mut m) = self.cover_misses.lock() {
                    m.insert(track_key, std::time::Instant::now());
                    if ask_album {
                        m.insert(album_key, std::time::Instant::now());
                    }
                }
            }
            return None;
        };
        let md5 = md5.as_str();
        if let Ok(mut fixes) = self.cover_fixes.lock() {
            // Clé : « t:<titre> » pour une pochette propre à ce titre, sinon l'ancienne image (tous ses titres).
            let key = if own { format!("t:{track_id}") } else { old.clone() };
            fixes.insert(key, md5.to_owned());
            // Gardée sur le disque : au prochain lancement, listes et lecteur ont la bonne pochette tout de suite.
            self.save_cover_fixes(&mut fixes);
        }
        Some(url.replacen(&old, md5, 1))
    }

    fn save_cover_fixes(&self, fixes: &mut std::collections::HashMap<String, String>) {
        // Images vérifiées bonnes : une entrée par pochette vue, le fichier grossissait sans fin. Au-delà de 20 000, on
        // garde les 15 000 plus récentes (les autres seront simplement revérifiées si elles réapparaissent).
        const MAX_OK: usize = 20_000;
        if fixes.keys().filter(|k| k.starts_with("ok:")).count() > MAX_OK {
            let mut ok: Vec<(u64, String)> =
                fixes.iter().filter(|(k, _)| k.starts_with("ok:")).map(|(k, v)| (v.parse().unwrap_or(0), k.clone())).collect();
            ok.sort_unstable();
            let drop = ok.len() - 15_000;
            for (_, k) in ok.into_iter().take(drop) {
                fixes.remove(&k);
            }
        }
        let Some(path) = self.cover_fixes_file.lock().ok().and_then(|p| p.clone()) else { return };
        let Ok(bytes) = serde_json::to_vec(fixes) else { return };
        // Écrit hors du verrou et hors des deux fils du cœur (partagés avec le lecteur) : jusqu'à ~1 Mo. Une écriture
        // dépassée par une plus récente avant son tour est sautée.
        static LATEST: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        static WRITING: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let seq = LATEST.fetch_add(1, std::sync::atomic::Ordering::AcqRel) + 1;
        let write = move || {
            let _guard = WRITING.lock();
            if LATEST.load(std::sync::atomic::Ordering::Acquire) != seq {
                return;
            }
            let tmp = path.with_extension("tmp");
            if std::fs::write(&tmp, bytes).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
        };
        match tokio::runtime::Handle::try_current() {
            Ok(rt) => drop(rt.spawn_blocking(write)),
            Err(_) => write(),
        }
    }

    /// Image déjà vérifiée complète (retenue sur le disque, voir `check_covers`).
    fn known_complete(&self, md5: &str) -> bool {
        self.cover_fixes.lock().is_ok_and(|f| f.contains_key(&format!("ok:{md5}")))
    }

    /// Retenue en mémoire seulement : écrite avec la prochaine sauvegarde du fichier. Avant, chaque image vérifiée bonne
    /// réécrivait tout `covers.json` (jusqu'à ~1 Mo), sur les fils partagés avec le lecteur.
    fn remember_complete(&self, md5: &str) {
        if let Ok(mut fixes) = self.cover_fixes.lock() {
            fixes.insert(format!("ok:{md5}"), today());
        }
    }

    /// Réparation déjà connue pour ce titre (la sienne, sinon celle de son image).
    fn known_cover_fix(&self, id: i64, url: &str, md5: &str) -> Option<String> {
        let fixes = self.cover_fixes.lock().ok()?;
        let new = fixes.get(&format!("t:{id}")).or_else(|| fixes.get(md5))?;
        Some(url.replacen(md5, new, 1))
    }

    /// Vérifie en arrière-plan les pochettes d'une page (titre, adresse, album) et renvoie celles à remplacer (titre,
    /// nouvelle adresse). Chaque image n'est vérifiée qu'une fois : une image complète est retenue sur le disque
    /// (« ok:<md5> »), et les titres d'un même album partagent la vérification.
    pub async fn check_covers(&self, items: Vec<(i64, String, u64)>) -> Vec<(i64, String)> {
        use futures_util::{stream, StreamExt};
        let mut out = Vec::new();
        let mut todo: std::collections::HashMap<String, Vec<(i64, String, u64)>> = std::collections::HashMap::new();
        for (id, url, album) in items {
            let Some(md5) = url.split("/images/cover/").nth(1).and_then(|r| r.split('/').next()).map(str::to_owned) else { continue };
            if md5 == EMPTY_PICTURE {
                continue;
            }
            if let Some(fixed) = self.known_cover_fix(id, &url, &md5) {
                if fixed != url {
                    out.push((id, fixed));
                }
                continue;
            }
            let good = self.cover_fixes.lock().is_ok_and(|f| f.contains_key(&format!("ok:{md5}")));
            if !good {
                todo.entry(md5).or_default().push((id, url, album));
            }
        }
        let checked: Vec<(String, Vec<(i64, String, u64)>, Option<bool>)> = stream::iter(todo)
            .map(|(md5, list)| async move {
                let complete = self.cover_complete(&md5).await;
                (md5, list, complete)
            })
            .buffer_unordered(6)
            .collect()
            .await;
        // Une vérification sans réponse (réseau faible, portail Wi-Fi) : aucune réparation cette fois. Avant, chaque
        // erreur réseau passait pour une pochette cassée et lançait des réparations en série (minutes de radio), à chaque
        // visite de la page.
        let unsure = checked.iter().any(|(_, _, complete)| complete.is_none());
        let mut learned = false;
        for (md5, list, complete) in checked {
            if complete == Some(true) {
                if let Ok(mut fixes) = self.cover_fixes.lock() {
                    fixes.insert(format!("ok:{md5}"), today());
                    learned = true;
                }
                continue;
            }
            if complete.is_none() || unsure {
                continue;
            }
            for (id, url, album) in list {
                let fixed = match self.known_cover_fix(id, &url, &md5) {
                    Some(f) => Some(f),
                    None => self.repair_incomplete(&url, &md5, album, id).await,
                };
                out.extend(fixed.filter(|f| *f != url).map(|f| (id, f)));
            }
        }
        if learned {
            if let Ok(mut fixes) = self.cover_fixes.lock() {
                self.save_cover_fixes(&mut fixes);
            }
        }
        out
    }

    /// Comme `repaired_track_cover`, sans le titre : seulement la pochette actuelle de l'album.
    pub async fn repaired_cover(&self, url: &str, album_id: u64) -> Option<String> {
        self.repaired_track_cover(url, album_id, 0).await
    }

    /// La pochette existe aux tailles qu'affichent les apps (petite, moyenne, grande) : le serveur d'images ne
    /// redirige vers son image vide pour aucune. `None` : pas de réponse fiable (réseau, portail Wi-Fi, serveur).
    async fn cover_complete(&self, md5: &str) -> Option<bool> {
        let timeout = std::time::Duration::from_secs(10);
        for size in [120, 250, 1000] {
            let url = format!("https://cdn-images.dzcdn.net/images/cover/{md5}/{size}x{size}-000000-80-0-0.jpg");
            let r = self.http().head(&url).timeout(timeout).send().await.ok()?;
            if r.url().as_str().contains(EMPTY_PICTURE) {
                return Some(false);
            }
            // Portail Wi-Fi (redirigé ailleurs) ou erreur du serveur : on ne sait pas.
            if !r.status().is_success() || !r.url().host_str().is_some_and(|h| h.ends_with("dzcdn.net")) {
                return None;
            }
        }
        Some(true)
    }

    /// Fichier des pochettes réparées (dans les données de l'app) : relu tout de suite, puis complété à chaque
    /// réparation. Sans lui, elles ne sont gardées que tant que l'app reste ouverte.
    pub fn use_cover_fixes_file(&self, path: std::path::PathBuf) {
        let saved: std::collections::HashMap<String, String> =
            std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        if let Ok(mut fixes) = self.cover_fixes.lock() {
            for (old, new) in saved {
                fixes.entry(old).or_insert(new);
            }
        }
        if let Ok(mut p) = self.cover_fixes_file.lock() {
            *p = Some(path);
        }
    }

    /// Remet les pochettes déjà réparées dans une liste de titres (aucune requête : seulement ce qui est connu).
    /// À appliquer à toute fiche reçue de Deezer : elle porte encore l'ancienne adresse, supprimée.
    pub fn apply_cover_fixes(&self, tracks: &mut [crate::TrackInfo]) {
        let Ok(fixes) = self.cover_fixes.lock() else { return };
        if fixes.is_empty() {
            return;
        }
        for t in tracks {
            let Some(url) = t.cover_url.as_mut() else { continue };
            let Some(old) = url.split("/images/cover/").nth(1).and_then(|r| r.split('/').next()).map(str::to_owned) else { continue };
            // D'abord la pochette propre à ce titre, puis celle de son album.
            if let Some(new) = fixes.get(&format!("t:{}", t.id)).or_else(|| fixes.get(&old)) {
                if *new != old {
                    *url = url.replacen(&old, new, 1);
                }
            }
        }
    }

    /// Requête GraphQL sur les services récents de Deezer (pipe.deezer.com), au nom du compte connecté. Erreur si
    /// Deezer en renvoie une ; sinon le contenu de `data`.
    pub async fn pipe(&self, operation: &str, query: &str, variables: Value) -> Result<Value> {
        let body = json!({ "operationName": operation, "query": query, "variables": variables });
        let mut retried = false;
        let r: Value = loop {
            let jwt = self.access_token().await?;
            let resp = self.http().post(PIPE_URL).bearer_auth(&jwt).json(&body).timeout(std::time::Duration::from_secs(20)).send().await?;
            // Jeton expiré : un nouveau, une seule fois.
            if resp.status() == reqwest::StatusCode::UNAUTHORIZED && !retried {
                retried = true;
                self.forget_access_token();
                continue;
            }
            break resp.error_for_status()?.json().await?;
        };
        if let Some(errs) = r.get("errors").and_then(Value::as_array).filter(|a| !a.is_empty()) {
            let msg: Vec<String> = errs.iter().map(|e| e.get("message").and_then(Value::as_str).unwrap_or("erreur").to_owned()).collect();
            return Err(DeezerError::Gateway(msg.join(" ; ")));
        }
        Ok(r.get("data").cloned().unwrap_or(Value::Null))
    }

    /// Remet la pochette d'origine (générée par Deezer) d'une playlist, comme « Pochette par défaut » sur le site.
    pub async fn playlist_reset_picture(&self, playlist_id: u64) -> Result<()> {
        let jwt = self.access_token().await?;
        let r: Value = self
            .http()
            .post(PIPE_URL)
            .bearer_auth(&jwt)
            .json(&json!({
                "operationName": "ResetPlaylistCover",
                "query": RESET_COVER,
                "variables": { "input": { "playlistId": playlist_id.to_string() } }
            }))
            .timeout(std::time::Duration::from_secs(20))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        if let Some(errs) = r.get("errors").and_then(Value::as_array).filter(|a| !a.is_empty()) {
            let msg: Vec<String> = errs.iter().map(|e| e.get("message").and_then(Value::as_str).unwrap_or("erreur").to_owned()).collect();
            return Err(DeezerError::Gateway(format!("Deezer a refusé : {}", msg.join(" ; "))));
        }
        reset_outcome(r.pointer("/data/resetDefaultPlaylistCover").unwrap_or(&Value::Null))
    }
}

/// Réponse de `resetDefaultPlaylistCover` : succès, ou la raison précise du refus.
fn reset_outcome(v: &Value) -> Result<()> {
    if v.get("__typename").and_then(Value::as_str) == Some("ResetDefaultPlaylistCoverMutationOutput") {
        return Ok(());
    }
    let flag = |k: &str| v.get(k).and_then(Value::as_bool).unwrap_or(false);
    let why = if flag("isLovedTracksPlaylist") {
        "Deezer ne permet pas de changer la pochette des Titres aimés"
    } else if flag("userIsNotPlaylistOwner") {
        "cette playlist ne t'appartient pas"
    } else if flag("playlistNotFound") {
        "playlist introuvable chez Deezer"
    } else {
        "Deezer n'a pas confirmé le retour à la pochette d'origine"
    };
    Err(DeezerError::Gateway(why.into()))
}

/// `{}`, `[]`, `""` et `null` ne comptent pas comme une erreur ni comme un résultat.
fn has_content(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Object(o) => !o.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::String(s) => !s.is_empty(),
        _ => true,
    }
}

/// Corps multipart/form-data avec un seul fichier.
fn multipart_body(boundary: &str, field: &str, filename: &str, mime: &str, data: &[u8]) -> Vec<u8> {
    let mut b = Vec::with_capacity(data.len() + 256);
    b.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"; filename=\"{filename}\"\r\nContent-Type: {mime}\r\n\r\n").as_bytes());
    b.extend_from_slice(data);
    b.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    b
}

#[cfg(test)]
mod tests {
    use super::*;

    /// covers.json : au-delà de 20 000 images vérifiées bonnes, seules les 15 000 plus récentes restent ; les vraies
    /// réparations ne sont jamais retirées.
    #[test]
    fn verified_covers_are_capped_oldest_first() {
        let c = DeezerClient::new().unwrap();
        let mut fixes = std::collections::HashMap::new();
        for i in 0..20_001u64 {
            fixes.insert(format!("ok:{i}"), i.to_string());
        }
        fixes.insert("abc".into(), "def".into());
        c.save_cover_fixes(&mut fixes);
        assert_eq!(fixes.keys().filter(|k| k.starts_with("ok:")).count(), 15_000);
        assert!(!fixes.contains_key("ok:0") && fixes.contains_key("ok:20000"));
        assert_eq!(fixes.get("abc").map(String::as_str), Some("def"));
    }

    #[test]
    fn multipart_body_is_well_formed() {
        let b = multipart_body("XYZ", "file", "cover.jpg", "image/jpeg", &[0xFF, 0xD8, 1, 2]);
        let head = b"--XYZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"cover.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n";
        assert!(b.starts_with(head));
        assert_eq!(&b[head.len()..head.len() + 4], &[0xFF, 0xD8, 1, 2]);
        assert!(b.ends_with(b"\r\n--XYZ--\r\n"));
    }

    #[test]
    fn empty_error_blocks_are_not_errors() {
        assert!(!has_content(&json!({})));
        assert!(!has_content(&json!([])));
        assert!(!has_content(&json!("")));
        assert!(has_content(&json!({ "code": 1 })));
        assert!(has_content(&json!("abc123")));
    }

    #[test]
    fn reset_outcome_reads_success_and_reasons() {
        assert!(reset_outcome(&json!({ "__typename": "ResetDefaultPlaylistCoverMutationOutput" })).is_ok());
        let e = reset_outcome(&json!({ "__typename": "ResetDefaultPlaylistCoverMutationError", "isLovedTracksPlaylist": true })).unwrap_err();
        assert!(e.to_string().contains("Titres aimés"), "{e}");
        let e = reset_outcome(&json!({ "__typename": "ResetDefaultPlaylistCoverMutationError", "userIsNotPlaylistOwner": true })).unwrap_err();
        assert!(e.to_string().contains("appartient"), "{e}");
        assert!(reset_outcome(&Value::Null).is_err());
    }

    #[tokio::test]
    async fn non_jpeg_data_is_rejected_before_any_request() {
        let c = DeezerClient::new().unwrap();
        assert!(c.playlist_set_picture(1, vec![1, 2, 3, 4]).await.is_err());
    }
}
