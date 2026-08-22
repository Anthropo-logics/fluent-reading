import assert from "node:assert/strict";
import test from "node:test";

import { parseCase, verifyRoundTrips } from "../../scripts/verify-anchor-roundtrip.mjs";

const unit = (id, x, confidence = 1) => ({
  unit_id: id,
  source_regions: [{ rect_pdf_points: [x, 10, 30, 20], confidence }],
});
const page = (index, route, units) => ({
  record: { page_index: index, route },
  units,
  anchors: units.map((entry) => ({ unit_id: entry.unit_id, generation_id: "generation-1", source_region_index: 0 })),
});

test("selects each Gate A document type and preserves every selected anchor", () => {
  const document = {
    document_id: "doc_hash",
    pages: [
      page(0, "direct_text", Array.from({ length: 10 }, (_, i) => unit(`digital-${i}`, 10))),
      page(1, "direct_text", Array.from({ length: 10 }, (_, i) => unit(`columns-${i}`, i % 2 ? 300 : 10))),
      page(2, "ocr", Array.from({ length: 10 }, (_, i) => unit(`scanned-${i}`, 10))),
    ],
  };
  const report = verifyRoundTrips(document, [
    parseCase("digital:0:direct_text:10"),
    parseCase("multi_column:1:direct_text:10"),
    parseCase("scanned:2:ocr:10"),
    parseCase("mixed:0,2:mixed:10"),
  ]);
  assert.equal(report.passed, true);
  assert.deepEqual(report.cases.map((entry) => entry.selected), [10, 10, 10, 10]);
  assert.ok(report.cases.flatMap((entry) => entry.anchors).every((entry) => entry.identity === "preserved"));
  assert.ok(report.cases.flatMap((entry) => entry.anchors)
    .every((entry) => entry.state_trace.includes("immersion/resized")));
});

test("fails a type instead of hiding a missing region or wrong route", () => {
  const document = { document_id: "doc_hash", pages: [page(0, "ocr", [unit("unit", 10)])] };
  const report = verifyRoundTrips(document, [parseCase("digital:0:direct_text:1")]);
  assert.equal(report.passed, false);
  assert.equal(report.cases[0].route, "mismatched");
});
