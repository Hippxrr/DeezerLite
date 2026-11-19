//! Test seul dans son fichier, donc dans son propre processus : il compte les fichiers temporaires du processus. Avant,
//! il était avec les autres tests, et leurs flux ouverts en parallèle le faisaient parfois échouer.

use std::io::{Read, Seek, SeekFrom, Write};
use std::net::TcpListener;
use std::sync::Arc;
use std::time::Duration;

use dz_stream::{Passthrough, StreamReader};

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
    // Sous iOS et macOS, le nom du fichier est effacé dès sa création (voir `open_temp`) : il n'est visible que sous Windows.
    // Avant, ce test échouait forcément sur iPhone et Mac.
    if cfg!(windows) {
        assert!(leftover_temp_files() >= 1, "le tampon doit être un fichier temporaire pendant la lecture");
    }

    drop(r);
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(leftover_temp_files(), 0, "le fichier temporaire est supprimé à la fermeture");
}
