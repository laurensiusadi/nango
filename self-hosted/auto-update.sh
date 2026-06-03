#!/usr/bin/env bash
# Update self-hosted Nango while preserving the custom Accurate provider.
#
# What it does:
#   1. Fetch the latest upstream code (pristine providers.yaml + new providers).
#   2. Re-merge our overlay onto the fresh upstream providers.yaml.
#   3. Resolve the latest released image tag (or use the one passed in).
#   4. Validate the merged providers against the upstream schema.
#   5. Pull the new image, recreate the container, restart (clears the in-memory
#      providers cache so the new providers.yaml takes effect).
#
# Because Accurate lives only in self-hosted/overlay/, upstream pulls never
# conflict with it. Run from the repo root.
#
# Usage:
#   self-hosted/auto-update.sh                 # update to latest release tag
#   self-hosted/auto-update.sh <image-tag>     # pin a specific tag
#
# Schedule via cron, e.g. weekly:
#   0 4 * * 1  cd /opt/nango && self-hosted/auto-update.sh >> /var/log/nango-update.log 2>&1

set -euo pipefail

cd "$(dirname "$0")/.."   # repo root
SELF_HOSTED="self-hosted"
ENV_FILE="$SELF_HOSTED/.env"
COMPOSE="docker compose -f $SELF_HOSTED/docker-compose.yaml --env-file $ENV_FILE"

echo "==> [1/5] Fetching upstream + merging into self-host branch..."
# Remotes:  upstream = NangoHQ/nango (read-only),  origin = our fork.
# We deploy from the 'self-host' branch, which carries self-hosted/ on top of
# upstream master. Upstream never touches self-hosted/, so this merge is
# conflict-free; if it ever conflicts, a tracked file was customized — stop.
git fetch upstream master
git checkout self-host
if ! git merge --no-edit upstream/master; then
    echo "!! Merge conflict — a tracked upstream file was customized."
    echo "!! Keep all customization under self-hosted/. Resolve manually, then re-run."
    git merge --abort
    exit 1
fi
git push origin self-host || echo "   (push to fork skipped/failed — continuing deploy)"

echo "==> [2/5] Merging Accurate overlay onto fresh providers.yaml (validates overlay)..."
node "$SELF_HOSTED/merge-providers.mjs"

echo "==> [3/5] Resolving image tag..."
if [[ "${1:-}" != "" ]]; then
    NEW_TAG="$1"
else
    # Latest non-floating tag from Docker Hub (filters out 'hosted'/'latest'/'edge').
    NEW_TAG=$(curl -fsSL "https://hub.docker.com/v2/repositories/nangohq/nango-server/tags?page_size=50&ordering=last_updated" \
        | node -e 'const d=JSON.parse(require("fs").readFileSync(0));const t=d.results.map(r=>r.name).find(n=>/^[0-9]/.test(n)||/^managed-/.test(n));process.stdout.write(t||"")')
    [[ -z "$NEW_TAG" ]] && { echo "!! Could not resolve a release tag; pass one explicitly."; exit 1; }
fi
echo "    -> $NEW_TAG"

echo "==> [4/5] Cross-checking full upstream provider set..."
npx tsx scripts/validation/providers/validate.ts >/dev/null && echo "    upstream providers OK"

echo "==> [5/5] Pulling + restarting..."
# Update the tag in .env (portable in-place sed for Linux + macOS).
if grep -q '^NANGO_IMAGE_TAG=' "$ENV_FILE"; then
    sed -i.bak "s|^NANGO_IMAGE_TAG=.*|NANGO_IMAGE_TAG=$NEW_TAG|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
else
    echo "NANGO_IMAGE_TAG=$NEW_TAG" >> "$ENV_FILE"
fi

$COMPOSE pull nango-server
$COMPOSE up -d --force-recreate nango-server   # recreate clears the providers cache

echo "==> Done. Now running nangohq/nango-server:$NEW_TAG with Accurate overlay."
