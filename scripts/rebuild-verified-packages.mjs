#!/usr/bin/env node
// Rebuilds <models-root>/verified-packages/<id>/data/... from the downloaded weights in
// <models-root>/models/<id>, copying only the artifacts each manifest lists and verifying every
// sha256 against it. `ModelPackageInstaller.verifiedPackage` rejects a package that carries any file
// its manifest does not declare, so a plain directory copy does not work.
//
// Usage: node scripts/rebuild-verified-packages.mjs <models-root> [id ...]

import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { copyFile, mkdir, readFile, readdir, stat } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";

const [modelsRoot, ...requested] = process.argv.slice(2);
if (!modelsRoot) {
  console.error("usage: rebuild-verified-packages.mjs <models-root> [id ...]");
  process.exit(64);
}

const repository = resolve(import.meta.dirname, "..");
const manifestDir = join(repository, "models", "manifests");

async function sha256(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

/** The weights on disk may keep the manifest layout (`data/config.json`) or a flat one. */
async function locate(sourceRoot, relativePath) {
  const candidates = [
    join(sourceRoot, relativePath),
    join(sourceRoot, relativePath.replace(/^data\//, "")),
    join(sourceRoot, basename(relativePath)),
  ];
  for (const candidate of candidates) {
    try {
      if ((await stat(candidate)).isFile()) return candidate;
    } catch {}
  }
  // Some packages ship nested inside another one (the G2P lexicons live under the Kokoro weights),
  // so fall back to a search by file name. The sha256 check downstream rejects a wrong match.
  return findByName(dirname(sourceRoot), basename(relativePath), 0);
}

async function findByName(root, name, depth) {
  if (depth > 4) return null;
  let entries;
  try {
    entries = await readdir(root, { withFileTypes: true });
  } catch {
    return null;
  }
  for (const entry of entries) {
    const path = join(root, entry.name);
    if (entry.isFile() && entry.name === name) return path;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const found = await findByName(join(root, entry.name), name, depth + 1);
    if (found) return found;
  }
  return null;
}

const manifests = (await readdir(manifestDir)).filter((f) => f.endsWith(".json"));
let rebuilt = 0;
let skipped = 0;

for (const file of manifests) {
  const manifest = JSON.parse(await readFile(join(manifestDir, file), "utf8"));
  const id = manifest.id;
  if (requested.length && !requested.includes(id)) continue;

  const sourceRoot = join(modelsRoot, "models", id);
  const target = join(modelsRoot, "verified-packages", id);
  const results = [];
  let missing = false;

  for (const artifact of manifest.artifacts) {
    const source = await locate(sourceRoot, artifact.relative_path);
    if (!source) {
      missing = true;
      results.push(`    FALTA ${artifact.relative_path}`);
      continue;
    }
    const digest = await sha256(source);
    if (digest !== artifact.sha256_hex) {
      missing = true;
      results.push(`    HASH  ${artifact.relative_path} (${digest.slice(0, 12)}…)`);
      continue;
    }
    results.push({ source, destination: join(target, artifact.relative_path) });
  }

  if (missing) {
    skipped += 1;
    console.log(`✗ ${id}`);
    for (const line of results) if (typeof line === "string") console.log(line);
    continue;
  }

  for (const { source, destination } of results) {
    await mkdir(dirname(destination), { recursive: true });
    await copyFile(source, destination);
  }
  rebuilt += 1;
  console.log(`✓ ${id} — ${manifest.artifacts.length} artefactos verificados`);
}

console.log(`\nreconstruidos: ${rebuilt}   sin fuente completa: ${skipped}`);
