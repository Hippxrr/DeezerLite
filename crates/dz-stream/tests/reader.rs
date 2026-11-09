use std::io::{Read, Seek, SeekFrom, Write};
use std::net::TcpListener;
use std::sync::Arc;
use std::time::Duration;

use dz_stream::{ChunkDecryptor, Passthrough, StreamReader, CHUNK};
use symphonia::core::io::MediaSource;

/// Serveur HTTP minimal : attend 300 ms avant d'envoyer les en-têtes (comme un CDN lent).
fn serve(body: Vec<u8>) -> String {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    std::thread::spawn(move || {
        let (mut s, _) = l.accept().unwrap();
        let mut buf = [0u8; 1024];
        let _ = s.read(&mut buf);
        std::thread::sleep(Duration::from_millis(300));
        let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
        s.write_all(head.as_bytes()).unwrap();
        for part in body.chunks(1500) {
            s.write_all(part).unwrap();
            std::thread::sleep(Duration::from_millis(5));
        }
    });
    format!("http://{addr}/t.mp3")
}

struct Xor;
impl ChunkDecryptor for Xor {
    fn decrypt_chunk(&self, _i: u64, c: &mut [u8]) {
        c.iter_mut().for_each(|b| *b ^= 0xFF);
    }
}

fn data() -> Vec<u8> {
    (0..10_000u32).map(|i| (i % 251) as u8).collect()
}

#[test]
fn reports_seekable_only_once_headers_arrive_and_reads_everything() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let url = serve(data());
    let mut r = StreamReader::spawn(rt.handle(), reqwest::Client::new(), url, Arc::new(Passthrough));

    // Appelé immédiatement, avant les en-têtes : doit attendre, pas répondre « non seekable ».
    assert!(r.is_seekable());
    assert_eq!(r.byte_len(), Some(10_000));

    let mut out = Vec::new();
    r.read_to_end(&mut out).unwrap();
    assert_eq!(out, data());

    // Seek arrière puis relecture.
    r.seek(SeekFrom::Start(1234)).unwrap();
    let mut b = [0u8; 4];
    r.read_exact(&mut b).unwrap();
    assert_eq!(b.to_vec(), data()[1234..1238].to_vec());
    assert_eq!(r.seek(SeekFrom::End(-10)).unwrap(), 9_990);
}

#[test]
fn decrypts_full_chunks_only() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let url = serve(data());
    let mut r = StreamReader::spawn(rt.handle(), reqwest::Client::new(), url, Arc::new(Xor));
    let mut out = Vec::new();
    r.read_to_end(&mut out).unwrap();
    let full = 10_000 / CHUNK * CHUNK;
    assert!(out[..full].iter().zip(data()).all(|(a, b)| *a == b ^ 0xFF));
    assert_eq!(&out[full..], &data()[full..]); // dernier bloc partiel laissé tel quel
}

/// Serveur qui coupe la connexion au milieu du titre, puis accepte la reprise (`Range`) sur une seconde connexion.
fn serve_with_cut(body: Vec<u8>, cut_at: usize) -> (String, std::sync::mpsc::Receiver<String>) {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        {
            let (mut s, _) = l.accept().unwrap();
            let mut buf = [0u8; 1024];
            let _ = s.read(&mut buf);
            let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
            s.write_all(head.as_bytes()).unwrap();
            s.write_all(&body[..cut_at]).unwrap();
            let _ = s.flush();
        } // connexion fermée avant la fin annoncée
        let (mut s, _) = l.accept().unwrap();
        let mut buf = [0u8; 2048];
        let n = s.read(&mut buf).unwrap();
        let req = String::from_utf8_lossy(&buf[..n]).to_string();
        let range = req.lines().find_map(|l| l.to_ascii_lowercase().strip_prefix("range: bytes=").map(|r| r.trim_end_matches('-').to_string())).unwrap_or_default();
        let _ = tx.send(range.clone());
        let from: usize = range.parse().unwrap();
        let head = format!("HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len() - from);
        s.write_all(head.as_bytes()).unwrap();
        s.write_all(&body[from..]).unwrap();
    });
    (format!("http://{addr}/t.flac"), rx)
}

#[test]
fn network_cut_resumes_where_it_stopped_and_keeps_decrypting_the_right_blocks() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let body: Vec<u8> = (0..20_000u32).map(|i| (i % 253) as u8).collect();
    let (url, ranges) = serve_with_cut(body.clone(), 5_000);
    let mut r = StreamReader::spawn(rt.handle(), reqwest::Client::new(), url, Arc::new(Xor));
    let mut out = Vec::new();
    r.read_to_end(&mut out).unwrap();
    // Reprise au dernier bloc complet reçu (4096), pas au début.
    assert_eq!(ranges.recv_timeout(Duration::from_secs(5)).unwrap(), "4096");
    assert_eq!(out.len(), body.len(), "titre complet malgré la coupure");
    let full = body.len() / CHUNK * CHUNK;
    assert!(out[..full].iter().zip(&body).all(|(a, b)| *a == b ^ 0xFF), "chaque bloc déchiffré avec le bon numéro");
    assert_eq!(&out[full..], &body[full..]);
}

fn leftover_temp_files() -> usize {
    let prefix = format!("deezer-lite-stream-{}-", std::process::id());
    std::fs::read_dir(std::env::temp_dir())
        .map(|d| d.filter_map(Result::ok).filter(|e| e.file_name().to_string_lossy().starts_with(&prefix)).count())
        .unwrap_or(0)
}

#[test]
fn big_stream_is_buffered_on_disk_with_random_access_and_cleans_up() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let body: Vec<u8> = (0..700_000u32).map(|i| (i.wrapping_mul(31) % 251) as u8).collect();
    let url = serve(body.clone());
    let mut r = StreamReader::spawn(rt.handle(), reqwest::Client::new(), url, Arc::new(Passthrough));

    // Accès aléatoire pendant que le téléchargement se poursuit.
    for &pos in &[600_000u64, 12_345, 400_001, 0, 699_990] {
        r.seek(SeekFrom::Start(pos)).unwrap();
        let mut buf = [0u8; 8];
        r.read_exact(&mut buf).unwrap();
        assert_eq!(buf.to_vec(), body[pos as usize..pos as usize + 8].to_vec(), "octets à la position {pos}");
    }
    assert_eq!(r.buffered(), 700_000);
    assert!(leftover_temp_files() >= 1, "le tampon doit être un fichier temporaire pendant la lecture");

    drop(r);
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(leftover_temp_files(), 0, "le fichier temporaire est supprimé à la fermeture");
}

/// Serveur qui envoie les en-têtes (ou pas) puis un début de titre, et reste muet ensuite (réseau figé).
fn serve_stalled(send_headers: bool) -> String {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    std::thread::spawn(move || {
        let (mut s, _) = l.accept().unwrap();
        let mut buf = [0u8; 1024];
        let _ = s.read(&mut buf);
        if send_headers {
            let _ = s.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n");
            let _ = s.write_all(&[7u8; 3000]);
            let _ = s.flush();
        }
        std::thread::sleep(Duration::from_secs(60));
    });
    format!("http://{addr}/t.mp3")
}

#[test]
fn cancel_unblocks_a_read_stuck_on_a_frozen_network() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let mut r = StreamReader::spawn(rt.handle(), reqwest::Client::new(), serve_stalled(true), Arc::new(Passthrough));
    let cancel = r.cancel_handle();
    let t = std::thread::spawn(move || {
        let mut b = vec![0u8; 50_000];
        let start = std::time::Instant::now();
        let res = r.read_exact(&mut b);
        (res, start.elapsed())
    });
    std::thread::sleep(Duration::from_millis(400));
    cancel.cancel();
    let (res, took) = t.join().unwrap();
    let err = res.expect_err("la lecture doit échouer une fois annulée");
    assert!(err.to_string().contains(dz_stream::CANCELLED), "{err}");
    assert!(took < Duration::from_secs(3), "rendu la main en {took:?}");
}

#[test]
fn cancel_unblocks_the_wait_for_headers() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let r = StreamReader::spawn(rt.handle(), reqwest::Client::new(), serve_stalled(false), Arc::new(Passthrough));
    let cancel = r.cancel_handle();
    let t = std::thread::spawn(move || {
        let start = std::time::Instant::now();
        let _ = r.is_seekable();
        start.elapsed()
    });
    std::thread::sleep(Duration::from_millis(300));
    cancel.cancel();
    assert!(t.join().unwrap() < Duration::from_secs(3));
}

#[test]
fn cancel_after_drop_is_harmless() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let r = StreamReader::spawn(rt.handle(), reqwest::Client::new(), serve_stalled(true), Arc::new(Passthrough));
    let cancel = r.cancel_handle();
    drop(r);
    cancel.cancel();
    cancel.clone().cancel();
}

/// Serveur qui coupe au milieu, puis ignore la demande de reprise (`Range`) et renvoie tout le fichier (réponse 200).
fn serve_with_cut_ignoring_range(body: Vec<u8>, cut_at: usize) -> String {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    std::thread::spawn(move || {
        {
            let (mut s, _) = l.accept().unwrap();
            let mut buf = [0u8; 1024];
            let _ = s.read(&mut buf);
            let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
            s.write_all(head.as_bytes()).unwrap();
            s.write_all(&body[..cut_at]).unwrap();
            let _ = s.flush();
        }
        let (mut s, _) = l.accept().unwrap();
        let mut buf = [0u8; 2048];
        let _ = s.read(&mut buf);
        let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
        s.write_all(head.as_bytes()).unwrap();
        for part in body.chunks(1000) {
            s.write_all(part).unwrap();
        }
    });
    format!("http://{addr}/t.mp3")
}

#[test]
fn network_cut_resumes_even_when_the_server_ignores_range() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let body: Vec<u8> = (0..20_000u32).map(|i| (i % 249) as u8).collect();
    let url = serve_with_cut_ignoring_range(body.clone(), 5_000);
    let mut r = StreamReader::spawn(rt.handle(), reqwest::Client::new(), url, Arc::new(Xor));
    let mut out = Vec::new();
    r.read_to_end(&mut out).expect("titre complet malgré un serveur qui ignore la reprise");
    assert_eq!(out.len(), body.len());
    let full = body.len() / CHUNK * CHUNK;
    assert!(out[..full].iter().zip(&body).all(|(a, b)| *a == b ^ 0xFF), "chaque bloc déchiffré avec le bon numéro");
    assert_eq!(&out[full..], &body[full..]);
}
