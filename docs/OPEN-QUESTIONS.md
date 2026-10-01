# Open Questions / Known Risks

Raised, reasoned through, and **not ratified**. Nothing here is implemented.

**Do not act on anything in this file** without deciding it first. When an item
is settled, move it to [DECISIONS.md](./DECISIONS.md) with its rationale and
delete it here — this file should shrink as the design firms up.

Last reviewed: **2026-10-01**.

---

## Urgent

### DNS redundancy — now live, not theoretical

**DHCP points every client on the network at `10.0.0.31`** — a single container
on a single node. **If Rhea dies, the network loses name resolution.** This was
an acceptable risk while `dns` was unbuilt; it is now the live topology.

> **Rollback for any DNS emergency: set the ER605's Primary DNS back to
> `10.0.0.1`.** The router answers regardless of Pi-hole's state. Know this
> before you need it.

The fix: **a second Pi-hole on Hestia plus a Keepalived VRRP floating VIP**, with
clients and DHCP pointing only at the VIP.

> **Never update both Pi-holes at once** — a bad update with both down means zero
> redundancy at exactly the wrong moment.

"Secondary DNS in DHCP" is **not** failover: clients either query both, wait an
age, or cache the primary and never try the backup. See [D20](./DECISIONS.md).

### Clients are not forced through Pi-hole

The **CRS310 NAT rules** from [D20](./DECISIONS.md) are **unbuilt, and their
absence has now been demonstrated**: during the cutover, a Mac with `1.1.1.1`
set manually in network settings bypassed Pi-hole entirely. `dig` against the
Pi-hole IP looked perfect while ordinary resolution never touched it.

Until the NAT rules exist, any client with a manual resolver silently opts out of
both filtering and split-horizon.

---

## Blocking the next builds

### Themis needs subuid/subgid before `arr` or `grab`

Themis lacks `root:3004:1` in `/etc/subuid` and `/etc/subgid`, plus the six
`lxc.idmap` lines in each container config. **Hestia already has this; Themis
does not.**

Without it, an unprivileged container maps UID 3004 → 103004, which the NFS
export rejects — and the share is mode `drwx------`, so the guest sees nothing
at all. Exact block:
[build-gotchas.md](./build-gotchas.md#unprivileged-containers-need-an-idmap-to-use-the-nfs-share).

### `/themis-500/incomplete` is owned `root:root`

qBittorrent runs as 3004 and **cannot write there**. Must become `3004:3004`
before `grab` goes up — do it as part of that build so the whole download path
can be verified end to end.

### `media` still resolves via `10.0.0.1`

It was built before `dns` existed. `media` is an ordinary client and should point
at `10.0.0.31`; only `monitor` keeps the bypass.

```bash
pct set 200 --nameserver 10.0.0.31   # then restart
```

### Local `.lan` DNS records are not configured

Split-horizon ([D20](./DECISIONS.md)) is decided but Pi-hole has no local records
yet, so `plex.lan` and friends do not resolve. Needed before Caddy is useful.

### ER605 cannot advertise a single-label search domain

Both `lan` and `.lan` fail the router's DHCP *Default Domain* validation —
*"Invalid domain format"*. The field wants at least one dot, and was left blank.

Two ways out, and this must be a **deliberate repo decision**, not an
improvisation at the console:

| Option | Cost |
|---|---|
| Set the search domain per-client | Manual, and easy to miss a device |
| Move to a two-label name (e.g. `home.lan`) | Changes **every** local DNS record and Caddy hostname |

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

### Unified auth layer

**The biggest open architectural question in the utility layer.** Authentik or
Authelia would cover Dozzle, Homepage, **and Posterizarr's WebUI, which is
currently exposed on the LAN with no authentication at all.**

Fine while everything is Tailscale-only; a problem the moment anything becomes
LAN- or internet-reachable.

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
socket-proxy, so agents are both the topology and the security answer.
**what's-up-docker still wants a socket-proxy.**

### No log persistence anywhere

Dozzle shows **live logs only**. Nothing retains logs across a container restart.

### changedetection.io fails silently

**The thing that would alert you is the thing that stopped.** Put Uptime Kuma on
watch-the-watcher duty. If it graduates from trial to relied-upon, move it out of
`sandbox`.

### Uptime Kuma needs an off-Hestia notification path

`monitor` will live on Hestia. A host-down event for Hestia is exactly the event
it cannot report through itself.

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
| `/dev/dri` passthrough for `media` | **Done.** Hardware encode *and* decode verified with `vainfo` — [build-record.md](./build-record.md) |
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
| Watchtower auto-update risk | Dropped for what's-up-docker, notify-only |
| Rhea load pinned at 1.00 | The `snd_hda_intel` audio timeout — [fixed](./hardware-inventory.md#rhea--snd_hda_intel-must-stay-blacklisted) |
| ZFS depends on Rhea's RAM upgrade | False. ARC auto-caps at 10% of RAM |
| VLANs blocked on a working Omada controller | False. The MikroTik does VLANs |
| SQLite / `/config` on NFS | Decided: node-local ZFS only — [D11](./DECISIONS.md) |
