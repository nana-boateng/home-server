# Homelab Architecture Notes

This note captures the recommended direction for the current homelab design,
based on the existing 3-node Proxmox cluster and the storage lessons learned
from the TrueNAS/NFS/LXC permission model.

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

- Jasper Lake QuickSync is the best media/transcode feature in the cluster.
- It should stay focused on media serving rather than download churn.

Recommended services:

- Plex or Jellyfin
- Channels-DVR
- Audiobookshelf
- Booklore
- Kavita
- Meelo
- ROMm

Suggestion:

- Keep playback and transcode services here.
- Avoid moving the downloader stack onto this node.

### Rhea

Role: control plane and always-on service node

Why:

- Good low-power box for 24/7 workloads.
- Natural fit for network-adjacent and orchestration services.

Recommended services:

- Pi-hole + Unbound
- Headscale / WireGuard
- Omada Controller
- `io`: Sabnzbd, qBittorrent, JDownloader, MeTube
- `asteria`: Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, related Arr tools
- `aeos`: Homepage, Jellyseerr, Tautulli, Speedtest

Suggestion:

- Keep calling it the "brain" if you want.
- Be careful calling it the "gateway" unless it is intentionally becoming a
  real network choke point for the whole homelab.

### Themis

Role: bursty compute and appliance host

Why:

- Better single-core performance than the N5095 nodes.
- Good place for dedicated VM workloads and heavier background jobs.

Recommended services:

- Home Assistant OS VM
- Immich
- Paperless-ngx
- `helios`: Logseq, Stirling-PDF, Mealie, Grocy
- MySpeed
- OpenGist

Suggestion:

- Home Assistant on a dedicated VM is the right call.
- Immich may work well enough here, but watch performance and power.
- If photo ML becomes a major workload, consider a future hardware upgrade
  rather than forcing the older platform to be something it is not.

## Recommended Service Placement

```text
Hestia
- Plex or Jellyfin
- Audiobookshelf
- Kavita
- Booklore
- Meelo
- ROMm
- Channels-DVR

Rhea
- Pi-hole + Unbound
- Headscale / WireGuard
- Omada Controller
- Asteria: Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, Recyclarr
- Io: Sabnzbd, qBittorrent, JDownloader, MeTube
- Aeos: Homepage, Tautulli, Jellyseerr, Speedtest

Themis
- Home Assistant OS VM
- Immich
- Paperless-ngx
- Helios: Logseq, Stirling-PDF, Mealie, Grocy
- MySpeed
- OpenGist
```

Notes:

- Tautulli can stay on Rhea, but putting it on Hestia is also reasonable if
  you want it physically close to Plex.
- Jellyseerr is a good fit on Rhea because it mainly coordinates with the Arr
  stack and media server over the network.

## Storage Layout

Recommended datasets and directory layout:

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

- `sisyphus` is the automation and app-write path.
- `sisyphus` should remain one dataset with plain directories inside it.
- Do not recreate `downloads`, `media`, `appdata`, or `shared` as child ZFS
  datasets unless you intentionally want separate exports and separate storage
  policy.
- `ixion` is personal storage and should not be the default write target for
  containers.
- If a container needs access to personal data, prefer a narrow mount or
  dedicated subdirectory instead of broad write access.

### Service Path Conventions

Use these conventions inside containers:

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
- /mnt/storage/appdata/asteria/prowlarr
- /mnt/storage/appdata/asteria/sonarr
- /mnt/storage/appdata/asteria/radarr
- /mnt/storage/appdata/asteria/lidarr
- /mnt/storage/appdata/asteria/bazarr

aeos
- /mnt/storage/appdata/aeos/homepage
- /mnt/storage/appdata/aeos/tautulli
- /mnt/storage/appdata/aeos/jellyseerr
- /mnt/storage/shared
```

For services that write to `sisyphus`, prefer running them as `3004:3004`.

Use real bind paths under `/mnt/storage/...` in Docker Compose files rather
than symlinked home-directory paths. Pre-create config directories before
starting containers on NFS-backed storage.

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

Suggestion:

- Add a secondary Pi-hole/Unbound somewhere outside Rhea if you want DNS
  maintenance to feel less dramatic.
- If you use a reverse proxy later, Rhea is a natural place for it unless you
  intentionally build a dedicated ingress layer.
- Use SMB for MacBook / human browsing and keep NFS as the Proxmox / LXC
  protocol.

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

## Final Direction

The overall architecture is strong. The main improvement is not the node
layout; it is the storage and identity model. If `sisyphus` is the single
container-write dataset owned by `sisyphus` (`3004:3004`), and `ixion` stays
personal and narrow, future nodes and future migrations will be much easier.
