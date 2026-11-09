//! Rapport d'écoute, comme l'app officielle à la fin de chaque titre : l'écoute rejoint l'historique du compte (ou du
//! profil ouvert), les statistiques (My Deezer Month, récap de l'année), « Écoutés récemment » et ce que Flow apprend.

use serde_json::{json, Value};

use crate::{DeezerClient, DeezerError, Result};

impl DeezerClient {
    /// Signale l'écoute du titre `track_id`, commencée à `started_at` (secondes Unix) et entendue `listened_s` secondes,
    /// dans le format reçu (`MP3_128`, `MP3_320`, `FLAC`).
    pub async fn log_listen(&self, track_id: i64, format: &str, started_at: u64, listened_s: u64) -> Result<()> {
        let body = json!({
            "params": {
                "__type__": "ListenData",
                "timestamp": started_at,
                "ts_listen": started_at,
                "type": 1,
                "lt": listened_s,
                "media": { "id": track_id.to_string(), "type": "song", "format": format },
                "stat": { "seek": 0, "pause": 0, "sync": 1 },
                "payload": {},
            }
        });
        match self.gw::<Value>("log.listen", &body).await {
            // Deezer ne renvoie rien d'utile : seule une erreur compte.
            Ok(_) | Err(DeezerError::EmptyResults) => Ok(()),
            Err(e) => Err(e),
        }
    }
}
