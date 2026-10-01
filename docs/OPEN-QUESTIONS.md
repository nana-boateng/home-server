# Open Questions / Known Risks

Raised, reasoned through, and **not ratified**. Nothing here is implemented.

**Do not act on anything in this file** without deciding it first. When an item
is settled, move it to [DECISIONS.md](./DECISIONS.md) with its rationale and
delete it here — this file should shrink as the design firms up.

Last reviewed: **2026-10-04**.

---

## Small items inside what is already built

Each of these is a loose end in a live LXC, not an architectural question.

### `media` resolv.conf still points at `10.0.0.1`

It was built before `dns` existed. `media` is an ordinary client and should use
the VIP; only `monitor` keeps the bypass.

```bash
pct set 200 --nameserver 10.0.0.33   # then restart
```

### Hardware transcoding is still OFF inside Plex and Jellyfin

**The passthrough is verified but inert until enabled in each app's own
settings.** Encode and decode both work at the `vainfo` level — nothing is using
them.

- **Jellyfin:** Dashboard → Playback → Transcoding → VA-API,
  `/dev/dri/renderD128`; enable H.264 / HEVC / VP9, **leave AV1 off**.
- **Plex:** Settings → Transcoder → enable hardware transcoding, temporary
  directory `/transcode`.

Confirm with a forced transcode — **Tautulli shows the decision.**

### Remaining `.lan` records

Only **`plex.lan`** exists. Still to add, all on the **primary** (`10.0.0.31`) —
never the replica:

| Record | Target |
|---|---|
| jellyfin, tautulli, navidrome, posterizarr | `10.0.0.30` |
| `pihole.lan` | `10.0.0.33` — follows the VIP |
| rhea / themis / hestia / tartarus | `.10` / `.11` / `.12` / `.20` |

### Beszel `FILESYSTEM` override on Rhea and Hestia

Both agents report **`sda`** for root I/O despite booting from **NVMe**, so
their disk figures are misleading. Themis correctly detected `nvme0n1`.

Fix by setting `FILESYSTEM` in `/etc/systemd/system/beszel-agent.service`.

`no valid SMART data found` is expected and separate — the sandboxed agent lacks
the privileges.

### Uptime Kuma off-Hestia notification path

**This is the piece that makes the monitoring layer meaningful.** Kuma *and* ntfy
both live on Hestia, so a Hestia failure kills the alert and the alerting system
together.

Kuma needs a second channel that **leaves the network entirely** — email,
Discord, Pushover — with ntfy kept as the everyday hub.

---

## Architectural

### Clients are not forced through Pi-hole

The **CRS310 NAT rules** from [D20](./DECISIONS.md) are **unbuilt, and their
absence has been demonstrated**: during the first cutover, a Mac with `1.1.1.1`
set manually bypassed Pi-hole entirely. `dig` against the Pi-hole IP looked
perfect while ordinary resolution never touched it.

Until the NAT rules exist, any client with a manual resolver silently opts out of
filtering and split-horizon both.

### Unified auth layer

**The biggest open architectural question in the utility layer.** Authentik or
Authelia.

Currently **unauthenticated on the LAN**:

| Service | Address |
|---|---|
| Dozzle agent | `10.0.0.30:7007` |
| Posterizarr WebUI | `10.0.0.30:8000` |

Would also cover Homepage when `apps` is built.

### CT ID numbering scheme

**Undefined.** IDs grew by node — 1xx Rhea, 2xx Hestia — which splits the DNS
pair across ranges: `dns` is **100**, `dns2` is **201**, even though the pair is
one logical unit deliberately split across nodes.

A service-based scheme would read better — e.g. 100/101 DNS, 200 media, 3xx
arr/grab, 4xx apps.

**Decide before the remaining six LXCs compound it.** Not renumbering what
exists.

### Docker version drift

`media` is on **29.8.1**, `monitor` on **29.8.2** — built days apart. Harmless
now; worth a deliberate bump policy before there are eleven of them.

### Themis needs subuid/subgid before `arr` or `grab`

Themis lacks `root:3004:1` in `/etc/subuid` and `/etc/subgid`, plus the six
`lxc.idmap` lines per container. **Hestia has this; Themis does not.**

Without it an unprivileged container maps UID 3004 → 103004, which the NFS export
rejects — and the share is mode `drwx------`, so the guest sees nothing at all.
Exact block:
[build-gotchas.md](./build-gotchas.md#unprivileged-containers-need-an-idmap-to-use-the-nfs-share).

### `/themis-500/incomplete` is owned `root:root`

qBittorrent runs as 3004 and **cannot write there**. Must become `3004:3004`
before `grab` goes up — do it as part of that build so the whole download path
gets verified at once.

### ER605 cannot advertise a single-label search domain

Both `lan` and `.lan` fail the router's DHCP *Default Domain* validation. The
field was left blank, so **`.lan` cannot be advertised by DHCP on this router**.

| Option | Cost |
|---|---|
| Set the search domain per-client | Manual, easy to miss a device |
| Move to a two-label name (e.g. `home.lan`) | Changes **every** local DNS record and Caddy hostname |

A **deliberate repo decision**, not an improvisation at the console.

### Themis's node search domain is unchecked

Rhea's was found set to **`an`**, not `lan`, and every guest it created inherited
the typo. Hestia was correct. **Themis has not been checked.** Containers pick up
a correction only on restart.

---

## Gating dependencies

### Nothing lives off Tartarus yet

Proxmox dumps, the Restic repo, and live data all land on the same box. **RAID
plus one-way rsync is not a backup.**

**This gates two things:**

- **Reclaimerr's scheduled deletion** ([D23](./DECISIONS.md)) — Restic-to-Tartarus
  is on-box, so a bad deletion rule propagates into the backup.
- **Proxmox HA**, which would make Tartarus a cluster-wide SPOF.

Underlined hard by Immich, which holds the most irreplaceable data in the lab and
wants 3-2-1 — **both** the database and the media filesystem.

---

## Infrastructure

### NFS-before-container ordering at boot

If the NFS mount is not up when Proxmox starts a container, **the bind mount
hands the guest an empty local directory** and writes land on node-local disk
instead of the NAS — silently.

`x-systemd.requires=network-online.target` is in the fstab line. **Verify on the
next reboot of each node rather than trusting it.**

### Second-tier SSD for Rhea and Hestia

Both 2.5" bays are empty. **Lower priority** now that `themis-500` exists.

### Corosync shares one NIC per node

Latency-sensitive, sharing with guest and storage traffic; heavy NFS or backup
traffic can make it flap. No fix today — one port per node. The CRS310's free
SFP+ ports allow a dedicated link if NICs are added.

### Proxmox HA vs Kubernetes

Leaning **HA** — the workload is overwhelmingly single-instance stateful
containers. But HA needs shared storage, making Tartarus a cluster SPOF, so
off-box backup comes first. **ZFS replication between nodes is the lighter
alternative.**

### VLAN rollout

Deferred until the flat 2.5G network is proven — **not blocked**. Needs the
CRS310 VLAN table and PVIDs, ER605 DHCP scopes and isolation rules, and the Omada
controller to tag the guest/IoT SSIDs. Ordering and traps:
[network-core-crs310.md](./network-core-crs310.md#vlan-rollout--procedure).

### OC200 RMA

Outstanding, **not blocking VLANs**. Needed only for Omada AP management, which
the software controller also covers.

### 2.5G negotiation

Only materialises where both ends support it. **The M720q is gigabit.**

---

## Operational gaps

### Docker socket exposure

Dozzle is solved via **agent mode** — and an agent *cannot* sit behind a
socket-proxy, so agents are the mechanism rather than a workaround.
**wud still wants a socket-proxy**; it mounts the socket read-only today, which
is still root-equivalent read access.

### No log persistence anywhere

Dozzle shows **live logs only**. Nothing retains logs across a container restart.

### changedetection.io fails silently

**The thing that would alert you is the thing that stopped.** Put Uptime Kuma on
watch-the-watcher duty. If it graduates from trial to relied-upon, move it out of
`sandbox`.

### Home Assistant USB passthrough pins the VM

Zigbee passthrough pins the VM to one node → **no Proxmox HA for it**. Either
accept, or decouple with a networked Zigbee coordinator, placed where the mesh
needs it rather than where the rack is.

---

## Deferred pending hardware or a decision

| Item | Blocked on |
|---|---|
| **Whisper AI subtitles** (Bazarr) | A GPU decision for Themis — its UHD 630 is not passed into `arr` |
| **Local LLM** (Ollama / Open WebUI) | Same. No ML acceleration on UHD 630, so CPU-only. Reopen if a real GPU joins |
| **Rhea RAM 16 → 32 GB** | Cost only. Blocks nothing, and **known-good** — Hestia runs 32 GB on the identical board |
| **Apprise notification fan-out** | Would serve ntfy, Speedtest Tracker and changedetection together |
| **Compose stubs** — Tracktor, ShipShipShip, ListingLab | User-provided images |

---

## Housekeeping

- **Check SMB and client bookmarks** still pointing at `tartarus.local` — the
  TrueNAS domain changed to `.lan`.
- **`atlas/sisyphus-migrator`** is not covered by the service review. It is a
  profile-gated one-shot rsync helper for the migration itself. Retire it once
  the migration is done.

---

## Resolved — do not re-open

| Was | Resolution |
|---|---|
| **DNS redundancy (urgent)** | **Built and tested.** Two Pi-holes, keepalived VIP at `10.0.0.33`, nebula-sync hourly — [D27](./DECISIONS.md). **The SPOF is closed** |
| Where the second Pi-hole lives | `dns2`, CT 201, on **Hestia** — not Rhea, which is the point |
| How the two Pi-holes stay in sync | nebula-sync, **one-way**, hourly. Edit the primary only |
| `/dev/dri` passthrough for `media` | **Done.** Encode *and* decode verified with `vainfo` |
| Transcode scratch on NFS | **Done.** Docker-level tmpfs — the LXC-level mount fails silently |
| `themis-500/downloads` rename, orphaned `transcode` | **Done** |
| sisyphus host mounts and bind mounts | **Done** on all three nodes, at `/mnt/sisyphus` — [D25](./DECISIONS.md) |
| Which LXC address range | `.30–.59` — [D24](./DECISIONS.md) |
| Stale `appdata/` and `dev/` on the share | Deleted — 403 MB plus a stray container `/dev` skeleton |
| Audiobookshelf placement | `arr` on Themis, beside abs-arr. Not `media` |
| Immich / Paperless not placed | Immich has a dedicated LXC; Paperless is in `apps` |
| Full per-service keep/drop | Pass 1 complete |
| Grouping validation | Pass 2 complete; every grouping structurally validated |
| Media / transcode placement | Media on Hestia; transcode to tmpfs |
| qBittorrent blocked on a second SSD | Unblocked by the `themis-500` HDD pool |
| Themis on a mechanical boot disk | Rebuilt onto NVMe |
| gluetun / VPN killswitch | Removed — [D17](./DECISIONS.md) |
| Watchtower auto-update risk | Dropped for wud, notify-only — [D28](./DECISIONS.md) |
| Rhea load pinned at 1.00 | The `snd_hda_intel` audio timeout — [fixed](./hardware-inventory.md#rhea--snd_hda_intel-must-stay-blacklisted) |
| ZFS depends on Rhea's RAM upgrade | False. ARC auto-caps at 10% of RAM |
| VLANs blocked on a working Omada controller | False. The MikroTik does VLANs |
| SQLite / `/config` on NFS | Decided: node-local ZFS only — [D11](./DECISIONS.md) |
