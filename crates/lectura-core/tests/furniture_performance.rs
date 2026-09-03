use lectura_core::{
    ExtractedBlock, PageExtraction, RequestedUnit, SourceRegion, normalize_digital_document,
};
use std::{process::Command, time::Instant};

fn block(id: String, text: String, y: f64, width: f64) -> ExtractedBlock {
    ExtractedBlock {
        block_id: id,
        text,
        spoken_text: None,
        region: SourceRegion {
            page_index: 0,
            rect_pdf_points: [60.0, y, width, 10.0],
            page_rotation_degrees: 0,
            source_to_page_transform: [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
            confidence: 1.0,
        },
        confidence: 1.0,
        layout_role: None,
        layout_confidence: None,
        layout_order: None,
        narration_disposition: None,
        physical_page_index: None,
    }
}

fn corpus(page_count: u32) -> Vec<PageExtraction> {
    (0..page_count)
        .map(|page_index| PageExtraction {
            document_fingerprint: "sha256:furniture-performance".into(),
            generation_id: "generation-performance".into(),
            page_index,
            blocks: vec![
                block(
                    format!("header-{page_index}"),
                    format!("Journal issue 42 · page {page_index}"),
                    740.0,
                    180.0,
                ),
                block(
                    format!("body-{page_index}"),
                    format!("Unique body paragraph for page {page_index}."),
                    400.0,
                    380.0,
                ),
                block(
                    format!("footer-{page_index}"),
                    format!("archive-export-{page_index}-{}.indd", page_index + 10_000),
                    4.0,
                    150.0,
                ),
            ],
        })
        .collect()
}

fn resident_kib() -> Option<u64> {
    let output = Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .ok()?;
    String::from_utf8(output.stdout).ok()?.trim().parse().ok()
}

#[test]
#[ignore = "release performance probe; run explicitly with --ignored --nocapture"]
fn furniture_qualification_release_benchmark() {
    for page_count in [10, 100, 1_000] {
        let pages = corpus(page_count);
        let rss_before = resident_kib();
        let started = Instant::now();
        let normalized = normalize_digital_document(&pages, "en", RequestedUnit::Paragraph);
        let elapsed = started.elapsed();
        let rss_after = resident_kib();

        assert_eq!(normalized.len(), page_count as usize);
        assert!(normalized.iter().all(|page| !page.omissions.is_empty()));
        eprintln!(
            "furniture_benchmark pages={page_count} elapsed_ms={} rss_before_kib={rss_before:?} rss_after_kib={rss_after:?}",
            elapsed.as_millis()
        );
    }
}
