# Network Implementation Phases

Step-by-step walkthrough for the Omada + Proxmox + TrueNAS rebuild.
Overview and design rationale: [homelab-network-plan.md](./homelab-network-plan.md).

Each phase ends with **verification** — do not advance until checks pass.

---

## Phase 0 — Inventory

**Goal:** Know exactly what you have before touching config.

### Collect

| Item | Record |
|------|--------|
| Omada gateway model + firmware | e.g. ER605 v2 |
| Switch(es) + port count / 10G | Core + theater? |
| AP model(s) | PoE from switch? |
| Proxmox nodes | Hestia, Rhea, Themis — NIC count, 10G? |
| TrueNAS tartarus | NICs, pool name, usable capacity |
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
    ip: 10.1.0.40
  - name: rhea
    mac: "aa:bb:cc:dd:ee:02"
    vlan: 1
    ip: 10.1.0.30
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

- [ ] Every static IP device has a MAC recorded
- [ ] ISP handoff type documented (photos of modem label help)
- [ ] 10G path drawn: tartarus ↔ switch ↔ which nodes
- [ ] `config/site.env` created from template (values filled or TBD)

---

## Phase 1 — Network Foundation (Omada)

**Goal:** VLANs, DHCP, DNS forwarding, WiFi, baseline firewall — **no apps yet**.

### 1.1 Omada Cloud site

1. Create site in Omada Cloud (or adopt into existing account)
2. Factory-reset gateway/switch/AP if migrating from standalone mode
3. Adopt devices in order: **gateway → core switch → AP → theater switch**

### 1.2 VLANs on gateway

Create LAN networks (Omada terminology varies by firmware):

| Network name | VLAN ID | Gateway IP | DHCP pool |
|--------------|---------|------------|-----------|
| Main | 1 | 10.1.0.1/24 | 10.1.0.100–200 |
| IoT | 2 | 10.2.0.1/24 | 10.2.0.100–200 |
| Guest | 3 | 10.3.0.1/24 | 10.3.0.100–200 |
| VPN | 4 | 10.4.0.1/24 | 10.4.0.100–200 |

**DHCP DNS (all VLANs):** primary `10.1.0.50`, secondary `10.1.0.51` (once Phase 3
secondary exists; use `10.1.0.50` only until then).

Domain: `lan`

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

Add every entry from Phase 0 inventory on **Main** VLAN.
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
4. IoT → 10.1.0.50:53: **allow**
5. IoT → WAN: **allow**
6. Main → IoT: **allow**
7. VPN → Main: **allow**

### 1.7 WAN

Configure from `config/site.env`. Test:

- Gateway gets internet
- Client on Main gets DHCP and can browse (DNS may fail until Phase 3 — expected)

### Verify Phase 1

- [ ] Ping `10.1.0.1` from a Main client
- [ ] IoT client gets `10.2.x`, cannot ping `10.1.0.30` (Rhea)
- [ ] Guest client has internet, cannot ping Main
- [ ] WiFi SSIDs map to correct VLAN (check IP subnet)
- [ ] Export Omada site backup → save off-box

---

## Phase 2 — Storage + Hypervisor

**Goal:** TrueNAS exports NFS; Proxmox nodes mount and run LXCs with correct UID map.

Reference: [truenas-proxmox-storage.md](./truenas-proxmox-storage.md)

### 2.1 TrueNAS datasets

```text
/mnt/tartarus/sisyphus/{downloads,media,appdata,shared}
/mnt/tartarus/ixion/{documents,photos,personal,archive}
/mnt/tartarus/proxmox/{dump,iso,snippets,templates}
```

Ownership: `sisyphus:sisyphus` (3004:3004) on sisyphus tree.

### 2.2 NFS export

- Path: `/mnt/tartarus/sisyphus`
- Authorized network: `10.1.0.0/24` only
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

- Debian/Ubuntu LXC, nesting on for Docker
- Bind mount: `/mnt/lxc_shares/sisyphus` → `/mnt/storage`
- UID map: passthrough **3004** (critical for NFS writes)
- Static IP on Main VLAN (reservations from Phase 0)

Run bootstrap:

```bash
sudo ./scripts/bootstrap-proxmox-node.sh <stack-name>
```

### 2.6 Proxmox backup storage

Add TrueNAS NFS `proxmox` dataset as Proxmox storage on each node.

### Verify Phase 2

- [ ] From LXC: `touch /mnt/storage/appdata/write-test` as UID 3004
- [ ] From TrueNAS shell: file owned by `sisyphus`
- [ ] Reboot one Proxmox node — mounts return clean
- [ ] `vzdump` test job to tartarus succeeds

---

## Phase 3 — Control Plane (Rhea)

**Goal:** DNS works house-wide; Tailscale mesh; core automation stacks online.

### 3.1 Pi-hole + Unbound

Deploy on Rhea (LXC or Compose — add stack when ready):

- Listen on `10.1.0.50` (may need macvlan or host IP alias until VIP pattern settled)
- Upstream: Unbound on localhost → recursive
- Local DNS records: all `*.lan` hosts from [homelab-network-plan.md](./homelab-network-plan.md)

Blocklists: default + optional custom

### 3.2 Confirm DNS house-wide

Omada DHCP already points to `10.1.0.50`. From phone on WiFi:

```bash
nslookup tartarus.lan
nslookup rhea.lan
```

### 3.3 Tailscale

On each Proxmox host:

```bash
tailscale up --advertise-routes=10.1.0.0/24 --accept-routes
```

Enable subnet routes in Tailscale admin. Test from phone (cellular, TS on):
ping `10.1.0.40`.

### 3.4 Deploy stacks on Rhea

Order:

1. `atlas` — Uptime Kuma, Dozzle, Watchtower (monitoring first)
2. `hera` — ntfy
3. `io` — Gluetun + qBittorrent (**network_mode: service:gluetun**), Sabnzbd, …
4. `asteria` — full Arr suite
5. `aeos` — Homepage, Jellyseerr, …

Clone repo to `/opt/stacks/home-server`, copy `.env` from templates.

### 3.5 Homepage + Uptime Kuma

Point at `http://*.lan:PORT` using [PLAN.md](../PLAN.md) port map.

### Verify Phase 3

- [ ] All clients resolve `*.lan` via Pi-hole
- [ ] qBittorrent traffic exits via Gluetun (IP check in container)
- [ ] Radarr sees download path on shared NFS
- [ ] Uptime Kuma green on gateway, tartarus, Pi-hole
- [ ] Tailscale subnet routing works off-LAN

---

## Phase 4 — Media + Apps (Hestia + Themis)

**Goal:** Playback, HA, photos, productivity — user-facing services.

### 4.1 Hestia

- LXC + bootstrap: `apollo`
- Pass QuickSync device for Jellyfin/Plex transcode
- Static `10.1.0.31`, DNS `hestia.lan`, `plex.lan` → hestia
- Connect Jellyseerr (on Rhea) to Plex/Jellyfin URLs

Optional same node: Channels-DVR, Audiobookshelf, Kavita, ROMm

### 4.2 Themis

- **Home Assistant OS** — dedicated VM (USB/Zigbee/Z-Wave passthrough if used)
- **Immich**, **Paperless-ngx** — VM or LXC per appetite
- LXC + bootstrap: `helios`
- Secondary Pi-hole at `10.1.0.51` (Unbound forward to primary or sync blocklists)

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
| Proxmox vzdump (all CT/VM) | daily | tartarus/proxmox |
| restic `.env` + secrets | daily | tartarus ixion encrypted |
| Pi-hole Teleporter | weekly | tartarus |
| Omada site export | monthly + post-change | tartarus |
| TrueNAS config save | weekly | tartarus |

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

### 5.4 Optional public access

If needed: Cloudflare Tunnels on Hestia/Rhea for Jellyseerr, ntfy — not required
for Tailscale-only households.

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
