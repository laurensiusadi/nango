# Self-hosted Nango (with custom Accurate provider)

Runs the **stock upstream `nangohq/nango-server` image** and injects our custom
**Accurate Online** provider via bind-mounts. No image builds — staying current
is just bumping the image tag.

## Why this works

Nango reads `providers.yaml` from disk at runtime
([`packages/providers/lib/index.ts`](../packages/providers/lib/index.ts) →
`fs.readFileSync`), so a provider can be added by overlaying that one file.
Everything custom lives under `self-hosted/`, which upstream never touches —
so merging `upstream/master` never conflicts.

## Git model

Two remotes, one custom branch:

- `upstream` → `NangoHQ/nango` (read-only source of truth)
- `origin` → your fork (`laurensiusadi/nango`) — backs up the customization
- branch **`self-host`** → carries `self-hosted/` on top of upstream `master`

`auto-update.sh` merges `upstream/master` into `self-host`, pushes to the fork,
then redeploys. The Hetzner box clones the fork and checks out `self-host`.

| Piece | Mechanism |
|---|---|
| Accurate auth/proxy | `overlay/accurate.provider.yaml` → merged into mounted `providers.yaml` |
| Accurate logo | `overlay/accurate.svg` → mounted into the built webapp `dist/` |
| Staying updated | bump `NANGO_IMAGE_TAG`, re-pull (`auto-update.sh`) |

> The webapp's `public/` is deleted at image-build time, so the logo can't ride
> the same path as a normal asset — it's mounted directly into the built
> `webapp/dist/images/template-logos/` path the server serves from.

## Layout

```
self-hosted/
├── overlay/
│   ├── accurate.provider.yaml   # the custom provider block (source of truth)
│   └── accurate.svg             # the logo
├── merge-providers.mjs          # upstream providers.yaml + overlays → build/providers.yaml
├── docker-compose.yaml          # stock image + bind-mounts
├── .env.example                 # copy to .env, fill in
├── nginx.conf                   # server blocks for Hetzner nginx
├── auto-update.sh               # fetch upstream, re-merge, bump tag, redeploy
└── build/                       # generated (gitignored)
```

## First-time setup (Hetzner)

```bash
git clone -b self-host https://github.com/laurensiusadi/nango.git /opt/nango
cd /opt/nango
cp self-hosted/.env.example self-hosted/.env
openssl rand -base64 32                          # -> NANGO_ENCRYPTION_KEY (set once, never change)
# edit self-hosted/.env: encryption key, DB password, dashboard creds, public URLs

node self-hosted/merge-providers.mjs             # generate build/providers.yaml
npx tsx scripts/validation/providers/validate.ts # sanity-check providers

docker compose -f self-hosted/docker-compose.yaml --env-file self-hosted/.env up -d
```

Then front it with the existing `workmode-nginx-1` (see `nginx.conf` — one 443
block, Connect UI is served by the main server under `/connect`, no separate
subdomain), issue a dedicated cert for `nango.workmode.now`, and **restart** the
nginx container (a bind-mounted config needs restart, not just reload).

**Status: deployed and public at https://nango.workmode.now** (dashboard + API +
Connect UI), behind a dedicated Let's Encrypt cert. Accurate provider + logo
verified live.

## Configure the Accurate integration

`providers.yaml` only makes Accurate *available*. In the dashboard
(`https://nango.workmode.now`) create the integration once: Accurate client
ID/secret (from the Accurate developer portal), and callback
`https://nango.workmode.now/oauth/callback`.

## Point Workmode at it

In Workmode's env:

```
NANGO_HOST=https://nango.workmode.now
NANGO_SECRET_KEY=<secret key from this dashboard>
NUXT_PUBLIC_NANGO_API_URL=https://nango.workmode.now
NUXT_PUBLIC_NANGO_CONNECT_URL=https://connect.nango.workmode.now
```

No Workmode code changes — it already talks to Nango via `@nangohq/node`.

## Updating

```bash
self-hosted/auto-update.sh            # -> latest release tag
self-hosted/auto-update.sh 0.71.0     # -> pin a specific tag
```

Cron (weekly):

```
0 4 * * 1  cd /opt/nango && self-hosted/auto-update.sh >> /var/log/nango-update.log 2>&1
```

> A container **restart** is required after any providers.yaml change — Nango
> caches providers in memory. `auto-update.sh` and `--force-recreate` handle this.

## Editing the Accurate provider later

1. Edit `overlay/accurate.provider.yaml`.
2. `node self-hosted/merge-providers.mjs`
3. `npx tsx scripts/validation/providers/validate.ts`
4. `docker compose -f self-hosted/docker-compose.yaml --env-file self-hosted/.env up -d --force-recreate nango-server`
