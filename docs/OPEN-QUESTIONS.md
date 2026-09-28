# Open Questions / Known Risks

Raised, reasoned through, and **not ratified**. Nothing here is implemented.

**Do not act on anything in this file** without deciding it first. When an item
is settled, move it to [DECISIONS.md](./DECISIONS.md) with its rationale and
delete it here — this file should shrink as the design firms up.

Last reviewed: **2026-09-27**.

---

## Next hands-on task

### `/dev/dri` passthrough for `media`

The immediate next build step. Host has `renderD128` (226:128) and
`getent group render` → GID 993; **the container's GID differs and must be read
separately.**

Order matters — verify before Docker exists, because debugging passthrough
through a Docker layer is much harder:

```bash
# push the CT template to tantalus first
pct create 200 --features nesting=1,keyctl=1 --unprivileged 1 --swap 0
pct exec 200 -- getent group render
pct set 200 -dev0 /dev/dri/renderD128,gid=<container-gid>,mode=0660
vainfo                                   # verify BEFORE installing Docker
```

> **`renderD128` only — never `card1`.**

The compose side is already in place: plex and jellyfin request
`/dev/dri/renderD128` and take the GID from `RENDER_GID`.

---

## Gating dependencies

These block other work, so they are not merely nice-to-have.

### Nothing lives off Tartarus yet

Proxmox dumps, the Restic repo, and live data all land on the same box. **RAID
plus one-way rsync is not a backup** — a bad delete or a pool loss takes
everything.

**This gates two things:**

- **Reclaimerr's scheduled deletion** ([D23](./DECISIONS.md)). Restic-to-Tartarus
  is on-box; it does not protect against a bad deletion rule, because the
  deletion propagates into the backup.
- **Proxmox HA**, which would make Tartarus a cluster-wide SPOF.

Underlined hard by Immich, which holds the most irreplaceable data in the lab
and wants 3-2-1 — **both** the database and the media filesystem.

### DNS redundancy

DNS is the correctly-narrowed SPOF: proxy and Tailscale failing is annoying and
recoverable, **DNS failing takes the whole network with it**.

Plan, not built: **a second Pi-hole on Hestia plus a Keepalived VRRP floating
virtual IP**, with clients and DHCP pointing only at the VIP.

> **Never update both Pi-holes at once** — a bad update with both down means
> zero redundancy at exactly the wrong moment.

"Secondary DNS in DHCP" is confirmed **not** real failover: clients either query
both, wait an age, or cache the primary and never try the backup. See
[D20](./DECISIONS.md).

### Unified auth layer

**The biggest open architectural question in the utility layer.** Authentik or
Authelia would cover Dozzle, Homepage, and the other internal tools that
currently have no authentication at all.

Fine while everything is Tailscale-only; a problem the moment anything becomes
LAN- or internet-reachable. The `apps` review named this as the one gap a
reviewer would flag.

---

## Infrastructure

### Second-tier SSD for Rhea and Hestia

Both 2.5" bays are empty. **Lower priority now that `themis-500` exists** and has
absorbed the scratch workload that was blocking qBittorrent.

### Corosync shares one NIC per node

Corosync is latency-sensitive and shares its NIC with guest and storage traffic;
heavy NFS or backup traffic can make it flap. No fix today — one port per node.
The CRS310's free SFP+ ports allow a dedicated link if NICs are ever added.

### Proxmox HA vs Kubernetes

Leaning **HA** — the workload is overwhelmingly single-instance stateful
containers. But HA needs shared storage, making Tartarus a cluster SPOF, so
off-box backup comes first. **ZFS replication between nodes is the lighter
alternative** and is genuinely available now that ZFS is live everywhere.

### VLAN rollout

Deferred until the flat 2.5G network is proven — **not blocked**. Needs the
CRS310 VLAN table and PVIDs, ER605 DHCP scopes and isolation rules, and the
Omada controller to tag the guest/IoT SSIDs. Ordering and its traps:
[network-core-crs310.md](./network-core-crs310.md#vlan-rollout--procedure).

### OC200 RMA

Outstanding, **not blocking VLANs**. Needed only for Omada AP management, which
the software controller also covers — the hardware and software controllers are
functionally identical.

### 2.5G negotiation

Only materialises where both ends support it. **The M720q is gigabit.** Check
negotiated rates rather than assuming.

---

## Operational gaps

### Docker socket exposure

Dozzle is solved via **agent mode** — and note an agent *cannot* sit behind a
socket-proxy, so agents are both the topology and the security answer.
**what's-up-docker still wants a socket-proxy**, which is root-equivalent access
until it gets one.

### No log persistence anywhere

Dozzle shows **live logs only**. Nothing retains logs after a container restarts.

### changedetection.io fails silently

**The thing that would alert you is the thing that stopped.** Put Uptime Kuma on
watch-the-watcher duty. If changedetection graduates from trial to relied-upon,
move it out of `sandbox` into `apps` or `monitor`.

### Uptime Kuma needs an off-Hestia notification path

`monitor` lives on Hestia. A host-down event for Hestia is exactly the event it
cannot report through itself.

### Home Assistant USB passthrough pins the VM

Zigbee passthrough pins the VM to one node → **no Proxmox HA for it**, and if
that node dies, home automation dies with it. Either accept, or decouple with a
networked Zigbee coordinator — placed where the mesh needs it, not where the
rack is.

---

## Deferred pending hardware or a decision

| Item | Blocked on |
|---|---|
| **Whisper AI subtitles** (Bazarr) | A GPU decision for Themis — its UHD 630 is not passed into `arr` |
| **Local LLM** (Ollama / Open WebUI) | Same. UHD 630 gives no ML acceleration, so CPU-only inference. Reopen if a real GPU joins the lab |
| **Rhea RAM 16 → 32 GB** | Cost only. Blocks nothing, and **known-good** — Hestia runs 32 GB on the identical board |
| **Apprise notification fan-out** | Would serve ntfy, Speedtest Tracker and changedetection together |
| **Compose stubs** — Tracktor, ShipShipShip, ListingLab | User-provided images |

---

## Housekeeping

- **Check SMB and client bookmarks** still pointing at `tartarus.local` — the
  TrueNAS domain changed to `.lan`.
- **`atlas/sisyphus-migrator`** is not covered by the rev-7 service review. It is
  a profile-gated one-shot rsync helper for the migration itself. Retire it once
  the migration is done.

---

## Resolved — do not re-open

Kept briefly so they are not rediscovered as questions.

| Was | Resolution |
|---|---|
| Immich / Paperless not placed | Immich has a dedicated LXC; Paperless is in `apps` |
| Full per-service keep/drop | Pass 1 complete — [service-architecture.md](./service-architecture.md) |
| Grouping validation | Pass 2 complete; every grouping structurally validated |
| Media / transcode placement | Media on Hestia; transcode to **tmpfs** |
| qBittorrent blocked on a second SSD | Unblocked by the `themis-500` HDD pool |
| Themis on a mechanical boot disk | Rebuilt onto NVMe — [rebuild-runbook.md](./rebuild-runbook.md) |
| gluetun / VPN killswitch | Removed — [D17](./DECISIONS.md) |
| Watchtower auto-update risk | Dropped for what's-up-docker, notify-only |
| Rhea hung NFS mount / load ~1.0 | The `snd_hda_intel` audio timeout — [fixed](./hardware-inventory.md#rhea--snd_hda_intel-must-stay-blacklisted) |
| ZFS depends on Rhea's RAM upgrade | False. ARC auto-caps at 10% of RAM |
| VLANs blocked on a working Omada controller | False. The MikroTik does VLANs |
| SQLite / `/config` on NFS | Decided: node-local ZFS only — [D11](./DECISIONS.md) |
| Stack placement partly unassigned | Resolved by the 11-LXC map |
