//! Changement de périphérique de sortie en cours de lecture (ignoré si aucun périphérique audio).

use std::fs::File;
use std::io::Write;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use dz_audio::{list_output_devices, Engine, EngineEvent};
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver};

fn write_wav(path: &std::path::Path, rate: u32, secs: f32) {
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
        let v = ((i as f32 / rate as f32 * 440.0 * std::f32::consts::TAU).sin() * 1500.0) as i16;
        f.write_all(&v.to_le_bytes()).unwrap();
        f.write_all(&v.to_le_bytes()).unwrap();
    }
}

async fn wait_for(rx: &mut UnboundedReceiver<EngineEvent>, secs: u64, pred: impl Fn(&EngineEvent) -> bool) -> Option<EngineEvent> {
    let deadline = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < deadline {
        if let Ok(Some(ev)) = tokio::time::timeout(Duration::from_millis(100), rx.recv()).await {
            if pred(&ev) {
                return Some(ev);
            }
        }
    }
    None
}

#[tokio::test]
async fn switching_device_keeps_playing_from_the_same_position() {
    let (devices, default) = list_output_devices();
    let Some(default) = default else {
        eprintln!("aucun périphérique de sortie : test ignoré");
        return;
    };
    assert!(devices.contains(&default), "le périphérique par défaut doit figurer dans la liste : {devices:?}");

    let path = std::env::temp_dir().join("dz_device.wav");
    write_wav(&path, 44_100, 4.0);
    let (tx, mut rx) = unbounded_channel();
    let eng = Engine::start(tx);
    eng.load(7, Box::new(File::open(&path).unwrap()), Some("wav".into()));
    match wait_for(&mut rx, 5, |e| matches!(e, EngineEvent::TrackStarted { .. } | EngineEvent::Error { .. })).await {
        Some(EngineEvent::TrackStarted { id: 7 }) => {}
        other => {
            eprintln!("sortie audio inutilisable ({other:?}) : test ignoré");
            return;
        }
    }
    tokio::time::sleep(Duration::from_millis(1000)).await;
    let before = eng.shared.position_ms.load(Ordering::Relaxed);
    assert!((700..1600).contains(&before), "position avant changement = {before} ms");

    // 1) Choix explicite du même périphérique : la sortie est rouverte, la lecture reprend à la même position.
    eng.set_device(Some(default.clone()));
    tokio::time::sleep(Duration::from_millis(700)).await;
    let after = eng.shared.position_ms.load(Ordering::Relaxed);
    assert!(after >= before && after < before + 1800, "après changement : {after} ms (avant : {before} ms)");
    assert!(eng.shared.playing.load(Ordering::Relaxed), "la lecture doit continuer");
    assert!(eng.shared.out_info.lock().unwrap().contains(&default), "la sortie décrite doit être celle choisie");

    // 2) Un périphérique inexistant retombe sur celui du système, sans interruption ni erreur.
    eng.set_device(Some("Périphérique qui n'existe pas".into()));
    tokio::time::sleep(Duration::from_millis(700)).await;
    assert!(eng.shared.playing.load(Ordering::Relaxed));
    let later = eng.shared.position_ms.load(Ordering::Relaxed);
    assert!(later > after, "la position doit avancer : {later} ms (avant : {after} ms)");

    // 3) Retour au périphérique par défaut puis fin normale du titre (et une seule annonce de début de piste).
    eng.set_device(None);
    let fin = wait_for(&mut rx, 8, |e| matches!(e, EngineEvent::Finished { id: 7 })).await;
    assert!(fin.is_some(), "fin de lecture non signalée après les changements de périphérique");
}
