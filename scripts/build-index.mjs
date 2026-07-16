#!/usr/bin/env node
// build-index.mjs — regenerate index.json from providers/*/provider.lua.
// Zero dependencies. Node >= 18.
//
// Scans every providers/<id>/provider.lua, parses the `-- @key value` metadata
// header, hashes the script + icon, and emits a stable, sorted index.json that
// the Kumo app + server consume for sha-verified auto-update.

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, writeFileSync, existsSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, relative } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const PROVIDERS_DIR = join(ROOT, "providers");

const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");

// Parse the leading `-- @key value` comment header. Stops at the first line
// that is not a comment (blank comment lines `--` are skipped, not terminal).
function parseMeta(src) {
  const meta = {};
  for (const raw of src.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === "" ) continue;
    if (!line.startsWith("--")) break; // first non-comment line ends the header
    const m = line.match(/^--\s*@(\w+)\s*(.*)$/);
    if (m) meta[m[1].toLowerCase()] = m[2].trim();
  }
  return meta;
}

// git log dates for a path: [firstISO, lastISO]. Returns [null, null] outside git.
function gitDates(path) {
  try {
    const created = execFileSync(
      "git",
      ["log", "--follow", "--diff-filter=A", "--format=%aI", "--", path],
      { cwd: ROOT, stdio: ["ignore", "pipe", "ignore"] }
    ).toString().trim().split(/\n/).filter(Boolean).pop();
    const updated = execFileSync(
      "git",
      ["log", "-1", "--format=%aI", "--", path],
      { cwd: ROOT, stdio: ["ignore", "pipe", "ignore"] }
    ).toString().trim();
    return [created || null, updated || null];
  } catch {
    return [null, null];
  }
}

function splitLangs(v) {
  if (!v) return [];
  return v.split(",").map((s) => s.trim()).filter(Boolean);
}

function toBool(v) {
  return String(v).trim().toLowerCase() === "true";
}

function iconFor(dir) {
  for (const name of ["icon.avif", "icon.png", "icon.webp", "icon.jpg"]) {
    const p = join(dir, name);
    if (existsSync(p)) return name;
  }
  return null;
}

function main() {
  const nowIso = new Date().toISOString();
  const entries = [];

  const dirs = readdirSync(PROVIDERS_DIR, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();

  for (const dirName of dirs) {
    const dir = join(PROVIDERS_DIR, dirName);
    const luaPath = join(dir, "provider.lua");
    if (!existsSync(luaPath)) {
      console.warn(`skip ${dirName}: no provider.lua`);
      continue;
    }
    const src = readFileSync(luaPath);
    const meta = parseMeta(src.toString("utf8"));
    const id = meta.id || dirName;
    if (meta.id && meta.id !== dirName) {
      throw new Error(
        `provider dir "${dirName}" mismatches @id "${meta.id}" — dir name MUST equal @id`
      );
    }

    const luaRel = relative(ROOT, luaPath).split("\\").join("/");
    let [created, updated] = gitDates(luaRel);
    if (!created) created = nowIso;
    if (!updated) updated = nowIso;

    const iconName = iconFor(dir);
    let iconRel = null;
    let iconSha = null;
    if (iconName) {
      const iconPath = join(dir, iconName);
      iconRel = relative(ROOT, iconPath).split("\\").join("/");
      iconSha = sha256(readFileSync(iconPath));
    }

    entries.push({
      id,
      name: meta.name || id,
      version: meta.version || "0.0.0",
      langs: splitLangs(meta.langs),
      nsfw: toBool(meta.nsfw),
      requires_verification: meta.verify !== undefined ? true : false,
      created,
      updated,
      url: luaRel,
      sha256: sha256(src),
      icon: iconRel,
      icon_sha256: iconSha,
      ua_hint: meta.ua || null,
    });
  }

  entries.sort((a, b) => a.id.localeCompare(b.id));

  // No volatile top-level timestamp: the file must be byte-stable across runs
  // so CI's `git diff --exit-code index.json` only trips on real changes.
  // Per-provider created/updated come from git history (deterministic once
  // committed), falling back to now only for never-committed working files.
  const index = {
    schema: 1,
    providers: entries,
  };

  const out = join(ROOT, "index.json");
  writeFileSync(out, JSON.stringify(index, null, 2) + "\n");
  console.log(`wrote ${relative(ROOT, out)} — ${entries.length} provider(s)`);
}

main();
