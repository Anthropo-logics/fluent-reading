#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export function rustSpokenPlan(text, language, execute = execFileSync) {
  const project = resolve(import.meta.dirname, "..");
  const lectura = process.env.LECTURA_CLI ?? join(project, "target/release/lectura");
  const output = execute(
    lectura, ["spoken", "plan", "--language", language, "--json"],
    { encoding: "utf8", maxBuffer: 1_048_576, input: text },
  );
  return JSON.parse(output);
}

export function normalizeSpokenText(text, language, planner = rustSpokenPlan) {
  return planner(text, language).normalized_text;
}

export function punctuatedIpa(text, language, phonemize, planner = rustSpokenPlan) {
  const plan = planner(text, language);
  return plan.parts
    .map(({ kind, value }) => kind === "punctuation"
      ? value
      : phonemize(value, plan.frontend_voice).trim())
    .join(" ")
    .replace(/\s+([,.;:!?])/gu, "$1");
}

export function runEspeak(span, voice, execute = execFileSync) {
  return execute(
    "/opt/homebrew/bin/espeak-ng", ["-q", "--ipa=3", "-v", voice, "--stdin"],
    { encoding: "utf8", maxBuffer: 1_048_576, input: `${span}\n` },
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const languageIndex = process.argv.indexOf("--language");
  const language = languageIndex >= 0 ? process.argv[languageIndex + 1] : undefined;
  const input = readFileSync(0, "utf8");
  if (Buffer.byteLength(input) > 524_288) throw new Error("input too large");
  const ipa = punctuatedIpa(input, language, runEspeak);
  process.stdout.write(ipa);
}
