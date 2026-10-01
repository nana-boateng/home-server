# Network Implementation Phases

Step-by-step walkthrough for the Omada + Proxmox + TrueNAS rebuild.
Overview and design rationale: [homelab-network-plan.md](./homelab-network-plan.md).
Locked decisions and their reasoning: [DECISIONS.md](./DECISIONS.md).

Each phase ends with **verification** — do not advance until checks pass.

> **Status (2026-09-26).** Phases 0–2 are substantially done and Phase 3 has
> started. `10.0.0.0/24` is live on the ER605 behind a **MikroTik CRS310** core
> switch; all three nodes are clean-installed on **PVE 9.2.2 with ZFS-on-root**
> and joined into cluster **`gaia`**. See
> [rebuild-runbook.md](./rebuild-runbook.md) for what actually happened.
>
> VLANs are **running flat by choice**, not blocked — the MikroTik does VLAN
> tagging itself, so the faulty OC200 is no longer in the way. See
> [network-core-crs310.md](./network-core-crs310.md).
>
> Still outstanding: NFS mounts to Tartarus, the infrastructure LXCs on Rhea,
> and the stack rebuild.

---

## Phase 0 — Inventory

**Goal:** Know exactly what you have before touching config.

### Collect

| Item | Record |
|------|--------|
| Omada gateway model + firmware | **ER605** — record firmware |
| Omada controller | **OC200** at `10.0.0.2` — faulty, RMA/replace |
| Core switch | **MikroTik CRS310-8G+2S+IN** at `10.0.0.3`, RouterOS 7.24.4 |
| AP | **EAP650** at `10.0.0.4` |
| Proxmox nodes | Measured — see [hardware-inventory.md](./hardware-inventory.md) |
| TrueNAS tartarus | F4-423 at `10.0.0.20` |
| ISP connection | DHCP / static / PPPoE / VLAN tag on WAN |
| Modem mode | Bridge vs router |

### MAC address table

Create a spreadsheet or `config/inventory.yaml` (gitignored if you prefer):

```yaml
# Example — replace with real MACs
devices:
  - name: tartarus
    mac: "aa:bb:cc:dd:ee:01"
    vlan: 1
    ip: 10.0.0.20
  - name: rhea
    mac: "aa:bb:cc:dd:ee:02"
    vlan: 1
    ip: 10.0.0.10
  # … every static host
```

Include: gateway WAN MAC (for ISP), all Proxmox NICs, NAS, Pi-hole VM/LXC,
Apple TVs, Hue bridge, printers.

### Site-specific WAN template

Copy when ready:

```bash
# config/site.env.template → config/site.env (gitignored)
WAN_TYPE=dhcp              # dhcp | static | pppoe
WAN_STATIC_IP=
WAN_GATEWAY=
WAN_DNS=
ISP_VLAN_ID=               # e.g. 201 for some fiber ISPs
PPPOE_USER=
PPPOE_PASS=
```

### Verify Phase 0

- [x] ~~Node specs recorded~~ — [hardware-inventory.md](./hardware-inventory.md)
- [ ] Every static IP device has a MAC recorded
- [ ] ISP handoff type documented (photos of modem label help)
- [ ] 10G path drawn: tartarus ↔ switch SFP+ (ports free, not yet wired)
- [ ] `config/site.env` created from template (values filled or TBD)

---

## Phase 1 — Network Foundation (Omada)

**Goal:** VLANs, DHCP, DNS forwarding, WiFi, baseline firewall — **no apps yet**.

### 1.1 Omada Cloud site

1. Create site in Omada Cloud (or adopt into existing account)
2. Factory-reset gateway/switch/AP if migrating from standalone mode
3. Adopt devices in order: **gateway → core switch → AP → theater switch**

### 1.2 VLANs

Main is live and flat. IoT and Guest are **deferred by choice**, not blocked —
the CRS310 does VLAN tagging, so the faulty OC200 is not in the way.

**Tagging happens on the CRS310; routing and firewalling stay on the ER605**
(router-on-a-stick — see [DECISIONS.md](./DECISIONS.md) D15). VLAN IDs mirror
the third octet under a `10.0.0.0/16` supernet, so Main never re-IPs.

| Network name | VLAN ID | Gateway IP | DHCP pool | Status |
|--------------|---------|------------|-----------|--------|
| Main | **10** | 10.0.0.1/24 | 10.0.0.100–254 | **live** |
| IoT | **20** | 10.0.20.1/24 | 10.0.20.100–200 | planned |
| Guest | **30** | 10.0.30.1/24 | 10.0.30.100–200 | planned |

**DHCP DNS (all VLANs): the VIP `10.0.0.33` only.** Secondary DNS stays
**empty** — a secondary is a bypass, not failover. Redundancy comes from
keepalived moving the VIP between the two Pi-holes, not from the client
choosing. See [DECISIONS.md](./DECISIONS.md) D20 and D27.

Domain: `lan`. Never `local` — see [DECISIONS.md](./DECISIONS.md) D2.

### 1.3 Switch port profiles

| Profile | Mode | Native | Tagged | Use |
|---------|------|--------|--------|-----|
| TRUNK-ALL | Trunk | 1 | 2,3,4 | Uplinks, AP |
| ACCESS-MAIN | Access | 1 | — | Servers, PCs |
| ACCESS-IOT | Access | 2 | — | Hue, printers |

Assign ports:

- Gateway ↔ core: **TRUNK-ALL**
- Core ↔ AP: **TRUNK-ALL**
- Core ↔ theater switch: **TRUNK-ALL**
- tartarus, Proxmox, desktop: **ACCESS-MAIN**
- dumb IoT gear: **ACCESS-IOT**

### 1.4 DHCP reservations

Add every entry from Phase 0 inventory on **Main** VLAN. Statics live in
`.1–.99` per the [addressing scheme](./homelab-network-plan.md#addressing-scheme):
`.2–.9` network gear, `.10–.29` physical hosts, `.30–.99` services.

Service addresses are assigned **by service, not by node** — an IP must never
imply which node a service runs on.

IoT: reserve bridges (Hue, etc.) as you connect them.

### 1.5 WiFi SSIDs

| SSID | VLAN | Notes |
|------|------|-------|
| Home | Main | WPA2/WPA3, family devices |
| Home-IoT | IoT | 2.4 GHz preferred for IoT |
| Guest | Guest | Client isolation ON |

### 1.6 Firewall / ACL

Apply rules in order (see [homelab-network-plan.md](./homelab-network-plan.md)):

1. Guest → private RFC1918: **deny**
2. Guest → WAN: **allow**
3. IoT → Main: **deny** (default)
4. IoT → 10.0.0.33:53: **allow**   *(IoT is `10.0.20.0/24`)*
5. IoT → WAN: **allow**
6. Main → IoT: **allow**
7. VPN → Main: **allow**

### 1.7 WAN

Configure from `config/site.env`. Test:

- Gateway gets internet
- Client on Main gets DHCP and can browse (DNS may fail until Phase 3 — expected)

### Verify Phase 1

- [ ] Ping `10.0.0.1` from a Main client
- [ ] IoT client gets `10.0.20.x`, cannot ping `10.0.0.10` (Rhea)
- [ ] Guest client has internet, cannot ping Main
- [ ] WiFi SSIDs map to correct VLAN (check IP subnet)
- [ ] Export Omada site backup → save off-box

---

## Phase 2 — Storage + Hypervisor

**Goal:** TrueNAS exports NFS; Proxmox nodes mount and run LXCs with correct UID map.

Reference: [truenas-proxmox-storage.md](./truenas-proxmox-storage.md)

### 2.1 TrueNAS datasets

```text
/mnt/tartarus/sisyphus/{downloads,media,shared}
/mnt/tartarus/ixion/{documents,photos,personal,archive}
/mnt/tartarus/proxmox/{dump,iso,snippets,templates}
```

Ownership: `sisyphus:sisyphus` (3004:3004) on sisyphus tree.

### 2.2 NFS export

- Path: `/mnt/tartarus/sisyphus`
- Authorized network: `10.0.0.0/24` only
- Maproot / mapall: `sisyphus`
- NFSv3 (per existing doc) unless you standardize on v4

### 2.3 SMB (human access)

- `ixion` for MacBooks
- Optional read-only `sisyphus-media` share

### 2.4 Proxmox host mounts

On **rhea, hestia, themis**:

```text
<tartarus-ip>:/mnt/tartarus/sisyphus  /mnt/lxc_shares/sisyphus  nfs  ...
```

`/etc/fstab` + `mount -a` test after reboot.

### 2.5 LXC template

Per stack host:

- Debian/Ubuntu LXC, nesting on for Docker — **not** a pre-2016-systemd template
  (CentOS 7 / Ubuntu 16.04 era); PVE 9 will not run those
- Bind mount: `/mnt/lxc_shares/sisyphus` → `/mnt/storage` (bulk data only)
- Local config path `/opt/appdata/<stack>/<service>` on the node's ZFS root
- UID map: passthrough **3004** (critical for NFS writes)
- Static IP in `.30–.99`, assigned by service rather than by node

Run bootstrap:

```bash
sudo ./scripts/bootstrap-proxmox-node.sh <stack-name>
```

### 2.6 Proxmox backup storage

Add TrueNAS NFS `proxmox` dataset as Proxmox storage on each node.

### Verify Phase 2

- [ ] From LXC: `touch /mnt/storage/shared/write-test` as UID 3004
- [ ] From TrueNAS shell: file owned by `sisyphus`
- [ ] Reboot one Proxmox node — mounts return clean
- [ ] `vzdump` test job to tartarus succeeds

---

## Phase 3 — Control Plane

**Goal:** DNS and ingress work house-wide; Tailscale mesh; core automation stacks
online.

Infrastructure (Pi-hole, Caddy, Uptime Kuma, ntfy, Omada controller, Tailscale
subnet router) goes in **Proxmox LXCs on Rhea** — the light always-on
infrastructure node — and never on the seedbox. See
[DECISIONS.md](./DECISIONS.md) D3, D4, D13.

**The heavy stacks do not go on Rhea.** `io` and `asteria` go to Themis;
`apollo` to Hestia.

### 3.1 Pi-hole + Unbound (LXC on Rhea)

Deploy as a **Proxmox LXC**, with Unbound inside the same container. **Not** a
Docker container and **not** part of a Compose stack — restarting a stack must
never take down DNS.

- Static `10.0.0.31` (primary; the replica is `10.0.0.32`, the VIP `10.0.0.33`)
- Upstream: Unbound on localhost → recursive
- **Split-horizon**: internal hostnames resolve to LAN IPs
- Local DNS records: all `*.lan` hosts from [homelab-network-plan.md](./homelab-network-plan.md)

Blocklists: default + optional custom

### 3.2 Caddy (LXC on Rhea)

Deploy as a **Proxmox LXC** alongside Pi-hole.

- One central instance fronts **every** service on **every** node
- Static Caddyfile: `hostname → 10.0.0.x:port` — **committed to this repo**
- Build with the **Cloudflare DNS plugin** for DNS-01 challenges, so
  internal-only services get real Let's Encrypt certs with no inbound exposure
- Public services go out over **Cloudflare Tunnel** — no port forwards
- **Jellyfin** must sit behind Cloudflare Access or Authentik, terminating at the
  proxy before Jellyfin sees the request
- **Plex is not proxied** — it keeps its own native remote access

### 3.3 Confirm DNS house-wide

DHCP points at the VIP `10.0.0.33`. From a phone on WiFi:

```bash
nslookup tartarus.lan
nslookup rhea.lan
```

### 3.4 Tailscale

Advertise the subnet route from a stable, always-on node or LXC — **not** the
fourth machine:

```bash
tailscale up --advertise-routes=10.0.0.0/24 --accept-routes
```

Enable subnet routes in Tailscale admin. Test from phone (cellular, TS on):
ping `10.0.0.20`.

### 3.5 Deploy the stacks

Placement per [service-architecture.md](./service-architecture.md) — **11 LXCs
and a VM, not all on one node.**

Order:

1. **Hestia — `monitor`** first (Uptime Kuma, Beszel, ntfy), so the rest of the
   build is observable. Point its `resolv.conf` at `10.0.0.1`, **not** Pi-hole.
2. **Themis — `arr`**, after Prowlarr's indexers are configured. Then `grab`,
   then `sandbox`, then the Home Assistant VM.
3. **Hestia — `media`**, but only after `/dev/dri` passthrough is verified with
   `vainfo`. Then `apps`, then `immich`.

> **Mount before you wire.** The `sisyphus` bind-mount path string must be
> identical in `arr` and `grab`, or hardlinks fail silently and imports double
> disk usage. [DECISIONS.md](./DECISIONS.md) D21.

> **Skip the VPN and Watchtower sections of any guide you follow.** Both were
> removed deliberately — D17.

Clone repo to `/opt/stacks/home-server`, copy `.env` from templates. Config
volumes resolve to `/opt/appdata/<stack>/<service>` on node-local ZFS — **never**
under `/mnt/storage` (D11).

### 3.6 Homepage + Uptime Kuma

Point at `http://*.lan:PORT` using [PLAN.md](../PLAN.md) port map.

### Verify Phase 3

- [ ] All clients resolve `*.lan` via Pi-hole
- [ ] Hardlinks work: the `sisyphus` mount path string is identical in `arr` and `grab`
- [ ] Radarr sees download path on shared NFS
- [ ] Uptime Kuma green on gateway, tartarus, Pi-hole
- [ ] Tailscale subnet routing works off-LAN
- [ ] Caddy serves a valid Let's Encrypt cert for an internal-only hostname
- [ ] Restarting a Compose stack does not interrupt DNS resolution
- [ ] No `/config` volume resolves under `/mnt/storage` on any node
- [ ] Restic backs up, notifies ntfy, and a **real restore** has been tested

---

## Phase 4 — Media + Apps (Hestia + Themis)

**Goal:** Playback, HA, photos, productivity — user-facing services.

### 4.1 Hestia

- LXC + bootstrap: `apollo`
- Pass QuickSync device for Jellyfin/Plex transcode
- Static `10.0.0.12`, DNS `hestia.lan`, `plex.lan` → hestia
- Connect Jellyseerr (on Rhea) to Plex/Jellyfin URLs

Optional same node: Channels-DVR, Kavita, ROMm. **Not** Audiobookshelf — it
belongs in `arr` on Themis, beside abs-arr which imports into it.

### 4.2 Themis

- **Home Assistant OS** — dedicated VM (USB/Zigbee/Z-Wave passthrough if used)
- **Immich**, **Paperless-ngx** — VM or LXC per appetite
- LXC + bootstrap: `helios`
- **The Pi-hole replica lives here** — `dns2`, CT 201, `10.0.0.32`, with **its
  own unbound** (it must not forward to the primary's). Behind a keepalived VRRP
  VIP at `10.0.0.33`, which is what DHCP advertises. **Built** — see
  [build-record.md](./build-record.md) and [D27](./DECISIONS.md).
- **`monitor`** — CT 202, `10.0.0.34`, deliberately resolving via `10.0.0.1`
  rather than the VIP, so it can alert when Rhea is down.

HA networking: if IoT devices need mDNS, plan VLAN/firewall exception or put
controller on IoT with Main access — document choice in `config/site.env`.

### 4.3 Cross-stack wiring

| From | To | URL |
|------|-----|-----|
| Jellyseerr | Radarr/Sonarr | `http://rhea.lan:7002` etc. |
| Jellyseerr | Plex | `http://hestia.lan:32400` |
| Tautulli | Plex | localhost on hestia |
| Arr apps | qBit/SAB | `http://rhea.lan:5002` / `:5003` |

### Verify Phase 4

- [ ] Plex/Jellyfin stream from library on NFS
- [ ] Transcode uses QuickSync (`intel_gpu_top` or Jellyfin dashboard)
- [ ] HA controls at least one real device
- [ ] Immich upload + browse works
- [ ] Secondary Pi-hole serves DNS if primary stopped (failover test)

---

## Phase 5 — Hardening + Portability

**Goal:** Backups proven; move/ISP change is a checklist, not a crisis.

### 5.1 Backup jobs

| Job | Schedule | Destination |
|-----|----------|-------------|
| **Restic appdata** (ZFS-snapshot quiesced) | daily | shared repo on tartarus |
| **`restic copy` off-box** | weekly | external drive — **not yet done** |
| Proxmox vzdump (all CT/VM) | daily | tartarus/proxmox |
| Pi-hole Teleporter | weekly | tartarus |
| Omada / RouterOS config export | monthly + post-change | tartarus |
| TrueNAS config save | weekly | tartarus |

Retention via `restic forget` — e.g. 7 daily / 4 weekly / 6 monthly. **Keep the
repo password off-cluster.** Notify success *and* failure to ntfy; silent backups
fail silently. Full rules: [DECISIONS.md](./DECISIONS.md) D12.

Wire Watchtower → ntfy for update notifications.

### 5.2 Restore drill (required once)

1. Delete a **test** LXC snapshot restore from vzdump
2. Restore one stack's appdata dir from snapshot
3. Import Omada backup to a **test site** name (or document re-import steps)

Record times and gaps in this file under `## Restore drill log`.

### 5.3 Move / ISP change checklist

Create `config/MOVE-CHECKLIST.md` when ready; minimum steps:

1. Export Omada backup
2. Snapshot TrueNAS + final vzdump
3. Pack: document `site.env`, `.env` backup, inventory MAC table
4. New location: modem → Omada WAN per `site.env`
5. Power tartarus + Proxmox; verify NFS mounts
6. Pi-hole + Tailscale come up; test `*.lan` resolution
7. Run Speedtest Tracker baseline; update Uptime Kuma

### 5.4 Public access

Public-facing services go out via **Cloudflare Tunnel** behind the central Caddy
LXC — no port forwards, no open inbound ports on the home IP. Anything
remote-user-facing (Jellyfin above all) sits behind an auth layer that terminates
at the proxy. Plex keeps its own native remote access and is not proxied. See
[DECISIONS.md](./DECISIONS.md) D5.

A Tailscale-only household needs none of this.

### Verify Phase 5

- [ ] Restore drill completed; duration documented
- [ ] All backup jobs reported success for 7 days
- [ ] `MOVE-CHECKLIST` walkthrough reviewed (mental or literal dry run)
- [ ] Omada + Pi-hole + TrueNAS exports stored in two places

---

## Restore Drill Log

| Date | What was tested | Duration | Gaps found |
|------|-----------------|----------|------------|
| | | | |

---

## Phase Dependency Graph

```text
Phase 0 (inventory)
    ↓
Phase 1 (Omada VLANs/WiFi/firewall)
    ↓
Phase 2 (TrueNAS + Proxmox + NFS) ── can parallel partial with 1 if Main VLAN up
    ↓
Phase 3 (Pi-hole + Tailscale + Rhea stacks)
    ↓
Phase 4 (Hestia + Themis apps)
    ↓
Phase 5 (backups + drill + move checklist)
```
