# Open Questions / Known Risks

Raised, reasoned through, and **not ratified**. Nothing here is implemented.

**Do not act on anything in this file** without deciding it first. When an item
is settled, move it to [DECISIONS.md](./DECISIONS.md) with its rationale and
delete it here — this file should shrink as the design firms up.

Last reviewed: **2026-09-26**.

---

## Blocked on hardware

### Second-tier storage is a purchase, not a re-use

All three 2.5" SATA bays are **empty**. Earlier planning assumed an existing SSD
could become a second local pool; that drive does not exist. **3× 2.5" SATA SSD
must be purchased.**

Gates two things:

- Bringing **qBittorrent** back onto the cluster (below).
- VM-disk and scratch tiering generally.

### qBittorrent stays on the seedbox

Sizing is settled; placement is not, because the disk it needs does not exist.

When it returns it goes on **Themis or Hestia, never Rhea**, with:

| Setting | Value |
|---|---|
| LXC `memory` | `4096` |
| LXC `swap` | `0` — OOM inside its own boundary, not host swap |
| qBittorrent disk cache | ~`1024` MiB (explicit, not auto) |
| Global connections | ~`500` |
| Connections per torrent | ~`50` |
| Active downloads | `5` |
| Active seeds | `20` |

This configuration is what prevents the earlier full-host hard-lock, where an
unbounded LXC drove the host out of memory and required a physical reset.

**Blocked:** the incomplete-downloads folder was to live on a second local SSD
pool. **Do not put it on the ZFS root pool** — torrent write patterns plus ZFS
write amplification is precisely the workload that burns consumer NVMe
endurance. **Leave qBittorrent on the seedbox until the SATA SSDs are bought.**

---

## Placement and architecture

### Transcode / media placement is reopened

Both Hestia and Themis do H.265, and **Themis is the faster node** — but Hestia
has **2× the disk**. Earlier docs treated Hestia as the only transcode-capable
node; that is no longer true and must not be hard-coded.

| Option | Trade |
|---|---|
| **(a) Keep Plex/Jellyfin on Hestia** — *current call* | Media locality; transcode on the slower CPU |
| (b) Move transcode to Themis | Faster transcode; media served over the network |
| (c) Split — Plex on Hestia, Jellyfin on Themis | Hedges both; two places to maintain |

Plex and Jellyfin stay on Hestia **by choice (disk locality)**, not by hardware
limit. Decide this deliberately rather than by inertia.

### Stack placement is partly unassigned

The placement rule covers the infrastructure services, `apollo`, `io`,
`asteria`, and `helios`. It does **not** say where `aeos` (Homepage, Jellyseerr,
Wizarr, Speedtest, ChangeDetection, File Browser) goes, nor the remainder of
`atlas` (Dozzle, Watchtower) once Uptime Kuma sits on Rhea. Assign these
explicitly rather than letting them land wherever the first deploy puts them.

### Proxmox HA vs Kubernetes

Leaning **Proxmox HA** — the workload is overwhelmingly single-instance stateful
containers, which is not what Kubernetes is good at.

But HA needs shared storage, which makes **Tartarus a cluster-wide single point
of failure**, so off-box backup has to be solved first.

**New option worth evaluating alongside it:** ZFS is now live on all three nodes,
so **ZFS replication between nodes** is genuinely available and is a
lighter-weight alternative to full HA.

### Home Assistant USB/Zigbee passthrough

Passthrough pins the VM to one node, making it ineligible for Proxmox HA live
migration. Either accept that, or decouple with a **networked Zigbee
coordinator**.

If decoupling: place the coordinator where the Zigbee mesh needs it, not where
the rack happens to be.

---

## Reliability and backup

### Nothing lives off Tartarus yet

Proxmox dumps, the Restic repo, and live data all land on the same box. **RAID
plus one-way rsync is not a backup** — a bad delete or a pool loss takes
everything.

D12 specifies `restic copy` to an external drive. **It has not been done.** Until
it is, the backup story is incomplete and Proxmox HA should not proceed.

### Rhea is a single point of failure for its own monitoring

Uptime Kuma and ntfy sit on Rhea alongside DNS and the reverse proxy. **A monitor
sharing a failure domain with what it monitors is weak** — if Rhea goes down
there is no alerting and no notification path, so the failure is silent.

Consider a lightweight external check that can see Rhea from outside.

Note this is a deliberate trade, not an oversight: D13 puts infrastructure on
Rhea for good reasons. The monitoring overlap is the cost of that choice.

### Secondary DNS is not real failover

Clients query both resolvers rather than cleanly failing over. Two Pi-holes with
divergent blocklists produce **inconsistent blocking, not redundancy**.

Either keep them synced (Gravity Sync or equivalent), or document the secondary
as availability-only and not policy-parity.

### Corosync shares a single NIC per node

Corosync is latency-sensitive, and it shares its NIC with guest and storage
traffic. Heavy NFS or backup traffic can make it flap.

No fix today — one port per node. The CRS310's free SFP+ ports make a dedicated
corosync link possible if NICs are ever added. **Known limitation, not a task.**

---

## Security

### Docker socket exposure

Dozzle and Watchtower both mount `/var/run/docker.sock`, which is
**root-equivalent**. Proposed: a socket-proxy in front of both, with read-only
scopes.

### Watchtower auto-updates

Auto-updating ~29 services invites breakage from upstream changes. Proposed:
monitor-only mode (`WATCHTOWER_MONITOR_ONLY`), notify via ntfy, pull
deliberately.

### No auth layer on internal tools

File Browser, Dozzle, and Homepage have no authentication. Fine while they are
Tailscale-only; a problem the moment anything makes them LAN- or
internet-reachable.

---

## Network

### VLAN rollout is deferred, not blocked

**Unblocked** — the MikroTik does VLAN tagging itself, so the faulty OC200 is no
longer in the way. Deferred **by choice**, until the flat 2.5G network is proven.

Needs: VLAN table and PVIDs on the CRS310, DHCP scopes and isolation rules on the
ER605, and the Omada software controller to tag the guest/IoT SSIDs on the
EAP650. Procedure and ordering:
[network-core-crs310.md](./network-core-crs310.md#vlan-rollout--procedure).

### OC200 RMA outstanding

No longer blocks VLANs. Needed only for Omada AP management, which the software
controller also covers. `10.0.0.2` stays reserved for it.

---

## Miscellaneous

- **Rhea RAM upgrade** (15.4 → 32 GiB) — deferred on cost. **Blocks nothing**;
  see [DECISIONS.md](./DECISIONS.md) D14.
- **Compose stubs** — Tracktor, ShipShipShip, and ListingLab still need
  user-provided images.

---

## Resolved — do not re-open

Kept briefly so they are not rediscovered as questions.

| Was | Resolution |
|---|---|
| Rhea hung NFS mount / load ~1.0 | Not NFS. The `snd_hda_intel` audio timeout — fixed, see [hardware-inventory.md](./hardware-inventory.md#rhea--snd_hda_intel-must-stay-blacklisted) |
| ZFS depends on Rhea's RAM upgrade | False. PVE caps ARC at 10% of RAM (max 16 GiB); Rhea runs ZFS fine at 15.4 GiB — D14 |
| VLANs blocked on a working Omada controller | False. The MikroTik does VLANs — D15 |
| SQLite/`/config` on NFS | Decided: configs on node-local ZFS, NFS for bulk data only — D11 |
