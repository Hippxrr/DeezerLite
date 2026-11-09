//! Cache LRU des pistes préchargées (piste N+1 à 80 % de N).

use std::num::NonZeroUsize;

use lru::LruCache;

use crate::StreamReader;

/// Petit cache de lecteurs préchargés. Capacité 2-3 : piste suivante + éventuel retour arrière.
pub struct PrefetchCache {
    inner: LruCache<u64, StreamReader>,
}

impl PrefetchCache {
    pub fn new(capacity: usize) -> Self {
        let cap = NonZeroUsize::new(capacity.max(1)).unwrap_or(NonZeroUsize::MIN);
        Self { inner: LruCache::new(cap) }
    }

    pub fn insert(&mut self, track_id: u64, reader: StreamReader) {
        // L'éviction droppe le StreamReader => annule le téléchargement en cours.
        self.inner.put(track_id, reader);
    }

    /// Retire et renvoie le lecteur préchargé (lecture gapless : l'ownership passe au décodeur).
    pub fn take(&mut self, track_id: u64) -> Option<StreamReader> {
        self.inner.pop(&track_id)
    }

    pub fn contains(&self, track_id: u64) -> bool {
        self.inner.contains(&track_id)
    }
}
