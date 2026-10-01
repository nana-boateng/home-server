# Homelab Architecture Notes

This note captures the recommended direction for the current homelab design,
based on the existing 3-node Proxmox cluster and the storage lessons learned
from the TrueNAS/NFS/LXC permission model.

> **Service placement now lives in
> [service-architecture.md](./service-architecture.md)** — the 11-LXC + VM map,
> grouped by failure domain, with per-service build notes. This document keeps
> the node roles and the storage/identity model; where the two overlap, the
> service architecture is authoritative.

Locked decisions live in [DECISIONS.md](./DECISIONS.md); addressing, DNS, and
proxy design live in [homelab-network-plan.md](./homelab-network-plan.md).
Unratified items are collected in [OPEN-QUESTIONS.md](./OPEN-QUESTIONS.md).
Measured hardware — which drives every placement call below — is in
[hardware-inventory.md](./hardware-inventory.md).

## Core Correction

The stack should not be described as "UID/GID mapping (UID 1000)" anymore.
That was the old working assumption, but the cleaner long-term model is:

```text
sisyphus = container/app/media automation storage, UID/GID 3004 (sisyphus)
ixion    = personal/human storage, UID/GID 3000 (nana)
proxmox  = ISO/backups/templates
```

Recommended wording:

> The cluster uses explicit LXC UID/GID passthrough for service identities.
> Container storage uses `sisyphus` UID/GID `3004` via the `sisyphus` NFS
> export; personal storage uses `nana` UID/GID `3000` via the `ixion` export
> and is read-only to containers by default.

## Node Roles

### Hestia

Role: media hub

Why:

- **1 TB boot disk — twice any other node.** This, not transcode, is Hestia's
  real advantage.
- H.265 QuickSync for playback.
- Media locality: serving from the node that holds the library.

Recommended LXCs:

- `media` — Plex, Jellyfin, Tautulli, Posterizarr, Aggregarr, Navidrome
  (**`/dev/dri` passthrough**, transcode scratch on **tmpfs**)
- `monitor` — Uptime Kuma, Beszel, ntfy, what's-up-docker, Dozzle
- `apps` — the utility layer, including Paperless-ngx and Stirling-PDF
- `immich` — dedicated LXC: server, ML, Postgres, Valkey

Suggestion:

- Keep playback services here for now.
- Avoid moving the downloader stack onto this node.

> **Media stays here even though Themis has the stronger iGPU** (UHD 630, 24 EU
> vs 16 EU). It keeps load on the idle node, and Hestia's blast radius now
> includes other people. Decided, not deferred.

> **No AV1 on any node** — Jasper Lake and UHD 630 both predate Intel's Gen-12
> AV1 decode. H.264 / HEVC / VP9 only.

### Rhea

Role: **light always-on infrastructure node**

Why:

- **RAM and disk**, not CPU: 16 GB and 500 GB against Hestia's 32 GB and 1 TB.
- Rhea and Hestia are the **same Beelink Mini S board**, so they are
  interchangeable — either can take the other's role if one fails.
- Light infrastructure has tiny configs and negligible CPU demand.

Recommended services — native-daemon LXCs only, no Docker:

- `dns` — Pi-hole + Unbound
- `proxy` — Caddy
- `tailscale` — subnet router
- `omada` — parked pending the OC200 RMA

Monitoring moved **off** Rhea to Hestia, so it can still alert when Rhea is
down.

> **Do NOT put the heavy ~29-service control plane here.** The `io` and
> `asteria` stacks belong on Themis. This reverses earlier guidance that routed
> infrastructure *away* from Rhea — see [DECISIONS.md](./DECISIONS.md) D13 for
> why both of that decision's premises expired.

Monitoring deliberately does **not** live here — Uptime Kuma, Beszel and ntfy
are in Hestia's `monitor` LXC, whose `resolv.conf` points at `10.0.0.1` rather
than Pi-hole, so alerting survives Rhea going down. Kuma still needs an
[off-Hestia notification path](./OPEN-QUESTIONS.md#uptime-kuma-needs-an-off-hestia-notification-path)
for host-down events about its own node.

### Themis

Role: **compute / appliance host + the heavy stacks**

Why:

- Strongest node by a wide margin: i7-8700T, 6c/12t.
- NVMe boot plus the `themis-500` HDD scratch pool.
- The right home for anything CPU-bound.

Note its **UHD 630 is not passed into `arr`**, which is why Bazarr's Whisper
subtitle generation is deferred.

Recommended LXCs:

- `arr` — Prowlarr, Radarr, Sonarr, Bazarr, Byparr, **SABnzbd**, abs-arr,
  Audiobookshelf, Reclaimerr, Recyclarr — treated as **one system**
- `grab` — qBittorrent, JDownloader, MeTube — a convenience bucket, not a
  coupled system
- `sandbox` — staged by **trust level**: changedetection, comet-editor, Grocy
- `homeassistant` — **a VM, not an LXC**

Suggestion:

- Home Assistant on a dedicated VM is the right call. Note its USB/Zigbee
  passthrough pins it to this node and makes it ineligible for Proxmox HA.
- Immich benefits from the QuickSync GPU here — the old "Immich is on the wrong
  node for its GPU" problem is solved.

> **Themis's limit is disk, not CPU:** ~446 GiB NVMe. The `themis-500` HDD pool
> adds disposable scratch, not capacity.

**qBittorrent now lives here**, in `grab`, with incomplete downloads on
`themis-500/incomplete`. The HDD is the point — sequential writes, no SSD wear,
disposable data. **Do not put incomplete downloads on the NVMe.**

**SABnzbd lives with `arr`, not `grab`** — Usenet is primary and reliable, so
they go up or down together, insulated from qBittorrent.

## Recommended Service Placement

```text
Rhea — native-daemon LXCs, no Docker
- dns        Pi-hole + Unbound
- proxy      Caddy (custom build w/ Cloudflare DNS plugin)
- tailscale  subnet router
- omada      parked pending OC200 RMA

Hestia — media, monitoring, apps, photos
- media      plex jellyfin tautulli posterizarr aggregarr navidrome   [/dev/dri]
- monitor    uptime-kuma beszel ntfy whats-up-docker dozzle
- apps       homepage jellyseerr wizarr speedtest nextexplorer pairdrop
             tandoor kitchenowl opengist immich-drop immich-public-proxy
             paperless-ngx stirling-pdf
- immich     server machine-learning postgres valkey

Themis — heavy compute
- arr        prowlarr radarr sonarr bazarr byparr sabnzbd abs-arr
             audiobookshelf reclaimerr recyclarr
- grab       qbittorrent jdownloader metube
- sandbox    changedetection comet-editor grocy
- homeassistant   (VM, not LXC)

Seedbox — outside the cluster, non-production
- experiments only
```

Full detail, including which of these are decided-but-unbuilt:
[service-architecture.md](./service-architecture.md).

Notes:

- **Tautulli lives on Hestia**, in `media` with the other Plex-adjacent
  services. Earlier notes placing it on Rhea in `aeos` were wrong.
- **One Docker daemon per coupling group, each in its own LXC.** Splitting
  compose files on a single daemon buys nothing — the daemon is the shared-fate
  unit.
- Caddy and Pi-hole are **not** applications and do not belong in a Compose
  stack — see [DECISIONS.md](./DECISIONS.md) D3, D4, D13, D22.

## Storage Layout

Recommended datasets and directory layout:

```text
/mnt/tartarus/sisyphus
  downloads/
  media/
  shared/

/mnt/tartarus/ixion
  documents/
  photos/
  personal/
  archive/

/mnt/tartarus/proxmox
  dump/
  iso/
  snippets/
  templates/
```

Recommended mount intent:

```text
sisyphus -> /mnt/storage
ixion    -> /mnt/personal, read-only by default
```

Guidance:

- `sisyphus` is the bulk-data path: `downloads/`, `media/`, `shared/`.
- **There is no `appdata/` on `sisyphus`.** Runtime config lives on node-local
  ZFS — see [DECISIONS.md](./DECISIONS.md) D11. It is omitted from the layout
  deliberately, so the wrong thing is unavailable rather than merely discouraged.
- `sisyphus` should remain one dataset with plain directories inside it.
- Do not recreate `downloads`, `media`, or `shared` as child ZFS datasets unless
  you intentionally want separate exports and separate storage policy.
- `ixion` is personal storage and should not be the default write target for
  containers.
- If a container needs access to personal data, prefer a narrow mount or
  dedicated subdirectory instead of broad write access.

### Service Path Conventions

**Two storage tiers, and the split is not negotiable.**

| Tier | Path | Holds | Backed by |
|---|---|---|---|
| **Node-local ZFS** | `/opt/appdata/<stack>/<service>` | `/config`, databases, all runtime state | Restic → Tartarus (D12) |
| **NFS (`sisyphus`)** | `/mnt/storage/...` | `downloads/`, `media/`, `shared/` — bulk data only | ZFS snapshots on Tartarus |

> **Databases and `/config` never touch NFS.** SQLite over NFS has unreliable
> locking and a well-known corruption mode, and Radarr, Sonarr, Prowlarr,
> Bazarr, Immich, and Paperless all keep SQLite or Postgres databases.
>
> An earlier version of this document prescribed the opposite — config volumes
> under `/mnt/storage/appdata/...`, pre-created on NFS-backed storage. **That was
> the corruption path.** See [DECISIONS.md](./DECISIONS.md) D11.

Config, on node-local ZFS:

```text
/opt/appdata/io/sabnzbd
/opt/appdata/io/qbittorrent
/opt/appdata/asteria/sonarr
/opt/appdata/asteria/radarr
/opt/appdata/apollo/tautulli
/opt/appdata/aeos/homepage
```

Bulk data, on NFS:

```text
io
- /mnt/storage/downloads/sabnzbd
- /mnt/storage/downloads/qbittorrent
- /mnt/storage/downloads/jdownloader
- /mnt/storage/downloads/metube

asteria
- /mnt/storage/media/tv
- /mnt/storage/media/movies
- /mnt/storage/media/music

aeos
- /mnt/storage/shared
```

`io` and `asteria` must mount the **same** NFS export at the **same** path, or
hardlinking breaks and imports silently double disk usage.

For services that write to `sisyphus`, prefer running them as `3004:3004`.

Use real bind paths in Docker Compose rather than symlinked home-directory
paths. Pre-create bind-mount source directories before `docker compose up` so
Docker does not create and `chown` them itself.

**Compose files and `.env` are the source of truth in Git** — declarative
configuration, not a state backup. State is backed up separately by Restic
(D12).

## Networking

Suggested stable names:

```text
hestia.lan
rhea.lan
themis.lan
tartarus.lan
plex.lan
jellyfin.lan
sonarr.lan
radarr.lan
paperless.lan
immich.lan
homeassistant.lan
```

The search domain is **`.lan`**. `.local` is reserved for mDNS and must not be
used anywhere — see [DECISIONS.md](./DECISIONS.md) D2.

Suggestion:

- Use SMB for MacBook / human browsing and keep NFS as the Proxmox / LXC
  protocol.

Settled elsewhere:

- **Reverse proxy**: one central **Caddy** LXC fronts every service on every
  node, with a static Caddyfile in this repo. **On Rhea.**
  See [DECISIONS.md](./DECISIONS.md) D4 and D13.
- **DNS**: Pi-hole + Unbound in a Proxmox LXC, split-horizon, **on Rhea**.
  See D3 and D13.
- **Remote access**: Tailscale with subnet routing for `10.0.0.0/24`, later the
  whole `10.0.0.0/16`. Headscale is not used. See D7.
- **VLAN-ready addressing**: future VLANs use the third octet under a
  `10.0.0.0/16` supernet, so Main never re-IPs. See D10.
- Whether a **secondary Pi-hole** is real redundancy is
  [still open](./OPEN-QUESTIONS.md#dns-redundancy--now-live-not-theoretical) —
  clients query both resolvers rather than failing over cleanly.

## Backups

Use the `proxmox` dataset for:

- Proxmox backups
- VM/CT dumps
- ISOs
- templates

Keep app-level backups separate from Proxmox infrastructure backups.

For Docker-based services, back up:

- compose files
- `.env` files
- bind-mounted config directories
- app databases

Important:

- Test at least one real restore path.
- A backup that has never been restored is still an assumption.

**App state is backed up by Restic**, per-node agents writing out to one shared
deduplicated repo on Tartarus, quiesced with a ZFS snapshot so databases are
copied atomically. Full rules: [DECISIONS.md](./DECISIONS.md) D12.

Everything still lands on Tartarus, and RAID plus one-way rsync is not a backup.
Getting at least one copy off that box is
[an open, unresolved risk](./OPEN-QUESTIONS.md#nothing-lives-off-tartarus-yet).

## Final Direction

The overall architecture is strong. The main improvement is not the node
layout; it is the storage and identity model. If `sisyphus` is the single
container-write dataset owned by `sisyphus` (`3004:3004`), and `ixion` stays
personal and narrow, future nodes and future migrations will be much easier.
