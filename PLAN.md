# Home Server Infrastructure as Code — Implementation Plan

## Context

The goal is to take a manually managed home server (documented as 5 Docker stacks across Proxmox VMs/LXCs with TrueNAS storage) and codify it into a single git repository that enables easy maintenance, migration, and reproducible deployments. The current documentation has several gaps (missing services, incorrect stack placement, no infrastructure layer) that this plan corrects.

---

## Confirmed Decision: CIFS → NFS for Media Paths

**DECIDED:** Switch TrueNAS media exports from CIFS to NFS. NFS supports hardlinks natively, which the *Arr apps require to avoid doubling disk usage during imports.

**Architecture:** TrueNAS --[NFS]--> Proxmox host `/mnt/storage` --> bind-mount into LXC `/mnt/storage` --> Docker volume `/storage`

A single NFS export containing both `downloads/` and `library/` under one mount point is required per TRaSH Guides best practices. Non-media CIFS shares can remain as-is.

---

## Corrected Stack Architecture (7 stacks, up from 5)

### New Stacks Added
- **Apollo** — Media Servers (Plex, Jellyfin, Tautulli, Maintainerr, Posterizarr)
- **Atlas** — Infrastructure (Watchtower, Uptime Kuma, Dozzle)

### Service Moves
- qBittorrent (full client) → **Io** (was only a UI in Aeos)
- Tautulli → **Apollo** (was in Aeos, but it's Plex-specific)
- Maintainerr, Posterizarr → **Apollo** (Plex/Jellyfin ecosystem tools)
- qBittorrent UI removed (the qBittorrent service includes its own web UI)

### Final Stack Compositions

| Stack | Purpose | Services |
|-------|---------|----------|
| **Io** | Data Pipeline | qBittorrent, Sabnzbd, JDownloader, MeTube, Immich Drop |
| **Asteria** | Media Management | Prowlarr, Radarr, Sonarr, Lidarr, Whisparr, Kapowarr, Bazarr, FlareSolverr, Linkarr, Boxarr, Aggregarr |
| **Apollo** | Media Servers | Plex, Jellyfin, Tautulli, Maintainerr, Posterizarr |
| **Helios** | Productivity | Logseq, Trilium, Stirling-PDF, Mealie, Grocy, Tracktor\*, ShipShipShip\*, OpenGist, ListingLab\* |
| **Aeos** | Observability | Homepage, Jellyseerr, Wizarr, Speedtest, ChangeDetection, FileBrowser Quantum |
| **Hera** | Notifications | ntfy, PairDrop |
| **Atlas** | Infrastructure | Watchtower, Uptime Kuma, Dozzle |

*\* Docker images to be provided by user before implementation*

> **Superseded in structure.** The seven stacks below are no longer the
> deployment unit — see
> [docs/service-architecture.md](./docs/service-architecture.md) for the 11-LXC +
> VM map. This section remains accurate as a **service inventory and port
> allocation**, which the new grouping does not change.

**Not stacks.** Pi-hole + Unbound, Caddy, and the Tailscale subnet router are
infrastructure, not applications. They run as **Proxmox LXCs on Rhea**, outside
Docker Compose, so that restarting a stack can never take down DNS or ingress.
See [docs/DECISIONS.md](./docs/DECISIONS.md) D3, D4, D13.

**Stack placement** (D13): `apollo` on Hestia; `io`, `asteria`, and `helios` on
Themis; Uptime Kuma and ntfy on Rhea with the infrastructure. `aeos` and the
`atlas` remainder are **not yet assigned**.

---

## Port Allocation Scheme

Each stack gets a dedicated port range. Host ports are sequential within each range. Services needing specialized ports (Plex, Jellyfin) keep their standard ports.

### Io — 5000 range
| Service | Host Port | Container Port | Notes |
|---------|-----------|---------------|-------|
| qBittorrent | 5002 | 8080 | Own IP and port — no VPN sidecar (D17) |
| Sabnzbd | 5003 | 8080 | |
| JDownloader | 5004 | 5800 | |
| MeTube | 5005 | 8081 | |
| Immich Drop | 5006 | 8080 | |

### Aeos — 6000 range
| Service | Host Port | Container Port | Notes |
|---------|-----------|---------------|-------|
| Homepage | 6001 | 3000 | |
| Jellyseerr | 6002 | 5055 | |
| Wizarr | 6003 | 5690 | |
| Speedtest | 6004 | 80 | |
| ChangeDetection | 6005 | 5000 | |
| FileBrowser Quantum | 6006 | 8080 | |

### Asteria — 7000 range
| Service | Host Port | Container Port | Notes |
|---------|-----------|---------------|-------|
| Prowlarr | 7001 | 9696 | |
| Radarr | 7002 | 7878 | |
| Sonarr | 7003 | 8989 | |
| Lidarr | 7004 | 8686 | |
| Whisparr | 7005 | 6969 | |
| Kapowarr | 7006 | 5656 | |
| Bazarr | 7007 | 6767 | |
| FlareSolverr | 7008 | 8191 | |
| Linkarr | 7009 | 8080 | |
| Boxarr | 7010 | 8888 | |
| Aggregarr | 7011 | 7171 | |

### Apollo — 8000 range (+ specialized ports)
| Service | Host Port | Container Port | Notes |
|---------|-----------|---------------|-------|
| Plex | **32400** | 32400 | Specialized — required for Plex protocol |
| Jellyfin | **8096** | 8096 | Specialized — standard Jellyfin port |
| Tautulli | 8001 | 8181 | |
| Maintainerr | 8002 | 6246 | |
| Posterizarr | 8003 | 8000 | |

### Helios — 9000 range
| Service | Host Port | Container Port | Notes |
|---------|-----------|---------------|-------|
| Logseq | 9001 | 80 | |
| Trilium | 9002 | 8080 | |
| Stirling-PDF | 9003 | 8080 | |
| Mealie | 9004 | 9000 | |
| Grocy | 9005 | 80 | |
| Tracktor\* | 9006 | TBD | |
| ShipShipShip\* | 9007 | TBD | |
| OpenGist | 9008 | 6157 | |
| ListingLab\* | 9009 | TBD | |

### Hera — 10000 range
| Service | Host Port | Container Port | Notes |
|---------|-----------|---------------|-------|
| ntfy | 10001 | 80 | |
| PairDrop | 10002 | 3000 | |

### Atlas — 11000 range
| Service | Host Port | Container Port | Notes |
|---------|-----------|---------------|-------|
| Uptime Kuma | 11001 | 3001 | |
| Dozzle | 11002 | 8080 | |
| Watchtower | — | 8080 | No port exposure needed (API-only) |

---

## Repository Structure

```
home-server/
├── .gitignore
├── README.md
├── common/
│   └── .env.template                    # Shared vars: PUID, PGID, TZ
├── scripts/
│   ├── deploy.sh                        # Deploy a stack: ./deploy.sh io
│   ├── provision-host.sh                # Base setup: Docker, NFS, Tailscale
│   ├── setup-nfs-mounts.sh             # NFS mount config per host
│   ├── setup-tailscale.sh               # Tailscale enrollment
│   ├── validate-env.sh                  # Check .env has all required vars
│   ├── backup.sh                        # Backup appdata to TrueNAS
│   └── restore.sh                       # Restore from backup
├── provisioning/
│   ├── fstab.template                   # NFS fstab entries template
│   ├── lxc-config.template              # Proxmox LXC bind mount template
│   └── nfs-exports.example              # TrueNAS NFS export reference
├── caddy/
│   └── Caddyfile                        # Central reverse proxy: hostname → 10.0.0.x:port
└── stacks/
    ├── io/
    │   ├── docker-compose.yml
    │   ├── .env.template
    │   └── config/
    ├── asteria/
    │   ├── docker-compose.yml
    │   ├── .env.template
    │   └── config/
    ├── apollo/
    │   ├── docker-compose.yml
    │   ├── .env.template
    │   └── config/
    ├── helios/
    │   ├── docker-compose.yml
    │   ├── .env.template
    │   └── config/
    ├── aeos/
    │   ├── docker-compose.yml
    │   ├── .env.template
    │   └── config/
    │       └── homepage/
    │           ├── services.yaml
    │           ├── bookmarks.yaml
    │           └── widgets.yaml
    ├── hera/
    │   ├── docker-compose.yml
    │   └── .env.template
    └── atlas/
        ├── docker-compose.yml
        └── .env.template
```

---

## Standardized Path Convention

### On each VM/LXC host:
```
/opt/stacks/home-server/            # Git repo clone — declarative only, no state
/opt/appdata/<stack>/<service>/     # Persistent config on node-local ZFS
/mnt/storage/                       # NFS mount from TrueNAS — bulk data only
```

### TrueNAS media directory (single NFS export for hardlinks):
```
/mnt/storage/
├── downloads/
│   ├── usenet/
│   │   ├── complete/{movies,tv,music,xxx,comics}/
│   │   └── incomplete/
│   ├── torrents/
│   │   ├── complete/{movies,tv,music,xxx}/
│   │   └── incomplete/
│   ├── jdownloader/
│   └── metube/
├── library/
│   ├── movies/
│   ├── tv/
│   ├── music/
│   ├── xxx/
│   ├── comics/
│   └── books/
└── photos/
```

### Docker volume mapping rule:
```yaml
# ALL media-accessing services use the same mount:
volumes:
  - ${APPDATA_DIR}/<stack>/<service>:/config   # node-local ZFS — never NFS
  - ${STORAGE_DIR}:/storage                    # Consistent path = hardlinks work
```

**Two tiers, and the split is load-bearing.** `/config` and databases go on
node-local ZFS; only `downloads/`, `media/`, and `shared/` go on NFS. SQLite over
NFS has unreliable locking and a well-known corruption mode, and Radarr, Sonarr,
Prowlarr, Bazarr, Immich, and Paperless all keep SQLite or Postgres databases.
See [docs/DECISIONS.md](./docs/DECISIONS.md) D11.

`APPDATA_DIR` defaults to `/opt/appdata`. The `${STORAGE_DIR}` mount must be
identical across `io` and `asteria` or hardlinking breaks and imports silently
double disk usage.

State on node-local disk is backed up by **Restic** — per-node agents, ZFS
snapshot quiesce, shared deduplicated repo on Tartarus. See D12. The git clone
holds declarative configuration only; it is never the state backup.

---

## Inter-Stack Communication

Since stacks run on separate Proxmox VMs, services talk over the network via Tailscale DNS:

| From | To | Address |
|------|----|---------|
| Radarr (asteria) | qBittorrent (io) | `io:5002` |
| Radarr (asteria) | Sabnzbd (io) | `io:5003` |
| Jellyseerr (aeos) | Radarr (asteria) | `asteria:7002` |
| Jellyseerr (aeos) | Sonarr (asteria) | `asteria:7003` |
| Jellyseerr (aeos) | Plex (apollo) | `apollo:32400` |
| Jellyseerr (aeos) | Jellyfin (apollo) | `apollo:8096` |
| Tautulli (apollo) | Plex (apollo) | `localhost:32400` (same stack) |
| Maintainerr (apollo) | Radarr (asteria) | `asteria:7002` |
| Maintainerr (apollo) | Sonarr (asteria) | `asteria:7003` |
| Homepage (aeos) | All services | Via Tailscale DNS |
| Uptime Kuma (atlas) | All services | Via Tailscale DNS |

**Shared filesystem note:** Both Io and Asteria mount the same NFS export to `/mnt/storage`. When qBittorrent on Io downloads to `/storage/downloads/torrents/complete/movies/`, Radarr on Asteria sees it at the same path and can hardlink to `/storage/library/movies/`.

---

## External Access

Design and rationale: [docs/DECISIONS.md](./docs/DECISIONS.md) D4, D5, D7.

- **Tailscale** is the primary path. Subnet routing advertises `10.0.0.0/24` from
  a stable, always-on node or LXC (never the fourth machine), so the whole LAN is
  reachable off-site with no open inbound ports.
- **Caddy** — one central instance in its own Proxmox LXC — fronts every service
  on every node. The Caddyfile is a static `hostname → 10.0.0.x:port` map,
  committed to this repo. The Cloudflare DNS plugin handles DNS-01 challenges, so
  internal-only services get real Let's Encrypt certs without any inbound
  exposure.
- **Cloudflare Tunnel** carries the genuinely public services out — no port
  forwards, no open inbound ports on the home IP.

| Service | Path | Notes |
|---------|------|-------|
| Plex (32400) | **Native Plex remote access** | Not proxied, not tunnelled |
| Jellyfin (8096) | Cloudflare Tunnel → Caddy → **auth layer** | Cloudflare Access or Authentik, terminating at the proxy |
| Jellyseerr (6002), Homepage (6001) | Caddy; tunnel only if remote users need them | Otherwise Tailscale-only |
| ntfy (10001) | Cloudflare Tunnel | If mobile push is needed externally |

**Jellyfin must not be exposed without an auth layer in front of it.** Unlike
Plex it has no brokered remote-access model, and some of its API endpoints do not
require authentication — app-level login alone is not sufficient. Authentication
has to terminate at the proxy, before the request reaches Jellyfin.

Several services (File Browser, Dozzle, Homepage) currently have **no auth layer
at all**. That is fine while they are Tailscale-only, and a problem the moment
anything makes them LAN- or internet-reachable — tracked as an
[open question](./docs/OPEN-QUESTIONS.md#unified-auth-layer).

---

## Secrets Strategy

- `.env.template` files committed to git (variable names, no values)
- `.env` files gitignored (actual secrets, created from template on deploy)
- `scripts/validate-env.sh` checks all template vars have values before deploy
- API keys generated by apps (Radarr, Sonarr, etc.) live in `/opt/appdata/` and are covered by backups

---

## Implementation Phases

### Phase 1: Foundation
1. Initialize git repo, directory structure, `.gitignore`
2. Write `common/.env.template`
3. Write provisioning scripts (`provision-host.sh`, `setup-nfs-mounts.sh`, `setup-tailscale.sh`)
4. Write `deploy.sh` and `validate-env.sh`
5. Write `fstab.template` and `lxc-config.template`

### Phase 2: Stacks — Infrastructure First
6. `stacks/atlas/docker-compose.yml` + `.env.template` (Watchtower, Uptime Kuma, Dozzle)
7. `stacks/hera/docker-compose.yml` + `.env.template` (ntfy, PairDrop)

### Phase 3: Stacks — Data Pipeline
8. `stacks/io/docker-compose.yml` + `.env.template` (qBittorrent, Sabnzbd, etc.)

### Phase 4: Stacks — Media
9. `stacks/asteria/docker-compose.yml` + `.env.template` (*Arr suite)
10. `stacks/apollo/docker-compose.yml` + `.env.template` (Plex, Jellyfin, etc.)

### Phase 5: Stacks — User-Facing
11. `stacks/aeos/docker-compose.yml` + `.env.template` + Homepage config
12. `stacks/helios/docker-compose.yml` + `.env.template`

### Phase 6: Operations
13. Write `backup.sh` and `restore.sh`
14. Write backup crontab example

---

## Verification

After implementation, verify by:
1. Run `scripts/validate-env.sh` against each stack's template — should pass with template values filled
2. Run `docker compose -f stacks/<stack>/docker-compose.yml config` for each stack — validates compose syntax
3. Inspect volume mappings: all media stacks must map `/mnt/storage:/storage`
4. Inspect inter-stack references: *Arr apps reference `io:PORT` for download clients
6. Confirm `.env` files are gitignored and `.env.template` files are committed

---

## Open Questions

Design questions raised but **not ratified** live in
[docs/OPEN-QUESTIONS.md](./docs/OPEN-QUESTIONS.md) — second-tier storage as a
purchase, transcode placement, off-box backup, Docker socket exposure, and the
unassigned `aeos`/`atlas` placement among them.

Nothing there is implemented.

## Build State

The infrastructure layer is **built, not planned**: three nodes clean-installed
on PVE 9.2.2 with ZFS-on-root, joined into cluster **`gaia`**, behind a MikroTik
CRS310 core switch. See [docs/rebuild-runbook.md](./docs/rebuild-runbook.md) for
the completed sequence and its gotchas, and
[docs/hardware-inventory.md](./docs/hardware-inventory.md) for measured specs.

Remaining: NFS mounts to Tartarus, stack rebuild per the placement rule, the
infrastructure LXCs on Rhea, and Restic.
