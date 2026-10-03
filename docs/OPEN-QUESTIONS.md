# Open Questions / Known Risks

Raised, reasoned through, and **not ratified**. Nothing here is implemented.

**Do not act on anything in this file** without deciding it first. When an item
is settled, move it to [DECISIONS.md](./DECISIONS.md) with its rationale and
delete it here — this file should shrink as the design firms up.

Last reviewed: **2026-10-03**.

---

## Next build steps, in order

### 1. Reboot Themis at a quiet time

Nothing downloading in SAB. Then **confirm `/mnt/sisyphus` mounted before
`arr`/`grab` started** — the ordering hazard below. Afterwards check
`iptables -S FORWARD` shows `-P FORWARD ACCEPT`.

### 2. Proton VPN Plus → gluetun + `qbittorrent-vpn`

[D30](./DECISIONS.md). `/dev/net/tun` passthrough to CT 301, WireGuard,
`VPN_PORT_FORWARDING=on` **plus a helper that pushes the forwarded port into
qBittorrent** (Proton assigns a random one), own incomplete folder, limited
seeding, and a **kill-switch test**: stop gluetun, confirm connectivity is gone.

Then connect Radarr (`movies`) and Sonarr (`tv`) to it.

### 3. Torrent hardlink test

After the first torrent import through `qbittorrent-vpn`, **both copies must
show link count 2.** This is the one check that proves the shared-path design
works; the Usenet path cannot prove it, because Usenet imports are moves.

### 4. Re-add the MyAnonymouse torrents

To the **VPN-free** `qbittorrent`. Download the `.torrent` files from the MAM
account, add with the save path pointing at the existing data in
`torrents/00-myanonymouse`, **leave "Skip hash check" unticked** so it rechecks,
confirm seeding.

> **Seeding time is accruing as downtime until this is done** — `grab` was built
> from scratch, so none of the 154 seeds survived.

### 5. VueTorrent

Install from the release zip, set as the alternative Web UI, **and record the
version** — it never self-updates.

### 6. abs-arr: bug adding qBittorrent as a download client

Own project; fix pending. **Until it is fixed abs-arr cannot download**;
everything else in it works.

---

## Small items inside what is already built

### Hardware transcoding fails — PARKED

After the `gid=3004` fix, **Plex can open the device, but changing playback
quality freezes and then falls back to direct play.** HW acceleration stays
unticked; software transcoding works.

**Parked deliberately until the rest of the lab is built.** Next steps when
picked up:

1. Tail Plex's log while reproducing:
   ```bash
   pct exec 200 -- docker exec plex tail -f \
     "/config/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log" \
     | grep -iE "transcod|vaapi|error"
   ```
2. On the Hestia **host**: `dmesg | grep -iE "huc|guc"`. Jasper Lake encodes only
   via the low-power encoder, which needs **HuC firmware**; the fix would be a
   host `i915` option plus a Hestia reboot — which briefly takes `dns2` and
   `monitor` down (the VIP stays on Rhea).
3. **Cross-check with Jellyfin.** If Jellyfin hardware-transcodes and Plex does
   not, it is Plex's bundled driver, not the passthrough.

### Jellyfin transcode settings and tmpfs resize

Parked with the above: transcode path `/transcode`, **Throttle transcodes** and
**Delete segments** (without those two Jellyfin keeps every segment for the whole
session). Measure with `df -h /transcode`, then **resize both tmpfs mounts to
~1 GB**.

### Jellyfin `12.1ubu2604-ls51`

A linuxserver rebuild of the same app version. Pull during a quiet window.

### wud only watches `monitor`'s Docker daemon

So **`media`, `arr` and `grab` get no update notifications at all.** Fix with a
read-only socket-proxy per Docker LXC that wud connects to, or one wud per LXC.

Until then, `scripts/check-versions.sh` is the stopgap.

### SAB tidy-up

- **Move or delete the backup zip from `usenet/complete`** — it contains provider
  passwords.
- Clear the stale server expiry dates (the "expiring in -310 days" warnings).
- Clear legacy `usenet/incomplete` and `torrents/incomplete` on the NAS.

### Manual sorting

- **`downloads/complete`** — epubs → `docs/books`, comics → `docs/comics`,
  `.m4b`/audiobook folders → `audio/ingest` or `audio/audiobooks`.
- **`media/audio/temp`** — 15 music releases, some duplicated with a `.1`
  suffix → `audio/music`.

Both are outside every pipeline, so nothing will do it for you. Use `setpriv` as
3004, `mv -n`, and `rmdir`.

### GitHub PAT expiry

**Record the date** of the classic `read:packages` token used by `arr`. When it
lapses, running containers keep working but **the next pull fails**.

### Recyclarr optional groups

DV Boost / HDR10+ Boost (only if the TV supports them) and Movie Versions. Off
until decided.

Also: the `[Audio] Audio Formats` `trash_ids` are **not** in the repo config —
they are opaque hashes that cannot be verified from here. Copy them from the live
config or TRaSH.

### Library Import

Confirm all ~58 films and 17 series are imported with profiles set, and the stock
quality profiles deleted.

---

## Architectural

### The book app is unchosen

**Not in the service map at all.** It will watch `media/docs/ingest/books` and
needs an LXC placement — likely `apps` or `sandbox`.

### Pi-hole enforcement rule on the ER605

[D31](./DECISIONS.md): deny LAN → WAN TCP/UDP 53 and 853 except from `.31`/`.32`.
**Unbuilt, and its absence is demonstrated** — a Mac with a manual `1.1.1.1`
bypassed Pi-hole entirely during the first cutover.

Confirm the ER605's rule UI at build time. **Redirect is not the design** — a
blocked client should fail loudly.

### Hestia-down blind spot in monitoring

**Kuma cannot report its own host's death.** Kuma and its notification sender
both run on Hestia, so if Hestia dies nothing alerts — **Telegram included**.

An **external dead-man's switch** would close it: something outside the network
that expects regular heartbeats from Kuma and alerts when they stop, e.g.
Healthchecks.io's free tier.

### Unified auth layer

**The biggest open architectural question in the utility layer.** Authentik or
Authelia.

Currently **unauthenticated on the LAN**:

| Service | Address |
|---|---|
| Dozzle agents | `10.0.0.30:7007`, `10.0.0.35:7007`, `10.0.0.36:7007` |
| Posterizarr | `10.0.0.30:8000` |
| JDownloader | `10.0.0.36:5800` — if its `WEB_AUTHENTICATION` isn't supported |

Would also cover Homepage when `apps` is built.

### CT ID numbering scheme

**Undefined.** IDs grew by node — 1xx Rhea, 2xx Hestia — which splits the DNS
pair across ranges: `dns` is 100, `dns2` is 201.

`arr` = 300 and `grab` = 301 **fit both candidate schemes**, so they defer rather
than compound the problem. **Decide before `sandbox` and the Hestia/Rhea LXCs.**

### Backup off-box

Nothing off Tartarus yet. **Gates Reclaimerr's deletion** and is underlined hard
by Immich (3-2-1 for irreplaceable photos).

**Restic ([D12](./DECISIONS.md)) is also still unbuilt**, so `arr` and `grab`
configs are currently **unprotected** — including Audiobookshelf's listening
progress and SABnzbd's restored-and-corrected ini.

### Second-tier SSD on Rhea/Hestia

Bays empty; lower priority now that `themis-500` exists. **Filling a bay may
renumber `sdX`** — revisit Beszel's root-device detection then.

### Corosync shares one NIC per node

Latency-sensitive, sharing with guest and storage traffic; heavy NFS or backup
traffic can make it flap. The CRS310's free SFP+ ports allow a dedicated link if
NICs are added.

### NFS-before-container ordering at boot

If the NFS mount is not up when Proxmox starts a container, **the bind mount
hands the guest an empty local directory** and writes land on node-local disk
instead of the NAS — silently.

`x-systemd.requires=network-online.target` is in the fstab line. **Themis's
reboot is queued above** as the first real test.

### Proxmox HA vs Kubernetes

Leaning **HA**, but HA needs shared storage, making Tartarus a cluster SPOF, so
off-box backup comes first. **ZFS replication between nodes is the lighter
alternative.**

### VLAN rollout

Deferred until the flat 2.5G network is proven — **not blocked**. Needs the
CRS310 VLAN table and PVIDs, ER605 DHCP scopes and isolation rules, and the Omada
controller to tag the guest/IoT SSIDs.

### ER605 cannot advertise a single-label search domain

Both `lan` and `.lan` fail the router's DHCP *Default Domain* validation — the
field wants at least one dot — so it was left blank. **`.lan` therefore cannot be
advertised by DHCP on this router.**

| Option | Cost |
|---|---|
| Set the search domain per-client | Manual, easy to miss a device |
| Move to a two-label name (e.g. `home.lan`) | Changes **every** local DNS record and Caddy hostname |

A **deliberate repo decision**, not an improvisation at the console.

### Other standing items

| Item | Status |
|---|---|
| **No log persistence anywhere** | Dozzle shows live logs only |
| **changedetection.io's silent failure** | Put Kuma on watch-the-watcher duty when `sandbox` exists |
| **HA USB/Zigbee passthrough** | Pins the VM to a node → no Proxmox HA for it |
| **OC200 RMA** | Outstanding; not blocking VLANs |
| **Compose stubs** | Tracktor / ShipShipShip / ListingLab need user images |
| **Rhea RAM 16 → 32 GB** | Deferred on cost; blocks nothing, known-good |
| **2.5G negotiation** | M720q is gigabit; 2.5G only where both ends support it |
| **Whisper subtitles, local LLM** | Deferred pending a GPU decision for Themis |
| **Apprise fan-out** | Would serve ntfy, Speedtest Tracker and changedetection together |
| **Docker version drift** | `media` 29.8.1; `monitor`/`arr`/`grab` 29.8.2. Harmless; worth a bump policy |
| **SMB bookmarks** | Check for any still referencing `tartarus.local` |

---

## Resolved — do not re-open

| Was | Resolution |
|---|---|
| `media` resolv.conf on `10.0.0.1` | Now the VIP `10.0.0.33` |
| Remaining `.lan` records | Added and replication verified |
| **Beszel `FILESYSTEM` override** | **Not needed — `sda` was correct.** Rhea and Hestia boot from **M.2 SATA**, not NVMe |
| Telegram on every monitor | Verified delivering |
| Themis `root:3004:1` subuid/subgid | Done |
| `/themis-500/incomplete` root-owned | Fixed — per-client subfolders owned 3004 |
| GPU device unopenable by `abc` | Pass the device with `gid=3004`, not the container's `render` group |
| Uptime Kuma stuck on 1.x | Migrated to 2.5.0; `:latest` was lagging a major version |
| **DNS redundancy (urgent)** | **Built and tested** — two Pi-holes, keepalived VIP, nebula-sync hourly |
| Where the second Pi-hole lives | `dns2`, CT 201, on **Hestia** — not Rhea, which is the point |
| How the two Pi-holes stay in sync | nebula-sync, **one-way**, hourly. Edit the primary only |
| `app_sudo` drifting between the pair | **Not carried by `FULL_SYNC`** — verified over six hourly syncs. Leave the primary `false` |
| `/dev/dri` passthrough | Done; encode *and* decode verified |
| Transcode scratch on NFS | Docker-level tmpfs — the LXC-level mount fails silently |
| sisyphus host mounts | Done on all three nodes at `/mnt/sisyphus` |
| Which LXC address range | `.30–.59` |
| Audiobookshelf placement | `arr` on Themis, beside abs-arr. Not `media` |
| qBittorrent blocked on a second SSD | Unblocked by the `themis-500` HDD pool |
| gluetun wired to nothing | Stale stub deleted; the new one is a fresh build in `grab` ([D30](./DECISIONS.md)) |
| Watchtower auto-update risk | Dropped for wud, notify-only |
| SQLite / `/config` on NFS | Node-local ZFS only |
