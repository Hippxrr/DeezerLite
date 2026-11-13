// Sortie du son sur iPhone : fonctions C du cœur Rust appelées par AVAudioEngine (voir AudioOutput.swift).
// Ajouté au module dz_ffiFFI par scripts/build-core.sh.
#pragma once
#include <stdint.h>

/// Remplit `frames` trames gauche et droite (thread temps réel : aucune allocation, aucun verrou).
void dz_render(float * _Nonnull left, float * _Nonnull right, uint32_t frames);

/// À appeler juste avant de (re)démarrer AVAudioEngine : le son repart en fondu.
void dz_output_restarting(void);

/// Fonctions qui démarrent et arrêtent AVAudioEngine, appelées par le moteur Rust depuis son propre thread.
void dz_output_set_hooks(void (* _Nullable start)(void), void (* _Nullable stop)(void));
