//! MP3 importés sur le compte Deezer (« Mes MP3 »), comme sur le site : liste, envoi, modification, suppression.
//! Mêmes appels que le site (`personal_song.*`, envoi sur `upload.deezer.com`). Les MP3 importés ont des identifiants
//! négatifs ; ils se lisent comme les autres titres (format `MP3_MISC`).

use serde::Deserialize;
use serde_json::{json, Value};

use crate::{DeezerClient, DeezerError, RawTrack, Result, TrackInfo};

impl DeezerClient {
    /// Tous les MP3 importés du compte, par pages de 1 000.
    pub async fn personal_songs(&self) -> Result<Vec<TrackInfo>> {
        #[derive(Deserialize)]
        struct Page {
            #[serde(default)]
            data: Vec<RawTrack>,
        }
        const NB: usize = 1000;
        let mut all = Vec::new();
        loop {
            let page: Page = self.gw("personal_song.getList", &json!({ "start": all.len(), "nb": NB })).await?;
            let n = page.data.len();
            all.extend(page.data.into_iter().map(TrackInfo::from));
            if n < NB {
                return Ok(all);
            }
        }
    }

    /// Envoie un MP3 sur le compte (formulaire multipart, champ « file », comme le site). Renvoie la réponse du serveur.
    pub async fn upload_personal_song(&self, file_name: &str, mp3: Vec<u8>) -> Result<Value> {
        let session = self.session().await.ok_or_else(|| DeezerError::Gateway("session Deezer fermée".into()))?;
        let sid = session.sid.ok_or_else(|| DeezerError::Gateway("session Deezer sans identifiant".into()))?;
        // Nom du fichier : sans « & » (le site les retire), et toujours en .mp3.
        let name: String = file_name.chars().filter(|c| *c != '&' && !c.is_control()).collect();
        let name = if name.to_lowercase().ends_with(".mp3") { name } else { format!("{name}.mp3") };
        let mut url = url::Url::parse("https://upload.deezer.com/").expect("adresse fixe");
        url.query_pairs_mut()
            .append_pair("sid", &sid)
            .append_pair("id", &session.user_id.to_string())
            .append_pair("resize", "1")
            .append_pair("directory", "user")
            .append_pair("type", "audio")
            .append_pair("referer", "FR")
            .append_pair("file", &name);
        let boundary = format!(
            "----DeezerLite{:016x}",
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(0)
        );
        let body = crate::cover::multipart_body(&boundary, "file", &name, "audio/mpeg", &mp3);
        let answer: Value = self
            .http()
            .post(url)
            .header(reqwest::header::CONTENT_TYPE, format!("multipart/form-data; boundary={boundary}"))
            .body(body)
            .timeout(std::time::Duration::from_secs(300))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        if let Some(e) = answer.get("error").filter(|e| crate::cover::has_content(e)) {
            return Err(DeezerError::Gateway(format!("envoi du MP3 refusé : {e}")));
        }
        Ok(answer.get("results").cloned().unwrap_or(Value::Null))
    }

    /// Change le titre, l'artiste et l'album d'un MP3 importé (les trois sont obligatoires pour Deezer).
    pub async fn update_personal_song(&self, id: i64, title: &str, artist: &str, album: &str) -> Result<()> {
        let data = json!({ "SNG_TITLE": title, "ART_NAME": artist, "ALB_TITLE": album });
        let ok: Value = self.gw("personal_song.update", &json!({ "upload_id": id, "data": data })).await?;
        if ok == Value::Bool(false) {
            return Err(DeezerError::Gateway("Deezer a refusé la modification".into()));
        }
        Ok(())
    }

    /// Supprime un MP3 importé du compte.
    pub async fn delete_personal_song(&self, id: i64) -> Result<()> {
        let _: Value = self.gw("personal_song.delete", &json!({ "upload_id": id })).await?;
        Ok(())
    }
}

/// MP3 prêt à envoyer : titre, artiste, album et pochette (JPEG) écrits dans son étiquette ID3 (v2.3, lue partout),
/// à la place de celle d'origine. Le son n'est pas touché.
pub fn tag_mp3(mp3: &[u8], title: &str, artist: &str, album: &str, cover_jpeg: Option<&[u8]>) -> Vec<u8> {
    let audio = &mp3[id3_len(mp3).min(mp3.len())..];
    let mut frames = Vec::new();
    for (id, text) in [(b"TIT2", title), (b"TPE1", artist), (b"TALB", album)] {
        if text.is_empty() {
            continue;
        }
        // Texte en UTF-16 avec marque d'ordre (encodage 1) : accents et emoji conservés.
        let mut body = vec![1u8, 0xFF, 0xFE];
        body.extend(text.encode_utf16().flat_map(u16::to_le_bytes));
        frame(&mut frames, id, &body);
    }
    if let Some(jpeg) = cover_jpeg {
        // Encodage 0, type « image/jpeg », image de type 3 (pochette avant), description vide.
        let mut body = vec![0u8];
        body.extend_from_slice(b"image/jpeg\0");
        body.extend_from_slice(&[3, 0]);
        body.extend_from_slice(jpeg);
        frame(&mut frames, b"APIC", &body);
    }
    let size = frames.len() as u32;
    let mut out = Vec::with_capacity(10 + frames.len() + audio.len());
    out.extend_from_slice(b"ID3\x03\x00\x00");
    // Taille « synchsafe » : 7 bits par octet.
    out.extend_from_slice(&[(size >> 21) as u8 & 0x7F, (size >> 14) as u8 & 0x7F, (size >> 7) as u8 & 0x7F, size as u8 & 0x7F]);
    out.extend_from_slice(&frames);
    out.extend_from_slice(audio);
    out
}

fn frame(out: &mut Vec<u8>, id: &[u8; 4], body: &[u8]) {
    out.extend_from_slice(id);
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    out.extend_from_slice(&[0, 0]);
    out.extend_from_slice(body);
}

/// Longueur de l'étiquette ID3v2 au début du fichier (0 s'il n'y en a pas).
fn id3_len(mp3: &[u8]) -> usize {
    if mp3.len() < 10 || &mp3[..3] != b"ID3" {
        return 0;
    }
    let size = mp3[6..10].iter().fold(0usize, |acc, b| (acc << 7) | (*b as usize & 0x7F));
    let footer = if mp3[5] & 0x10 != 0 { 10 } else { 0 };
    10 + size + footer
}

/// Titre et artiste lus dans l'étiquette ID3v2 d'un MP3 (pour préremplir la fenêtre d'import), s'il y en a une.
pub fn read_mp3_tags(mp3: &[u8]) -> (Option<String>, Option<String>) {
    let end = id3_len(mp3).min(mp3.len());
    if end == 0 {
        return (None, None);
    }
    let v3 = mp3[3] >= 3;
    let (mut title, mut artist) = (None, None);
    let mut at = 10;
    while at + 10 <= end {
        let id = &mp3[at..at + 4];
        if id[0] == 0 {
            break;
        }
        let raw = [mp3[at + 4], mp3[at + 5], mp3[at + 6], mp3[at + 7]];
        let len = if mp3[3] >= 4 {
            raw.iter().fold(0usize, |acc, b| (acc << 7) | (*b as usize & 0x7F))
        } else {
            u32::from_be_bytes(raw) as usize
        };
        let start = at + 10;
        let Some(body) = mp3.get(start..start + len) else { break };
        if v3 && (id == b"TIT2" || id == b"TPE1") {
            let text = decode_text(body);
            if id == b"TIT2" { title = text } else { artist = text }
        }
        at = start + len;
    }
    (title, artist)
}

fn decode_text(body: &[u8]) -> Option<String> {
    let (enc, rest) = body.split_first()?;
    let text = match enc {
        1 | 2 => {
            let (le, data) = match rest {
                [0xFF, 0xFE, d @ ..] => (true, d),
                [0xFE, 0xFF, d @ ..] => (false, d),
                d => (*enc == 1, d),
            };
            let units: Vec<u16> = data.chunks_exact(2).map(|c| if le { u16::from_le_bytes([c[0], c[1]]) } else { u16::from_be_bytes([c[0], c[1]]) }).collect();
            String::from_utf16_lossy(&units)
        }
        3 => String::from_utf8_lossy(rest).into_owned(),
        _ => rest.iter().map(|&b| b as char).collect(),
    };
    let t = text.trim_matches(char::from(0)).trim().to_owned();
    (!t.is_empty()).then_some(t)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_replace_the_old_ones_and_are_read_back() {
        // Ancienne étiquette (à retirer), puis le son.
        let old = tag_mp3(b"\xFF\xFBson", "Ancien", "Vieux", "", None);
        let jpeg = [0xFF, 0xD8, 0xFF, 0xD9];
        let out = tag_mp3(&old, "Mon titre é 🎵", "Moi", "Mes MP3", Some(&jpeg));
        assert!(out.ends_with(b"\xFF\xFBson"), "le son reste intact");
        assert_eq!(out.windows(4).filter(|w| w == b"TIT2").count(), 1, "une seule étiquette");
        assert!(out.windows(10).any(|w| w == b"image/jpeg"));
        assert_eq!(read_mp3_tags(&out), (Some("Mon titre é 🎵".into()), Some("Moi".into())));
        assert_eq!(read_mp3_tags(b"\xFF\xFBson"), (None, None));
    }

    #[test]
    fn id3_length_counts_header_and_footer() {
        let t = tag_mp3(b"x", "a", "", "", None);
        assert_eq!(id3_len(&t), t.len() - 1);
    }
}
