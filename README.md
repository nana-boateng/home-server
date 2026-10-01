# home-server

This repository is an infrastructure blueprint for a 3-node Proxmox homelab
backed by a TrueNAS storage server. It documents how services are grouped,
where they are intended to run, and how storage should be mounted and owned so
containers can share data cleanly.

The core storage model is:

- `tartarus` provides two NFS-backed datasets
- `sisyphus` is the shared container/app/media write path
- `ixion` is personal storage
- `sisyphus` is the canonical shared service identity for container writes

The most important reference documents are:

- [Decision Log](./docs/DECISIONS.md) — locked decisions and their rationale
- [Service Architecture](./docs/service-architecture.md) — the 11-LXC + VM map
- [Build Record](./docs/build-record.md) — what is live, and how it was verified
- [Build Gotchas](./docs/build-gotchas.md) — **read before building any LXC**
- [Open Questions](./docs/OPEN-QUESTIONS.md) — unratified items and known risks
- [Hardware Inventory](./docs/hardware-inventory.md) — measured node specs
- [Rebuild Runbook](./docs/rebuild-runbook.md) — the PVE 9 + `gaia` build
- [Network Core — CRS310](./docs/network-core-crs310.md) — switch and port map
- [Homelab Network Plan](./docs/homelab-network-plan.md)
- [Network Implementation Phases](./docs/network-implementation-phases.md)
- [TrueNAS to Proxmox Container Storage](./docs/truenas-proxmox-storage.md)
- [Homelab Architecture Notes](./docs/homelab-architecture-notes.md)
- [Implementation Plan](./PLAN.md)

## What This Homelab Is

At a high level, this homelab is a media-heavy self-hosting setup built around:

- Proxmox for virtualization and workload placement
- TrueNAS for shared storage
- NFS for Proxmox/LXC container mounts
- SMB for human/macOS access
- Docker Compose stacks for application grouping

The design emphasizes:

- clean separation between app storage and personal storage
- shared media paths that support hardlinks for Arr workflows
- stack-based organization by function
- predictable service ownership and mount paths

## Proxmox Machines

Three nodes, clustered as **`gaia`** on PVE 9.2.2 with ZFS-on-root. Measured
specs: [hardware-inventory.md](./docs/hardware-inventory.md).

Placement follows one rule: **put work where the hardware actually suits it**,
which is not where earlier revisions of these docs assumed. See
[DECISIONS.md](./docs/DECISIONS.md) D13.

### Rhea — light always-on infrastructure

Weakest CPU (N5095), so it carries small always-on LXCs rather than heavy
stacks. Infrastructure whose failure takes down access to everything else
belongs on managed, always-on hardware, and light infrastructure is the one
thing an N5095 is genuinely fine at.

Intended workloads:

- Pi-hole + Unbound
- Caddy
- Uptime Kuma
- ntfy
- Omada software controller
- Tailscale subnet router

**The heavy ~29-service control plane does not go here.**

### Hestia — media / storage hub

1 TB boot disk, **twice any other node**. That, not transcode, is its real
advantage — Themis does H.265 too, and faster.

Intended workloads:

- `media` LXC — Plex, Jellyfin, Tautulli, Posterizarr, Navidrome (**built**)
- `monitor`, `apps`, `immich` LXCs
- Channels-DVR
- Booklore
- Kavita
- Meelo
- ROMm

Audiobookshelf is **not** here — it lives in `arr` on Themis, because abs-arr
imports into it and the pair must share a daemon and filesystem for hardlinks.

### Themis — compute / appliances + heavy stacks

Strongest node by a wide margin (i7-8700T, 6c/12t) with H.265 QuickSync. Its
limit is disk (~446 GiB), not CPU.

Intended workloads:

- `io` stack (qBittorrent excepted — see below)
- `asteria` stack
- Home Assistant OS VM
- Immich — now GPU-accelerated here
- Paperless-ngx
- `helios` stack
- MySpeed
- OpenGist

`aeos` and the remainder of `atlas` (Dozzle, Watchtower) have **no assigned
node** yet — see [OPEN-QUESTIONS.md](./docs/OPEN-QUESTIONS.md).

### Infrastructure LXCs (on Rhea)

DNS and the reverse proxy are infrastructure, not applications. They run as
Proxmox LXCs outside Docker Compose, so restarting a stack can never take down
access to everything else.

- **Pi-hole + Unbound** — split-horizon DNS, in an LXC rather than a container
- **Caddy** — one central reverse proxy fronting every service on every node,
  with a static Caddyfile committed to this repo
- **Tailscale subnet router** — advertises `10.0.0.0/24` for off-site access

### The fourth machine (seedbox)

A fourth box, same specs as the weakest node, stays **outside** the `gaia`
cluster. It is explicitly **non-production**: experiments and disposable
workloads only. It gets no snapshots and no backups, and nothing critical — least
of all Caddy, Pi-hole, or the Tailscale subnet router — belongs on it.

qBittorrent runs here for now, and stays until second-tier SSDs are purchased.

## Networking

The LAN is `10.0.0.0/24`, gateway `10.0.0.1` (TP-Link ER605), with a **MikroTik
CRS310** core switch. DHCP pool `.100–.254`, statics in `.1–.99`. Service
addresses are assigned **by service, not by node**, so an IP never implies where
a service runs. The search domain is `.lan`; `.local` is reserved for mDNS and is
not used anywhere.

Future VLANs use the **third octet** under a `10.0.0.0/16` supernet (VLAN 10
Main, 20 IoT, 30 Guest), so Main never re-IPs when they arrive. Tagging happens
on the switch; routing and firewalling stay on the ER605.

Full detail: [Homelab Network Plan](./docs/homelab-network-plan.md) and
[Network Core — CRS310](./docs/network-core-crs310.md).

## Storage Tiers

Two tiers, and the split is load-bearing:

| Tier | Path | Holds |
|---|---|---|
| Node-local ZFS | `/opt/appdata/<stack>/<service>` | `/config`, databases, runtime state |
| NFS (`sisyphus`) | `/mnt/storage/...` | `downloads/`, `media/`, `shared/` |

**Databases and `/config` never touch NFS** — SQLite over NFS has unreliable
locking and a well-known corruption mode. Node-local state is backed up to
Tartarus by **Restic**, quiesced with a ZFS snapshot so databases copy
atomically. See [DECISIONS.md](./docs/DECISIONS.md) D11 and D12.

## Docker Stacks

> **`stacks/<name>/` is a service inventory, not a placement map.** The seven
> directory names below predate the current architecture and are **no longer the
> deployment unit**. `aeos`, `helios`, `atlas` and `hera` dissolve; `io`,
> `asteria` and `apollo` survive as `grab`, `arr` and `media`. The real map —
> 11 LXCs and a VM, grouped by failure domain — is
> [service-architecture.md](./docs/service-architecture.md), which also carries
> the inventory → grouping table.
>
> Several services listed there are decided but **not yet built**, so they have
> no compose file here.

The repository currently defines seven top-level Docker stack directories:

- `io`: download and ingestion pipeline
- `asteria`: media automation and Arr ecosystem
- `apollo`: media servers and companions
- `helios`: productivity and household utilities
- `aeos`: dashboard, requests, and user-facing support tools
- `hera`: lightweight notifications and sharing
- `atlas`: infrastructure and operational tooling

These stacks are defined under [`stacks/`](./stacks).

### Stack Details

#### `io`

Download and ingestion services.

- [qBittorrent](https://www.qbittorrent.org/): BitTorrent client for automated
  downloads
- [SABnzbd](https://sabnzbd.org/): Usenet downloader
- [JDownloader](https://jdownloader.org/): direct-download manager for
  file-hosting and bulk link workflows
- [MeTube](https://github.com/alexta69/metube): simple web frontend for
  `yt-dlp` downloads
- [Immich Drop](https://github.com/Nasogaa/immich-drop): lightweight guest
  uploader for sending photos and videos into Immich

#### `asteria`

Media automation and supporting tools.

- [Prowlarr](https://prowlarr.org/): central indexer manager for the Arr stack
- [Radarr](https://radarr.video/): movie library automation
- [Sonarr](https://sonarr.tv/): TV library automation
- [Lidarr](https://lidarr.audio/): music library automation
- [Whisparr](https://wiki.servarr.com/whisparr): automation for adult media
- [Kapowarr](https://github.com/Casvt/Kapowarr): comics and manga library
  automation
- [Bazarr](https://www.bazarr.media/): subtitle management for Sonarr and
  Radarr libraries
- [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr): browser-backed
  helper for sites protected by anti-bot checks
- [Linkarr](https://github.com/ItsMeJoeeey/Linkarr): helper app for creating
  direct share links into the Arr ecosystem
- [Boxarr](https://github.com/iongpt/boxarr): companion utility included in
  the media automation stack
- [Agregarr](https://github.com/agregarr/agregarr): Plex collection and media
  discovery automation

#### `apollo`

Playback servers and media-server companion apps.

- [Plex](https://www.plex.tv/): media server for streaming and library
  management
- [Jellyfin](https://jellyfin.org/): open-source media server
- [Tautulli](https://tautulli.com/): Plex activity monitoring and analytics
- [Maintainerr](https://github.com/jorenn92/Maintainerr): cleanup and policy
  automation for media requests and libraries
- [Posterizarr](https://github.com/fscorrupt/Posterizarr): poster and artwork
  management for media libraries

#### `helios`

Productivity, household, and personal utility apps.

- [Logseq](https://logseq.com/): local-first knowledge base and note-taking
- [Trilium Notes](https://github.com/TriliumNext/Notes): hierarchical note and
  knowledge management app
- [Stirling PDF](https://stirlingpdf.io/): self-hosted PDF toolkit
- [Mealie](https://mealie.io/): recipe management and meal planning
- [Grocy](https://grocy.info/): pantry, chores, and household inventory
  tracking
- `Tracktor`: user-provided image for parcel or tracking workflows
- `ShipShipShip`: user-provided image for shipping or tracking workflows
- [OpenGist](https://github.com/thomiceli/opengist): self-hosted code and note
  snippets
- `ListingLab`: user-provided image for listing or catalog workflows

#### `aeos`

Dashboards, requests, onboarding, and user-facing support services.

- [Homepage](https://gethomepage.dev/): application dashboard for the homelab
- [Jellyseerr](https://github.com/Fallenbagel/jellyseerr): request management
  for Jellyfin and Plex libraries
- [Wizarr](https://github.com/Wizarrrr/wizarr): user-invite and onboarding
  helper for media servers
- [Speedtest Tracker](https://github.com/alexjustesen/speedtest-tracker):
  ongoing internet speed monitoring
- [changedetection.io](https://github.com/dgtlmoon/changedetection.io): web
  page change monitoring
- [File Browser](https://filebrowser.org/): simple web file manager

#### `hera`

Lightweight sharing and notification services.

- [ntfy](https://ntfy.sh/): publish-subscribe notifications
- [PairDrop](https://pairdrop.net/): local file sharing between devices

#### `atlas`

Infrastructure and operational tooling.

- [Uptime Kuma](https://uptimekuma.org/): service and endpoint monitoring
- [Dozzle](https://dozzle.dev/): live Docker log viewer
- [Watchtower](https://containrrr.dev/watchtower/): automated container update
  watcher
- `sisyphus-migrator`: local `rsync`-style helper for one-way data migration
  into the shared storage dataset

## Storage Model

The storage layout is one of the most important parts of this repo.

- `sisyphus` is the shared bulk-data dataset
- `ixion` is personal storage and should not be the default write target for
  containers
- Proxmox nodes mount storage from TrueNAS over NFS
- Containers see shared writable storage at `/mnt/storage`
- Personal storage should be mounted narrowly and read-only by default
- **Runtime config does not live here** — it is on node-local ZFS

The recommended TrueNAS layout is:

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
```

The recommended mount intent is:

```text
sisyphus -> /mnt/storage
ixion    -> /mnt/personal
```

For services that write to shared storage, the preferred runtime identity is
the shared `sisyphus` service account.

## Service Flow

The media flow is designed so downloaders and media managers share consistent
paths across hosts:

- download clients write into shared storage on `sisyphus`
- Arr applications see those same paths from their own containers
- media managers can hardlink files into library locations instead of copying
- request and dashboard apps talk to services across the cluster over the
  network

This is the key reason the repo standardizes shared mounts and service
identity.

## Repo Intent

This repository is best understood as documentation plus Compose-based
infrastructure-as-code for the homelab's desired state. Some documents describe
the recommended direction, while the `stacks/` tree captures the current stack
layout more concretely.

**This repo is the source of truth.** Decisions that live only in a chat session
do not survive — they get rediscovered and re-argued. Anything settled belongs in
[docs/DECISIONS.md](./docs/DECISIONS.md); anything still unsettled belongs in
[Open Questions / Known Risks](./docs/homelab-network-plan.md#open-questions--known-risks).
