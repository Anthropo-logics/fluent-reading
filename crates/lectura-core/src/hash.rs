//! Único punto del núcleo donde se calcula un SHA-256 y se representa en hexadecimal minúsculo.
//!
//! La huella de un documento, la del corpus y la de un artefacto de modelo son el mismo cálculo con
//! distinto tipo de error; cada llamante traduce el error de E/S al suyo con `map_err`.

use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

use sha2::{Digest, Sha256};

/// SHA-256 hexadecimal de un búfer ya en memoria.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex_lower(&Sha256::digest(bytes))
}

/// SHA-256 hexadecimal de un fichero, leído por bloques para no cargarlo entero en memoria.
pub fn fingerprint_file(path: &Path) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 65_536];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok(hex_lower(&digest.finalize()))
}

pub(crate) fn hex_lower(digest: &[u8]) -> String {
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}
