# Build Record

What has actually been built and verified, with the commands that proved it.
**Reproduce from here, not from memory.**

Read [build-gotchas.md](./build-gotchas.md) before building the next LXC — it is
the higher-value page of the two.

Status against the [service architecture](./service-architecture.md):
**6 of 12 LXCs built.** The DNS single point of failure is **closed**.

| LXC | CT | Node | IP | Status |
|---|---|---|---|---|
| `media` | 200 | Hestia | `10.0.0.30` | **Live** |
| `dns` | 100 | Rhea | `10.0.0.31` | **Live** — Pi-hole primary |
| `dns2` | 201 | Hestia | `10.0.0.32` | **Live** — Pi-hole replica |
| — | — | floating | **`10.0.0.33`** | **Live** — keepalived VIP, what DHCP advertises |
| `monitor` | 202 | Hestia | `10.0.0.34` | **Live** |
| `arr` | 300 | Themis | `10.0.0.35` | **Live** |
| `grab` | 301 | Themis | `10.0.0.36` | **Live** — except `qbittorrent-vpn` |
| `proxy`, `tailscale`, `omada` | | Rhea | — | Not built |
| `apps`, `immich` | | Hestia | — | Not built |
| `sandbox`, `homeassistant` (VM) | | Themis | — | Not built |

Native LXC configuration (keepalived, unbound, nebula-sync) is in
[`infra/dns/`](../infra/dns/).

---

## `media` — CT 200 on Hestia, `10.0.0.30`

### Container

Debian 13 (trixie) amd64, **unprivileged**, `nesting=1,keyctl=1`, 4 cores,
8192 MB, `swap 0`, 32 GB rootfs on `local-zfs`, `onboot 1`, static IP in the
container config.

**`nameserver 10.0.0.33`** — the VIP. `media` is an ordinary client; only
`monitor` keeps the Pi-hole bypass.

### GPU passthrough

Host: `/dev/dri/renderD128` is `226:128`, host `render` group is GID 993. Pass
the render node into the container **owned by group 3004**:

```bash
pct set 200 -dev0 /dev/dri/renderD128,gid=3004,mode=0660
pct reboot 200
```

> **Why 3004 and not the container's own `render` group (992), which is what was
> used through rev 9.** Plex and Jellyfin run as `abc`, UID 3004, whose groups
> are only `3004` and `100`. With the device at `0:992` mode `0660` the services
> could **see** it but not **open** it — Plex logged
> `opening hw device failed - probably not supported by this system, error:
> Invalid argument` and fell back to software.
>
> The linuxserver init normally adds `abc` to the device's group at startup;
> **inside this idmapped LXC it did not.** Every service in `media` runs as
> 3004, so assigning the device to that group covers all of them without
> relying on in-container group handling.
>
> **A root-run `vainfo` succeeding proves nothing** about what the service user
> can open — that is why the problem survived the original verification.

**`renderD128` only — never `card0`/`card1`.** Check the ownership that actually
landed:

```bash
pct exec 200 -- docker exec plex ls -ln /dev/dri    # group must be 3004
pct exec 200 -- docker exec plex id abc
```

Verified with `vainfo`, after installing `vainfo` and
`intel-media-va-driver-non-free`:

- **H.264** Main / High
- **HEVC** Main / Main10 / Main422_10 / Main444 / Main444_10
- **VP9** profiles 0–3
- VC1, MPEG2, JPEG
- both `VLD` (decode) **and** `EncSliceLP` (encode) entrypoints

**No AV1** — exactly as the hardware inventory predicted. Jasper Lake predates
Intel's Gen-12 AV1 decode.

### sisyphus

Host fstab entry (see below) plus:

```bash
pct set 200 -mp0 /mnt/sisyphus,mp=/mnt/sisyphus
```

### idmap — required for NFS UID 3004 in an unprivileged container

Host:

```bash
echo 'root:3004:1' >> /etc/subuid
echo 'root:3004:1' >> /etc/subgid
```

`/etc/pve/lxc/200.conf`, **container stopped**:

```
lxc.idmap: u 0 100000 3004
lxc.idmap: u 3004 3004 1
lxc.idmap: u 3005 103005 62531
lxc.idmap: g 0 100000 3004
lxc.idmap: g 3004 3004 1
lxc.idmap: g 3005 103005 62531
```

Verified — numeric `3004 3004`, not `nobody`, not `103004`:

```bash
pct exec 200 -- ls -ln /mnt/sisyphus
```

The GPU `dev0` bind survives the idmap unchanged.

### Docker

Docker CE from the official repo, **deb822 format**
(`/etc/apt/sources.list.d/docker.sources`): `docker-ce docker-ce-cli
containerd.io docker-buildx-plugin docker-compose-plugin`. Verified with
`hello-world`.

### Stack

Live at `/opt/stacks/media/compose.yaml`; mirrored in this repo at
[`stacks/media/compose.yaml`](../stacks/media/compose.yaml). API keys in an
uncommitted `/opt/stacks/media/.env` (mode `600`). Configs under
`/opt/appdata/media/<service>`, owned `3004:3004`.

**Versions as pulled and verified 2026-09-28:**

| Service | Image | Version pulled |
|---|---|---|
| plex | `lscr.io/linuxserver/plex` | `1.43.4.10903-e5521bd8c-ls326` (pinned `1.43.4`) |
| jellyfin | `lscr.io/linuxserver/jellyfin` | `12.1ubu2604-ls50` |
| tautulli | `lscr.io/linuxserver/tautulli` | `v2.18.2-ls245` |
| navidrome | `deluan/navidrome` | `0.64.2` |
| posterizarr | `ghcr.io/fscorrupt/posterizarr` | `3.3.6` |
| dozzle-agent | `amir20/dozzle` | `v11.1.3` — port 7007, added for `monitor` |

**Plex runs `network_mode: host`** for discovery and native remote access
([D18](./DECISIONS.md)), so it has no `ports:` block — it is on
`10.0.0.30:32400`. Jellyfin 8096, Tautulli 8181, Navidrome 4533, Posterizarr
8000. Navidrome mounts `/mnt/sisyphus/media/audio/music` read-only.

**Transcode scratch is tmpfs declared per-container in the compose**, not at the
LXC level — `lxc.mount.entry` tmpfs into an idmapped unprivileged container
fails silently. On plex and jellyfin only:

```yaml
    tmpfs:
      - /transcode:rw,size=4g,uid=3004,gid=3004
```

**aggregarr is not built** — decided, but not in the live compose.

### Plex transcoder settings — done

Settings → Transcoder → **Show Advanced** (the fields below are hidden without
it):

- **Transcoder temporary directory: `/transcode`.** Takes effect for **new
  playback sessions only** — restart playback after saving. Verified: during a
  1080p transcode at ~8–12 Mbps, `df -h /transcode` sawtooths between 21 and
  104 MB (Plex transcodes about a minute ahead and deletes finished segments),
  and the old default under `/config/.../Cache/Transcode` stops growing.
  **Measure with `df`, not `du`** — deleted-but-open segments still hold RAM and
  only `df` sees them.
- **Downloads temporary directory: deliberately left BLANK**, so offline-download
  conversions (whole files, potentially several GB) stay on node-local ZFS under
  `/config` and never fill the tmpfs. **Do not** point it at `/transcode` or at
  sisyphus.
- **Hardware acceleration: both checkboxes UNTICKED** until the
  [parked failure](./OPEN-QUESTIONS.md#hardware-transcoding-fails--parked) is
  fixed. With them on, changing quality freezes playback and falls back to
  direct play — which would break remote friends' transcodes. Software
  transcoding works.

### Still to do inside `media`

- **Jellyfin transcode settings** — Dashboard → Playback → Transcoding: VA-API,
  `/dev/dri/renderD128`, enable H.264 / HEVC / VP9, **leave AV1 off**, transcode
  path `/transcode`, and tick **Throttle transcodes** and **Delete segments** —
  without the last two Jellyfin keeps every segment for the whole session.
- **Resize both tmpfs mounts to ~1 GB** once measured.
- Point libraries at `/data/media/...`.
- Add aggregarr if wanted.

---

## `dns` — CT 100 on Rhea, `10.0.0.31`

### Container

Debian 13 amd64, **unprivileged**, **no nesting** (native daemons, not Docker),
2 cores, 512 MB, `swap 0`, 8 GB rootfs on `local-zfs`, `onboot 1`, static IP.

> A `WARN: Systemd 257 detected. You may need to enable nesting` at create/start
> is **benign for this workload** and was deliberately not acted on.

### unbound

Packages: `unbound`, `dns-root-data`, `dnsutils`. Config at
`/etc/unbound/unbound.conf.d/pi-hole.conf`: `interface 127.0.0.1`, `port 5335`,
IPv4 only, `harden-glue`, `harden-dnssec-stripped`, `use-caps-for-id: no`,
`edns-buffer-size 1232`, `prefetch`, plus the standard `private-address`
rebinding-protection block.

**`dns-root-data` supplies root hints**, so they are not hand-maintained.

Verified:

```bash
dig pi-hole.net @127.0.0.1 -p 5335          # NOERROR with an answer
dig sigfail.verteiltesysteme.net            # SERVFAIL
dig sigok.verteiltesysteme.net              # NOERROR with the ad flag
```

> **The `ad` flag is the real proof of DNSSEC validation.** A NOERROR without it
> proves nothing.

**`openresolv` was NOT installed** — Pi-hole's docs warn about it on Bullseye+.
Proxmox owns `/etc/resolv.conf` via its `# --- BEGIN PVE ---` block, which is
cleaner.

### Pi-hole — PRIMARY

Core **v6.4.3**, Web **v6.6**, FTL **v6.7.1**. Installed unattended — see
[build-gotchas.md](./build-gotchas.md#pi-hole-v6---unattended-is-ignored-on-a-genuinely-fresh-system),
because the documented flag does not work on a fresh system.

Upstream is `127.0.0.1#5335` **and nothing else**:

```bash
pihole-FTL --config dns.upstreams      # -> [ 127.0.0.1#5335 ]
```

`listeningMode = "LOCAL"`. Gravity built from the default StevenBlack list:
**74,761 domains**.

Verified end to end from a LAN client:

```bash
dig google.com @10.0.0.31              # resolves
dig doubleclick.net @10.0.0.31         # 0.0.0.0 with the aa flag
```

> The **`aa` flag** means the answer came authoritatively from gravity rather
> than being forwarded — that is the proof blocking is live.

### Cutover

ER605 → Network → LAN → DHCP:

| Field | Value |
|---|---|
| Primary DNS | `10.0.0.31` |
| Secondary DNS | **empty** — a secondary is not failover, it is a bypass ([D20](./DECISIONS.md)) |
| Default Gateway | blank (the router advertises itself) |
| Default Domain | blank — [the ER605 rejects a single-label domain](./build-gotchas.md#er605-dhcp-rejects-a-single-label-default-domain) |
| Lease time | 120 min |
| Pool | `.100–.254`, unchanged |

Verified on a client after lease renewal:

```bash
scutil --dns            # nameserver[0] : 10.0.0.31
dig doubleclick.net +short    # 0.0.0.0
```

> **Rollback for any DNS emergency: set the ER605's Primary DNS back to
> `10.0.0.1`.** The router answers regardless of Pi-hole's state.

Also hosts **nebula-sync** — see below.

### Local DNS records — done

Local `.lan` records live **here, on the primary**, and replicate to the replica.

| Records | Target |
|---|---|
| `rhea`, `themis`, `hestia`, `tartarus` | `.10`, `.11`, `.12`, `.20` |
| `plex`, `jellyfin`, `tautulli`, `navidrome`, `posterizarr` | `.30` |
| `pihole` | `.33` — follows the VIP |

Replication verified: `dig +short jellyfin.lan @10.0.0.32`.

> **Service names for the other LXCs are deliberately NOT added yet.** Once
> Caddy exists they should point at the proxy, not at each LXC.

---

## `dns2` + keepalived VIP + nebula-sync

### `dns2` — CT 201 on Hestia, `10.0.0.32`

Built identically to `dns`: Debian 13 amd64, unprivileged, **no nesting**,
2 cores, 512 MB, `swap 0`, 8 GB rootfs, static IP. Same Pi-hole versions
(Core 6.4.3 / Web 6.6 / FTL 6.7.1), same 74,761-domain gravity.

> **It runs its OWN unbound on `127.0.0.1#5335`.** It must **not** forward to
> Rhea's — if it did, a Rhea failure would take the replica's upstream with it
> and defeat the entire design. The replica would hold the VIP and resolve
> nothing.

**Deliberately on Hestia, not Rhea.** That separation is the whole point.

One config difference from the primary: `webserver.api.app_sudo = true`, so
nebula-sync can apply configuration through the API. Set it **after** install —
do not hand-write it into the TOML:

```bash
pihole-FTL --config webserver.api.app_sudo true
```

### keepalived — VRRP VIP at `10.0.0.33`

`apt install keepalived` on both. **Plain VRRP only — no `virtual_server`/LVS
block**, which is what needs the `ip_vs`/`xt_set` kernel modules an unprivileged
LXC cannot load.

**No special container config was needed** — no capability grants, no
`lxc.cap.drop` changes, nothing.

Configs are in [`infra/dns/`](../infra/dns/):
[`keepalived-primary.conf`](../infra/dns/keepalived-primary.conf) and
[`keepalived-replica.conf`](../infra/dns/keepalived-replica.conf).

> **The weight arithmetic is the part that is easy to get wrong.**
>
> Priority 150 with `weight -60` drops the primary to **90** on FTL failure,
> below the backup's 100, so the VIP moves.
>
> An earlier `-40` gave **110** — still above 100 — so **FTL could die while the
> primary kept the VIP and pointed every client at a dead resolver.** The health
> check was running correctly the whole time; only the arithmetic was wrong.

**Preemption is ON** (the default; no `nopreempt`). The primary reclaims the VIP
whenever it is healthy.

Accepted trade-off: an FTL restart on the primary briefly moves the VIP and moves
it back. `nopreempt` was **rejected** because silently running on the replica for
weeks is the worse failure — the replica's config is a one-way copy, so edits
made there vanish.

Verified in **all four directions**:

| Condition | Result |
|---|---|
| normal | primary holds `.33` as `secondary proto keepalived`; replica has only `.32` |
| keepalived stopped on primary | replica takes `.33` and answers queries |
| keepalived restarted | primary reclaims, replica releases |
| `pihole-FTL` stopped on primary | replica takes `.33`; on FTL restart, primary reclaims |

### DHCP cutover

ER605 → Network → LAN → DHCP: **Primary DNS `10.0.0.33`, Secondary DNS empty.**

Verified from a client with no explicit resolver:

```bash
dig doubleclick.net +short     # -> 0.0.0.0
```

### nebula-sync — on `dns`, native systemd

**nebula-sync is the Pi-hole v6 tool.** Orbital Sync is v5-era, built around the
old API and Teleporter workflow, with one repo archived in March 2025.

v0.11.2, binary from the GitHub release, installed to
`/usr/local/bin/nebula-sync`. Env template and unit file in
[`infra/dns/`](../infra/dns/).

> **`PRIMARY` is addressed as `10.0.0.31`, NOT the VIP.** Sync must always push
> *from* the real primary, never from whoever happens to hold `.33`.

The binary does its own cron scheduling, so the unit is a **long-lived daemon,
not a systemd timer**. `systemctl restart nebula-sync` forces an immediate sync.

Verified: the log shows authenticate → sync teleporters → sync configs → run
gravity → *"Sync completed"* in under a second. And `plex.lan`, added on the
primary, resolved on `10.0.0.32` after a forced sync.

> **If it restarts every 30 seconds, `PRIMARY`/`REPLICAS` are not set.** That is
> the documented behaviour for missing config, not a crash.

> **`10.0.0.31` is the only Pi-hole you edit.** Sync is one-way; anything changed
> on the replica is overwritten within the hour. See [D27](./DECISIONS.md).

---

## `monitor` — CT 202 on Hestia, `10.0.0.34`

### Container

Debian 13 amd64, unprivileged, `nesting=1,keyctl=1`, 2 cores, 2048 MB, `swap 0`,
16 GB rootfs, `onboot 1`, static IP. Docker **29.8.2**.

> **`nameserver 10.0.0.1` — the deliberate Pi-hole bypass.** Monitoring must
> still alert when Rhea is down, so `monitor` is the one LXC that does not use
> the DNS VIP.

### Stack

`/opt/stacks/monitor/compose.yaml`, mirrored at
[`stacks/monitor/compose.yaml`](../stacks/monitor/compose.yaml). Configs under
`/opt/appdata/monitor/<service>`; credentials in an uncommitted
`/opt/stacks/monitor/.env` (mode `600`).

**Versions as pulled and verified 2026-10-01:**

| Service | Image | Version | Port (host:container) |
|---|---|---|---|
| uptime-kuma | `louislam/uptime-kuma` | **`2.5.0`** (was `1.23.17`) | 3001:3001 |
| beszel | `henrygd/beszel` | `0.20.0` | 8090:8090 |
| ntfy | `binwiederhier/ntfy` | `v2.28.0` | 8080:8080 |
| wud | `ghcr.io/getwud/wud` | `9.2.1` | 3000:3000 |
| dozzle | `amir20/dozzle` | `v11.1.3` | **8888:8080** |

**Uptime Kuma 1 → 2 migration (done).** `1.23.17` was the old 1.x line, pinned
because **`:latest` still pointed at it while 2.x was current** — see
[build-gotchas.md](./build-gotchas.md#latest-can-lag-a-whole-major-version).
Migrated in place with the major-upgrade procedure in
[update-discipline.md](./update-discipline.md): `pct snapshot 202 pre-kuma2`,
change the tag, `docker compose up -d uptime-kuma`, watch the logs through the
migration, verify monitors and notifications, `pct delsnapshot 202 pre-kuma2`.

Database stays **SQLite** — MariaDB, 2.x's headline feature, targets far larger
deployments. 2.x also patched a **LiquidJS remote-code-execution issue in
notification templates** (fixed in 2.4.0), so **stay at or above 2.4.0**.

**ntfy** runs with `NTFY_AUTH_DEFAULT_ACCESS=deny-all`. It **defaults to fully
open**, so without this anyone who can reach it could publish to or subscribe to
alert topics. Create a user after first start:

```bash
docker exec -it ntfy ntfy user add --role=admin <name>
```

**wud** requires `WUD_AUTH_ADMIN_USER` and `WUD_AUTH_ADMIN_PASSWORD` **or it
refuses to start**. Supplied via `env_file: .env`. It watches the local Docker
socket by default — no watcher config needed.

**wud** watches the local Docker socket by default — **which means it sees only
`monitor`'s containers, not `media`, `arr` or `grab`.**
[Open](./OPEN-QUESTIONS.md#wud-only-watches-monitors-docker-daemon); until it is
fixed, `scripts/check-versions.sh` is the stopgap.

**dozzle** needs `/opt/appdata/monitor/dozzle:/data` mounted **or its users and
settings are lost on every recreate**. Server mode, with
`DOZZLE_REMOTE_AGENT=10.0.0.30:7007,10.0.0.35:7007,10.0.0.36:7007` — agents in
`media`, `arr` and `grab`, each setting its own `DOZZLE_HOSTNAME`.

> **Actions and shell are deliberately NOT enabled.** Dozzle is a log viewer;
> enabling them turns it into a remote control for every connected Docker
> daemon, duplicates `docker compose` from the host shell where the repo is the
> source of truth ([D9](./DECISIONS.md)), and is premature while the auth layer
> is unsolved.

### Beszel agents — native systemd on all three PVE nodes

**Not in containers.** An agent inside an LXC reports that container's slice, not
the node. Installed with the hub's own generated command (the `get.beszel.dev`
script), port 45876, one token per host. **Auto-updates declined** —
[update-discipline.md](./update-discipline.md).

> **Gotcha that cost time: the hub's add-system dialog must be SAVED before its
> token is valid.** Closing it without clicking Add generates a command whose
> token the hub has no record of, and the agent loops on
> `WebSocket connection failed err="unexpected status code: 401"` with no further
> detail.
>
> Fix: add the system properly, then replace the `Environment="TOKEN=..."` line
> in `/etc/systemd/system/beszel-agent.service`, `daemon-reload`, restart.
>
> A 401 immediately at agent start followed by a successful connect ten seconds
> later is **normal**.

**`sda` on Rhea and Hestia is CORRECT** — corrected 2026-10-03. Both boot from
**M.2 SATA**, not NVMe. The agent logs `WARN Using most active device for root
I/O ... device=sda` only because a ZFS root is not a block device, so it picks
the disk itself; Themis correctly shows `nvme0n1`.

> **Deliberately no `FILESYSTEM` override.** `sdX` names can change at boot once
> a 2.5" bay is filled, so a hard-coded name could become wrong. Revisit when a
> second disk goes in.

`no valid SMART data found` is **expected** — the sandboxed agent lacks the
privileges.

### Uptime Kuma monitors to create

| Type | Target | Why |
|---|---|---|
| **DNS** (native type, not HTTP) | `10.0.0.31`, `10.0.0.32` | Tells you *which* Pi-hole is unhealthy |
| **DNS** | `10.0.0.33` | Whether clients can resolve at all — should stay green *through* a failover |
| **DNS** | `plex.lan` against `.32` specifically | Catches a replica that resolves public names but has silently lost its local records — the failure nebula-sync could produce. Optionally add a Condition requiring the answer to equal `10.0.0.30`, which also catches a wrong record |
| HTTP | Plex, Jellyfin, Tautulli, Navidrome, Posterizarr, Beszel, wud | |
| HTTP-keyword `OK` on `/ping` | Prowlarr, Radarr, Sonarr | Unauthenticated health endpoint — avoids the login redirect |
| HTTP | SABnzbd `:8080`, Bazarr `:6767`, Audiobookshelf `:13378/healthcheck`, abs-arr `:8788`, Reclaimerr `:8000` | |
| HTTP | qBittorrent `:8080`, JDownloader `:5800`, MeTube `:8081` | |
| Ping | Rhea `.10`, Themis `.11`, Hestia `.12`, Tartarus `.20` | The Hestia ping is largely a placeholder — see the blind spot below |

**Not monitored, deliberately:** **Byparr** (unpublished; Prowlarr flags tagged
indexers if it dies) and **Recyclarr** (no UI — check its log after daily runs).

60s interval throughout.

**Notifications.** **Telegram is the off-network channel** — it leaves the
network entirely, so alerts survive an ntfy outage; ntfy stays the everyday hub.
Both marked Default. **Telegram verified delivering and attached to every
monitor.**

> **Remaining blind spot: Kuma cannot report its own host's death.** Kuma and
> its notification sender both run on Hestia, so if Hestia itself dies, nothing
> alerts — **Telegram included**. Closing this needs something *outside* Hestia
> that expects regular heartbeats and alerts when they stop, e.g.
> Healthchecks.io's free tier.
> [Open](./OPEN-QUESTIONS.md#hestia-down-blind-spot-in-monitoring).

---

## sisyphus host mounts — all three nodes

`/etc/fstab` on Rhea, Themis and Hestia:

```
10.0.0.20:/mnt/tartarus/sisyphus  /mnt/sisyphus  nfs  vers=4.2,_netdev,noatime,hard,x-systemd.requires=network-online.target  0  0
```

`nfs-common` is already present on PVE 9. Run `systemctl daemon-reload` after
editing.

Verified: `downloads/`, `media/`, `shared/` all owned `3004:3004`, mode
`drwx------` with NFSv4 ACLs (`+`).

> **The restrictive mode is why the idmap is mandatory.** Only UID 3004 exactly
> gets in, so any container running as a different PUID sees nothing at all.

NFS export paths, confirmed on the box:
`10.0.0.20:/mnt/tartarus/sisyphus` and `10.0.0.20:/mnt/tartarus/tantalus`.

> **Ordering hazard.** If the NFS mount is not up when Proxmox starts a
> container at boot, the bind mount hands the guest an **empty local directory**
> and writes land on node-local disk instead of the NAS.
> `x-systemd.requires=network-online.target` helps — **verify after the next
> reboot of each node rather than trusting it.**

### Share cleanup

Deleted from the share during rev 8:

- the stale `appdata/` tree — **403 MB** across `asteria`, `atlas` and `io`,
  left over from the abandoned config-on-NFS convention ([D11](./DECISIONS.md))
- a `dev/` directory — a container `/dev` skeleton written to NFS by a
  misdirected bind mount in Aug 2024
- an empty top-level `media/audiobooks/` — the real library path is
  `/mnt/sisyphus/media/audio/audiobooks`

**The live layout now matches the documented one:** `downloads/`, `media/`,
`shared/` and nothing else.

---

## `arr` — CT 300 on Themis, `10.0.0.35`

### Container

Debian 13 amd64 (`debian-13-standard_13.6-1_amd64` from `tantalus`),
unprivileged, `nesting=1,keyctl=1`, 4 cores, 6144 MB, `swap 0`, 32 GB rootfs on
`local-zfs`, `onboot 1`, static IP, `nameserver 10.0.0.33`, `searchdomain lan`.
Docker **29.8.2**. Container timezone set to `America/Toronto` — **the template
default is UTC.**

```bash
pct create 300 tantalus:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname arr --unprivileged 1 --features nesting=1,keyctl=1 \
  --cores 4 --memory 6144 --swap 0 --rootfs local-zfs:32 \
  --net0 name=eth0,bridge=vmbr0,ip=10.0.0.35/24,gw=10.0.0.1 \
  --nameserver 10.0.0.33 --searchdomain lan --onboot 1 \
  --mp0 /mnt/sisyphus,mp=/mnt/sisyphus \
  --mp1 /themis-500/incomplete,mp=/mnt/incomplete
# then append the idmap block to /etc/pve/lxc/300.conf BEFORE the first start
```

Same six `lxc.idmap` lines as `media`; Themis's host got `root:3004:1` in
`/etc/subuid` and `/etc/subgid`. Verified: `ls -ln` on **both** mounts shows
numeric `3004 3004` inside the container.

### Stack

Live at `/opt/stacks/arr/compose.yaml`, mirrored at
[`stacks/arr/compose.yaml`](../stacks/arr/compose.yaml). Configs under
`/opt/appdata/arr/<service>` owned 3004; every linuxserver service `PUID=3004`,
`PGID=3004`, `TZ=America/Toronto`.

| Service | Image | Version | Port | Mounts besides `/config` |
|---|---|---|---|---|
| prowlarr | `lscr.io/linuxserver/prowlarr` | `2.6.5.5623-ls162` | 9696 | — |
| radarr | `lscr.io/linuxserver/radarr` | *see note* | 7878 | `/mnt/sisyphus:/data` |
| sonarr | `lscr.io/linuxserver/sonarr` | *see note* | 8989 | `/mnt/sisyphus:/data` |
| sabnzbd | `lscr.io/linuxserver/sabnzbd` | `5.1.3-ls275` | 8080 | `/mnt/sisyphus:/data`, `/mnt/incomplete/sabnzbd:/incomplete-downloads` |
| byparr | `ghcr.io/thephaseless/byparr` | *see note* | — (8191 internal) | — |
| recyclarr | `ghcr.io/recyclarr/recyclarr` | *see note* | — | `user: 3004:3004`, `CRON_SCHEDULE=@daily` |
| bazarr | `lscr.io/linuxserver/bazarr` | *see note* | 6767 | `/mnt/sisyphus/media:/data/media` |
| audiobookshelf | `ghcr.io/advplyr/audiobookshelf` | `2.37.1` | 13378 | `/metadata` local; `/mnt/sisyphus/media:/data/media` |
| abs-arr | `ghcr.io/nana-boateng/abs-arr` | `0.2.1` | 8788 | `/mnt/sisyphus:/data` |
| reclaimerr | `ghcr.io/jessielw/reclaimerr` | *see note* | 8000 | none (`/app/data` only) |
| dozzle-agent | `amir20/dozzle` | `v11.1.3` | 7007 | docker socket `:ro` |

> **Six tags are marked `PIN-ME` in the repo compose** because they were not
> recorded. Read them off the live host and replace them there *and* in
> `scripts/check-versions.sh`:
> ```bash
> pct exec 300 -- docker inspect -f '{{index .Config.Labels "build_version"}}' <image>
> ```

### Wiring

**Prowlarr Apps:** Radarr `http://radarr:7878`, Sonarr `http://sonarr:8989`
(Full Sync), **abs-arr added as a Readarr app** `http://abs-arr:8788`.

**Download clients** in Radarr/Sonarr: SABnzbd `sabnzbd:8080`, categories
`movies` / `tv`. **qBittorrent is NOT connected to Radarr/Sonarr yet** — they
will use `qbittorrent-vpn` ([D30](./DECISIONS.md)).

Bazarr connects to `sonarr` and `radarr` by name; **set the languages profile as
default before connecting.** Every web UI uses Forms authentication required for
**all** addresses — not "disabled for local".

**Root folders:** Radarr `/data/media/video/movies`, Sonarr
`/data/media/video/tv`. Stock quality profiles deleted after the Recyclarr sync;
existing titles brought in with Library Import, profile chosen per title.

**Byparr** is added in Prowlarr as a "FlareSolverr" proxy with tag
`flaresolverr`, applied **only** to Cloudflare-protected indexers.

### SABnzbd restore

From `sabnzbd_backup_4.3.3_2025.01.27_10.29.27.zip`. **Only `sabnzbd.ini` was
restored** — `history1.db`, `totals10.sab` and `rss_data.sab` were left out
because they carry old paths. Copied into `/opt/appdata/arr/sabnzbd/` **before
the first start**; SAB 5.1.3 then converted the 4.3.3 config.

Fixes needed afterwards, **with SAB stopped**:

| Setting | Change |
|---|---|
| `port` | `7777` → `8080` — the restored config listened on 7777 while compose mapped 8080 |
| `download_dir` | → `/incomplete-downloads` |
| `complete_dir` | → `/data/downloads/usenet/complete` |
| `dirscan_dir` | left empty — the watch folder was never used |
| `host_whitelist` | **add `sabnzbd`** or the arr apps are rejected by container name |
| ownership | `chown 3004:3004 sabnzbd.ini` after editing |

All four news servers tested OK. Their *"expiring in -310 days"* warnings were
**stale expiry dates in SAB's own settings, not real expiries** — clear the date
fields.

### Verified

Indexers sync from Prowlarr to both apps; Byparr serves tagged indexers; a
Usenet grab downloaded to `themis-500`, completed to `usenet/complete/movies`,
and was **moved** into `video/movies` — **link count 1, by design**, because
Usenet has nothing to seed ([D32](./DECISIONS.md)).

**The torrent hardlink test waits for `qbittorrent-vpn`.**

---

## `grab` — CT 301 on Themis, `10.0.0.36`

### Container

As `arr` except: hostname `grab`, **8192 MB**, 16 GB rootfs, IP `10.0.0.36`.
Same two mounts and idmap. Docker 29.8.2, timezone `America/Toronto`.

**Memory was raised from 4096 to 8192**: hundreds of torrents seed permanently,
plus JDownloader's JVM and MeTube.

Pending for gluetun: **`/dev/net/tun` passthrough** ([D30](./DECISIONS.md)).

### Stack

Live at `/opt/stacks/grab/compose.yaml`, mirrored at
[`stacks/grab/compose.yaml`](../stacks/grab/compose.yaml).

| Service | Image | Version | Ports | Mounts besides `/config` |
|---|---|---|---|---|
| qbittorrent | `lscr.io/linuxserver/qbittorrent` | `5.2.4_v2.0.15-ls479` | 8080, 6881 tcp+udp | `/mnt/sisyphus:/data`, `/mnt/incomplete/qbittorrent:/incomplete` |
| jdownloader | `jlesage/jdownloader-2` | *see note* | 5800 | `downloads/direct/jdownloader:/output` |
| metube | `ghcr.io/alexta69/metube` | *see note* | 8081 | `downloads/direct/metube:/downloads`; state + temp node-local |
| dozzle-agent | `amir20/dozzle` | `v11.1.3` | 7007 | docker socket `:ro` |

**Port 6881 TCP+UDP is forwarded on the ER605** to `10.0.0.36` — standalone UI:
Transmission → NAT → Virtual Servers.

### qBittorrent settings

- Web UI credentials **changed from the temporary password printed in the log**.
- Default save path `/data/downloads/torrents/complete`, incomplete in
  `/incomplete`, torrent management **Automatic**.
- Queueing: **5 active downloads** (sensible for the HDD scratch disk) and
  **unlimited active uploads and torrents (`-1`)**. Queued torrents do not seed,
  and private trackers count that against you — a cap of 20 would have stopped
  everything past the 20th torrent.
- **~1000 global connections**, ~50 per torrent; raise if peers are refused.
- Disk cache: the old "~1024 MiB" setting probably **does not exist** in
  libtorrent 2.x builds (the OS caches instead) — verify in Advanced and drop the
  line if absent.
- Connectable check: **green globe in the status bar.**

> **Started from scratch** — no old config or `BT_backup` survived, so the **154
> MyAnonymouse seeds** in `torrents/00-myanonymouse` must be re-added and
> rechecked. **Seeding time is accruing as downtime until that is done.**

**VueTorrent** is installed **manually from its release zip** into
`/config/vuetorrent` and set as the alternative Web UI — **not** via the
linuxserver mod, which pulls the newest version on every start. It therefore
never self-updates: record the installed version.

**JDownloader:** default download folder `/output`; `WEB_AUTHENTICATION` login in
front of the GUI (if the image version lacks it, `10.0.0.36:5800` joins the
unauthenticated list). It **self-updates its own core at runtime** by design; the
image stays pinned.

**MeTube:** `DOWNLOAD_DIR=/downloads`, `STATE_DIR=/state`, `TEMP_DIR=/tmp-dl`,
`UID`/`GID` 3004.

---

## `themis-500` cleanup

```bash
zfs rename themis-500/downloads themis-500/incomplete
zfs destroy themis-500/transcode        # transcode is tmpfs now
```

Pool is now `themis-500` plus `themis-500/incomplete`, mounted at
`/themis-500/incomplete`.

> **`/themis-500/incomplete` is owned `root:root`.** qBittorrent runs as 3004
> and **will not be able to write there.** Set ownership when `grab` is built,
> so the whole path can be verified end to end.

---

## Node search domain

Rhea's node-level search domain was found set to **`an`**, not `lan`, and every
guest created on it inherited the typo. Corrected via GUI *System → DNS*.
Hestia was already correct. **Themis is unchecked.**

Containers pick up a corrected node search domain **only on restart**, not on
`pct set`.
