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

The cluster is organized around three main Proxmox nodes:

### Hestia

Hestia is the media hub. It is intended to host playback and transcode-heavy
services because it has the strongest media-serving capabilities in the
cluster.

Intended workloads:

- Plex or Jellyfin
- Channels-DVR
- Audiobookshelf
- Booklore
- Kavita
- Meelo
- ROMm

### Rhea

Rhea is the always-on control-plane node. It is the "brain" of the homelab and
the natural home for download, automation, network-adjacent, and dashboard
services.

Intended workloads:

- Pi-hole + Unbound
- Headscale / WireGuard
- Omada Controller
- `io` stack
- `asteria` stack
- `aeos` stack

### Themis

Themis is the bursty compute and appliance host. It is intended for heavier
background jobs and standalone self-hosted appliances.

Intended workloads:

- Home Assistant OS VM
- Immich
- Paperless-ngx
- `helios` stack
- MySpeed
- OpenGist

## Docker Stacks

The repository currently defines seven top-level Docker stacks:

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

- [Gluetun](https://github.com/qdm12/gluetun): VPN container used to route
  selected download traffic through a private tunnel
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

- `sisyphus` is the shared automation and app-write dataset
- `ixion` is personal storage and should not be the default write target for
  containers
- Proxmox nodes mount storage from TrueNAS over NFS
- Containers see shared writable storage at `/mnt/storage`
- Personal storage should be mounted narrowly and read-only by default

The recommended TrueNAS layout is:

```text
/mnt/tartarus/sisyphus
  downloads/
  media/
  appdata/
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
