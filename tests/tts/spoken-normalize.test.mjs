import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

import {
  legacyIpaChunks,
  normalizeSpokenText,
  punctuatedIpa,
  runEspeak,
  rustSpokenPlan,
} from "../../scripts/spoken-normalize.mjs";

const plans = new Map([
  ["pt:Tambem era rapido; naquelle lugar.", {
    normalized_text: "Tambem era rapido; naquelle lugar.", frontend_voice: "pt-br",
    parts: [{ kind: "text", value: "Tambem era rapido" }, { kind: "punctuation", value: ";" },
      { kind: "text", value: "naquelle lugar" }, { kind: "punctuation", value: "." }],
  }],
  ["es:Puso en efeto lo que debía emendar.", { normalized_text: "Puso en efeto lo que debía emendar." }],
  ["en:CHAPTER I. Alice waited.", { normalized_text: "Chapter one. Alice waited." }],
]);
const fixturePlanner = (text, language) => {
  const plan = plans.get(`${language}:${text}`);
  if (!plan) throw new Error("unsupported language");
  return plan;
};

test("normalizes only universal forms without changing punctuation", () => {
  assert.equal(
    normalizeSpokenText("Tambem era rapido; naquelle lugar.", "pt", fixturePlanner),
    "Tambem era rapido; naquelle lugar.",
  );
  assert.equal(
    normalizeSpokenText("Puso en efeto lo que debía emendar.", "es", fixturePlanner),
    "Puso en efeto lo que debía emendar.",
  );
  assert.equal(normalizeSpokenText("CHAPTER I. Alice waited.", "en", fixturePlanner), "Chapter one. Alice waited.");
});

test("phonemizes text spans while preserving prosodic punctuation", () => {
  const calls = [];
  const ipa = punctuatedIpa("Hechas, pues: adelante.", "es", (text, voice) => {
    calls.push([text, voice]);
    return `<${text}>`;
  }, () => ({
    frontend_voice: "es",
    parts: [
      { kind: "text", value: "Hechas" }, { kind: "punctuation", value: "," },
      { kind: "text", value: "pues" }, { kind: "punctuation", value: ":" },
      { kind: "text", value: "adelante" }, { kind: "punctuation", value: "." },
    ],
  }));
  assert.equal(ipa, "<Hechas>, <pues>: <adelante>.");
  assert.deepEqual(calls, [["Hechas", "es"], ["pues", "es"], ["adelante", "es"]]);
});

test("maps Portuguese to Brazilian phonemization and rejects unknown languages", () => {
  let selectedVoice;
  assert.equal(punctuatedIpa("Olá!", "pt", (_, voice) => {
    selectedVoice = voice;
    return "olˈa";
  }, () => ({ frontend_voice: "pt-br", parts: [
    { kind: "text", value: "Olá" }, { kind: "punctuation", value: "!" },
  ] })), "olˈa!");
  assert.equal(selectedVoice, "pt-br");
  assert.throws(() => normalizeSpokenText("Salut", "fr", fixturePlanner), /unsupported language/);
});

test("invokes the Rust plan command without duplicating normalization rules", () => {
  let invocation;
  const plan = rustSpokenPlan("Tambem", "pt", (...parameters) => {
    invocation = parameters;
    return JSON.stringify({ normalized_text: "Tambem", frontend_voice: "pt-br", parts: [] });
  });
  assert.equal(plan.normalized_text, "Tambem");
  assert.deepEqual(invocation[1], ["spoken", "plan", "--language", "pt", "--json"]);
  assert.equal(invocation[2].input, "Tambem");
});

test("terminates stdin text so eSpeak preserves the final phoneme", () => {
  let invocation;
  const result = runEspeak("--Quem fala?", "pt-br", (...parameters) => {
    invocation = parameters;
    return "ipa";
  });
  assert.equal(result, "ipa");
  assert.deepEqual(invocation[1], ["-q", "--ipa=3", "-v", "pt-br", "--stdin"]);
  assert.equal(invocation[2].input, "--Quem fala?\n");
});

test("reproduces the former balanced 30-word IPA fragmentation for A/B", () => {
  const chunks = legacyIpaChunks(
    Array.from({ length: 65 }, (_, index) => `w${index + 1}`).join(" "),
  );
  assert.deepEqual(chunks.map((chunk) => chunk.split(" ").length), [22, 22, 21]);
  assert.equal(chunks.flatMap((chunk) => chunk.split(" ")).length, 65);
});

test("keeps the 20 A/B stimuli resolvable and balanced across ES, EN and PT", () => {
  const root = import.meta.dirname;
  const evaluation = JSON.parse(readFileSync(join(root, "natural-reading-ab.json"), "utf8"));
  const corpus = JSON.parse(readFileSync(join(root, "corpus.json"), "utf8"));
  const passages = new Map(corpus.passages.map((passage) => [passage.id, passage]));
  const sources = new Map(corpus.sources.map((source) => [source.id, source]));
  assert.equal(evaluation.stimuli.length, evaluation.expected_stimuli);
  assert.equal(new Set(evaluation.stimuli.map(({ id }) => id)).size, 20);
  assert.ok(evaluation.stimuli.filter(({ features }) => features.includes("long_sentence")).length >= 5);
  for (const language of ["es", "en", "pt"]) {
    assert.ok(evaluation.stimuli.filter((stimulus) => stimulus.language === language).length >= 6);
  }
  for (const stimulus of evaluation.stimuli) {
    const passage = passages.get(stimulus.passage_id);
    assert.equal(passage?.language, stimulus.language);
    assert.ok(Number.isSafeInteger(stimulus.sentence_index) && stimulus.sentence_index >= 0);
    const source = sources.get(passage.source_id);
    const text = readFileSync(join(root, source.path), "utf8")
      .split(/\r?\n/u).slice(passage.line_start - 1, passage.line_end)
      .join(" ").replace(/\s+/gu, " ").trim();
    const sentences = [...new Intl.Segmenter(stimulus.language, { granularity: "sentence" }).segment(text)];
    assert.ok(sentences[stimulus.sentence_index]);
  }
});
