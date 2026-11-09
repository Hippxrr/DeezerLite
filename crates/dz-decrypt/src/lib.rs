use std::sync::Arc;

use blowfish::cipher::{generic_array::GenericArray, BlockDecrypt, KeyInit};
use blowfish::Blowfish;
use dz_stream::ChunkDecryptor;
use md5::{Digest, Md5};

const SECRET: &[u8; 16] = b"g4el58wc0zvf9na1";
const STRIPE_IV: [u8; 8] = [0, 1, 2, 3, 4, 5, 6, 7];

pub struct DeezerDecryptor {
    cipher: Blowfish,
}

impl DeezerDecryptor {
    pub fn new(track_id: i64) -> Self {
        let key = blowfish_key(track_id);
        let cipher = Blowfish::new_from_slice(&key).expect("la clé Blowfish Deezer fait 16 octets");
        Self { cipher }
    }
}

pub fn decryptor(track_id: i64) -> Arc<dyn ChunkDecryptor> {
    Arc::new(DeezerDecryptor::new(track_id))
}

fn blowfish_key(track_id: i64) -> [u8; 16] {
    let hash = format!("{:x}", Md5::digest(track_id.to_string()));
    let hash = hash.as_bytes();
    let mut key = [0; 16];
    for i in 0..16 {
        key[i] = hash[i] ^ hash[i + 16] ^ SECRET[i];
    }
    key
}

impl ChunkDecryptor for DeezerDecryptor {
    fn decrypt_chunk(&self, index: u64, chunk: &mut [u8]) {
        if index % 3 != 0 {
            return;
        }

        let mut previous = STRIPE_IV;
        for block in chunk.chunks_exact_mut(8) {
            let mut ciphertext = [0; 8];
            ciphertext.copy_from_slice(block);
            self.cipher
                .decrypt_block(GenericArray::from_mut_slice(block));
            for i in 0..8 {
                block[i] ^= previous[i];
            }
            previous = ciphertext;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use blowfish::cipher::BlockEncrypt;
    use dz_stream::CHUNK;

    fn encrypt_chunk(cipher: &Blowfish, plaintext: &[u8]) -> Vec<u8> {
        let mut encrypted = plaintext.to_vec();
        let mut previous = STRIPE_IV;
        for block in encrypted.chunks_exact_mut(8) {
            for i in 0..8 {
                block[i] ^= previous[i];
            }
            cipher.encrypt_block(GenericArray::from_mut_slice(block));
            previous.copy_from_slice(block);
        }
        encrypted
    }

    #[test]
    fn derives_opendeezer_key_vector() {
        assert_eq!(
            blowfish_key(3_135_556),
            [108, 108, 102, 107, 57, 102, 44, 55, 101, 37, 117, 96, 60, 100, 52, 57]
        );
    }

    #[test]
    fn decrypts_only_every_third_chunk() {
        let decryptor = DeezerDecryptor::new(3_135_556);
        let input: Vec<u8> = (0..CHUNK * 3).map(|i| (i % 251) as u8).collect();
        let mut output = input.clone();
        for (index, chunk) in output.chunks_exact_mut(CHUNK).enumerate() {
            decryptor.decrypt_chunk(index as u64, chunk);
        }

        assert_ne!(output[..CHUNK], input[..CHUNK]);
        assert_eq!(output[CHUNK..], input[CHUNK..]);
    }

    #[test]
    fn decrypts_cbc_chunk_in_place() {
        let decryptor = DeezerDecryptor::new(3_135_556);
        let plaintext: Vec<u8> = (0..CHUNK).map(|i| (i % 251) as u8).collect();
        let mut encrypted = encrypt_chunk(&decryptor.cipher, &plaintext);
        let ciphertext = encrypted.clone();

        decryptor.decrypt_chunk(0, &mut encrypted);

        assert_ne!(encrypted, ciphertext);
        assert_eq!(encrypted, plaintext);
    }

    #[test]
    fn chunk_decryption_is_independent_of_call_order() {
        let decryptor = DeezerDecryptor::new(3_135_556);
        let plaintext: Vec<u8> = (0..CHUNK).map(|i| (i % 239) as u8).collect();
        let encrypted = encrypt_chunk(&decryptor.cipher, &plaintext);

        let mut isolated = encrypted.clone();
        decryptor.decrypt_chunk(3, &mut isolated);

        let mut after_other_chunks = encrypted;
        decryptor.decrypt_chunk(0, &mut vec![0; CHUNK]);
        decryptor.decrypt_chunk(3, &mut after_other_chunks);

        assert_eq!(isolated, plaintext);
        assert_eq!(after_other_chunks, isolated);
    }
}
