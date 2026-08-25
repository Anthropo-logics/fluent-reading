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

// Kept only to produce a faithful before/after artifact for Story 6.27.
export function legacyIpaChunks(text) {
  const words = text.trim().split(/\s+/u).filter(Boolean);
  const chunkCount = Math.ceil(words.length / 30);
  const chunks = [];
  let start = 0;
  for (let remainingChunks = chunkCount; remainingChunks >= 1; remainingChunks -= 1) {
    const remainingWords = words.length - start;
    if (remainingChunks === 1) {
      chunks.push(words.slice(start).join(" "));
      break;
    }
    const ideal = Math.min(30, Math.ceil(remainingWords / remainingChunks));
    const required = remainingWords - (remainingChunks - 1) * 30;
    const lower = Math.max(required, ideal - 8);
    const upper = Math.min(30, ideal + 8);
    const endsInPunctuation = (size) => /[,.;:!?]$/u.test(words[start + size - 1]);
    let nearby = lower;
    for (let size = lower + 1; size <= upper; size += 1) {
      if (endsInPunctuation(size) !== endsInPunctuation(nearby)) {
        if (endsInPunctuation(size)) nearby = size;
      } else if (Math.abs(size - ideal) < Math.abs(nearby - ideal)) {
        nearby = size;
      }
    }
    const size = endsInPunctuation(nearby) ? nearby : ideal;
    chunks.push(words.slice(start, start + size).join(" "));
    start += size;
  }
  return chunks;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const languageIndex = process.argv.indexOf("--language");
  const language = languageIndex >= 0 ? process.argv[languageIndex + 1] : undefined;
  const input = readFileSync(0, "utf8");
  if (Buffer.byteLength(input) > 524_288) throw new Error("input too large");
  const ipa = punctuatedIpa(input, language, runEspeak);
  process.stdout.write(ipa);
}
