//! Joue de vrais WAV générés sur le périphérique par défaut (ignoré si aucun périphérique).

use std::fs::File;
use std::io::Write;
use std::time::{Duration, Instant};

use dz_audio::{Engine, EngineEvent};
use tokio::sync::mpsc::unbounded_channel;

fn write_wav(path: &std::path::Path, rate: u32, secs: f32, freq: f32) {
    let n = (rate as f32 * secs) as u32;
    let mut f = File::create(path).unwrap();
    let data_len = n * 4; // stéréo 16 bits
    f.write_all(b"RIFF").unwrap();
    f.write_all(&(36 + data_len).to_le_bytes()).unwrap();
    f.write_all(b"WAVEfmt ").unwrap();
    f.write_all(&16u32.to_le_bytes()).unwrap();
    f.write_all(&1u16.to_le_bytes()).unwrap();
    f.write_all(&2u16.to_le_bytes()).unwrap();
    f.write_all(&rate.to_le_bytes()).unwrap();
    f.write_all(&(rate * 4).to_le_bytes()).unwrap();
    f.write_all(&4u16.to_le_bytes()).unwrap();
    f.write_all(&16u16.to_le_bytes()).unwrap();
    f.write_all(b"data").unwrap();
    f.write_all(&data_len.to_le_bytes()).unwrap();
    for i in 0..n {
        let v = ((i as f32 / rate as f32 * freq * std::f32::consts::TAU).sin() * 3000.0) as i16;
        f.write_all(&v.to_le_bytes()).unwrap();
        f.write_all(&v.to_le_bytes()).unwrap();
    }
}

async fn wait_for(
    rx: &mut tokio::sync::mpsc::UnboundedReceiver<EngineEvent>,
    secs: u64,
    pred: impl Fn(&EngineEvent) -> bool,
) -> Option<EngineEvent> {
    let deadline = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < deadline {
        if let Ok(Some(ev)) = tokio::time::timeout(Duration::from_millis(100), rx.recv()).await {
            if let EngineEvent::Error { msg, .. } = &ev {
                eprintln!("événement erreur: {msg}");
            }
            if pred(&ev) {
                return Some(ev);
            }
        }
    }
    None
}

#[tokio::test]
async fn plays_seeks_and_chains_gaplessly() {
    let dir = std::env::temp_dir();
    let (a, b) = (dir.join("dz_a.wav"), dir.join("dz_b.wav"));
    write_wav(&a, 44_100, 2.0, 440.0);
    write_wav(&b, 22_050, 1.0, 660.0); // fréquence différente => resampling

    let (tx, mut rx) = unbounded_channel();
    let eng = Engine::start(tx);
    eng.load(1, Box::new(File::open(&a).unwrap()), Some("wav".into()));

    let first = wait_for(&mut rx, 5, |e| matches!(e, EngineEvent::TrackStarted { .. } | EngineEvent::Error { .. })).await;
    match first {
        Some(EngineEvent::TrackStarted { id: 1 }) => {}
        other => {
            eprintln!("pas de périphérique audio exploitable ({other:?}) : test ignoré");
            return;
        }
    }
    assert_eq!(eng.shared.duration_ms.load(std::sync::atomic::Ordering::Relaxed), 2000);

    // La position doit avancer.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let p1 = eng.shared.position_ms.load(std::sync::atomic::Ordering::Relaxed);
    assert!((300..900).contains(&p1), "position après 0,5 s = {p1} ms");

    // Seek à 1,5 s puis enchaînement gapless sur B.
    eng.seek(1500);
    // Dès l'annonce du saut, la position partagée est déjà la nouvelle (les fenêtres la reçoivent sans attendre le point suivant).
    assert!(wait_for(&mut rx, 2, |e| matches!(e, EngineEvent::StateChanged)).await.is_some(), "saut non annoncé");
    let at_notice = eng.shared.position_ms.load(std::sync::atomic::Ordering::Relaxed);
    assert!((1450..1700).contains(&at_notice), "position au moment de l'annonce du saut = {at_notice} ms");
    eng.queue_next(2, Box::new(File::open(&b).unwrap()), Some("wav".into()));
    tokio::time::sleep(Duration::from_millis(200)).await;
    let p2 = eng.shared.position_ms.load(std::sync::atomic::Ordering::Relaxed);
    assert!((1450..1900).contains(&p2), "position après seek = {p2} ms");

    let started_b = wait_for(&mut rx, 5, |e| matches!(e, EngineEvent::TrackStarted { id: 2 })).await;
    assert!(started_b.is_some(), "transition gapless vers la piste 2 absente");
    let fin = wait_for(&mut rx, 5, |e| matches!(e, EngineEvent::Finished { id: 2 })).await;
    assert!(fin.is_some(), "fin de lecture non signalée");
}

/// En pause, le flux de sortie est arrêté : la position ne bouge plus, un saut reste possible,
/// et la reprise repart de l'endroit choisi.
#[tokio::test]
async fn pause_stops_output_and_resume_continues_after_seek() {
    use std::sync::atomic::Ordering;
    let path = std::env::temp_dir().join("dz_pause.wav");
    write_wav(&path, 44_100, 4.0, 440.0);

    let (tx, mut rx) = unbounded_channel();
    let eng = Engine::start(tx);
    eng.load(7, Box::new(File::open(&path).unwrap()), Some("wav".into()));
    match wait_for(&mut rx, 5, |e| matches!(e, EngineEvent::TrackStarted { .. } | EngineEvent::Error { .. })).await {
        Some(EngineEvent::TrackStarted { id: 7 }) => {}
        other => {
            eprintln!("pas de périphérique audio exploitable ({other:?}) : test ignoré");
            return;
        }
    }
    tokio::time::sleep(Duration::from_millis(400)).await;

    eng.pause();
    tokio::time::sleep(Duration::from_millis(200)).await;
    let paused_at = eng.shared.position_ms.load(Ordering::Relaxed);
    tokio::time::sleep(Duration::from_millis(500)).await;
    let still = eng.shared.position_ms.load(Ordering::Relaxed);
    assert!(still.abs_diff(paused_at) < 60, "la position avance en pause : {paused_at} -> {still} ms");
    assert!(!eng.shared.playing.load(Ordering::Relaxed));

    // Saut pendant la pause (le vidage du tampon passe par le flux, relancé le temps de le faire).
    let t0 = Instant::now();
    eng.seek(2500);
    assert!(wait_for(&mut rx, 2, |e| matches!(e, EngineEvent::StateChanged)).await.is_some(), "saut non annoncé");
    assert!(t0.elapsed() < Duration::from_millis(800), "saut en pause trop lent : {:?}", t0.elapsed());
    tokio::time::sleep(Duration::from_millis(300)).await;
    let after_seek = eng.shared.position_ms.load(Ordering::Relaxed);
    assert!((2450..2700).contains(&after_seek), "position après saut en pause = {after_seek} ms");

    eng.resume();
    tokio::time::sleep(Duration::from_millis(500)).await;
    let resumed = eng.shared.position_ms.load(Ordering::Relaxed);
    assert!((2700..3300).contains(&resumed), "position 0,5 s après la reprise = {resumed} ms");
    assert!(eng.shared.playing.load(Ordering::Relaxed));
    assert!(wait_for(&mut rx, 5, |e| matches!(e, EngineEvent::Finished { id: 7 })).await.is_some(), "fin non signalée après la reprise");
}
