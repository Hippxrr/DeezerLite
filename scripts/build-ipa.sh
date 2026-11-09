#!/usr/bin/env bash
# Construit l'IPA sur un Mac, en une commande : moteur Rust, projet Xcode, app sans signature, puis IPA.
# Même suite d'étapes que le workflow GitHub. La version vient du projet (MARKETING_VERSION dans ios/project.yml).
# Usage, depuis n'importe où : bash scripts/build-ipa.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "❌ $1" >&2; exit 1; }

# --- Outils nécessaires
command -v xcodebuild >/dev/null || fail "Xcode introuvable : installe-le, puis « sudo xcode-select -s /Applications/Xcode.app »."
command -v cargo >/dev/null || fail "Rust introuvable : installe-le (rustup), puis rouvre le Terminal."
command -v xcodegen >/dev/null || fail "XcodeGen introuvable : « brew install xcodegen »."
rustup target list --installed | grep -q '^aarch64-apple-ios$' || fail "Cible iPhone absente : « rustup target add aarch64-apple-ios »."

VERSION=$(sed -nE 's/.*MARKETING_VERSION: "([^"]*)".*/\1/p' ios/project.yml)
[ -n "$VERSION" ] || fail "Version introuvable dans ios/project.yml."
echo "▶ Deezer Lite $VERSION · $(xcodebuild -version | head -1)"

# --- 1. Moteur Rust -> XCFramework + Swift généré
echo "▶ 1/4 Moteur Rust"
bash scripts/build-core.sh

# --- 2. Projet Xcode
echo "▶ 2/4 Projet Xcode"
xcodegen generate --spec ios/project.yml --quiet

# --- 3. App, sans signature (journal complet dans build/xcodebuild.log, seules les erreurs affichées en cas d'échec)
echo "▶ 3/4 Compilation de l'app"
mkdir -p build
if ! xcodebuild \
    -project ios/DeezerLite.xcodeproj \
    -scheme DeezerLite \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build/dd \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build > build/xcodebuild.log 2>&1; then
  echo "❌ Échec de la compilation. Erreurs :" >&2
  grep -E "error:" build/xcodebuild.log | sed 's|.*/ios/DeezerLite/||' | sort -u | head -40 >&2
  echo "Journal complet : build/xcodebuild.log" >&2
  exit 1
fi

# --- 4. IPA : signature ad hoc avec les droits (CarPlay), puis archive
echo "▶ 4/4 IPA"
rm -rf build/ipa
mkdir -p build/ipa/Payload
cp -R build/dd/Build/Products/Release-iphoneos/DeezerLite.app build/ipa/Payload/
codesign --force --sign - --entitlements ios/DeezerLite/App/DeezerLite.entitlements build/ipa/Payload/DeezerLite.app
IPA="build/DeezerLite-$VERSION.ipa"
rm -f "$IPA"
(cd build/ipa && zip -qry "../DeezerLite-$VERSION.ipa" Payload)

echo "✅ $IPA ($(du -h "$IPA" | cut -f1))"
