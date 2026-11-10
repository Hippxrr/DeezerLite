# 🎧 Deezer Lite · iOS

![Version](https://img.shields.io/badge/version-2.3.0-a238ff)
![iOS](https://img.shields.io/badge/iOS-17%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/SwiftUI-native-F05138?logo=swift&logoColor=white)
![Rust](https://img.shields.io/badge/engine-Rust-B7410E?logo=rust&logoColor=white)
![License](https://img.shields.io/badge/license-AGPL--3.0-blue)

A lightweight, native Deezer client for iPhone: a **SwiftUI** interface on top of a **Rust** engine that handles
networking, the play queue and audio.

> 💬 **Contact**: on Discord, `@chippooo.` (on request).
>
> 🤖 **Vibe-coded project**: largely written with AI, and tested step by step on a real iPhone.
>
> ⚠️ **Unofficial app**, not affiliated with Deezer: see the [Disclaimer](#%EF%B8%8F-disclaimer).

**At a glance**

- 📱 **Runs on**: iPhone with iOS 17 or later (portrait). Liquid Glass and the app's own tab bar on iOS 26.1+.
- 🎵 **Needs**: a Deezer account. FLAC requires a subscription that includes lossless.
- 🛠 **Built with**: a Mac and Xcode, one command (`bash scripts/build-ipa.sh`), producing an unsigned IPA.
- 📲 **Installed by**: sideloading only (no App Store, no TestFlight, no source to add).

| | |
|---|---|
| Device | iPhone, iOS 17 or later |
| Display name | Deezer |
| Version | 2.3.0 |
| Bundle ID | `com.hippxrr.deezerlite` |
| UI | SwiftUI, Observation, Liquid Glass on iOS 26 |
| Engine | Rust (2021 edition), bridged to Swift with UniFFI 0.29 |
| Xcode project | Described as text with XcodeGen (`ios/project.yml`) |
| Build | On a Mac, unsigned IPA |
| License | AGPL-3.0 |

---

## Contents

1. [Features](#-features)
2. [Sign-in and account](#-sign-in-and-account)
3. [Privacy](#-privacy)
4. [Architecture](#-architecture)
5. [Audio pipeline](#-audio-pipeline)
6. [Building the IPA](#-building-the-ipa)
7. [Credits](#-credits)
8. [Disclaimer](#%EF%B8%8F-disclaimer)

---

## ✨ Features

### Playback

- **Selectable quality**: FLAC, MP3 320 kbps or MP3 128 kbps.
- **Gapless playback** between tracks, plus an adjustable **crossfade** from 0 to 10 s.
- **5-band equalizer** (60 Hz, 230 Hz, 910 Hz, 3.6 kHz, 14 kHz) with about fifteen presets and a custom mode. When
  flat, the signal is left strictly untouched.
- **Full player**: synced lyrics, editable queue, track credits, sharing, blurred background taken from the cover.
- **Mini player**: swipe sideways to change track, tap to open the full player; its progress bar can be hidden.
- **Lock screen and Control Center**: title, artwork, position and controls.
- **CarPlay**: home, library and recent listens on the car screen.
- **Interruptions handled like Apple's music apps**: playback pauses when another app takes the audio (call, voice
  message, video) and resumes only if that app allows it and music was playing. Removing earbuds pauses; putting
  them back within 30 minutes resumes.
- **Resume on launch**: the last session comes back at the same position (can be turned off).

### 📥 Offline

- **Downloads**: single tracks, albums, playlists and liked tracks, with their own download quality setting.
- **Background downloads**: they keep going when the app is closed; iOS hands the finished files back on the next
  launch.
- **Network-aware queue**: without a connection, downloads wait instead of failing, and restart when the network
  comes back. Failed items are listed and can be cleared.
- **Collections kept in sync**: at launch, downloaded playlists and albums pick up the tracks added on Deezer and
  drop the removed ones. A track downloaded on its own stays even if it leaves those collections.
- **Full offline playback**: artwork and lyrics are stored with the tracks, so the player looks the same without a
  network.
- **Offline listens**: listens made without a network are kept and reported to Deezer later, with their real time.
- **Downloads page**: downloads in progress first, then failures, in the order they were requested.

### Browsing

- 🏠 **Home**: Flow, liked tracks, pinned playlists, albums and artists, then Deezer's recommendations grouped by
  category (recently played, new releases, mixes, "Mixes inspired by"…), each one can be toggled and reordered.
- 🔍 **Search**: results as you type, a featured artist with their latest release, tracks, albums, playlists and
  artists; search history.
- 📚 **Library**: playlists, albums, artists and stats.
- 📊 **Official stats**: Deezer's monthly recap (listening time, tracks, artists, genres) as a shareable image, and
  the latest listens from Deezer's history.
- 👨‍👩‍👧 **Family accounts**: profile picker at launch ("Who's listening?") and profile switching in settings.

### Personalization

- 🌍 **Language**: French, English, Spanish, switched without restarting the app.
- 🎨 **Appearance**: dark, light or system mode; color themes; black, OLED black, slate blue or plum background;
  four app icons.
- **Tab bar** (iOS 26.1 and later): the app's own full-width bar, which shrinks while scrolling (current tab on the
  left, mini player in the middle, search on the right), or the native iOS bar.
- **Custom playlist covers**, cropped inside the app.
- **Renamable liked tracks** (on the phone only).

### Under the hood

- **Listens reported to Deezer** like the official app (history, stats, "My Deezer Month"): a listen counts after
  30 s, or 90 % of a shorter track.
- **Cover repair**: when Deezer keeps the address of a deleted image, the album's current cover is found and
  remembered.
- **Local copy** of home and library: shown instantly at launch, then refreshed.

---

## 🔑 Sign-in and account

Two ways to sign in, both from the first screen:

- **With Deezer's website** (recommended): the regular Deezer sign-in page opens inside the app. Once you are
  signed in, the app keeps only the session cookie (`arl`) and closes the page. The page runs in a private,
  in-memory browser: no cookie, cache or file from it stays on the phone.
- **With an `arl` cookie**: paste the value of the `arl` cookie from a browser where you are signed in to
  deezer.com.

The `arl` cookie gives full access to the account, like a password: never share it. The app stores it in the iOS
keychain, on this device only.

**What the account changes:**

- **Quality**: the app asks for the chosen quality and steps down when the account isn't entitled to it. FLAC needs
  a subscription that includes lossless; otherwise MP3 320 kbps, then MP3 128 kbps, are used.
- **Actual quality** is shown in the player, as delivered by Deezer, not as requested.
- **Family accounts**: after signing in, the app asks which profile is listening; the choice is remembered.

---

## 🔐 Privacy

- **No tracking, no analytics, no ads, no third-party service.** The app only talks to Deezer's own servers.
- **The only usage data sent to Deezer is listen reports** (which track, how long it was played, in which format,
  and when). They are what feeds your Deezer history and your official monthly and yearly stats.
- **Everything else is either content or your own actions**: requests needed to show the catalog, search and your
  library, plus what you explicitly do (liking a track, adding it to a playlist…).
- **Stays on the phone**: search history, pinned items, custom covers, the liked tracks name, settings, the cached
  home and library, and downloads. The Deezer session is kept in the iOS keychain.

### Logout and uninstall

- **Logging out** (Settings → Log out) erases everything tied to the account from the phone: the session, its
  cookies and keychain entry, the cached home, library and pages, search history, pinned items, the last session to
  resume, custom covers, the liked tracks name, and all offline downloads (downloads in progress are stopped).
- **Deleting the app**: iOS removes all of its files, settings and downloads, but keeps keychain items. To make
  sure nothing survives, the app checks on launch whether its data folder exists: if it doesn't (first launch after
  an install), any Deezer session left in the keychain by a deleted install is erased. A reinstall therefore always
  starts logged out, while regular app updates keep you logged in.

---

## 🧱 Architecture

The app is split into two parts that stay separate.

```
┌──────────────────────────── iOS app (Swift) ─────────────────────────────┐
│  SwiftUI UI      Player (@Observable)      CarPlay      Lock screen        │
│                         │                                                  │
│                 audio session · AVAudioEngine                              │
└─────────────────────────┼───────────────────────────┬──────────────────────┘
                          │ UniFFI (calls, data)       │ dz_render (C, real-time)
┌─────────────────────────┼────────── Engine (Rust) ───┼──────────────────────┐
│  dz-ffi ── dz-core (player, queue, listens) ── dz-audio (decoding, mixing)  │
│                 │                                     │                      │
│              dz-api (Deezer)                    dz-stream (streams)          │
└───────────────────────────────────────────────────────────────────────────┘
```

**The engine, in Rust**, does all the business work: it talks to Deezer (catalog, search, library, listens, stats),
owns the play queue, preloads the next track, downloads, decodes and mixes audio. It is built as a static library
for `aarch64-apple-ios`, fully optimized (`lto = "fat"`, `panic = "abort"`).

**The app, in Swift**, handles everything specific to iOS: screens, the audio session, the lock screen, CarPlay and
the keychain. A single observable object, `Player`, connects both sides: it calls the engine, keeps the displayed
state and publishes it to the screens.

**The bridge** is generated by UniFFI: `scripts/build-core.sh` produces the Swift bindings and a
`DeezerLiteCore.xcframework` from the library. Calls are asynchronous on the Swift side (`async`/`await`) and never
block the UI.

---

## 🔊 Audio pipeline

```
network ─▶ dz-stream ─▶ decoding (Symphonia) ─▶ resampling ─▶ crossfade / mixing
                                                                     │
                                       lock-free ring buffer (~500 ms)
                                                                     │
           AVAudioEngine ◀── dz_render ◀── volume · equalizer · limiter
```

- **Decoding** runs on a dedicated thread with Symphonia (FLAC, MP3, AAC…). The next track is prepared ahead of
  time for gapless playback.
- **Ring buffer**: `rtrb` (single producer, single consumer), about half a second between decoding and output.
- **Output**: an `AVAudioSourceNode` calls the C function `dz_render` on iOS's real-time thread. This path never
  allocates memory, never takes a lock and never waits: if audio is missing, it outputs silence.
- **Rendering**: volume, equalizer (biquad filters) and a soft limiter that only kicks in when gain exceeds 1.
- **Power saving**: iOS's audio engine is stopped while paused. During playback, the decoding thread wakes up every
  100 ms when the buffer is full. Requested hardware buffer: 46 ms.

---

## 🛠 Building the IPA

Everything below happens on a Mac, in the **Terminal** app (Applications → Utilities → Terminal). Run the commands
one at a time and wait for each one to finish.

### What you need

- A Mac with **macOS Tahoe 26.6 or later** if you want Xcode 27 (iOS 27 SDK). Xcode 26 also works on older macOS
  versions.
- About **20 GB of free space** (Xcode, Rust and the build files).
- A copy of this repository (cloned with git, or downloaded as a ZIP from GitHub).

### 1. One-time setup

**Xcode.** Install it from the App Store, open it once, accept the license and let it finish installing its
components. Then point the command-line tools to it:

```bash
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
```

**Homebrew** (package manager for the Mac). Follow the one-line install from [brew.sh](https://brew.sh), then close
and reopen the Terminal.

**Rust** and the iPhone target. Accept the default options, then close and reopen the Terminal:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-apple-ios
```

**XcodeGen** (creates the Xcode project from `ios/project.yml`):

```bash
brew install xcodegen
```

**Get the code**, either way:

- **With git**:

  ```bash
  cd ~
  git clone https://github.com/Hippxrr/DeezerLite.git
  ```

  The code is now in the `DeezerLite` folder of your home folder.

- **As a ZIP**: on the repository page on GitHub, click **Code** → **Download ZIP**, unzip it, rename the folder to
  `DeezerLite` (GitHub names it `DeezerLite-main`) and move it to your home folder.

### 2. Build

Go into the folder:

```bash
cd ~/DeezerLite
```

To get the latest changes: run `git pull` if you cloned with git, or download the ZIP again and replace the
folder.

Then build everything with one command:

```bash
bash scripts/build-ipa.sh
```

The script first checks that Xcode, Rust, the iPhone target and XcodeGen are installed, then runs four steps: Rust
engine, Xcode project, app, IPA. The first run downloads and compiles everything and can take several minutes;
later runs are much faster. It ends with:

```
✅ build/DeezerLite-x.x.x.ipa
```

where `x.x.x` is the app version (see [Versioning](#versioning)).

The IPA is in `~/DeezerLite/build/` (in Finder: Go → Home → `DeezerLite` → `build`). If the app fails
to compile, the script prints only the `error:` lines; the full log is in `build/xcodebuild.log`.

<details>
<summary>What the script does, step by step</summary>

```bash
# 1. Rust engine -> XCFramework + generated Swift
bash scripts/build-core.sh

# 2. Xcode project
xcodegen generate --spec ios/project.yml

# 3. App, without signing
xcodebuild -project ios/DeezerLite.xcodeproj -scheme DeezerLite -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/dd \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

# 4. IPA: ad hoc signature with the entitlements, then zip
mkdir -p build/ipa/Payload
cp -R build/dd/Build/Products/Release-iphoneos/DeezerLite.app build/ipa/Payload/
codesign --force --sign - --entitlements ios/DeezerLite/App/DeezerLite.entitlements build/ipa/Payload/DeezerLite.app
(cd build/ipa && zip -qry ../DeezerLite-x.x.x.ipa Payload)
```

</details>

### 3. Install

The app is installed by **sideloading only**: there is no App Store release, no TestFlight and no source or repo to
add to an install app. Take the IPA from `build/` and install it on the iPhone with a sideloading tool, which signs
it with your own Apple ID or certificate.

The IPA only carries an ad hoc signature, so it must be signed during sideloading. CarPlay only works if the signing
profile also includes the CarPlay entitlement.

### Versioning

The app version is fixed in the code: `MARKETING_VERSION` in `ios/project.yml`, currently **2.3.0**. A build made
on the Mac always carries that version, there is nothing to choose. To release a new version, change that line.

### If something goes wrong

| Message | Fix |
|---|---|
| `xcode-select: error` or `xcodebuild: command not found` | Xcode is not installed or not selected: run the two `sudo` commands of the Xcode step again |
| `iOS … is not installed` | Open Xcode → Settings → Components and install the iOS platform, then build again |
| `cargo: command not found` | Close and reopen the Terminal after installing Rust |
| `error:` lines during `xcodebuild` | A compilation error in the Swift code: copy those lines |

---

## 🙏 Credits

- [OpenDeezer](https://github.com/Cycl0o0/OpenDeezer) (AGPL-3.0): the `dz-decrypt` crate is based on this project,
  then reworked for Deezer Lite.

---

## ⚠️ Disclaimer

Deezer Lite is an independent, personal project. It is not affiliated with, endorsed by or supported by Deezer SA.
"Deezer" and the Deezer logo are trademarks of Deezer SA. The app requires your own Deezer account, and using it
remains subject to Deezer's terms of use. This software is provided as is, without warranty of any kind.

---

## 📄 License

AGPL-3.0, see [LICENSE](LICENSE).
