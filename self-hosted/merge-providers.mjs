#!/usr/bin/env node
// Merge custom provider overlays into the upstream providers.yaml.
//
// Reads the pristine upstream packages/providers/providers.yaml plus every
// *.provider.yaml under self-hosted/overlay/, deep-merges them (overlay wins),
// and writes the result to self-hosted/build/providers.yaml — the file that
// docker-compose bind-mounts into the container.
//
// This keeps the upstream file untouched so `git pull` never conflicts, while
// our custom providers (e.g. accurate) survive every update.
//
// Usage: node self-hosted/merge-providers.mjs
//   then: docker compose -f self-hosted/docker-compose.yaml up -d
//
// Validate the result with the upstream validator before deploying:
//   npx tsx scripts/validation/providers/validate.ts

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import yaml from 'js-yaml';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.join(__dirname, '..');

const UPSTREAM = path.join(repoRoot, 'packages/providers/providers.yaml');
const OVERLAY_DIR = path.join(__dirname, 'overlay');
const OUT_DIR = path.join(__dirname, 'build');
const OUT = path.join(OUT_DIR, 'providers.yaml');

function loadYaml(file) {
    return yaml.load(fs.readFileSync(file, 'utf8')) ?? {};
}

const base = loadYaml(UPSTREAM);

const overlayFiles = fs
    .readdirSync(OVERLAY_DIR)
    .filter((f) => f.endsWith('.provider.yaml'))
    .sort();

const added = [];
for (const file of overlayFiles) {
    const entries = loadYaml(path.join(OVERLAY_DIR, file));
    for (const key of Object.keys(entries)) {
        if (base[key]) {
            console.warn(`⚠️  overlay "${key}" (from ${file}) overrides an upstream provider — intentional?`);
        }
        base[key] = entries[key];
        added.push(key);
    }
}

// Validate each overlaid provider against the upstream JSON schema so a bad
// edit fails here, before it ever reaches the running container.
const schema = JSON.parse(fs.readFileSync(path.join(repoRoot, 'scripts/validation/providers/schema.json'), 'utf8'));
const { default: Ajv } = await import('ajv');
const ajv = new Ajv({ allErrors: true, strict: false });
const validate = ajv.compile(schema);
if (!validate(base)) {
    const overlayErrors = (validate.errors ?? []).filter((e) => added.some((k) => e.instancePath.startsWith(`/${k}`)));
    if (overlayErrors.length) {
        console.error('❌ overlay provider failed schema validation:');
        console.error(JSON.stringify(overlayErrors, null, 2));
        process.exit(1);
    }
}

fs.mkdirSync(OUT_DIR, { recursive: true });
fs.writeFileSync(
    OUT,
    `# GENERATED — do not edit. Produced by self-hosted/merge-providers.mjs.\n` +
        `# Upstream providers.yaml + overlays: ${added.join(', ')}\n` +
        yaml.dump(base, { lineWidth: -1, noRefs: true, sortKeys: false })
);

console.log(`✅ wrote ${OUT} (${Object.keys(base).length} providers, overlays: ${added.join(', ')}, schema OK)`);
