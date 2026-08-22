use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;

use serde_json::Value;
use sha2::{Digest, Sha256};

#[test]
fn tts_corpus_is_fixed_licensed_multilingual_and_long_enough() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/tts");
    let manifest: Value =
        serde_json::from_slice(&fs::read(root.join("corpus.json")).unwrap()).unwrap();
    let mut sources = HashMap::new();
    for source in manifest["sources"].as_array().unwrap() {
        let bytes = fs::read(root.join(source["path"].as_str().unwrap())).unwrap();
        assert_eq!(bytes.len() as u64, source["size_bytes"].as_u64().unwrap());
        let hash = Sha256::digest(&bytes)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        assert_eq!(hash, source["sha256"]);
        assert!(
            source["url"]
                .as_str()
                .unwrap()
                .starts_with("https://www.gutenberg.org/")
        );
        assert!(source["rights"].as_str().unwrap().contains("public_domain"));
        sources.insert(
            source["id"].as_str().unwrap(),
            String::from_utf8(bytes).unwrap(),
        );
    }

    let mut counts = HashMap::new();
    let mut long_languages = HashSet::new();
    for passage in manifest["passages"].as_array().unwrap() {
        let language = passage["language"].as_str().unwrap();
        *counts.entry(language).or_insert(0_u8) += 1;
        let lines: Vec<_> = sources[passage["source_id"].as_str().unwrap()]
            .lines()
            .collect();
        let start = passage["line_start"].as_u64().unwrap() as usize - 1;
        let end = passage["line_end"].as_u64().unwrap() as usize;
        let words = lines[start..end].join(" ").split_whitespace().count() as u64;
        assert_eq!(words, passage["word_count"].as_u64().unwrap());
        assert!(passage["features"].as_array().unwrap().len() >= 3);
        if passage["long"].as_bool().unwrap() {
            assert!(words * 60 >= 10 * 60 * 170);
            assert!(long_languages.insert(language));
        }
    }
    assert_eq!(counts, HashMap::from([("es", 5), ("en", 5), ("pt", 5)]));
    assert_eq!(long_languages, HashSet::from(["es", "en", "pt"]));

    for candidate in manifest["candidates"].as_array().unwrap() {
        assert_eq!(candidate["runtime_id"], "mlx-audio-swift");
        assert_eq!(candidate["runtime_version"], "v0.1.3");
        let voices = candidate["voices"].as_object().unwrap();
        assert_eq!(voices.len(), 3);
        assert!(
            ["es", "en", "pt"]
                .iter()
                .all(|language| voices.contains_key(*language))
        );
    }
}
