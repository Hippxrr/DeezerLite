//! Moteur audio : décodeur symphonia -> ring buffer lock-free (rtrb) -> rendu (`Renderer`) -> sortie.
//!
//! Sortie : cpal sur ordinateur ; sur iPhone, AVAudioEngine (côté Swift) tire le son par la fonction C `dz_render`
//! (cpal y gère mal les coupures et les changements de sortie d'iOS).
//! Un seul thread "engine" possède la sortie, le décodeur courant et le décodeur suivant (gapless : la sortie
//! n'est jamais fermée entre deux pistes). Le rendu ne prend aucun verrou et n'alloue pas.

mod eq;
mod resample;

use std::collections::VecDeque;
use std::io::{self, Read, Seek, SeekFrom};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(not(target_os = "ios"))]
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
#[cfg(not(target_os = "ios"))]
use cpal::{FromSample, SampleFormat, SizedSample};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{Decoder, DecoderOptions};
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use symphonia::core::units::Time;
use tokio::sync::mpsc::UnboundedSender;

pub use symphonia::core::io::MediaSource;

use eq::EqState;
use resample::Resampler;

#[derive(Debug, thiserror::Error)]
pub enum AudioError {
    #[error("périphérique audio: {0}")]
    Device(String),
    #[error("décodage: {0}")]
    Decode(String),
}

/// Événements remontés au `Player`.
#[derive(Debug, Clone)]
pub enum EngineEvent {
    /// La piste `id` devient audible (début de lecture ou transition gapless).
    TrackStarted { id: i64 },
    /// Pause, reprise, seek ou arrêt traités : l'état partagé est à jour.
    StateChanged,
    /// Plus rien à jouer : la dernière piste est terminée.
    Finished { id: i64 },
    Error { id: i64, msg: String },
    /// Le périphérique de sortie a disparu (casque débranché…) : la lecture est mise en pause.
    DeviceLost,
    /// `skip_next` demandé alors qu'aucune piste suivante n'était prête (déjà commencée en fondu…).
    SkipFailed,
}

/// État partagé avec le reste de l'application. `paused` et `volume` sont lus directement par le
/// callback audio : les modifier agit sur le son immédiatement, sans passer par une file de messages.
pub struct Shared {
    pub position_ms: AtomicU64,
    pub duration_ms: AtomicU64,
    pub playing: AtomicBool,
    pub current_id: AtomicI64,
    pub paused: AtomicBool,
    /// Durée du fondu enchaîné en ms (0 = désactivé).
    pub crossfade_ms: AtomicU64,
    /// Volume 0.0..=1.0, stocké sous forme de bits f32.
    pub volume: AtomicU32,
    /// Gain supplémentaire (facteur linéaire, de ~0,32 à ~4, bits f32) ; au-dessus de 1, un limiteur doux l'accompagne.
    pub boost: AtomicU32,
    /// Égaliseur : gain de chaque bande (60 Hz, 230 Hz, 910 Hz, 3,6 kHz, 14 kHz) en dixièmes de dB (-120..=120).
    pub eq: [AtomicI32; eq::BANDS],
    /// Description de la sortie ouverte (nom, fréquence, canaux), pour le diagnostic ; vide si aucune.
    pub out_info: Mutex<String>,
    /// Mesure du son pour le fond animé : activée seulement quand il est affiché (sinon aucun calcul).
    pub levels_on: AtomicBool,
    /// Niveaux (efficaces) des graves, médiums et aigus du dernier bloc joué (bits f32), avant volume et égaliseur.
    pub levels: [AtomicU32; 3],
    /// Plus rien à jouer dans le moteur (dernier titre fini, ou titre impossible à ouvrir) : une reprise ne ferait rien,
    /// le lecteur doit recharger le titre.
    pub idle: AtomicBool,
}

impl Default for Shared {
    fn default() -> Self {
        Self {
            position_ms: AtomicU64::new(0),
            duration_ms: AtomicU64::new(0),
            playing: AtomicBool::new(false),
            current_id: AtomicI64::new(0),
            paused: AtomicBool::new(false),
            crossfade_ms: AtomicU64::new(0),
            volume: AtomicU32::new(0.5f32.to_bits()), // moitié par défaut
            boost: AtomicU32::new(1.0f32.to_bits()),
            eq: std::array::from_fn(|_| AtomicI32::new(0)),
            out_info: Mutex::new(String::new()),
            levels_on: AtomicBool::new(false),
            levels: [AtomicU32::new(0), AtomicU32::new(0), AtomicU32::new(0)],
            idle: AtomicBool::new(false),
        }
    }
}

enum Cmd {
    Load { id: i64, src: Box<dyn MediaSource>, ext: Option<String> },
    QueueNext { id: i64, src: Box<dyn MediaSource>, ext: Option<String> },
    Pause,
    Resume,
    Seek(u64),
    Stop,
    /// Oublie la piste suivante préchargée (la file d'attente a changé).
    ClearNext,
    /// Passe tout de suite à la piste suivante préchargée (sans la retélécharger) ; `SkipFailed` s'il n'y en a pas.
    SkipNext,
    /// Choisit le périphérique de sortie (`None` = périphérique par défaut du système).
    SetDevice(Option<String>),
    /// Rouvre la sortie actuelle (iOS : après un appel ou un redémarrage du service audio, l'ancienne est arrêtée sans erreur).
    ReopenOutput,
}

#[derive(Clone)]
pub struct Engine {
    tx: mpsc::Sender<Cmd>,
    pub shared: Arc<Shared>,
}

impl Engine {
    pub fn start(events: UnboundedSender<EngineEvent>) -> Self {
        let (tx, rx) = mpsc::channel();
        let shared = Arc::new(Shared::default());
        let s = shared.clone();
        thread::Builder::new()
            .name("dz-engine".into())
            .spawn(move || Worker::new(rx, events, s).run())
            .expect("impossible de lancer le thread audio");
        Self { tx, shared }
    }

    pub fn load(&self, id: i64, src: Box<dyn MediaSource>, ext: Option<String>) {
        let _ = self.tx.send(Cmd::Load { id, src, ext });
    }
    /// Piste suivante préchargée : enchaînée sans silence à la fin de la courante.
    pub fn queue_next(&self, id: i64, src: Box<dyn MediaSource>, ext: Option<String>) {
        let _ = self.tx.send(Cmd::QueueNext { id, src, ext });
    }
    /// Le son s'arrête immédiatement (drapeau lu par le callback) ; la commande met ensuite l'état à jour.
    pub fn pause(&self) {
        self.shared.paused.store(true, Ordering::Relaxed);
        let _ = self.tx.send(Cmd::Pause);
    }
    pub fn resume(&self) {
        self.shared.paused.store(false, Ordering::Relaxed);
        let _ = self.tx.send(Cmd::Resume);
    }
    pub fn seek(&self, ms: u64) { let _ = self.tx.send(Cmd::Seek(ms)); }
    pub fn stop(&self) { let _ = self.tx.send(Cmd::Stop); }
    pub fn clear_next(&self) { let _ = self.tx.send(Cmd::ClearNext); }
    pub fn skip_next(&self) { let _ = self.tx.send(Cmd::SkipNext); }
    /// Fondu enchaîné entre deux pistes (0 à 12 s ; 0 = enchaînement sans coupure classique).
    pub fn set_crossfade(&self, ms: u64) { self.shared.crossfade_ms.store(ms.min(12_000), Ordering::Relaxed); }
    /// Gain en décibels (−10 à +12 dB) : négatif = son plus faible. Au-delà de 0 dB, un limiteur doux évite l'écrêtage brutal.
    pub fn set_boost_db(&self, db: f32) {
        let gain = 10f32.powf(db.clamp(-10.0, 12.0) / 20.0);
        self.shared.boost.store(gain.to_bits(), Ordering::Relaxed);
    }
    pub fn set_volume(&self, v: f32) { self.shared.volume.store(v.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed); }
    /// Égaliseur : gain de chaque bande en dB (-12 à +12 ; bandes manquantes : 0). Effet immédiat.
    pub fn set_eq_bands(&self, gains: &[f32]) {
        for (i, slot) in self.shared.eq.iter().enumerate() {
            let db = gains.get(i).copied().unwrap_or(0.0);
            slot.store((db.clamp(-12.0, 12.0) * 10.0).round() as i32, Ordering::Relaxed);
        }
    }
    /// Périphérique de sortie (`None` = celui du système). Si un titre joue, il continue sur le nouveau périphérique.
    pub fn set_device(&self, name: Option<String>) { let _ = self.tx.send(Cmd::SetDevice(name)); }
    pub fn reopen_output(&self) { let _ = self.tx.send(Cmd::ReopenOutput); }
}

/// Périphériques de sortie disponibles : (noms, nom du périphérique par défaut du système).
/// iPhone : c'est iOS qui choisit la sortie (AirPods, haut-parleur, CarPlay…), rien à lister.
#[cfg(target_os = "ios")]
pub fn list_output_devices() -> (Vec<String>, Option<String>) {
    (Vec::new(), None)
}

/// Périphériques de sortie disponibles : (noms, nom du périphérique par défaut du système).
#[cfg(not(target_os = "ios"))]
pub fn list_output_devices() -> (Vec<String>, Option<String>) {
    let host = cpal::default_host();
    let default = host.default_output_device().and_then(|d| d.name().ok());
    let mut names: Vec<String> = host.output_devices().map(|it| it.filter_map(|d| d.name().ok()).collect()).unwrap_or_default();
    names.sort();
    names.dedup();
    (names, default)
}

// ---------------------------------------------------------------- sortie

struct OutCtl {
    played: AtomicU64, // échantillons réellement consommés par le device
    /// Le flux a signalé une erreur (périphérique retiré…) : le moteur doit le rouvrir.
    failed: AtomicBool,
    shared: Arc<Shared>,
    flush_req: AtomicU64,
    flush_ack: AtomicU64,
}

struct Output {
    #[cfg(not(target_os = "ios"))]
    stream: cpal::Stream,
    /// Rendu installé pour AVAudioEngine (voir `ios_out`) ; remplacé à chaque vidage du tampon.
    #[cfg(target_os = "ios")]
    renderer: *mut Renderer,
    /// Flux réellement en marche. En pause, il est arrêté (et non plus nourri de silence) : aucun calcul audio,
    /// et le système sait que rien ne joue (bouton lecture/pause juste sur l'écran verrouillé d'iOS).
    running: bool,
    producer: rtrb::Producer<f32>,
    ctl: Arc<OutCtl>,
    rate: u32,
    channels: usize,
    /// Nom du périphérique (ordinateur : pour suivre le périphérique par défaut du système).
    #[cfg_attr(target_os = "ios", allow(dead_code))]
    name: String,
}

fn new_ctl(shared: Arc<Shared>) -> Arc<OutCtl> {
    Arc::new(OutCtl {
        played: AtomicU64::new(0),
        failed: AtomicBool::new(false),
        shared,
        flush_req: AtomicU64::new(0),
        flush_ack: AtomicU64::new(0),
    })
}

/// iPhone : la sortie est AVAudioEngine, démarré et arrêté par Swift. Le rendu est installé ici ; Swift le tire.
#[cfg(target_os = "ios")]
fn open_output(shared: Arc<Shared>, _wanted: Option<&str>) -> Result<Output, AudioError> {
    let (rate, channels) = (ios_out::RATE, ios_out::CHANNELS);
    let (producer, consumer) = rtrb::RingBuffer::<f32>::new(rate as usize * channels / 2); // ~500 ms
    let ctl = new_ctl(shared);
    let renderer = Box::into_raw(Box::new(Renderer::new(consumer, ctl.clone(), rate, channels)));
    if !ios_out::swap(std::ptr::null_mut(), renderer) {
        // SAFETY: `renderer` vient de `Box::into_raw` et n'a pas été installé.
        drop(unsafe { Box::from_raw(renderer) });
        return Err(AudioError::Device("une sortie est déjà ouverte".into()));
    }
    // En pause (sortie rouverte après un appel…), le moteur reste arrêté : le démarrer couperait le son d'une autre app.
    let running = !ctl.shared.paused.load(Ordering::Relaxed);
    if running {
        ios_out::start();
    }
    if let Ok(mut info) = ctl.shared.out_info.lock() {
        *info = format!("AVAudioEngine · {rate} Hz · {channels} canaux");
    }
    Ok(Output { renderer, running, producer, ctl, rate, channels, name: "iPhone".into() })
}

/// Sortie fermée : son rendu est retiré (AVAudioEngine joue du silence) et le moteur est arrêté.
#[cfg(target_os = "ios")]
impl Drop for Output {
    fn drop(&mut self) {
        if ios_out::swap(self.renderer, std::ptr::null_mut()) {
            ios_out::stop();
        }
    }
}

/// Ouvre la sortie : le périphérique nommé s'il existe, sinon celui par défaut du système.
#[cfg(not(target_os = "ios"))]
fn open_output(shared: Arc<Shared>, wanted: Option<&str>) -> Result<Output, AudioError> {
    let host = cpal::default_host();
    let named = wanted.and_then(|w| host.output_devices().ok().and_then(|mut it| it.find(|d| d.name().is_ok_and(|n| n == w))));
    let dev = named
        .or_else(|| host.default_output_device())
        .ok_or_else(|| AudioError::Device("aucun périphérique de sortie".into()))?;
    let name = dev.name().unwrap_or_else(|_| "périphérique inconnu".into());
    let cfg = dev.default_output_config().map_err(|e| AudioError::Device(e.to_string()))?;
    let rate = cfg.sample_rate().0;
    let channels = cfg.channels() as usize;
    let fmt = cfg.sample_format();
    let config = cfg.config();

    let (producer, consumer) = rtrb::RingBuffer::<f32>::new(rate as usize * channels / 2); // ~500 ms
    let ctl = new_ctl(shared);

    let stream = match fmt {
        SampleFormat::F32 => build::<f32>(&dev, &config, consumer, ctl.clone()),
        SampleFormat::I16 => build::<i16>(&dev, &config, consumer, ctl.clone()),
        SampleFormat::U16 => build::<u16>(&dev, &config, consumer, ctl.clone()),
        other => Err(AudioError::Device(format!("format d'échantillon non géré: {other:?}"))),
    }?;
    stream.play().map_err(|e| AudioError::Device(e.to_string()))?;
    if let Ok(mut info) = ctl.shared.out_info.lock() {
        *info = format!("{name} · {rate} Hz · {channels} canaux");
    }
    Ok(Output { stream, running: true, producer, ctl, rate, channels, name })
}

/// Limiteur doux : linéaire jusqu'à 0,8, puis compression progressive qui tend vers 1,0 sans jamais le dépasser
/// (évite la distorsion dure d'un écrêtage quand le gain dépasse le maximum d'origine).
fn soft_limit(x: f32) -> f32 {
    const KNEE: f32 = 0.8;
    let a = x.abs();
    if a <= KNEE {
        x
    } else {
        x.signum() * (KNEE + (1.0 - KNEE) * ((a - KNEE) / (1.0 - KNEE)).tanh())
    }
}

/// Le son au moment de le jouer : vidage demandé, pause, volume, égaliseur, limiteur, mesure des niveaux.
/// Commun aux deux sorties (cpal sur ordinateur, AVAudioEngine sur iPhone). Aucun verrou, aucune allocation.
struct Renderer {
    cons: rtrb::Consumer<f32>,
    ctl: Arc<OutCtl>,
    eq: EqState,
    bands: Bands,
    channels: usize,
    /// Fondu de 5 ms au passage pause / lecture : `gain` va de 0 (silence) à `ramp` (plein volume), suivi d'un bloc audio
    /// à l'autre (avec de petits tampons, un fondu calculé bloc par bloc était tronqué : le clic revenait).
    gain: usize,
    /// Durée du fondu en trames (5 ms).
    ramp: usize,
    /// iPhone : trames entrelacées le temps de les séparer en gauche / droite (alloué une fois, à la création).
    #[cfg(target_os = "ios")]
    scratch: Vec<f32>,
}

impl Renderer {
    fn new(cons: rtrb::Consumer<f32>, ctl: Arc<OutCtl>, rate: u32, channels: usize) -> Self {
        Self {
            cons,
            ctl,
            eq: EqState::new(rate, channels),
            bands: Bands::new(rate),
            channels,
            gain: (rate as usize / 200).max(1),
            ramp: (rate as usize / 200).max(1),
            #[cfg(target_os = "ios")]
            scratch: vec![0.0; 4096 * channels.max(1)],
        }
    }

    /// Remplit `data` (échantillons entrelacés). `silence` et `conv` : le format d'échantillon de la sortie.
    #[inline]
    fn render<T: Copy>(&mut self, data: &mut [T], silence: T, conv: impl Fn(f32) -> T) {
        let Self { cons, ctl, eq, bands, channels, gain, ramp, .. } = self;
        // Vidage demandé (saut, autre titre, arrêt) : le son en cours descend d'abord à zéro en 5 ms, puis le tampon est
        // vidé. Le nouveau son remonte ensuite en 5 ms. Avant, la coupure nette faisait un petit clic.
        let req = ctl.flush_req.load(Ordering::Acquire);
        let flushing = req != ctl.flush_ack.load(Ordering::Relaxed);
        if flushing && *gain == 0 {
            while cons.pop().is_ok() {}
            ctl.flush_ack.store(req, Ordering::Release);
            data.fill(silence);
            return;
        }
        let paused = ctl.shared.paused.load(Ordering::Relaxed);
        // Pause ou vidage : le son descend vers zéro.
        let fading = paused || flushing;
        if paused && *gain == 0 {
            data.fill(silence);
            bands.publish_silence(&ctl.shared);
            return;
        }
        // Pause qui commence : le son descend à zéro en 5 ms, puis silence (le reste du tampon est gardé pour la reprise).
        // Reprise : il remonte en 5 ms. Sans ce fondu, la coupure nette faisait parfois un petit clic.
        let ramp = (*ramp).max(1);
        let measure = ctl.shared.levels_on.load(Ordering::Relaxed);
        let vol = f32::from_bits(ctl.shared.volume.load(Ordering::Relaxed)) * f32::from_bits(ctl.shared.boost.load(Ordering::Relaxed));
        eq.set(std::array::from_fn(|i| ctl.shared.eq[i].load(Ordering::Relaxed)));
        // Le limiteur n'intervient que si le gain dépasse 1 (volume + amplification, ou un réglage d'égaliseur actif) :
        // au maximum d'origine et à plat, le son est strictement inchangé.
        let limit = vol > 1.0 || eq.active();
        let mut n = 0u64;
        let ch = (*channels).max(1);
        // Trame entière (un échantillon par canal) ou rien : son en retard, la fin du tampon est du silence
        // sans jamais décaler la gauche et la droite.
        let mut starved = false;
        for (i, s) in data.iter_mut().enumerate() {
            if i % ch == 0 {
                if fading {
                    *gain = gain.saturating_sub(1);
                }
                if !starved {
                    starved = (fading && *gain == 0) || cons.slots() < ch;
                }
                // Remontée seulement sur du vrai son : sinon, après une reprise ou un saut, elle s'écoulait pendant
                // l'attente du premier son, qui arrivait alors d'un coup (clic).
                if !fading && !starved && *gain < ramp {
                    *gain += 1;
                }
            }
            match if starved { None } else { cons.pop().ok() } {
                Some(v) => {
                    if measure {
                        bands.push(v, i % ch == ch - 1, ch);
                    }
                    let mut y = eq.process(i % ch, v) * vol;
                    if *gain < ramp {
                        y *= *gain as f32 / ramp as f32;
                    }
                    *s = conv(if limit { soft_limit(y) } else { y });
                    n += 1;
                }
                None => *s = silence,
            }
        }
        ctl.played.fetch_add(n, Ordering::Relaxed);
        if measure {
            bands.publish(&ctl.shared);
        }
    }

    /// iPhone : AVAudioEngine fournit un tampon par canal (gauche, droite). Rendu par blocs dans `scratch`, puis séparé.
    #[cfg(target_os = "ios")]
    fn render_planar(&mut self, left: &mut [f32], right: &mut [f32]) {
        let frames = left.len().min(right.len());
        let per_block = self.scratch.len() / 2;
        let mut done = 0;
        while done < frames {
            let n = (frames - done).min(per_block);
            let mut buf = std::mem::take(&mut self.scratch);
            self.render(&mut buf[..n * 2], 0.0, |x| x);
            for i in 0..n {
                left[done + i] = buf[2 * i];
                right[done + i] = buf[2 * i + 1];
            }
            self.scratch = buf;
            done += n;
        }
    }
}

#[cfg(not(target_os = "ios"))]
fn build<T>(
    dev: &cpal::Device,
    config: &cpal::StreamConfig,
    cons: rtrb::Consumer<f32>,
    ctl: Arc<OutCtl>,
) -> Result<cpal::Stream, AudioError>
where
    T: SizedSample + FromSample<f32>,
{
    let (rate, channels) = (config.sample_rate.0, config.channels as usize);
    let mut renderer = Renderer::new(cons, ctl.clone(), rate, channels);
    let ctl_err = ctl;
    dev.build_output_stream(
        config,
        move |data: &mut [T], _| renderer.render(data, T::EQUILIBRIUM, T::from_sample),
        move |e| {
            eprintln!("erreur flux audio: {e}");
            ctl_err.failed.store(true, Ordering::Release);
        },
        None,
    )
    .map_err(|e| AudioError::Device(e.to_string()))
}

/// Attente quand le tampon de sortie est plein.
/// (Même valeur que les versions Windows et Mac.)
const FULL_BUFFER_WAIT_MS: u64 = 100;

/// Délai avant d'arrêter la sortie quand plus rien ne joue (voir `Worker::idle_stop_at`).
const IDLE_STOP: Duration = Duration::from_secs(30);

/// Sortie iPhone : le rendu installé est tiré par AVAudioEngine (thread temps réel d'iOS) à travers `dz_render`.
/// Échange sans verrou : un pointeur atomique vers le rendu, et un compteur des rendus en cours pour ne libérer
/// l'ancien qu'une fois qu'aucun rendu ne s'en sert plus.
#[cfg(target_os = "ios")]
mod ios_out {
    use super::Renderer;
    use std::ptr;
    use std::sync::atomic::{AtomicPtr, AtomicU32, Ordering::SeqCst};
    use std::sync::OnceLock;
    use std::thread;
    use std::time::{Duration, Instant};

    /// Format donné à AVAudioEngine (le même dans `AudioOutput.swift`) ; il convertit lui-même vers le matériel.
    pub const RATE: u32 = 44_100;
    pub const CHANNELS: usize = 2;

    static SLOT: AtomicPtr<Renderer> = AtomicPtr::new(ptr::null_mut());
    static ACTIVE: AtomicU32 = AtomicU32::new(0);
    /// Démarrer / arrêter AVAudioEngine : fonctions C données par Swift au lancement.
    static HOOKS: OnceLock<(extern "C" fn(), extern "C" fn())> = OnceLock::new();

    pub fn set_hooks(start: extern "C" fn(), stop: extern "C" fn()) {
        let _ = HOOKS.set((start, stop));
    }

    pub fn start() {
        if let Some((start, _)) = HOOKS.get() {
            start();
        }
    }

    pub fn stop() {
        if let Some((_, stop)) = HOOKS.get() {
            stop();
        }
    }

    /// Installe `new` à la place de `old` (`false` si `old` n'est pas le rendu installé). `old` est libéré
    /// dès qu'aucun rendu n'est en cours.
    pub fn swap(old: *mut Renderer, new: *mut Renderer) -> bool {
        if SLOT.compare_exchange(old, new, SeqCst, SeqCst).is_err() {
            return false;
        }
        if !old.is_null() {
            let t = Instant::now();
            while ACTIVE.load(SeqCst) != 0 {
                if t.elapsed() > Duration::from_millis(500) {
                    return true; // rendu bloqué : on laisse l'ancien en mémoire plutôt que de le libérer sous ses pieds
                }
                thread::sleep(Duration::from_millis(1));
            }
            // SAFETY: `old` venait de `Box::into_raw`, n'est plus installé et aucun rendu ne l'utilise.
            drop(unsafe { Box::from_raw(old) });
        }
        true
    }

    /// # Safety
    /// `left` et `right` : tampons de `frames` échantillons, valides pendant l'appel.
    pub unsafe fn render(left: *mut f32, right: *mut f32, frames: usize) {
        ACTIVE.fetch_add(1, SeqCst);
        let r = SLOT.load(SeqCst);
        let (l, rt) = (std::slice::from_raw_parts_mut(left, frames), std::slice::from_raw_parts_mut(right, frames));
        match r.as_mut() {
            // SAFETY: le rendu installé n'est libéré qu'une fois ACTIVE revenu à 0 ; un seul thread de rendu.
            Some(renderer) => renderer.render_planar(l, rt),
            None => {
                l.fill(0.0);
                rt.fill(0.0);
            }
        }
        ACTIVE.fetch_sub(1, SeqCst);
    }
}

/// iPhone : remplit `frames` trames (gauche, droite) depuis le moteur. Appelé par AVAudioEngine sur son thread
/// temps réel : aucune allocation, aucun verrou.
///
/// # Safety
/// `left` et `right` : nuls, ou tampons de `frames` échantillons valides pendant l'appel.
#[cfg(target_os = "ios")]
pub unsafe fn ios_render(left: *mut f32, right: *mut f32, frames: u32) {
    if left.is_null() || right.is_null() {
        return;
    }
    // SAFETY: tampons non nuls de `frames` échantillons (contrat de la fonction).
    unsafe { ios_out::render(left, right, frames as usize) }
}

/// iPhone : fonctions Swift qui démarrent et arrêtent AVAudioEngine (appelées depuis le thread du moteur).
#[cfg(target_os = "ios")]
pub fn ios_set_output_hooks(start: extern "C" fn(), stop: extern "C" fn()) {
    ios_out::set_hooks(start, stop);
}

/// Mesure grossière du son en trois bandes (graves < 150 Hz, médiums, aigus > 2,5 kHz) pour le fond animé.
/// Deux filtres passe-bas d'ordre 1 sur le signal mono : quelques multiplications par échantillon, sans allocation.
struct Bands {
    a_low: f32,
    a_high: f32,
    lp_low: f32,
    lp_high: f32,
    frame_sum: f32,
    acc: [f32; 3],
    frames: u32,
}

impl Bands {
    fn new(rate: u32) -> Self {
        let coef = |fc: f32| 1.0 - (-2.0 * std::f32::consts::PI * fc / rate.max(1) as f32).exp();
        Self { a_low: coef(150.0), a_high: coef(2500.0), lp_low: 0.0, lp_high: 0.0, frame_sum: 0.0, acc: [0.0; 3], frames: 0 }
    }
    /// Un échantillon entrelacé ; `last` : dernier canal de la trame (on travaille sur la moyenne des canaux).
    #[inline]
    fn push(&mut self, v: f32, last: bool, ch: usize) {
        self.frame_sum += v;
        if !last {
            return;
        }
        let m = self.frame_sum / ch as f32;
        self.frame_sum = 0.0;
        self.lp_low += self.a_low * (m - self.lp_low);
        self.lp_high += self.a_high * (m - self.lp_high);
        let (low, mid, high) = (self.lp_low, self.lp_high - self.lp_low, m - self.lp_high);
        self.acc[0] += low * low;
        self.acc[1] += mid * mid;
        self.acc[2] += high * high;
        self.frames += 1;
    }
    fn publish(&mut self, shared: &Shared) {
        if self.frames == 0 {
            return;
        }
        for (slot, sum) in shared.levels.iter().zip(self.acc) {
            slot.store((sum / self.frames as f32).sqrt().to_bits(), Ordering::Relaxed);
        }
        self.acc = [0.0; 3];
        self.frames = 0;
    }
    fn publish_silence(&mut self, shared: &Shared) {
        self.acc = [0.0; 3];
        self.frames = 0;
        for slot in &shared.levels {
            slot.store(0, Ordering::Relaxed);
        }
    }
}

// ------------------------------------------------------------------ décodage

struct Track {
    id: i64,
    format: Box<dyn FormatReader>,
    decoder: Box<dyn Decoder>,
    track_id: u32,
    src_ch: usize,
    rs: Option<Resampler>,
    /// Fréquence d'origine du fichier (pour recréer le rééchantillonneur si la sortie change).
    src_rate: u32,
    duration_ms: u64,
    sbuf: Option<SampleBuffer<f32>>,
    /// Échantillons décodés (au format de sortie) pas encore livrés au ring buffer.
    pending: Vec<f32>,
    /// Trames (au débit de sortie) déjà livrées : sert à savoir quand commencer le fondu.
    delivered: u64,
    out_rate: u32,
    eof: bool,
}

/// Saute l'étiquette ID3v2 en tête de flux. Les aperçus Deezer commencent par une étiquette vide
/// (taille 0) que l'analyseur MP3 de symphonia rejette avec « out of bounds » ; les métadonnées
/// viennent de toute façon de l'API, pas du fichier.
struct SkipId3 {
    inner: Box<dyn MediaSource>,
    offset: u64,
    /// Octets déjà lus mais à rejouer (flux non seekable sans étiquette).
    prefix: Vec<u8>,
    prefix_pos: usize,
}

impl SkipId3 {
    fn new(mut inner: Box<dyn MediaSource>) -> io::Result<Self> {
        let mut head = [0u8; 10];
        let mut n = 0;
        while n < head.len() {
            let r = inner.read(&mut head[n..])?;
            if r == 0 {
                break;
            }
            n += r;
        }
        let is_tag = n == 10 && &head[..3] == b"ID3" && head[6..].iter().all(|b| b & 0x80 == 0);
        let offset = if is_tag {
            let size = head[6..].iter().fold(0u64, |acc, b| (acc << 7) | u64::from(*b));
            10 + size + if head[5] & 0x10 != 0 { 10 } else { 0 }
        } else {
            0
        };

        let mut me = Self { inner, offset, prefix: Vec::new(), prefix_pos: 0 };
        if me.inner.is_seekable() {
            me.inner.seek(SeekFrom::Start(offset))?;
        } else if is_tag {
            io::copy(&mut (&mut me.inner).take(offset.saturating_sub(n as u64)), &mut io::sink())?;
        } else {
            me.prefix = head[..n].to_vec();
        }
        Ok(me)
    }
}

impl Read for SkipId3 {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.prefix_pos < self.prefix.len() {
            let n = buf.len().min(self.prefix.len() - self.prefix_pos);
            buf[..n].copy_from_slice(&self.prefix[self.prefix_pos..self.prefix_pos + n]);
            self.prefix_pos += n;
            return Ok(n);
        }
        self.inner.read(buf)
    }
}

impl Seek for SkipId3 {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        let abs = match to {
            SeekFrom::Start(n) => self.inner.seek(SeekFrom::Start(n + self.offset))?,
            other => self.inner.seek(other)?,
        };
        Ok(abs.saturating_sub(self.offset))
    }
}

impl MediaSource for SkipId3 {
    fn is_seekable(&self) -> bool {
        self.prefix.is_empty() && self.inner.is_seekable()
    }
    fn byte_len(&self) -> Option<u64> {
        self.inner.byte_len().map(|l| l.saturating_sub(self.offset))
    }
}

struct Pending {
    id: i64,
    src: Box<dyn MediaSource>,
    ext: Option<String>,
}

fn open_track(p: Pending, out_rate: u32, out_ch: usize) -> Result<Track, AudioError> {
    let mut hint = Hint::new();
    if let Some(e) = &p.ext {
        hint.with_extension(e);
    }
    let src = SkipId3::new(p.src).map_err(|e| AudioError::Decode(format!("lecture du flux: {e}")))?;
    let mss = MediaSourceStream::new(Box::new(src), Default::default());
    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions { enable_gapless: true, ..Default::default() },
            &MetadataOptions::default(),
        )
        .map_err(|e| AudioError::Decode(format!("format non reconnu: {e}")))?;
    let format = probed.format;
    let track = format
        .default_track()
        .ok_or_else(|| AudioError::Decode("aucune piste audio".into()))?;
    let params = track.codec_params.clone();
    let track_id = track.id;
    let decoder = symphonia::default::get_codecs()
        .make(&params, &DecoderOptions::default())
        .map_err(|e| AudioError::Decode(format!("codec: {e}")))?;

    let src_rate = params.sample_rate.unwrap_or(44_100);
    let src_ch = params.channels.map(|c| c.count()).unwrap_or(2).max(1);
    let duration_ms = match (params.n_frames, params.time_base) {
        (Some(n), Some(tb)) => {
            let t = tb.calc_time(n);
            t.seconds * 1000 + (t.frac * 1000.0) as u64
        }
        (Some(n), None) => n * 1000 / src_rate as u64,
        _ => 0,
    };
    let rs = if src_rate != out_rate {
        Some(Resampler::new(src_rate, out_rate, out_ch).map_err(AudioError::Decode)?)
    } else {
        None
    };
    Ok(Track { id: p.id, format, decoder, track_id, src_ch, rs, src_rate, duration_ms, sbuf: None, pending: Vec::new(), delivered: 0, out_rate, eof: false })
}

/// Remappe des échantillons entrelacés `src_ch` -> `dst_ch` (mono<->stéréo, sinon troncature/zéros).
fn remap(input: &[f32], src: usize, dst: usize, out: &mut Vec<f32>) {
    if src == dst {
        out.extend_from_slice(input);
        return;
    }
    for frame in input.chunks_exact(src) {
        for c in 0..dst {
            let v = if src == 1 {
                frame[0]
            } else if dst == 1 {
                frame.iter().sum::<f32>() / src as f32
            } else if c < src {
                frame[c]
            } else {
                0.0
            };
            out.push(v);
        }
    }
}

enum Step {
    Samples,
    Eof,
}

impl Track {
    /// Décode un paquet et ajoute les échantillons (au format de sortie) à `out`.
    fn step(&mut self, out_ch: usize, out: &mut Vec<f32>) -> Result<Step, AudioError> {
        loop {
            let packet = match self.format.next_packet() {
                Ok(p) => p,
                Err(SymError::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                    return Ok(Step::Eof)
                }
                Err(SymError::ResetRequired) => return Ok(Step::Eof),
                Err(e) => return Err(AudioError::Decode(e.to_string())),
            };
            if packet.track_id() != self.track_id {
                continue;
            }
            let decoded = match self.decoder.decode(&packet) {
                Ok(d) => d,
                Err(SymError::DecodeError(_)) => continue, // paquet corrompu : on saute
                Err(SymError::IoError(_)) => return Ok(Step::Eof),
                Err(e) => return Err(AudioError::Decode(e.to_string())),
            };
            let spec = *decoded.spec();
            let cap = decoded.capacity() as u64;
            if self.sbuf.as_ref().map_or(true, |b| (b.capacity() as u64) < cap * spec.channels.count() as u64) {
                self.sbuf = Some(SampleBuffer::<f32>::new(cap, spec));
            }
            let sbuf = self.sbuf.as_mut().expect("sbuf initialisé");
            sbuf.copy_interleaved_ref(decoded);

            let mut mapped = Vec::with_capacity(sbuf.samples().len() * out_ch / self.src_ch.max(1) + 8);
            remap(sbuf.samples(), self.src_ch, out_ch, &mut mapped);
            match &mut self.rs {
                Some(rs) => rs.process(&mapped, out),
                None => out.extend_from_slice(&mapped),
            }
            return Ok(Step::Samples);
        }
    }

    /// Décode jusqu'à disposer d'au moins `min` échantillons en attente (ou jusqu'à la fin du fichier).
    fn fill(&mut self, ch: usize, min: usize) -> Result<(), AudioError> {
        while self.pending.len() < min && !self.eof {
            let mut buf = Vec::new();
            match self.step(ch, &mut buf)? {
                Step::Samples => self.pending.extend_from_slice(&buf),
                Step::Eof => self.eof = true,
            }
        }
        Ok(())
    }

    /// La sortie a changé (autre périphérique, autre fréquence ou nombre de canaux) : on recrée le rééchantillonneur.
    /// À appeler avant un `seek`, qui vide les échantillons en attente.
    fn reconfigure(&mut self, out_rate: u32, out_ch: usize) -> Result<(), AudioError> {
        self.rs = if self.src_rate != out_rate {
            Some(Resampler::new(self.src_rate, out_rate, out_ch).map_err(AudioError::Decode)?)
        } else {
            None
        };
        self.delivered = self.delivered * u64::from(out_rate) / u64::from(self.out_rate.max(1));
        self.out_rate = out_rate;
        self.pending.clear();
        Ok(())
    }

    /// Seek précis ; renvoie la position réelle atteinte en ms.
    fn seek(&mut self, ms: u64) -> Result<u64, AudioError> {
        let to = SeekTo::Time {
            time: Time::new(ms / 1000, (ms % 1000) as f64 / 1000.0),
            track_id: Some(self.track_id),
        };
        let seeked = self
            .format
            .seek(SeekMode::Accurate, to)
            .map_err(|e| AudioError::Decode(format!("seek: {e}")))?;
        self.decoder.reset();
        if let Some(rs) = &mut self.rs {
            rs.reset();
        }
        self.pending.clear();
        self.eof = false;
        let tb = self
            .format
            .tracks()
            .iter()
            .find(|t| t.id == self.track_id)
            .and_then(|t| t.codec_params.time_base);
        let actual = match tb {
            Some(tb) => {
                let t = tb.calc_time(seeked.actual_ts);
                t.seconds * 1000 + (t.frac * 1000.0) as u64
            }
            None => ms,
        };
        self.delivered = actual * u64::from(self.out_rate) / 1000;
        Ok(actual)
    }
}

// -------------------------------------------------------------------- worker

/// Mélange deux blocs entrelacés avec une courbe à puissance constante (cos / sin) :
/// le volume perçu reste stable pendant tout le fondu.
/// Au milieu du fondu, deux titres forts s'additionnent (jusqu'à ×1,41) : le limiteur doux évite l'écrêtage
/// (il ne touche à rien sous 0,8, donc les passages normaux restent intacts).
fn mix_equal_power(a: &[f32], b: &[f32], ch: usize, start_frame: u64, total_frames: u64) -> Vec<f32> {
    let total = total_frames.max(1) as f32;
    let mut out = Vec::with_capacity(a.len());
    for (i, (fa, fb)) in a.chunks_exact(ch).zip(b.chunks_exact(ch)).enumerate() {
        let t = ((start_frame + i as u64) as f32 / total).clamp(0.0, 1.0);
        let (gain_in, gain_out) = (t * std::f32::consts::FRAC_PI_2).sin_cos();
        for c in 0..ch {
            out.push(soft_limit(fa[c] * gain_out + fb[c] * gain_in));
        }
    }
    out
}

struct Segment {
    /// Numéro de lecture : permet d'annoncer chaque passage même quand le même titre se répète.
    seq: u64,
    id: i64,
    start_sample: u64, // index (depuis le dernier flush) du premier échantillon de ce segment
    start_ms: u64,
    duration_ms: u64,
}

struct Worker {
    rx: mpsc::Receiver<Cmd>,
    events: UnboundedSender<EngineEvent>,
    shared: Arc<Shared>,
    out: Option<Output>,
    cur: Option<Track>,
    next: Option<Pending>,
    /// Piste entrante pendant un fondu enchaîné (mélangée avec `cur`).
    incoming: Option<Track>,
    fade_pos: u64,
    fade_total: u64,
    segments: VecDeque<Segment>,
    written: u64,
    played_base: u64,
    leftover: Vec<f32>,
    leftover_off: usize,
    announced: Option<u64>,
    next_seq: u64,
    /// Périphérique demandé par l'utilisateur (`None` = celui du système).
    device: Option<String>,
    /// Position (ms) du titre en cours au moment où la sortie a disparu : on y reprend à la reprise de la lecture.
    lost_pos: Option<u64>,
    last_default_check: Instant,
    /// Plus rien à jouer (file terminée, titre impossible à charger) : la sortie s'arrête à cet instant, pas tout de
    /// suite. Le lecteur relance souvent un titre juste après (coupure réseau, titre suivant pas encore prêt) ; sur
    /// iPhone verrouillé, une sortie arrêtée laisserait iOS endormir l'app avant, et la musique ne reprendrait pas.
    idle_stop_at: Option<Instant>,
}

impl Worker {
    fn new(rx: mpsc::Receiver<Cmd>, events: UnboundedSender<EngineEvent>, shared: Arc<Shared>) -> Self {
        Self {
            rx, events, shared, out: None, cur: None, next: None, incoming: None, fade_pos: 0, fade_total: 1,
            segments: VecDeque::new(), written: 0, played_base: 0,
            leftover: Vec::new(), leftover_off: 0, announced: None, next_seq: 0,
            device: None, lost_pos: None, last_default_check: Instant::now(), idle_stop_at: None,
        }
    }

    fn err(&self, id: i64, msg: String) {
        let _ = self.events.send(EngineEvent::Error { id, msg });
    }

    fn run(mut self) {
        loop {
            self.watch_output();
            let draining = !self.segments.is_empty() || self.leftover_off < self.leftover.len();
            // Combien de temps dormir (un message réveille immédiatement) :
            //  - en pause, ou rien à jouer       : jusqu'au prochain message (aucun réveil : rien ne peut changer seul) ;
            //  - fin de piste qui se termine     : 30 ms ;
            //  - lecture, tampon plein           : 100 ms ;
            //  - lecture, il reste à décoder     : on enchaîne sans attendre.
            let paused = self.shared.paused.load(Ordering::Relaxed);
            // Rien à jouer, arrêt de la sortie prévu : on attend jusque-là (un message, comme un nouveau titre, passe avant).
            if let (false, false, Some(at)) = (paused, self.cur.is_some() || draining, self.idle_stop_at) {
                match self.rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                    Ok(c) => self.handle(c),
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        self.idle_stop_at = None;
                        self.run_stream(false);
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => return,
                }
                continue;
            }
            if paused || (self.cur.is_none() && !draining) {
                // Ordinateur : sortie perdue ou périphérique par défaut changé ne comptent qu'en lecture ; la reprise
                // (un message) relance la surveillance.
                match self.rx.recv() {
                    Ok(c) => self.handle(c),
                    Err(_) => return,
                }
                continue;
            }
            let wait = if self.cur.is_none() {
                Duration::from_millis(30)
            } else {
                Duration::from_millis(0)
            };
            let cmd = if wait.is_zero() {
                self.rx.try_recv().ok()
            } else {
                match self.rx.recv_timeout(wait) {
                    Ok(c) => Some(c),
                    Err(mpsc::RecvTimeoutError::Timeout) => None,
                    Err(mpsc::RecvTimeoutError::Disconnected) => return,
                }
            };
            if let Some(c) = cmd {
                self.handle(c);
                continue;
            }
            let pushed = if paused { false } else { self.pump() };
            self.update_position();
            if self.cur.is_some() && !paused && !pushed {
                // Tampon plein (une demi-seconde de son) : inutile de tourner à vide. iPhone : un réveil toutes les 100 ms
                // au lieu de 66 par seconde (le processeur reste au repos, téléphone verrouillé compris) ; il reste toujours
                // au moins 0,4 s de son d'avance.
                match self.rx.recv_timeout(Duration::from_millis(FULL_BUFFER_WAIT_MS)) {
                    Ok(c) => self.handle(c),
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => return,
                }
            }
        }
    }

    /// Surveille la sortie : périphérique retiré (erreur du flux) ou périphérique par défaut du système qui a changé.
    #[cfg_attr(target_os = "ios", allow(clippy::needless_return))]
    fn watch_output(&mut self) {
        let Some(o) = &self.out else { return };
        if o.ctl.failed.load(Ordering::Acquire) {
            // Casque débranché, périphérique désactivé… : pause, on reprendra sur la sortie disponible.
            let pos = self.shared.position_ms.load(Ordering::Relaxed);
            // Titre réellement entendu (fondu, fin d'enchaînement) : voir `audible_resume`.
            self.lost_pos = self.audible_resume(pos);
            // Fin du dernier titre (plus rien à décoder) : une reprise relancera le titre affiché.
            if self.cur.is_none() {
                self.shared.idle.store(true, Ordering::Relaxed);
            }
            self.out = None;
            self.incoming = None;
            self.segments.clear();
            self.leftover.clear();
            self.leftover_off = 0;
            self.written = 0;
            if let Ok(mut info) = self.shared.out_info.lock() {
                info.clear();
            }
            self.set_paused(true);
            let _ = self.events.send(EngineEvent::DeviceLost);
            return;
        }
        // Périphérique « par défaut » : si le système en change (nouveau casque branché), la lecture le suit.
        // (iPhone : AVAudioEngine suit la sortie choisie par iOS de lui-même.)
        #[cfg(not(target_os = "ios"))]
        if self.device.is_none() && !self.shared.paused.load(Ordering::Relaxed) && self.last_default_check.elapsed() >= Duration::from_secs(3) {
            self.last_default_check = Instant::now();
            let current = cpal::default_host().default_output_device().and_then(|d| d.name().ok());
            if let Some(name) = current {
                if name != o.name {
                    let pos = self.shared.position_ms.load(Ordering::Relaxed);
                    self.rebuild_output(Some(pos));
                }
            }
        }
    }

    /// Avant de jeter la sortie : le titre réellement entendu devient `cur`, et la position à laquelle le reprendre est
    /// renvoyée. Pendant un fondu enchaîné, on entend déjà le titre entrant (la position partagée est la sienne) : il
    /// était jeté et le titre sortant reprenait à sa position. À la fin d'un enchaînement, `cur` est déjà le titre
    /// suivant alors qu'on entend encore la fin du précédent : il repart du début, annoncé normalement.
    fn audible_resume(&mut self, pos: u64) -> Option<u64> {
        let front = self.segments.front().map(|s| s.id);
        if let (Some(f), Some(inc)) = (front, self.incoming.as_ref()) {
            if inc.id == f {
                self.cur = self.incoming.take();
                return Some(pos);
            }
        }
        match (&self.cur, front) {
            (Some(c), Some(f)) if c.id != f => {
                self.announced = None;
                Some(0)
            }
            (Some(_), _) => Some(pos),
            (None, _) => None,
        }
    }

    /// Rouvre la sortie (autre périphérique, autre fréquence possible) et reprend le titre en cours à `resume_ms`.
    fn rebuild_output(&mut self, resume_ms: Option<u64>) -> bool {
        let resume_ms = match resume_ms {
            Some(p) => self.audible_resume(p),
            None => None,
        };
        // Fin du dernier titre en train de jouer (plus rien à décoder) : voir plus bas.
        let tail = if self.cur.is_none() { self.segments.front().map(|s| s.id) } else { None };
        self.out = None;
        self.incoming = None;
        self.leftover.clear();
        self.leftover_off = 0;
        self.written = 0;
        self.segments.clear();
        if !self.ensure_output() {
            return false;
        }
        let Some((rate, ch)) = self.out.as_ref().map(|o| (o.rate, o.channels)) else { return false };
        self.flush();
        let Some(track) = self.cur.as_mut() else {
            if let Some(id) = tail {
                if let Some(p) = self.next.take() {
                    // Le suivant était prêt : il démarre sur la nouvelle sortie.
                    self.handle(Cmd::Load { id: p.id, src: p.src, ext: p.ext });
                } else {
                    // Le reste du titre est perdu avec l'ancienne sortie : fin du titre, comme s'il avait fini de jouer.
                    // Avant, rien n'était signalé et la lecture restait bloquée (ni titre suivant, ni reprise possible).
                    self.announced = None;
                    self.shared.playing.store(false, Ordering::Relaxed);
                    self.shared.idle.store(true, Ordering::Relaxed);
                    self.idle_stop_at = Some(Instant::now() + IDLE_STOP);
                    let _ = self.events.send(EngineEvent::Finished { id });
                }
            }
            return true;
        };
        let result = track.reconfigure(rate, ch).and_then(|_| track.seek(resume_ms.unwrap_or(0)));
        match result {
            Ok(actual) => {
                let (id, dur) = (track.id, track.duration_ms);
                // Même numéro de lecture : le titre n'est pas annoncé une seconde fois.
                let seq = self.announced.unwrap_or_else(|| {
                    let s = self.next_seq;
                    self.next_seq += 1;
                    s
                });
                self.segments.push_back(Segment { seq, id, start_sample: 0, start_ms: actual, duration_ms: dur });
                true
            }
            Err(e) => {
                let id = track.id;
                self.cur = None;
                self.err(id, e.to_string());
                false
            }
        }
    }

    fn ensure_output(&mut self) -> bool {
        if self.out.is_none() {
            match open_output(self.shared.clone(), self.device.as_deref()) {
                Ok(o) => {
                    self.out = Some(o);
                    // Sortie rouverte pendant une pause : elle reste arrêtée jusqu'à la reprise.
                    if self.shared.paused.load(Ordering::Relaxed) {
                        self.run_stream(false);
                    }
                }
                Err(e) => {
                    self.err(0, e.to_string());
                    return false;
                }
            }
        }
        true
    }

    /// Vide le ring buffer et remet les compteurs à zéro. iPhone : un tampon neuf remplace l'ancien, sans attendre
    /// le rendu (AVAudioEngine peut être arrêté, en pause).
    #[cfg(target_os = "ios")]
    fn flush(&mut self) {
        self.leftover.clear();
        self.leftover_off = 0;
        self.written = 0;
        self.segments.clear();
        let Some(o) = self.out.as_mut() else { return };
        let (producer, consumer) = rtrb::RingBuffer::<f32>::new(o.rate as usize * o.channels / 2);
        let ctl = new_ctl(self.shared.clone());
        let r = Box::into_raw(Box::new(Renderer::new(consumer, ctl.clone(), o.rate, o.channels)));
        if ios_out::swap(o.renderer, r) {
            o.renderer = r;
            o.producer = producer;
            o.ctl = ctl;
        } else {
            // SAFETY: `r` vient de `Box::into_raw` et n'a pas été installé.
            drop(unsafe { Box::from_raw(r) });
        }
        self.played_base = 0;
    }

    /// Vide le ring buffer et remet les compteurs à zéro.
    #[cfg(not(target_os = "ios"))]
    fn flush(&mut self) {
        self.leftover.clear();
        self.leftover_off = 0;
        self.written = 0;
        self.segments.clear();
        // Le vidage est fait par le callback audio : flux arrêté (pause), on le relance le temps du vidage
        // (il ne produit que du silence tant que la pause est active), puis on l'arrête de nouveau.
        let stopped = self.out.as_ref().is_some_and(|o| !o.running);
        if stopped {
            self.run_stream(true);
        }
        let Some(o) = &self.out else { return };
        let req = o.ctl.flush_req.fetch_add(1, Ordering::AcqRel) + 1;
        let start = Instant::now();
        while o.ctl.flush_ack.load(Ordering::Acquire) != req && start.elapsed() < Duration::from_millis(300) {
            thread::sleep(Duration::from_millis(1));
        }
        self.played_base = o.ctl.played.load(Ordering::Relaxed);
        if stopped {
            self.run_stream(false);
        }
    }

    fn set_paused(&mut self, p: bool) {
        self.shared.paused.store(p, Ordering::Relaxed);
        let something = self.cur.is_some() || !self.segments.is_empty();
        self.shared.playing.store(!p && something, Ordering::Relaxed);
        if !p && something {
            self.idle_stop_at = None;
        }
        // Reprise sans rien à jouer (file terminée) : la sortie reste arrêtée au lieu de tourner sur du silence.
        self.run_stream(!p && something);
        if p {
            for l in &self.shared.levels {
                l.store(0f32.to_bits(), Ordering::Relaxed);
            }
        }
        let _ = self.events.send(EngineEvent::StateChanged);
    }

    /// Met en marche ou arrête le flux de sortie (sans le fermer : la reprise est immédiate, le tampon est gardé).
    fn run_stream(&mut self, run: bool) {
        let Some(o) = self.out.as_mut() else { return };
        // iPhone : une demande de lecture redemande toujours le démarrage (sans effet s'il tourne déjà) ; si iOS avait
        // refusé de relancer le moteur, la reprise le relance au lieu de croire qu'il tourne.
        if o.running == run && !(cfg!(target_os = "ios") && run) {
            return;
        }
        #[cfg(target_os = "ios")]
        let done = {
            if run {
                ios_out::start();
            } else {
                ios_out::stop();
            }
            true
        };
        #[cfg(not(target_os = "ios"))]
        let done = if run { o.stream.play().is_ok() } else { o.stream.pause().is_ok() };
        if done {
            o.running = run;
        }
    }

    fn start_track(&mut self, track: Track, start_ms: u64) {
        self.shared.idle.store(false, Ordering::Relaxed);
        self.shared.duration_ms.store(track.duration_ms, Ordering::Relaxed);
        let seq = self.next_seq;
        self.next_seq += 1;
        self.segments.push_back(Segment {
            seq,
            id: track.id,
            start_sample: self.written,
            start_ms,
            duration_ms: track.duration_ms,
        });
        self.cur = Some(track);
    }

    fn handle(&mut self, cmd: Cmd) {
        match cmd {
            Cmd::Load { id, src, ext } => {
                if !self.ensure_output() {
                    // Aucune sortie (seul casque débranché…) : le titre demandé ne joue pas, l'ancien n'est pas gardé (une
                    // reprise le relançait alors que l'écran montrait le nouveau), et plus d'« en lecture » sans son.
                    self.cur = None;
                    self.incoming = None;
                    self.next = None;
                    self.shared.idle.store(true, Ordering::Relaxed);
                    self.shared.playing.store(false, Ordering::Relaxed);
                    let _ = self.events.send(EngineEvent::StateChanged);
                    return;
                }
                let (rate, ch) = self.out.as_ref().map(|o| (o.rate, o.channels)).unwrap_or((44_100, 2));
                self.cur = None;
                self.incoming = None;
                self.next = None;
                self.flush();
                self.announced = None;
                self.shared.position_ms.store(0, Ordering::Relaxed);
                match open_track(Pending { id, src, ext }, rate, ch) {
                    Ok(t) => {
                        self.start_track(t, 0);
                        self.set_paused(false);
                    }
                    Err(e) => {
                        // Rien à jouer : la sortie s'arrêtera dans 30 s si le lecteur ne relance rien (voir `idle_stop_at`).
                        self.shared.idle.store(true, Ordering::Relaxed);
                        // Plus « en lecture » non plus (l'app et l'écran verrouillé l'affichaient sans aucun son).
                        self.shared.playing.store(false, Ordering::Relaxed);
                        let _ = self.events.send(EngineEvent::StateChanged);
                        self.idle_stop_at = Some(Instant::now() + IDLE_STOP);
                        self.err(id, e.to_string());
                    }
                }
            }
            Cmd::QueueNext { id, src, ext } => {
                let p = Pending { id, src, ext };
                // Le titre en cours est déjà entièrement décodé (saut près de la fin, titre très court) mais encore en train de jouer :
                // le suivant est enchaîné tout de suite. Sinon il attendrait une fin de décodage déjà passée et la lecture resterait bloquée.
                if self.cur.is_none() && self.incoming.is_none() && !self.segments.is_empty() {
                    if let Some((rate, ch)) = self.out.as_ref().map(|o| (o.rate, o.channels)) {
                        match open_track(p, rate, ch) {
                            Ok(t) => self.start_track(t, 0),
                            Err(e) => self.fail(id, e),
                        }
                        return;
                    }
                }
                self.next = Some(p);
            }
            Cmd::ClearNext => self.next = None,
            // Même chose qu'un chargement, avec la piste déjà préparée (et déjà en partie ou entièrement téléchargée).
            Cmd::SkipNext => match self.next.take() {
                Some(p) => self.handle(Cmd::Load { id: p.id, src: p.src, ext: p.ext }),
                None => {
                    let _ = self.events.send(EngineEvent::SkipFailed);
                }
            },
            Cmd::Pause => self.set_paused(true),
            Cmd::Resume => {
                // Sortie perdue puis reprise : on la rouvre (sur le périphérique disponible) à l'endroit où on s'était arrêté.
                if self.out.is_none() && self.cur.is_some() {
                    let pos = self.lost_pos.take().or(Some(self.shared.position_ms.load(Ordering::Relaxed)));
                    if !self.rebuild_output(pos) {
                        self.set_paused(true);
                        return;
                    }
                }
                self.set_paused(false);
            }
            Cmd::SetDevice(name) => {
                if name == self.device {
                    return;
                }
                self.device = name;
                self.last_default_check = Instant::now();
                if self.out.is_some() && (self.cur.is_some() || !self.segments.is_empty()) {
                    // Le titre continue sur le nouveau périphérique, à la même position.
                    let pos = self.shared.position_ms.load(Ordering::Relaxed);
                    self.rebuild_output(Some(pos));
                } else {
                    self.out = None; // sera rouverte sur le bon périphérique au prochain titre
                    if let Ok(mut info) = self.shared.out_info.lock() {
                        info.clear();
                    }
                }
            }
            // iPhone : AVAudioEngine arrêté par iOS (appel, redémarrage du service audio) est simplement relancé :
            // le tampon et la position restent, pas de nouveau chargement du titre.
            #[cfg(target_os = "ios")]
            Cmd::ReopenOutput => {
                if let Some(o) = self.out.as_mut() {
                    o.running = false;
                }
                // Relancé seulement s'il y a quelque chose à jouer (file finie : pas de moteur qui tourne sur du silence).
                let something = self.cur.is_some() || !self.segments.is_empty();
                let run = something && !self.shared.paused.load(Ordering::Relaxed);
                self.run_stream(run);
            }
            #[cfg(not(target_os = "ios"))]
            Cmd::ReopenOutput => {
                if self.cur.is_some() {
                    // Même titre, même position ; pause ou lecture inchangée.
                    let pos = self.lost_pos.take().unwrap_or_else(|| self.shared.position_ms.load(Ordering::Relaxed));
                    self.rebuild_output(Some(pos));
                } else {
                    self.out = None; // rouverte au prochain titre
                }
            }
            Cmd::Stop => {
                self.cur = None;
                self.incoming = None;
                self.next = None;
                self.flush();
                self.announced = None;
                self.shared.idle.store(true, Ordering::Relaxed);
                self.shared.playing.store(false, Ordering::Relaxed);
                self.shared.position_ms.store(0, Ordering::Relaxed);
                // Arrêt demandé : la sortie s'arrête tout de suite au lieu de tourner sur du silence (le prochain titre la relance).
                self.idle_stop_at = None;
                self.run_stream(false);
                let _ = self.events.send(EngineEvent::StateChanged);
            }
            Cmd::Seek(ms) => {
                // Pendant un fondu, le titre affiché est déjà l'entrant (annoncé au début du fondu) : un saut le vise lui.
                // On termine donc le fondu d'un coup et on saute dans le titre entrant. Avant que le fondu soit audible,
                // le titre affiché est encore le sortant, dont le décodeur est déjà arrivé à la fin : le saut est ignoré.
                if let Some(inc_id) = self.incoming.as_ref().map(|t| t.id) {
                    if self.segments.front().map(|s| s.id) != Some(inc_id) {
                        return;
                    }
                    self.cur = self.incoming.take();
                }
                let audible = self.segments.front().map(|s| s.id);
                let Some(track) = self.cur.as_mut() else { return };
                if Some(track.id) != audible {
                    return;
                }
                let ms = if track.duration_ms > 0 { ms.min(track.duration_ms.saturating_sub(1)) } else { ms };
                match track.seek(ms) {
                    Ok(actual) => {
                        let id = track.id;
                        let dur = track.duration_ms;
                        let seq = self.segments.front().map_or(0, |s| s.seq);
                        // Le titre suivant déjà préparé reste valable : un saut dans le titre en cours ne le change pas.
                        self.flush();
                        self.segments.push_back(Segment { seq, id, start_sample: 0, start_ms: actual, duration_ms: dur });
                        // Position à jour AVANT de prévenir : sinon les fenêtres reçoivent l'ancienne et n'ont la bonne qu'au point suivant (1 s).
                        self.shared.position_ms.store(actual, Ordering::Relaxed);
                        let _ = self.events.send(EngineEvent::StateChanged);
                    }
                    Err(e) => {
                        let id = track.id;
                        self.err(id, e.to_string());
                    }
                }
            }
        }
    }

    /// Pousse des échantillons dans le ring buffer. Renvoie `true` si quelque chose a été écrit.
    fn pump(&mut self) -> bool {
        let mut pushed_any = false;
        loop {
            // 1) vider le reliquat dans le ring buffer
            if self.leftover_off < self.leftover.len() {
                let Some(out) = self.out.as_mut() else { return pushed_any };
                let rest = &self.leftover[self.leftover_off..];
                let n = rest.len().min(out.producer.slots());
                if n == 0 {
                    return pushed_any;
                }
                if let Ok(mut chunk) = out.producer.write_chunk(n) {
                    let (a, b) = chunk.as_mut_slices();
                    let (r1, r2) = rest[..n].split_at(a.len());
                    a.copy_from_slice(r1);
                    b.copy_from_slice(r2);
                    chunk.commit_all();
                }
                self.leftover_off += n;
                self.written += n as u64;
                pushed_any = true;
                if self.leftover_off < self.leftover.len() {
                    return pushed_any; // ring plein
                }
                self.leftover.clear();
                self.leftover_off = 0;
            }
            // 2) produire le bloc suivant (piste seule ou mélange de deux pistes)
            let Some((rate, ch)) = self.out.as_ref().map(|o| (o.rate, o.channels)) else { return pushed_any };
            match self.next_block(rate, ch) {
                Some(block) => self.leftover = block,
                None => return pushed_any,
            }
        }
    }

    fn fail(&mut self, id: i64, e: AudioError) {
        self.err(id, e.to_string());
    }

    /// Prochain bloc d'échantillons à jouer. `None` : rien à produire pour l'instant.
    fn next_block(&mut self, rate: u32, ch: usize) -> Option<Vec<f32>> {
        // Début d'un fondu : la fin de la piste approche et la suivante est prête.
        let xf_ms = self.shared.crossfade_ms.load(Ordering::Relaxed);
        if xf_ms > 0 && self.incoming.is_none() && self.next.is_some() {
            if let Some(cur) = self.cur.as_ref() {
                if cur.duration_ms > 0 {
                    let total = cur.duration_ms * u64::from(rate) / 1000;
                    let remaining = total.saturating_sub(cur.delivered);
                    // Jamais plus de la moitié de la piste.
                    let xf_frames = (xf_ms * u64::from(rate) / 1000).min(total / 2);
                    if xf_frames > 0 && remaining <= xf_frames {
                        if let Some(p) = self.next.take() {
                            let id = p.id;
                            match open_track(p, rate, ch) {
                                Ok(t) => {
                                    self.fade_total = remaining.max(1);
                                    self.fade_pos = 0;
                                    let seq = self.next_seq;
                                    self.next_seq += 1;
                                    self.segments.push_back(Segment {
                                        seq,
                                        id: t.id,
                                        start_sample: self.written,
                                        start_ms: 0,
                                        duration_ms: t.duration_ms,
                                    });
                                    self.incoming = Some(t);
                                }
                                Err(e) => self.fail(id, e),
                            }
                        }
                    }
                }
            }
        }

        // --- Mélange pendant le fondu
        if self.incoming.is_some() {
            let want = 4096 - (4096 % ch);
            let (Some(cur), Some(inc)) = (self.cur.as_mut(), self.incoming.as_mut()) else {
                // Piste sortante disparue (erreur) : la piste entrante prend le relais seule.
                self.cur = self.incoming.take();
                return Some(Vec::new());
            };
            if let Err(e) = cur.fill(ch, want) {
                let id = cur.id;
                self.cur = self.incoming.take();
                self.fail(id, e);
                return Some(Vec::new());
            }
            if let Err(e) = inc.fill(ch, want) {
                let id = inc.id;
                self.incoming = None;
                self.fail(id, e);
                return Some(Vec::new());
            }
            let n = cur.pending.len().min(inc.pending.len()).min(want);
            let n = n - n % ch;
            if n == 0 {
                // La piste sortante est vide (fin de fichier) : le fondu est terminé.
                self.cur = self.incoming.take();
                return Some(Vec::new());
            }
            let mixed = mix_equal_power(&cur.pending[..n], &inc.pending[..n], ch, self.fade_pos, self.fade_total);
            cur.pending.drain(..n);
            inc.pending.drain(..n);
            let frames = (n / ch) as u64;
            cur.delivered += frames;
            inc.delivered += frames;
            self.fade_pos += frames;
            if self.fade_pos >= self.fade_total {
                self.cur = self.incoming.take();
            }
            return Some(mixed);
        }

        // --- Lecture normale d'une seule piste
        let track = self.cur.as_mut()?;
        if track.pending.is_empty() {
            if let Err(e) = track.fill(ch, 1) {
                let id = track.id;
                self.cur = None;
                // Le suivant préparé est lâché aussi : sinon le moteur ne voyait jamais la fin (ni « fini », ni suivant)
                // et tournait sur du silence en gardant l'app éveillée. Le lecteur retente ou passe au suivant lui-même.
                self.next = None;
                self.fail(id, e);
                return None;
            }
        }
        if !track.pending.is_empty() {
            let block = std::mem::take(&mut track.pending);
            track.delivered += (block.len() / ch) as u64;
            return Some(block);
        }
        // Fin de fichier : enchaînement sans coupure sur la piste suivante, si elle est prête.
        self.cur = None;
        if let Some(p) = self.next.take() {
            let id = p.id;
            match open_track(p, rate, ch) {
                Ok(t) => self.start_track(t, 0),
                Err(e) => self.fail(id, e),
            }
        }
        None
    }

    fn update_position(&mut self) {
        let Some(o) = &self.out else { return };
        let played = o.ctl.played.load(Ordering::Relaxed).saturating_sub(self.played_base);
        let per_ms = (o.rate as u64 * o.channels as u64).max(1);

        while self.segments.len() >= 2 && self.segments[1].start_sample <= played {
            self.segments.pop_front();
        }
        let Some(front) = self.segments.front() else { return };

        if self.announced != Some(front.seq) && played >= front.start_sample {
            self.announced = Some(front.seq);
            self.shared.current_id.store(front.id, Ordering::Relaxed);
            self.shared.duration_ms.store(front.duration_ms, Ordering::Relaxed);
            let _ = self.events.send(EngineEvent::TrackStarted { id: front.id });
        }
        let pos = front.start_ms + played.saturating_sub(front.start_sample) * 1000 / per_ms;
        self.shared.position_ms.store(pos, Ordering::Relaxed);
        self.shared.playing.store(!self.shared.paused.load(Ordering::Relaxed), Ordering::Relaxed);

        // Fin : plus de décodeur, plus de suivant, ring buffer entièrement joué.
        if self.cur.is_none() && self.incoming.is_none() && self.next.is_none() && self.leftover_off >= self.leftover.len()
            && self.segments.len() == 1 && played >= self.written
        {
            let id = front.id;
            self.segments.clear();
            self.announced = None;
            self.shared.playing.store(false, Ordering::Relaxed);
            self.shared.idle.store(true, Ordering::Relaxed);
            // Dernier titre joué : la sortie s'arrêtera dans 30 s si rien n'est relancé d'ici là (voir `idle_stop_at`).
            self.idle_stop_at = Some(Instant::now() + IDLE_STOP);
            let _ = self.events.send(EngineEvent::Finished { id });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn id3(size: u8, body: &[u8]) -> Vec<u8> {
        let mut v = vec![b'I', b'D', b'3', 4, 0, 0, 0, 0, 0, size];
        v.extend(std::iter::repeat(0u8).take(size as usize));
        v.extend_from_slice(body);
        v
    }

    fn read_all(mut s: SkipId3) -> Vec<u8> {
        let mut out = Vec::new();
        s.read_to_end(&mut out).unwrap();
        out
    }

    #[test]
    fn skips_empty_and_filled_tags() {
        for size in [0u8, 5, 100] {
            let s = SkipId3::new(Box::new(Cursor::new(id3(size, b"AUDIO")))).unwrap();
            assert_eq!(s.byte_len(), Some(5));
            assert_eq!(read_all(s), b"AUDIO");
        }
    }

    #[test]
    fn leaves_untagged_streams_alone() {
        let s = SkipId3::new(Box::new(Cursor::new(b"RIFF0123456789".to_vec()))).unwrap();
        assert_eq!(read_all(s), b"RIFF0123456789");
    }

    #[test]
    fn seek_is_relative_to_audio_start() {
        let mut s = SkipId3::new(Box::new(Cursor::new(id3(0, b"ABCDEF")))).unwrap();
        assert_eq!(s.seek(SeekFrom::Start(2)).unwrap(), 2);
        let mut b = [0u8; 2];
        s.read_exact(&mut b).unwrap();
        assert_eq!(&b, b"CD");
        assert_eq!(s.seek(SeekFrom::End(-1)).unwrap(), 5);
    }

    /// Données réelles : un aperçu Deezer (étiquette ID3 vide). Ignoré si le fichier est absent.
    #[test]
    fn opens_real_deezer_preview() {
        let p = std::env::temp_dir().join("prev.mp3");
        let Ok(f) = std::fs::File::open(p) else { return };
        let t = open_track(Pending { id: 1, src: Box::new(f), ext: Some("mp3".into()) }, 48_000, 2)
            .unwrap_or_else(|e| panic!("{e}"));
        assert!(t.src_ch >= 1);
    }

    /// Petit fichier WAV (silence) ouvert comme un vrai titre.
    fn wav_track(id: i64) -> Track {
        let data_len = 4u32 * 100;
        let mut v = Vec::new();
        v.extend_from_slice(b"RIFF");
        v.extend_from_slice(&(36 + data_len).to_le_bytes());
        v.extend_from_slice(b"WAVEfmt ");
        v.extend_from_slice(&16u32.to_le_bytes());
        v.extend_from_slice(&1u16.to_le_bytes());
        v.extend_from_slice(&2u16.to_le_bytes());
        v.extend_from_slice(&48_000u32.to_le_bytes());
        v.extend_from_slice(&(48_000u32 * 4).to_le_bytes());
        v.extend_from_slice(&4u16.to_le_bytes());
        v.extend_from_slice(&16u16.to_le_bytes());
        v.extend_from_slice(b"data");
        v.extend_from_slice(&data_len.to_le_bytes());
        v.resize(v.len() + data_len as usize, 0);
        open_track(Pending { id, src: Box::new(Cursor::new(v)), ext: Some("wav".into()) }, 48_000, 2)
            .unwrap_or_else(|e| panic!("{e}"))
    }

    /// Changement de sortie : on reprend le titre réellement entendu, pas celui que le décodeur prépare.
    #[test]
    fn output_change_resumes_the_track_heard() {
        let (_tx, rx) = mpsc::channel();
        let (events, _rx_events) = tokio::sync::mpsc::unbounded_channel();
        let mut w = Worker::new(rx, events, Arc::new(Shared::default()));
        let seg = |id| Segment { seq: 0, id, start_sample: 0, start_ms: 0, duration_ms: 0 };
        // Fondu enchaîné : on entend déjà le titre entrant, il devient le titre en cours, à la même position.
        w.cur = Some(wav_track(1));
        w.incoming = Some(wav_track(2));
        w.segments.push_back(seg(2));
        assert_eq!(w.audible_resume(1234), Some(1234));
        assert_eq!(w.cur.as_ref().map(|t| t.id), Some(2));
        assert!(w.incoming.is_none());
        // Fin d'un enchaînement : on entend encore la fin du titre 1 alors que le 2 est prêt ; le 2 repart du début.
        w.segments.clear();
        w.segments.push_back(seg(1));
        w.announced = Some(7);
        assert_eq!(w.audible_resume(500), Some(0));
        assert_eq!(w.announced, None);
        // Cas simple : le titre entendu est le titre en cours.
        w.segments.clear();
        w.segments.push_back(seg(2));
        assert_eq!(w.audible_resume(800), Some(800));
        // Plus rien en cours : rien à reprendre.
        w.cur = None;
        assert_eq!(w.audible_resume(800), None);
    }

    #[test]
    fn equal_power_fade_keeps_energy_and_hits_the_ends() {
        let n = 1000;
        // Niveau modéré (sous le seuil du limiteur une fois mélangé) : le mélange est exactement celui de la courbe.
        let a = vec![0.5f32; n * 2];
        let b = vec![0.5f32; n * 2];
        let out = mix_equal_power(&a, &b, 2, 0, n as u64);
        // Début : seulement la piste sortante ; fin : seulement l'entrante.
        assert!((out[0] - 0.5).abs() < 1e-3);
        assert!((out[(n - 1) * 2] - 0.5).abs() < 0.01);
        // Deux sources identiques : l'énergie (somme des carrés des gains) est constante = 1.
        for (i, f) in out.chunks_exact(2).enumerate() {
            let t = i as f32 / n as f32;
            let (si, co) = (t * std::f32::consts::FRAC_PI_2).sin_cos();
            assert!((si * si + co * co - 1.0).abs() < 1e-5);
            assert!(f[0] > 0.49, "pas de creux de volume au milieu du fondu: {}", f[0]);
        }
        // Deux titres à pleine puissance : la somme (jusqu'à 1,41) ne dépasse jamais 1, donc pas d'écrêtage.
        let loud = vec![1.0f32; n * 2];
        let out3 = mix_equal_power(&loud, &loud, 2, 0, n as u64);
        assert!(out3.iter().all(|&x| x <= 1.0), "écrêtage pendant le fondu");
        assert!(out3[n] > 0.95, "le milieu du fondu reste fort (compressé, pas écrasé) : {}", out3[n]);
        // Sources opposées au milieu : tout vient de la piste sortante au début.
        let out2 = mix_equal_power(&[0.6, 0.6], &[0.0, 0.0], 2, 0, 100);
        assert!((out2[0] - 0.6).abs() < 1e-3);
    }

    #[test]
    fn bands_separate_bass_from_treble() {
        let rate = 48_000;
        let level = |freq: f32| {
            let shared = Shared::default();
            let mut b = Bands::new(rate);
            for i in 0..rate {
                let v = (i as f32 / rate as f32 * freq * std::f32::consts::TAU).sin() * 0.5;
                b.push(v, false, 2);
                b.push(v, true, 2);
            }
            b.publish(&shared);
            shared.levels.each_ref().map(|x| f32::from_bits(x.load(Ordering::Relaxed)))
        };
        let [lo, _, hi] = level(60.0);
        assert!(lo > hi * 10.0, "60 Hz : surtout des graves ({lo} / {hi})");
        let [lo, _, hi] = level(8_000.0);
        assert!(hi > lo * 10.0, "8 kHz : surtout des aigus ({lo} / {hi})");
        let [_, mid, _] = level(700.0);
        assert!(mid > 0.1, "700 Hz : des médiums ({mid})");
    }

    #[test]
    fn gain_goes_from_minus_10_to_plus_12_db() {
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let e = Engine::start(tx);
        let gain = || f32::from_bits(e.shared.boost.load(Ordering::Relaxed));
        e.set_boost_db(-10.0);
        assert!((gain() - 0.3162).abs() < 1e-3, "−10 dB ≈ ×0,316 : {}", gain());
        e.set_boost_db(-40.0);
        assert!((gain() - 0.3162).abs() < 1e-3, "borné à −10 dB");
        e.set_boost_db(0.0);
        assert!((gain() - 1.0).abs() < 1e-6);
        e.set_boost_db(30.0);
        assert!((gain() - 3.981).abs() < 1e-2, "borné à +12 dB");
    }

    #[test]
    fn soft_limit_is_transparent_below_the_knee_and_never_exceeds_one() {
        for x in [0.0f32, 0.1, -0.5, 0.79, -0.8] {
            assert_eq!(soft_limit(x), x, "inchangé sous le seuil");
        }
        let mut prev = soft_limit(0.8);
        for i in 1..=200 {
            let x = 0.8 + i as f32 * 0.05; // jusqu'à ~10,8 (gain énorme)
            let y = soft_limit(x);
            assert!(y >= prev && y <= 1.0, "croissant et borné par 1.0 : {x} -> {y}");
            assert_eq!(soft_limit(-x), -y, "symétrique");
            prev = y;
        }
        assert!((soft_limit(0.8001) - 0.8001).abs() < 1e-3, "continu au seuil");
        let y = soft_limit(1.5);
        assert!(y > 0.8 && y < 1.0, "un pic à 1,5 est compressé sous 1,0 sans être écrasé : {y}");
    }
}
