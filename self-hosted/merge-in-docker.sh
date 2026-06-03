#!/usr/bin/env bash
# Run merge-providers.mjs without a host Node install, using a throwaway
# node:20-alpine container. For servers (like the Hetzner box) that have Docker
# but no Node toolchain.
#
# Skips the ajv schema validation that the host script does (that runs locally
# pre-commit); here it only merges upstream providers.yaml + overlays.
#
# Usage: self-hosted/merge-in-docker.sh
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

docker run --rm -v "$PWD:/work" -w /work node:20-alpine sh -c '
  npm install --no-save --silent js-yaml@4 >/dev/null 2>&1
  node --input-type=module -e "
    import fs from \"node:fs\";
    import path from \"node:path\";
    import yaml from \"js-yaml\";
    const UP = \"packages/providers/providers.yaml\";
    const OVL = \"self-hosted/overlay\";
    const OUT = \"self-hosted/build/providers.yaml\";
    const base = yaml.load(fs.readFileSync(UP, \"utf8\")) ?? {};
    const files = fs.readdirSync(OVL).filter(f => f.endsWith(\".provider.yaml\")).sort();
    const added = [];
    for (const f of files) {
      const e = yaml.load(fs.readFileSync(path.join(OVL, f), \"utf8\")) ?? {};
      for (const k of Object.keys(e)) { base[k] = e[k]; added.push(k); }
    }
    fs.mkdirSync(\"self-hosted/build\", { recursive: true });
    fs.writeFileSync(OUT, \"# GENERATED in-docker. Upstream + overlays: \" + added.join(\", \") + \"\n\" + yaml.dump(base, { lineWidth: -1, noRefs: true, sortKeys: false }));
    console.log(\"wrote\", OUT, \"(\" + Object.keys(base).length + \" providers, overlays: \" + added.join(\", \") + \")\");
  "
'
