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

    /// Supprime un MP3 du compte et d'abord de partout où il est sur le compte : Deezer, lui, ne le retire que de la
    /// liste des MP3 (il restait dans les titres aimés et les playlists). Retiré des titres aimés s'il y est, puis de
    /// chaque playlist de l'utilisateur qui le contient (4 regardées à la fois). Renvoie ces playlists.
    pub async fn delete_personal_song_everywhere(&self, id: i64) -> Result<Vec<u64>> {
        use futures_util::{stream, StreamExt};
        // Liste illisible : on tente quand même (sans effet s'il n'y est pas).
        if self.loved_tracks().await.map_or(true, |loved| loved.iter().any(|t| t.id == id)) {
            let _ = self.unlike_track(id).await;
        }
        let loved = self.session().await.map_or(0, |s| s.loved_playlist_id);
        let mine: Vec<u64> = self
            .user_playlists()
            .await
            .unwrap_or_default()
            .into_iter()
            .filter(|c| c.kind == "playlist" && c.owned && c.id != loved)
            .map(|c| c.id)
            .collect();
        let cleaned: Vec<u64> = stream::iter(mine)
            .map(|pid| async move {
                let has = self.collection("playlist", pid).await.is_ok_and(|c| c.tracks.iter().any(|t| t.id == id));
                (has && self.playlist_remove(pid, id).await.is_ok()).then_some(pid)
            })
            .buffer_unordered(4)
            .filter_map(|pid| async move { pid })
            .collect()
            .await;
        self.delete_personal_song(id).await?;
        Ok(cleaned)
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

/// Titre, artiste et album lus dans l'étiquette ID3v2 d'un MP3 (pour préremplir la fenêtre d'import), s'il y en a une.
pub fn read_mp3_tags(mp3: &[u8]) -> (Option<String>, Option<String>, Option<String>) {
    let end = id3_len(mp3).min(mp3.len());
    if end == 0 {
        return (None, None, None);
    }
    let v3 = mp3[3] >= 3;
    let (mut title, mut artist, mut album) = (None, None, None);
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
        if v3 {
            match id {
                b"TIT2" => title = decode_text(body),
                b"TPE1" => artist = decode_text(body),
                b"TALB" => album = decode_text(body),
                _ => {}
            }
        }
        at = start + len;
    }
    (title, artist, album)
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

/// Une trame MPEG audio : longueur en octets, échantillons, fréquence, et de quoi reconnaître les suivantes.
#[derive(Clone, Copy)]
struct MpegFrame {
    len: usize,
    samples: u64,
    rate: u64,
    /// Version, couche et fréquence : les mêmes pour toutes les trames d'un fichier (évite les faux débuts de trame).
    kind: u8,
    /// Taille des infos de côté (position d'un en-tête Xing / Info dans la première trame).
    side: usize,
}

fn mpeg_frame(h: &[u8]) -> Option<MpegFrame> {
    let [a, b, c, d] = *h.get(..4)? else { return None };
    if a != 0xFF || b & 0xE0 != 0xE0 {
        return None;
    }
    let version = (b >> 3) & 3; // 0 : MPEG 2.5, 2 : MPEG 2, 3 : MPEG 1
    let layer = (b >> 1) & 3; // 1 : couche III, 2 : II, 3 : I
    let (bi, si) = ((c >> 4) as usize, ((c >> 2) & 3) as usize);
    if version == 1 || layer == 0 || bi == 0 || bi == 15 || si == 3 {
        return None;
    }
    let v1 = version == 3;
    const B: [[u16; 14]; 5] = [
        [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448], // MPEG 1, couche I
        [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],    // MPEG 1, couche II
        [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],     // MPEG 1, couche III
        [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],    // MPEG 2 / 2.5, couche I
        [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],         // MPEG 2 / 2.5, couches II et III
    ];
    let row = match (v1, layer) {
        (true, 3) => 0,
        (true, 2) => 1,
        (true, _) => 2,
        (false, 3) => 3,
        _ => 4,
    };
    let bitrate = B[row][bi - 1] as usize * 1000;
    let rate = [44100, 48000, 32000][si] >> if v1 { 0 } else if version == 2 { 1 } else { 2 };
    let pad = ((c >> 1) & 1) as usize;
    let (len, samples) = match layer {
        3 => ((12 * bitrate / rate + pad) * 4, 384),
        2 => (144 * bitrate / rate + pad, 1152),
        _ if v1 => (144 * bitrate / rate + pad, 1152),
        _ => (72 * bitrate / rate + pad, 576),
    };
    let mono = d >> 6 == 3;
    let side = match (v1, mono) {
        (true, true) => 17,
        (true, false) => 32,
        (false, true) => 9,
        (false, false) => 17,
    };
    Some(MpegFrame { len, samples, rate: rate as u64, kind: b & 0xFE | (c & 0x0C), side })
}

/// Vraie trame à `at` : son en-tête est valable et la trame suivante (s'il y en a une) est du même genre.
fn frame_at(data: &[u8], at: usize, kind: Option<u8>) -> Option<MpegFrame> {
    let f = mpeg_frame(data.get(at..)?)?;
    if kind.is_some_and(|k| k != f.kind) || at + f.len > data.len() {
        return None;
    }
    match data.get(at + f.len..at + f.len + 4) {
        Some(next) if kind.is_none() => mpeg_frame(next).filter(|n| n.kind == f.kind).map(|_| f),
        _ => Some(f),
    }
}

/// Garde de `start_ms` à `end_ms` (`None` : jusqu'à la fin) d'un MP3. Coupé entre deux trames entières : aucun bout de
/// trame, ni étiquette (ID3, APE), ni en-tête Xing / Info (il donnerait l'ancienne durée) ne reste. `None` si le fichier
/// n'a pas de son MPEG lisible ou si rien ne reste.
pub fn cut_mp3(mp3: &[u8], start_ms: u64, end_ms: Option<u64>) -> Option<Vec<u8>> {
    let mut at = id3_len(mp3).min(mp3.len());
    // Première vraie trame (des octets parasites peuvent précéder).
    let first = loop {
        if at + 4 > mp3.len() {
            return None;
        }
        if let Some(f) = frame_at(mp3, at, None) {
            break f;
        }
        at += 1;
    };
    // En-tête Xing / Info (LAME) ou VBRI : une trame sans son qui décrit l'ancien fichier entier.
    let head = &mp3[at..at + first.len];
    let info = [4 + first.side, 36].iter().any(|&o| matches!(head.get(o..o + 4), Some(b"Xing" | b"Info" | b"VBRI")));
    if info {
        at += first.len;
    }
    let mut out = Vec::new();
    let (mut count, mut bitrates) = (0u32, std::collections::BTreeSet::new());
    let mut elapsed = 0u64; // échantillons déjà passés
    while at + 4 <= mp3.len() {
        let Some(f) = frame_at(mp3, at, Some(first.kind)) else {
            // Étiquette de fin (ID3v1 « TAG », APE…) ou octets abîmés : on cherche la trame suivante, sinon c'est fini.
            match (at + 1..mp3.len().saturating_sub(3)).find(|&i| frame_at(mp3, i, Some(first.kind)).is_some()) {
                Some(next) if !mp3[at..].starts_with(b"TAG") && !mp3[at..].starts_with(b"APETAGEX") => {
                    at = next;
                    continue;
                }
                _ => break,
            }
        };
        let ms = elapsed * 1000 / f.rate;
        if end_ms.is_some_and(|end| ms >= end) {
            break;
        }
        if ms >= start_ms {
            out.extend_from_slice(&mp3[at..at + f.len]);
            count += 1;
            bitrates.insert(mp3[at + 2] >> 4);
        }
        elapsed += f.samples;
        at += f.len;
    }
    if out.is_empty() {
        return None;
    }
    Some(match info_frame(&out, count, bitrates.len() > 1) {
        Some(mut head) => {
            head.extend_from_slice(&out);
            head
        }
        None => out,
    })
}

/// Nouvel en-tête Xing (débit variable) ou Info (constant) : nombre de trames et taille du son coupé, pour que la durée
/// soit exacte partout (sans lui, celle d'un débit variable est estimée, souvent fausse). Une trame muette, comme LAME.
fn info_frame(audio: &[u8], frames: u32, vbr: bool) -> Option<Vec<u8>> {
    let h = [audio[0], audio[1] | 1, audio[2], audio[3]]; // sans somme de contrôle (CRC)
    let f = mpeg_frame(&h)?;
    if f.len < 4 + f.side + 16 {
        return None; // trame trop petite pour l'en-tête (très bas débit) : on s'en passe
    }
    let mut out = vec![0u8; f.len];
    out[..4].copy_from_slice(&h);
    let at = 4 + f.side;
    out[at..at + 4].copy_from_slice(if vbr { b"Xing" } else { b"Info" });
    out[at + 4..at + 8].copy_from_slice(&3u32.to_be_bytes()); // champs présents : trames et octets
    out[at + 8..at + 12].copy_from_slice(&frames.to_be_bytes());
    out[at + 12..at + 16].copy_from_slice(&((f.len + audio.len()) as u32).to_be_bytes());
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// MP3 factice : MPEG 1 couche III, 128 kbit/s, 44,1 kHz (trames de 417 octets, 1152 échantillons ≈ 26,1 ms),
    /// numérotées dans leur 5e octet.
    fn fake_mp3(frames: usize, xing: bool) -> Vec<u8> {
        let mut out = tag_mp3(b"", "Titre", "", "", None);
        let mut frame = |n: u8, xing: bool| {
            let mut f = vec![0u8; 417];
            f[..4].copy_from_slice(&[0xFF, 0xFB, 0x90, 0x00]);
            f[4] = n;
            if xing {
                f[36..40].copy_from_slice(b"Info");
            }
            out.extend_from_slice(&f);
        };
        if xing {
            frame(255, true);
        }
        for n in 0..frames {
            frame(n as u8, false);
        }
        out.extend_from_slice(b"TAG");
        out.extend_from_slice(&[0u8; 125]);
        out
    }

    #[test]
    fn cut_keeps_whole_frames_of_the_chosen_part_only() {
        let mp3 = fake_mp3(100, true);
        let cut = cut_mp3(&mp3, 1000, Some(2000)).unwrap();
        // Nouvel en-tête Info (1re trame, muette), puis les trames qui commencent entre 1 s et 2 s : n° 39 (1018 ms)
        // à 76 (1985 ms).
        assert_eq!(cut.len(), 39 * 417, "trames entières seulement");
        let (info, audio) = cut.split_at(417);
        assert_eq!(&info[36..40], b"Info");
        assert_eq!(info[44..48], 38u32.to_be_bytes(), "nombre de trames du son coupé");
        assert_eq!(info[48..52], (39u32 * 417).to_be_bytes(), "taille du fichier coupé");
        let numbers: Vec<u8> = audio.chunks(417).map(|f| f[4]).collect();
        assert_eq!(numbers, (39..=76).collect::<Vec<u8>>());
        assert!(audio.chunks(417).all(|f| f[..4] == [0xFF, 0xFB, 0x90, 0x00]));
        assert_eq!(cut.windows(4).filter(|w| w == b"Info").count(), 1, "l'ancien en-tête est retiré");
        assert!(!cut.windows(3).any(|w| w == b"TAG" || w == b"ID3"));
        // Jusqu'à la fin : toutes les trames depuis le début choisi, sans l'étiquette de fin.
        assert_eq!(cut_mp3(&mp3, 0, None).unwrap().len(), 101 * 417);
        assert_eq!(cut_mp3(&fake_mp3(10, false), 0, None).unwrap().len(), 11 * 417);
        // Rien de lisible, ou rien dans la partie choisie.
        assert!(cut_mp3(b"pas un mp3", 0, None).is_none());
        assert!(cut_mp3(&mp3, 10_000, None).is_none());
    }

    #[test]
    fn tags_replace_the_old_ones_and_are_read_back() {
        // Ancienne étiquette (à retirer), puis le son.
        let old = tag_mp3(b"\xFF\xFBson", "Ancien", "Vieux", "", None);
        let jpeg = [0xFF, 0xD8, 0xFF, 0xD9];
        let out = tag_mp3(&old, "Mon titre é 🎵", "Moi", "Mes MP3", Some(&jpeg));
        assert!(out.ends_with(b"\xFF\xFBson"), "le son reste intact");
        assert_eq!(out.windows(4).filter(|w| w == b"TIT2").count(), 1, "une seule étiquette");
        assert!(out.windows(10).any(|w| w == b"image/jpeg"));
        assert_eq!(read_mp3_tags(&out), (Some("Mon titre é 🎵".into()), Some("Moi".into()), Some("Mes MP3".into())));
        assert_eq!(read_mp3_tags(b"\xFF\xFBson"), (None, None, None));
    }

    #[test]
    fn id3_length_counts_header_and_footer() {
        let t = tag_mp3(b"x", "a", "", "", None);
        assert_eq!(id3_len(&t), t.len() - 1);
    }
}
