import assert from "node:assert/strict";
import test from "node:test";

import { normalizeSpokenText, punctuatedIpa, runEspeak, rustSpokenPlan } from "../../scripts/spoken-normalize.mjs";

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
