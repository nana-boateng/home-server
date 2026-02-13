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
- qBittorrent (full client + Gluetun VPN) → **Io** (was only a UI in Aeos)
- Tautulli → **Apollo** (was in Aeos, but it's Plex-specific)
- Maintainerr, Posterizarr → **Apollo** (Plex/Jellyfin ecosystem tools)
- qBittorrent UI removed (the qBittorrent service includes its own web UI)

### Final Stack Compositions

| Stack | Purpose | Services |
|-------|---------|----------|
| **Io** | Data Pipeline | Gluetun (VPN), qBittorrent, Sabnzbd, JDownloader, MeTube, Immich Drop |
| **Asteria** | Media Management | Prowlarr, Radarr, Sonarr, Lidarr, Whisparr, Kapowarr, Bazarr, FlareSolverr, Linkarr, Boxarr, Aggregarr |
| **Apollo** | Media Servers | Plex, Jellyfin, Tautulli, Maintainerr, Posterizarr |
| **Helios** | Productivity | Logseq, Trilium, Stirling-PDF, Mealie, Grocy, Tracktor\*, ShipShipShip\*, OpenGist, ListingLab\* |
| **Aeos** | Observability | Homepage, Jellyseerr, Wizarr, Speedtest, ChangeDetection, FileBrowser Quantum |
| **Hera** | Notifications | ntfy, PairDrop |
| **Atlas** | Infrastructure | Watchtower, Uptime Kuma, Dozzle |

*\* Docker images to be provided by user before implementation*

---

## Port Allocation Scheme

Each stack gets a dedicated port range. Host ports are sequential within each range. Services needing specialized ports (Plex, Jellyfin) keep their standard ports.

### Io — 5000 range
| Service | Host Port | Container Port | Notes |
|---------|-----------|---------------|-------|
| Gluetun (control) | 5001 | 8000 | |
| qBittorrent (via Gluetun) | 5002 | 8080 | Published on Gluetun container |
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
/opt/stacks/home-server/          # Git repo clone
/opt/appdata/<service-name>/      # Persistent config (Docker volumes)
/mnt/storage/                     # NFS mount from TrueNAS (where needed)
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
  - /opt/appdata/<service>:/config
  - /mnt/storage:/storage              # Consistent path = hardlinks work
```

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

- **Tailscale**: All services accessible privately via mesh network
- **Cloudflare Tunnels**: Only for public-facing services:
  - Apollo: Plex (32400), Jellyfin (8096)
  - Aeos: Jellyseerr (6002), Homepage (6001)
  - Hera: ntfy (10001) — if mobile push notifications needed externally

Cloudflared runs as a container in the stacks that need external access.

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
8. `stacks/io/docker-compose.yml` + `.env.template` (Gluetun, qBittorrent, Sabnzbd, etc.)

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
5. Inspect Gluetun networking: qBittorrent must use `network_mode: service:gluetun`
6. Confirm `.env` files are gitignored and `.env.template` files are committed
