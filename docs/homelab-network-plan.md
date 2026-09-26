# Homelab Network Plan (Omada + Proxmox + TrueNAS)

This document captures the **general gist** of the homelab rebuild: replicate the
reference pfSense/VLAN/Synology layout using **TP-Link Omada** (ER605 gateway,
smart switch, OC200 controller), the existing **3-node Proxmox** cluster, and
**TrueNAS tartarus** — with portability (move homes, change ISP) as a
first-class goal.

Related docs:

- [Decision Log](./DECISIONS.md) — locked decisions and their rationale
- [Homelab Architecture Notes](./homelab-architecture-notes.md) — node roles, stacks
- [TrueNAS to Proxmox Storage](./truenas-proxmox-storage.md) — NFS identity model
- [Network Implementation Phases](./network-implementation-phases.md) — step-by-step build

---

## The Gist

**What we're replicating from the reference diagram**

- Four VLANs: Main, IoT, Guest, VPN
- Static infrastructure on Main; DHCP for clients
- Pi-hole + recursive DNS (Unbound)
- Central storage server + Docker workloads
- Room-based switching (office core, optional theater switch, WiFi AP)
- Remote access without re-architecting on ISP change

**What we're using instead**

| Reference | Ours |
|-----------|------|
| pfSense firewall | TP-Link Omada ER605 gateway |
| Netgear switches | Omada smart switch(es) |
| Meraki AP | Omada EAP |
| Synology + Docker | TrueNAS tartarus + Proxmox LXCs + Compose stacks |
| WireGuard on firewall | Tailscale mesh (+ optional Omada WireGuard) |
| pfSense Pi-hole | Pi-hole + Unbound in a **Proxmox LXC** (see [DECISIONS.md](./DECISIONS.md)) |

**Portability rules**

1. **Git** = service source of truth (`stacks/`, scripts, this doc)
2. **MAC-based DHCP** reservations — not "this jack = this IP"
3. **`site.env`** (gitignored) holds WAN/ISP-only settings
4. **DNS hostnames** (`*.lan`) — apps never hardcode IPs
5. **Tailscale** overlay survives ISP/moves without port forwards
6. **Export backups**: Omada site, TrueNAS config, Proxmox dumps, Pi-hole, `.env` files

---

## Addressing Scheme

The LAN is **`10.0.0.0/24`**, gateway **`10.0.0.1`** (TP-Link ER605). The DHCP
pool `.100–.254` is configured and live on the router. Statics live in `.1–.99`.

| Range | Purpose |
|-------|---------|
| `.1` | ER605 router / gateway |
| `.2–.9` | Core network gear (`.2` reserved for OC200) |
| `.10–.29` | Physical hosts |
| `.30–.99` | Services, VMs, LXCs — assigned by service, not by node |
| `.100–.254` | DHCP pool |

**Assigned and live**

| Host | IP | Notes |
|------|-----|-------|
| ER605 router | `10.0.0.1` | |
| OC200 | `10.0.0.2` | Reserved — hardware currently faulty |
| Rhea | `10.0.0.10` | Proxmox, `vmbr0` |
| Themis | `10.0.0.11` | Proxmox, `vmbr0` |
| Hestia | `10.0.0.12` | Proxmox, `vmbr0` |
| Tartarus (TrueNAS) | `10.0.0.20` | static alias on `enp2s0` |

**Rule: service IPs are not node-encoded.** An IP must never imply which node a
service runs on — HA migration would immediately make that encoding a lie.
Assign from `.30–.99` by service, and let DNS and the reverse proxy hide the
placement.

Suggested (not yet assigned) grouping inside `.30–.99`:

| Range | Grouping |
|-------|----------|
| `.30–.49` | Media |
| `.50–.69` | Infrastructure |
| `.70–.99` | Everything else |

Pi-hole primary at `.50` and secondary at `.51` fit the infrastructure band.

### Search domain

The search domain is **`.lan`**. All host and service names are `*.lan`.

**`.local` must not be used anywhere.** It is reserved for mDNS (RFC 6762) and
causes intermittent, hard-to-debug resolution failures on macOS and Linux.

> **Action item:** the TrueNAS box is currently configured with domain `local`
> and needs to be moved to `lan`.

### VLANs

The Main VLAN is the live `10.0.0.0/24` above. The remaining VLANs are still
**planned, not built** — they depend on the Omada controller, and the OC200 is
currently faulty.

| VLAN | Name | Subnet | Gateway | Status |
|------|------|--------|---------|--------|
| 1 | Main | `10.0.0.0/24` | `10.0.0.1` | **Live** |
| 2 | IoT | `10.2.0.0/24` | `10.2.0.1` | Planned |
| 3 | Guest | `10.3.0.0/24` | `10.3.0.1` | Planned |
| 4 | VPN | `10.4.0.0/24` | `10.4.0.1` | Planned |

All VLANs use Pi-hole (`10.0.0.50`) as DNS via DHCP — not ISP DNS.

---

## Physical Topology

```text
[ISP Modem] → [ER605 Gateway] → [Core Switch] ─┬─ tartarus (10G if available)
                                                  ├─ rhea / hestia / themis
                                                  ├─ [Theater Switch] (trunk)
                                                  └─ [Omada AP] (trunk, multi-SSID)
```

- **Trunk ports**: gateway ↔ core, core ↔ AP, core ↔ theater switch
- **Access ports**: end devices on single VLAN
- **Gaming/consoles** → Main (VLAN 1); **TVs/speakers/bridges** → IoT (VLAN 2)

---

## DNS

**Pi-hole runs as a Proxmox LXC, not a Docker container**, with Unbound behind
it inside the same LXC.

Why not Docker:

- A bridged container conflicts on port 53 and reports the Docker gateway as the
  client for every query, destroying per-device statistics.
- `macvlan` fixes the client attribution but blocks host↔container traffic.
- An LXC avoids both problems.

Rules:

- **DNS must not be entangled with the Compose stacks.** Restarting a stack must
  never take down DNS.
- Pi-hole serves **split-horizon DNS**: internal hostnames resolve to LAN IPs.

Placement: see [Infrastructure Placement](#infrastructure-placement) below.

---

## Reverse Proxy and External Access

**Caddy**, running in its own Proxmox LXC. Chosen over Traefik deliberately, for
the static, version-controllable Caddyfile.

- **One central Caddy instance fronts every service on every node.** The
  Caddyfile is a static `hostname → 10.0.0.x:port` map and **lives in this repo**.
- **Caddy Cloudflare DNS plugin** for DNS-01 challenges, so internal-only
  services get real Let's Encrypt certificates with no inbound exposure. Domains
  are on Cloudflare.
- **Public services** (Jellyfin, and anything else remote users touch) go out via
  **Cloudflare Tunnel** — no port forwards, no open inbound ports on the home IP.
- **Jellyfin must sit behind an auth layer** (Cloudflare Access or Authentik).
  Unlike Plex, Jellyfin has no brokered remote-access model, and some of its API
  endpoints do not require authentication — app-level login alone is not enough.
  Auth must terminate at the proxy, **before** Jellyfin sees the request.
- **Plex keeps its own native remote access.** Do not proxy it.

---

## Infrastructure Placement

Caddy and Pi-hole are **infrastructure, not applications**. Both:

- run as **LXCs on the Proxmox cluster**, outside Docker Compose
- go on a **quieter node (Themis or Hestia)** — **not** Rhea
- must **not** go on the fourth non-clustered machine

The reverse proxy and DNS are the two components whose failure takes down access
to everything else. They belong on managed, snapshotted, always-on hardware with
`vzdump` coverage. The fourth machine sits outside the cluster, gets no snapshots
or backups, and is expected to be repurposed and rebooted freely — the wrong home
for a front door.

### The fourth machine

Same specs as the weakest node. Stays **outside** the Proxmox cluster. Reserved
for experiments, tinkering, and disposable workloads. **Explicitly
non-production** — nothing critical goes here, and work should not drift onto it.

---

## Compute Placement

| Node | Role | Stacks / services |
|------|------|-------------------|
| **tartarus** | Storage | NFS `sisyphus`, SMB `ixion`, Proxmox backups |
| **rhea** | Control plane | `io`, `asteria`, `aeos`, `atlas`, `hera` |
| **hestia** | Media hub | `apollo`, Channels-DVR, Audiobookshelf, … |
| **themis** | Compute / appliances | HA OS VM, Immich, Paperless, `helios` |
| **(themis or hestia)** | Infrastructure LXCs | Caddy, Pi-hole + Unbound, Tailscale subnet router |
| **fourth machine** | Non-production | Experiments only — see above |

Storage identity: **`sisyphus` UID/GID 3004** on NFS; see
[truenas-proxmox-storage.md](./truenas-proxmox-storage.md).

---

## Firewall Intent (Omada)

Keep rules simple — pfSense-level micro-rules not required.

1. **Guest** → RFC1918: deny; → WAN: allow
2. **IoT** → Main: deny (default); allow DNS to `10.0.0.50`; allow WAN
3. **Main** → IoT: allow (admin); → anywhere: allow
4. **VPN** → Main (+ optional IoT): allow

NFS (`10.0.0.20`) is **not** exposed to IoT/Guest.

---

## Remote Access

- **Primary**: Tailscale, with **subnet routing** advertising `10.0.0.0/24` from
  a stable always-on node or LXC — **not** the fourth machine. Approve the route
  in the Tailscale admin console. This gives full LAN reachability off-site with
  no open ports.
- **Public services**: Cloudflare Tunnel via Caddy — see
  [Reverse Proxy and External Access](#reverse-proxy-and-external-access).
- **Optional**: Omada WireGuard for full-tunnel road warriors.

Tailscale is the standard. **Headscale is not used.**

---

## Backup Layers

| Layer | What |
|-------|------|
| Git | Compose stacks, docs, Caddyfile, DNS record templates |
| Encrypted restic | `.env`, `site.env`, API keys |
| Omada | Monthly site export |
| TrueNAS | Config + ZFS snapshots |
| Proxmox | `vzdump` → `tartarus/proxmox` |
| Appdata | `/mnt/storage/appdata/**` snapshots |

**Restore drill**: time a full LXC + one stack + Omada import before relying on backups.

See also the unresolved backup risk in
[Open Questions](#open-questions--known-risks).

---

## Implementation Phases (overview)

Detailed steps: [network-implementation-phases.md](./network-implementation-phases.md)

| Phase | Focus |
|-------|--------|
| **0** | Inventory — hardware, MACs, ISP type |
| **1** | Network foundation — VLANs, Omada, WiFi, firewall |
| **2** | Storage + hypervisor — TrueNAS, NFS, Proxmox LXCs |
| **3** | Control plane — Pi-hole, Caddy, Tailscale, core stacks |
| **4** | Media + apps — Hestia/Themis workloads |
| **5** | Hardening + portability — backups, restore drill, move checklist |

---

## Open Questions / Known Risks

Raised and reasoned through, but **not ratified**. Nothing here is implemented —
do not change architecture or Compose files to act on these until they are
decided and moved into [DECISIONS.md](./DECISIONS.md).

### SQLite on NFS (highest-risk open item)

The `io` and `asteria` stacks share an NFS path on `sisyphus` so the Arr apps can
hardlink instead of copy. That is correct for **media and download data**. But
Radarr, Sonarr, Prowlarr, Bazarr, Immich, and Paperless all keep SQLite/Postgres
databases, and SQLite over NFS has unreliable locking and a well-known corruption
failure mode.

Proposed rule, **pending confirmation**: media and downloads on NFS; `/config`
volumes on node-local storage; scheduled backup of configs to Tartarus.

**Open:** does each node actually have local SSD available to hold configs?

### Rhea is a single point of failure for its own monitoring

Uptime Kuma, ntfy, Dozzle, and primary DNS currently all live on Rhea. If Rhea
goes down there is no monitoring and no notification path — the failure is
silent.

Proposed, **pending confirmation**: move Uptime Kuma and ntfy to Themis. A
monitor must not share a failure domain with what it monitors.

### Secondary DNS is not real failover

Clients typically query both resolvers rather than cleanly failing over. Two
Pi-holes with different blocklists produce inconsistent blocking, not redundancy.
Either keep them synced (Gravity Sync or equivalent), or document that the
secondary is availability-only and not policy-parity.

Related: **the Proxmox hosts themselves should not use Pi-hole as their
resolver.** Point them at `10.0.0.1` + `1.1.1.1` so DNS recovery is not circular
when the Pi-hole node is down.

### Backup story

Proxmox dumps, the `sisyphus-migrator` rsync, and live data all land on Tartarus.
RAID and one-way rsync are not backups — a bad delete or a pool loss takes
everything. At least one copy needs to live off that box. **Unresolved.**

### Watchtower and Docker socket exposure

- Watchtower auto-updating ~29 services invites breakage from upstream changes.
  Proposed: run in monitor-only mode (`WATCHTOWER_MONITOR_ONLY`), notify via
  ntfy, pull deliberately.
- Dozzle and Watchtower both mount `/var/run/docker.sock`, which is
  root-equivalent. Proposed: put a socket-proxy in front of both with read-only
  scopes.

### qBittorrent — host lockup, sizing pinned

qBittorrent in an LXC on a Proxmox node repeatedly **hard-locked the entire
host**, requiring a physical reset. It was moved to the fourth machine as a
workaround. The intent is to bring it back onto the cluster.

Working theory: host OOM from an unbounded LXC. Many hundreds of torrents,
downloading and seeding simultaneously, drives large per-torrent state plus disk
cache; without an enforced container memory limit this pressures the host.

Mitigations to apply when it returns — **sizing not final**:

- hard memory limit on the container, so it OOMs inside its own boundary
- explicit qBittorrent disk-cache cap rather than auto
- bounded global and per-torrent connection limits
- active-torrent queueing, so not every torrent runs hot
- incomplete-downloads folder on node-local SSD, moved to NAS on completion

**Blocked on:** total RAM of the weakest node.

### Other flagged items

- **No auth layer** in front of File Browser, Dozzle, or Homepage. Matters if
  anything becomes LAN-reachable rather than Tailscale-only.
- **Home Assistant OS VM** uses USB/Zigbee passthrough, which pins it to Themis
  and makes it ineligible for live migration — so it cannot participate in
  Proxmox HA. Either accept that, or decouple with a network Zigbee coordinator.
  Also: place the coordinator where the Zigbee mesh needs it, not where the rack
  is.
- **Immich is on Themis but the QuickSync GPU is on Hestia.** Its ML workload
  would benefit from the GPU. Either move it, or accept CPU-only detection.
- **Omada software controller** should not go on Rhea (already overloaded).
  Themis, or a small LXC on Hestia.
- **Proxmox HA vs Kubernetes** — leaning Proxmox HA, since the workload is
  overwhelmingly single-instance stateful containers. Note that HA needs shared
  storage, which makes Tartarus a cluster-wide single point of failure — so the
  backup story should be resolved first.
- The Compose stubs **Tracktor**, **ShipShipShip**, and **ListingLab** are still
  waiting on user-provided images.

---

## Open Decisions (network build)

Fill in before Phase 1:

- [ ] Exact Omada switch / AP models (gateway is ER605, controller is OC200)
- [ ] OC200 replacement or RMA — hardware currently faulty
- [ ] Theater second switch: yes/no
- [ ] HomeKit/AirPlay: same-VLAN vs mDNS reflector
