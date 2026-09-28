# Homelab Network Plan (Omada + Proxmox + TrueNAS)

This document captures the **general gist** of the homelab network: a **TP-Link
ER605** gateway for routing and firewalling, a **MikroTik CRS310** core switch
doing all VLAN work, the **3-node Proxmox cluster `gaia`**, and **TrueNAS
tartarus** — with portability (move homes, change ISP) as a first-class goal.

Related docs:

- [Decision Log](./DECISIONS.md) — locked decisions and their rationale
- [Open Questions](./OPEN-QUESTIONS.md) — unratified items and known risks
- [Network Core — CRS310](./network-core-crs310.md) — switch, port map, VLAN rollout
- [Hardware Inventory](./hardware-inventory.md) — measured node specs
- [Rebuild Runbook](./rebuild-runbook.md) — the PVE 9 + cluster build
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
| Netgear switches | **MikroTik CRS310-8G+2S+IN** core switch |
| Meraki AP | Omada EAP650 |
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
| ER605 router | `10.0.0.1` | Gateway; keeps inter-VLAN routing and firewalling |
| OC200 | `10.0.0.2` | Reserved — faulty, RMA outstanding |
| CRS310 switch | `10.0.0.3` | Management on the **bridge** interface |
| EAP650 | `10.0.0.4` | Access point |
| Rhea | `10.0.0.10` | Proxmox 9.2.2, ZFS-on-root |
| Themis | `10.0.0.11` | Proxmox 9.2.2, ZFS-on-root |
| Hestia | `10.0.0.12` | Proxmox 9.2.2, ZFS-on-root |
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

> **Action item (not a repo change).** The only live `.local` in the homelab is
> the TrueNAS box's domain setting. Fix it on the TrueNAS console — the repo
> itself has zero `.local` occurrences.

### VLANs — third octet under a `10.0.0.0/16` supernet

**Main stays `10.0.0.0/24`.** Future VLANs use the **third octet** under one
`10.0.0.0/16` supernet.

| VLAN ID | Name | Subnet | Gateway | Status |
|---------|------|--------|---------|--------|
| 10 | Main | `10.0.0.0/24` | `10.0.0.1` | **Live** |
| 20 | IoT | `10.0.20.0/24` | `10.0.20.1` | Planned |
| 30 | Guest | `10.0.30.0/24` | `10.0.30.1` | Planned |

VLAN IDs mirror the third octet. **Main is the exception — VLAN 10**, because
VLAN 0 is reserved. **Avoid VLAN 1 entirely.**

Why the third octet and not the second: the old scheme (`10.1`–`10.4`) encoded
VLANs in the second octet, which would have forced **every live machine to
re-IP** the moment VLANs arrived. Under one supernet, Main never re-IPs, a
single Tailscale route covers every VLAN, and firewall rules stay simple.

**Running flat today.** One bridge, `vlan-filtering` off. VLANs are **not**
blocked on the faulty OC200 — the MikroTik does VLAN tagging itself. They are
deferred by the deliberate choice to prove the flat 2.5G network first. Rollout
ordering and its two traps:
[network-core-crs310.md](./network-core-crs310.md#vlan-rollout--procedure).

All VLANs use Pi-hole (`10.0.0.50`) as DNS via DHCP — not ISP DNS.

---

## Physical Topology

```text
[ISP Modem] → [ER605 Gateway] → [CRS310 Core Switch] ─┬─ tartarus  (ether5)
                                                       ├─ rhea     (ether2)
                                                       ├─ themis   (ether3)
                                                       ├─ hestia   (ether4)
                                                       ├─ seedbox  (ether7)
                                                       └─ [EAP650] (ether6, trunk)
```

- **Trunk ports**: ether1 (ER605) and ether6 (EAP650) — tagged 20, 30; untagged PVID 10
- **Access ports**: ether2–5, 7–8 — PVID 10
- **SFP+ 1–2**: free, reserved for a future 10G link to Tartarus
- **Gaming/consoles** → Main (VLAN 10); **TVs/speakers/bridges** → IoT (VLAN 20)

Full port map and the router-on-a-stick rationale:
[network-core-crs310.md](./network-core-crs310.md).

**2.5G only materialises where both ends support it.** Tartarus does; the M720q
is gigabit; the N5095 boxes vary. Check negotiated rates rather than assuming.

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

Placement: the `dns` LXC on **Rhea** — see
[Infrastructure Placement](#infrastructure-placement) below.

**All clients are forced through Pi-hole using CRS310 NAT rules**, and **no
public resolver is listed as secondary DNS in DHCP** — clients leak to it
unpredictably. See [DECISIONS.md](./DECISIONS.md) D20.

The Proxmox hosts themselves deliberately resolve via the router (`10.0.0.1`),
**not** Pi-hole, so DNS recovery is not circular when the Pi-hole LXC is down.

---

## Reverse Proxy and External Access

**Caddy**, running in its own Proxmox LXC. Chosen over Traefik deliberately, for
the static, version-controllable Caddyfile.

- **One central Caddy instance fronts every service on every node.** The
  Caddyfile is a static `hostname → 10.0.0.x:port` map and **lives in this repo**.
- **Caddy needs a custom build carrying the Cloudflare DNS plugin** (`xcaddy` or
  a bundling image) for DNS-01 challenges, so internal-only services get real
  Let's Encrypt certificates with no inbound exposure. The stock image does not
  include it. Domains are on Cloudflare.
- **Public services** (Jellyfin, and anything else remote users touch) go out via
  **Cloudflare Tunnel** — no port forwards, no open inbound ports on the home IP.
- **Jellyfin must sit behind an auth layer** (Cloudflare Access or Authentik).
  Unlike Plex, Jellyfin has no brokered remote-access model, and some of its API
  endpoints do not require authentication — app-level login alone is not enough.
  Auth must terminate at the proxy, **before** Jellyfin sees the request.
- **Plex keeps its own native remote access.** Do not proxy it — two friends
  stream remotely plus owner travel, and Plex's relay handles that better than
  Caddy would. A manual 32400 forward is a fallback only.
- **Immich gets HTTPS before any family or friends are onboarded** — retrofitting
  means touching every phone twice. The real Immich stays internal-only;
  immich-drop and immich public proxy carry the outside traffic.

---

## Infrastructure Placement

Caddy and Pi-hole are **infrastructure, not applications**. Both:

- run as **LXCs on the Proxmox cluster**, outside Docker Compose
- go **on Rhea**, the light always-on infrastructure node
- must **not** go on the fourth non-clustered machine

The reverse proxy and DNS are the two components whose failure takes down access
to everything else. They belong on managed, snapshotted, always-on hardware. The
fourth machine sits outside the cluster, gets no snapshots or backups, and is
expected to be repurposed and rebooted freely — the wrong home for a front door.

**Rhea's full infrastructure load:** `dns` (Pi-hole + Unbound), `proxy` (Caddy),
`tailscale`, and `omada` — four native-daemon LXCs, no Docker, ~3.3 GB of RAM
between them.

Monitoring moved **off** Rhea to Hestia's `monitor` LXC, whose `resolv.conf`
points at `10.0.0.1` rather than Pi-hole so it can still alert when Rhea is
down.

Rhea is light-infra because of **RAM and disk, not CPU** — it and Hestia are the
same Beelink Mini S board, which makes them interchangeable if either fails.

> **Do NOT put the heavy ~29-service control plane on Rhea.** Those stacks go to
> Themis.

> Earlier revisions of this plan routed infrastructure *away* from Rhea. Both
> premises for that have expired — Rhea is no longer the busiest node, and its
> 54 GiB pool constraint is gone. See [DECISIONS.md](./DECISIONS.md) D13.

### The fourth machine (seedbox)

Same specs as the weakest node. Stays **outside** the `gaia` cluster. Reserved
for experiments, tinkering, and disposable workloads. **Explicitly
non-production** — nothing critical goes here, and work should not drift onto it.

qBittorrent currently runs here as a workaround and stays until the 2.5" SATA
SSDs are purchased.

---

## Compute Placement

| Node | Role | LXCs / VM |
|------|------|-----------|
| **tartarus** | Storage | NFS `sisyphus` + `tantalus`, SMB `ixion`, Proxmox backups, Restic repo |
| **rhea** | Light infrastructure, deliberately underloaded | `dns`, `proxy`, `tailscale`, `omada` |
| **hestia** | Media, monitoring, apps, photos (1 TB) | `media`, `monitor`, `apps`, `immich` |
| **themis** | Heavy compute (6c/12t, NVMe + HDD scratch) | `arr`, `grab`, `sandbox`, `homeassistant` (VM) |
| **seedbox** | Non-production | Experiments only |

Full map with per-service build notes:
[service-architecture.md](./service-architecture.md).

**Rhea hosts only native-daemon LXCs** — no Docker. The heavy stacks are on
Themis; media and user-facing services on Hestia.

Storage identity: **`sisyphus` UID/GID 3004** on NFS; see
[truenas-proxmox-storage.md](./truenas-proxmox-storage.md).

**Runtime config does not live on NFS.** Configs sit on node-local ZFS at
`/opt/appdata/<stack>/<service>`; NFS carries `downloads/`, `media/`, and
`shared/` only. See [DECISIONS.md](./DECISIONS.md) D11.

---

## Firewall Intent (ER605)

Keep rules simple — pfSense-level micro-rules not required.

Rules live on the **ER605**, not the switch — the CRS310 tags and forwards, the
router filters. See [DECISIONS.md](./DECISIONS.md) D15 for why routing is
deliberately *not* offloaded to the switch.

1. **Guest** (`10.0.30.0/24`) → RFC1918: deny; → WAN: allow
2. **IoT** (`10.0.20.0/24`) → Main: deny (default); allow DNS to `10.0.0.50`; allow WAN
3. **Main** (`10.0.0.0/24`) → IoT: allow (admin); → anywhere: allow

NFS (`10.0.0.20`) is **not** exposed to IoT/Guest.

---

## Remote Access

- **Primary**: Tailscale, with **subnet routing** advertising `10.0.0.0/24` —
  later the whole `10.0.0.0/16`, which is the point of the supernet — from a
  stable always-on node or LXC (**not** the fourth machine). Approve the route in
  the Tailscale admin console. Full LAN reachability off-site, no open ports.
- **Public services**: Cloudflare Tunnel via Caddy — see
  [Reverse Proxy and External Access](#reverse-proxy-and-external-access).
- **Optional**: Omada WireGuard for full-tunnel road warriors.

Tailscale is the standard. **Headscale is not used.**

---

## Backup Layers

| Layer | What |
|-------|------|
| Git | Compose stacks, docs, Caddyfile, DNS record templates |
| **Restic** | Node-local `/opt/appdata/**`, ZFS-snapshot-quiesced → shared repo on Tartarus |
| Omada / MikroTik | Site export; RouterOS config export |
| TrueNAS | Config + ZFS snapshots |
| Proxmox | `vzdump` → `tartarus/proxmox` |
| **Off-box** | `restic copy` to an external drive — **not yet done** |

App-state backup rules in full: [DECISIONS.md](./DECISIONS.md) D12.

**Restore drill**: time a full LXC + one stack + config restore before relying on
backups. A backup that has never been restored is still an assumption.

Nothing lives off Tartarus yet — see
[OPEN-QUESTIONS.md](./OPEN-QUESTIONS.md#nothing-lives-off-tartarus-yet).

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

Moved to a dedicated file so it pairs with the decision log and can shrink as
items are settled: **[OPEN-QUESTIONS.md](./OPEN-QUESTIONS.md)**.

Nothing there is implemented. Highlights as of 2026-09-26:

- **Second-tier storage is a purchase**, not a re-use — all three 2.5" bays are
  empty. Gates qBittorrent's return to the cluster.
- **Transcode/media placement is reopened** — Themis also does H.265 and is
  faster, but Hestia has 2× the disk.
- **Nothing lives off Tartarus yet.** Must be solved before Proxmox HA.
- **`aeos` and the `atlas` remainder have no assigned node.**
- **Rhea hosts its own monitoring** — a known cost of the D13 placement.

---

## Open Decisions (network build)

- [x] ~~Exact switch / AP models~~ — CRS310 core, EAP650 AP
- [ ] OC200 replacement or RMA — no longer blocks VLANs, only Omada AP management
- [ ] Turn on VLANs once the flat 2.5G network is proven
- [ ] Dedicated corosync link if NICs are ever added (free SFP+ ports exist)
- [ ] HomeKit/AirPlay: same-VLAN vs mDNS reflector
