#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";

const [output, ...inputs] = process.argv.slice(2);
if (!output || inputs.length !== 3) {
  throw new Error("usage: verify-audiobook-format.mjs <output.m4b> <chapter1.wav> <chapter2.wav> <chapter3.wav>");
}
const work = mkdtempSync(join(tmpdir(), "lectura-format-"));
try {
  const durations = inputs.map((input) => Number(execFileSync("ffprobe", [
    "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", resolve(input),
  ], { encoding: "utf8" }).trim()));
  const titles = ["Capítulo: niñez y acción", "Capítulo: coração e atenção", "Chapter: continuity"];
  let start = 0;
  const chapters = durations.map((duration, index) => {
    const end = start + duration;
    const value = `[CHAPTER]\nTIMEBASE=1/1000\nSTART=${Math.round(start * 1000)}\nEND=${Math.round(end * 1000)}\ntitle=${titles[index]}\n`;
    start = end;
    return value;
  }).join("");
  const metadata = join(work, "chapters.ffmetadata");
  writeFileSync(metadata, `;FFMETADATA1\ntitle=Lectura fluida — prueba portátil\nlanguage=mul\n${chapters}`);
  const preliminary = join(work, "preliminary.m4a");
  execFileSync("ffmpeg", [
    "-v", "error", "-y", ...inputs.flatMap((input) => ["-i", resolve(input)]), "-f", "ffmetadata", "-i", metadata,
    "-filter_complex", "[0:a][1:a][2:a]concat=n=3:v=0:a=1[a]", "-map", "[a]", "-map_metadata", "3", "-map_chapters", "3",
    "-c:a", "aac", "-b:a", "64k", "-ac", "1", "-ar", "24000", "-movflags", "+faststart", "-f", "ipod", preliminary,
  ], { stdio: "inherit" });
  const chapterJSON = join(work, "chapters.json");
  let chapterStart = 0;
  writeFileSync(chapterJSON, JSON.stringify(durations.map((duration, index) => {
    const chapter = { title: titles[index], language: ["es", "pt", "en"][index], start: chapterStart, end: chapterStart + duration };
    chapterStart += duration;
    return chapter;
  })));
  const muxer = join(work, "native-muxer");
  execFileSync("xcrun", [
    "swiftc", "-parse-as-library", resolve(import.meta.dirname, "mux-audiobook-native.swift"), "-o", muxer,
  ], { stdio: "inherit", env: process.env });
  execFileSync(muxer, [preliminary, resolve(output), chapterJSON], { stdio: "inherit" });
  const portable = JSON.parse(execFileSync("ffprobe", [
    "-v", "error", "-show_format", "-show_streams", "-show_chapters", "-of", "json", resolve(output),
  ], { encoding: "utf8" }));
  const nativeCheck = join(work, "native-check");
  execFileSync("xcrun", [
    "swiftc", "-parse-as-library", resolve(import.meta.dirname, "verify-audiobook-native.swift"),
    "-o", nativeCheck,
  ], { stdio: "inherit", env: process.env });
  const native = JSON.parse(execFileSync(nativeCheck, [resolve(output)], { encoding: "utf8" }));
  const audio = portable.streams.find((stream) => stream.codec_type === "audio");
  const report = {
    schema_version: 1,
    decision: "GO",
    extension: resolve(output).split(".").at(-1),
    container: portable.format.format_name,
    codec: audio?.codec_name,
    sample_rate_hz: Number(audio?.sample_rate),
    channels: audio?.channels,
    bitrate_bps: Number(audio?.bit_rate),
    drm: false,
    title: portable.format.tags?.title,
    language: portable.format.tags?.language,
    chapters: native.native_timed_titles,
    duration_seconds: Number(portable.format.duration),
    bytes: statSync(resolve(output)).size,
    sha256: createHash("sha256").update(readFileSync(resolve(output))).digest("hex"),
    native,
    cross_platform_probe: portable.chapters.length === 3 && audio?.codec_name === "aac",
    source: "three approved spoken-v3 Kokoro benchmark WAV files",
  };
  if (report.chapters.length !== 3 || report.native.native_chapters !== 3
    || report.native.native_navigable_chapters !== 3 || !report.native.native_seek) {
    throw new Error(`format validation failed: ${JSON.stringify(report)}`);
  }
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
