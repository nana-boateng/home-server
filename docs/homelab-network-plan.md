# Homelab Network Plan (Omada + Proxmox + TrueNAS)

This document captures the **general gist** of the homelab rebuild: replicate the
reference pfSense/VLAN/Synology layout using **TP-Link Omada** (router, smart
switch, cloud controller), the existing **3-node Proxmox** cluster, and **TrueNAS
tartarus** — with portability (move homes, change ISP) as a first-class goal.

Related docs:

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
| pfSense firewall | Omada gateway |
| Netgear switches | Omada smart switch(es) |
| Meraki AP | Omada EAP |
| Synology + Docker | TrueNAS tartarus + Proxmox LXCs + Compose stacks |
| WireGuard on firewall | Tailscale mesh (+ optional Omada WireGuard) |
| pfSense Pi-hole | Pi-hole + Unbound on **Rhea** |

**Portability rules**

1. **Git** = service source of truth (`stacks/`, scripts, this doc)
2. **MAC-based DHCP** reservations — not “this jack = this IP”
3. **`site.env`** (gitignored) holds WAN/ISP-only settings
4. **DNS hostnames** (`*.lan`) — apps never hardcode IPs
5. **Tailscale** overlay survives ISP/moves without port forwards
6. **Export backups**: Omada site, TrueNAS config, Proxmox dumps, Pi-hole, `.env` files

---

## VLAN & IP Scheme

Mirror the reference subnets for consistency.

| VLAN | Name | Subnet | Gateway |
|------|------|--------|---------|
| 1 | Main | `10.1.0.0/24` | `10.1.0.1` |
| 2 | IoT | `10.2.0.0/24` | `10.2.0.1` |
| 3 | Guest | `10.3.0.0/24` | `10.3.0.1` |
| 4 | VPN | `10.4.0.0/24` | `10.4.0.1` |

**Main VLAN static reservations (by MAC)**

| IP | Host |
|----|------|
| `10.1.0.10` | Core switch |
| `10.1.0.11` | Theater switch (if used) |
| `10.1.0.20` | Primary AP |
| `10.1.0.30` | rhea.lan |
| `10.1.0.31` | hestia.lan |
| `10.1.0.32` | themis.lan |
| `10.1.0.40` | tartarus.lan (TrueNAS) |
| `10.1.0.50` | pihole.lan |
| `10.1.0.51` | pihole2.lan (secondary, Themis) |

All VLANs use Pi-hole (`10.1.0.50`) as DNS via DHCP — not ISP DNS.

---

## Physical Topology

```text
[ISP Modem] → [Omada Gateway] → [Core Switch] ─┬─ tartarus (10G if available)
                                                  ├─ rhea / hestia / themis
                                                  ├─ [Theater Switch] (trunk)
                                                  └─ [Omada AP] (trunk, multi-SSID)
```

- **Trunk ports**: gateway ↔ core, core ↔ AP, core ↔ theater switch
- **Access ports**: end devices on single VLAN
- **Gaming/consoles** → Main (VLAN 1); **TVs/speakers/bridges** → IoT (VLAN 2)

---

## Compute Placement

| Node | Role | Stacks / services |
|------|------|-------------------|
| **tartarus** | Storage | NFS `sisyphus`, SMB `ixion`, Proxmox backups |
| **rhea** | Control plane | Pi-hole, Unbound, Tailscale, `io`, `asteria`, `aeos`, `atlas`, `hera` |
| **hestia** | Media hub | `apollo`, Channels-DVR, Audiobookshelf, … |
| **themis** | Compute / appliances | HA OS VM, Immich, Paperless, `helios`, secondary Pi-hole |

Storage identity: **`sisyphus` UID/GID 3004** on NFS; see
[truenas-proxmox-storage.md](./truenas-proxmox-storage.md).

---

## Firewall Intent (Omada)

Keep rules simple — pfSense-level micro-rules not required.

1. **Guest** → RFC1918: deny; → WAN: allow
2. **IoT** → Main: deny (default); allow DNS to `10.1.0.50`; allow WAN
3. **Main** → IoT: allow (admin); → anywhere: allow
4. **VPN** → Main (+ optional IoT): allow

NFS (`10.1.0.40`) is **not** exposed to IoT/Guest.

---

## Remote Access

- **Primary**: Tailscale on all nodes; Rhea as subnet router for `10.1.0.0/24`
- **Optional**: Omada WireGuard for full-tunnel road warriors
- **Public-facing** (if needed): Cloudflare Tunnels for Jellyseerr, ntfy — see [PLAN.md](../PLAN.md)

---

## Backup Layers

| Layer | What |
|-------|------|
| Git | Compose stacks, docs, DNS record templates |
| Encrypted restic | `.env`, `site.env`, API keys |
| Omada | Monthly site export |
| TrueNAS | Config + ZFS snapshots |
| Proxmox | `vzdump` → `tartarus/proxmox` |
| Appdata | `/mnt/storage/appdata/**` snapshots |

**Restore drill**: time a full LXC + one stack + Omada import before relying on backups.

---

## Implementation Phases (overview)

Detailed steps: [network-implementation-phases.md](./network-implementation-phases.md)

| Phase | Focus |
|-------|--------|
| **0** | Inventory — hardware, MACs, ISP type |
| **1** | Network foundation — VLANs, Omada, WiFi, firewall |
| **2** | Storage + hypervisor — TrueNAS, NFS, Proxmox LXCs |
| **3** | Control plane — Pi-hole, Tailscale, core stacks on Rhea |
| **4** | Media + apps — Hestia/Themis workloads |
| **5** | Hardening + portability — backups, restore drill, move checklist |

---

## Open Decisions

Fill in before Phase 1:

- [ ] Exact Omada gateway / switch / AP models
- [ ] Omada Cloud only vs local Software Controller on Rhea
- [ ] Theater second switch: yes/no
- [ ] Remote access: Tailscale-only vs Cloudflare for public services
- [ ] HomeKit/AirPlay: same-VLAN vs mDNS reflector
