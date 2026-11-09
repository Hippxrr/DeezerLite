#!/usr/bin/env bash
# Cœur Rust -> libdz_ffi.a (iPhone) -> Swift généré par UniFFI -> DeezerLiteCore.xcframework.
# À lancer sur un Mac (ou par le workflow GitHub), depuis n'importe où.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=aarch64-apple-ios
export IPHONEOS_DEPLOYMENT_TARGET=17.0

cargo build -p dz-ffi --release --target "$TARGET"
LIB="target/$TARGET/release/libdz_ffi.a"

rm -rf build/gen build/DeezerLiteCore.xcframework
mkdir -p build/gen/include ios/Generated

# Le générateur est un petit binaire pour le Mac ; il lit l'interface directement dans la bibliothèque.
cargo run -q -p uniffi-bindgen -- generate --library "$LIB" --language swift --out-dir build/gen

mv build/gen/*.h build/gen/include/
# Xcode cherche un module.modulemap à côté des en-têtes de l'XCFramework.
mv build/gen/dz_ffiFFI.modulemap build/gen/include/module.modulemap
# Sortie du son (dz_render, appelée par AVAudioEngine) : fonctions C hors UniFFI, ajoutées au même module.
cp crates/dz-ffi/include/dz_audio_output.h build/gen/include/
perl -0pi -e 's/(header "dz_ffiFFI\.h")/$1\n    header "dz_audio_output.h"/' build/gen/include/module.modulemap
grep -q 'dz_audio_output.h' build/gen/include/module.modulemap || { echo "module.modulemap : en-tête de sortie audio non ajouté" >&2; exit 1; }
cp build/gen/*.swift ios/Generated/

xcodebuild -create-xcframework -library "$LIB" -headers build/gen/include -output build/DeezerLiteCore.xcframework
echo "Cœur prêt : build/DeezerLiteCore.xcframework ($(du -h "$LIB" | cut -f1) de bibliothèque statique avant édition de liens)"
