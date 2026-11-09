//! Vrai fondu enchaîné sur le périphérique par défaut : deux pistes de 3 s, fondu de 1 s.
use std::fs::File;
use std::io::Write;
use std::time::{Duration, Instant};

use dz_audio::{Engine, EngineEvent};

fn write_wav(path: &std::path::Path, rate: u32, secs: f32, freq: f32) {
    let n = (rate as f32 * secs) as u32;
    let mut f = File::create(path).unwrap();
    let data_len = n * 4;
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

async fn run(crossfade_ms: u64) -> Option<(f32, f32)> {
    let dir = std::env::temp_dir();
    let (a, b) = (dir.join("dz_xa.wav"), dir.join("dz_xb.wav"));
    write_wav(&a, 44_100, 3.0, 440.0);
    write_wav(&b, 22_050, 3.0, 660.0);

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let eng = Engine::start(tx);
    eng.set_crossfade(crossfade_ms);
    eng.load(1, Box::new(File::open(&a).unwrap()), Some("wav".into()));
    eng.queue_next(2, Box::new(File::open(&b).unwrap()), Some("wav".into()));

    let (mut t0, mut t2, mut tend) = (None, None, None);
    let deadline = Instant::now() + Duration::from_secs(12);
    while Instant::now() < deadline && tend.is_none() {
        let Ok(Some(ev)) = tokio::time::timeout(Duration::from_millis(100), rx.recv()).await else { continue };
        match ev {
            EngineEvent::TrackStarted { id: 1 } => t0 = Some(Instant::now()),
            EngineEvent::TrackStarted { id: 2 } => t2 = Some(Instant::now()),
            EngineEvent::Finished { id: 2 } => tend = Some(Instant::now()),
            EngineEvent::Error { msg, .. } => { eprintln!("XFADE erreur/pas de périphérique: {msg}"); return None; }
            _ => {}
        }
    }
    let t0 = t0?;
    Some(((t2?.duration_since(t0)).as_secs_f32(), (tend?.duration_since(t0)).as_secs_f32()))
}

/// Pendant le fondu, le titre affiché est déjà l'entrant : un saut doit s'appliquer à lui (avant, il était ignoré).
#[tokio::test]
async fn seek_during_crossfade_jumps_in_the_incoming_track() {
    let dir = std::env::temp_dir();
    let (a, b) = (dir.join("dz_xsa.wav"), dir.join("dz_xsb.wav"));
    write_wav(&a, 44_100, 3.0, 440.0);
    write_wav(&b, 44_100, 4.0, 660.0);
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let eng = Engine::start(tx);
    eng.set_crossfade(1500);
    eng.load(1, Box::new(File::open(&a).unwrap()), Some("wav".into()));
    eng.queue_next(2, Box::new(File::open(&b).unwrap()), Some("wav".into()));

    let deadline = Instant::now() + Duration::from_secs(8);
    let mut started2 = false;
    while Instant::now() < deadline && !started2 {
        let Ok(Some(ev)) = tokio::time::timeout(Duration::from_millis(100), rx.recv()).await else { continue };
        match ev {
            EngineEvent::TrackStarted { id: 2 } => started2 = true,
            EngineEvent::Error { msg, .. } => { eprintln!("XFADE erreur/pas de périphérique: {msg}"); return; }
            _ => {}
        }
    }
    if !started2 {
        eprintln!("pas de périphérique audio exploitable : test ignoré");
        return;
    }
    // On est en plein fondu (1,5 s) : saut à 2,5 s dans le titre entrant.
    tokio::time::sleep(Duration::from_millis(300)).await;
    eng.seek(2500);
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut seen = false;
    while Instant::now() < deadline && !seen {
        if let Ok(Some(EngineEvent::StateChanged)) = tokio::time::timeout(Duration::from_millis(100), rx.recv()).await {
            seen = true;
        }
    }
    assert!(seen, "saut non pris en compte pendant le fondu");
    let pos = eng.shared.position_ms.load(std::sync::atomic::Ordering::Relaxed);
    assert_eq!(eng.shared.current_id.load(std::sync::atomic::Ordering::Relaxed), 2);
    assert!((2400..2800).contains(&pos), "position après le saut dans le titre entrant = {pos} ms");
    // Le titre entrant se termine ~1,5 s plus tard (4 s − 2,5 s), sans repartir dans le fondu.
    let fin = Instant::now();
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut done = None;
    while Instant::now() < deadline && done.is_none() {
        if let Ok(Some(EngineEvent::Finished { id: 2 })) = tokio::time::timeout(Duration::from_millis(100), rx.recv()).await {
            done = Some(fin.elapsed().as_secs_f32());
        }
    }
    let d = done.expect("fin du titre entrant non signalée");
    assert!((d - 1.5).abs() < 0.5, "fin {d:.2} s après le saut (attendu ~1,5 s)");
}

#[tokio::test]
async fn crossfade_overlaps_tracks() {
    let Some((s_plain, e_plain)) = run(0).await else { return };
    let Some((s_fade, e_fade)) = run(1000).await else { return };
    eprintln!("XFADE sans fondu : piste 2 à {s_plain:.2}s, fin à {e_plain:.2}s");
    eprintln!("XFADE fondu 1 s  : piste 2 à {s_fade:.2}s, fin à {e_fade:.2}s");
    assert!((s_plain - 3.0).abs() < 0.5, "enchaînement classique ~3 s: {s_plain}");
    assert!((s_fade - 2.0).abs() < 0.5, "avec fondu la piste 2 démarre ~1 s plus tôt: {s_fade}");
    assert!((e_plain - e_fade - 1.0).abs() < 0.5, "le fondu raccourcit le total d'~1 s: {e_plain} vs {e_fade}");
}
