# Build Record

What has actually been built and verified, with the commands that proved it.
**Reproduce from here, not from memory.**

Read [build-gotchas.md](./build-gotchas.md) before building the next LXC — it is
the higher-value page of the two.

Status against the [service architecture](./service-architecture.md):
**5 of 11 LXCs built.** The DNS single point of failure is **closed**.

| LXC | CT | Node | IP | Status |
|---|---|---|---|---|
| `media` | 200 | Hestia | `10.0.0.30` | **Live** |
| `dns` | 100 | Rhea | `10.0.0.31` | **Live** — Pi-hole primary |
| `dns2` | 201 | Hestia | `10.0.0.32` | **Live** — Pi-hole replica |
| — | — | floating | **`10.0.0.33`** | **Live** — keepalived VIP, what DHCP advertises |
| `monitor` | 202 | Hestia | `10.0.0.34` | **Live** |
| `proxy`, `tailscale`, `omada` | | Rhea | — | Not built |
| `apps`, `immich` | | Hestia | — | Not built |
| `arr`, `grab`, `sandbox`, `homeassistant` | | Themis | — | Not built |

Native LXC configuration (keepalived, unbound, nebula-sync) is in
[`infra/dns/`](../infra/dns/).

---

## `media` — CT 200 on Hestia, `10.0.0.30`

### Container

Debian 13 (trixie) amd64, **unprivileged**, `nesting=1,keyctl=1`, 4 cores,
8192 MB, `swap 0`, 32 GB rootfs on `local-zfs`, `onboot 1`, static IP in the
container config.

> **`nameserver` is still `10.0.0.1` and should now be the VIP `10.0.0.33`** —
> `media` is an ordinary client. Only `monitor` keeps the bypass.
> `pct set 200 --nameserver 10.0.0.33`, then restart. **Still outstanding.**

### GPU passthrough

Host: `/dev/dri/renderD128` is `226:128`, host `render` group is GID **993**.
**The container's own `render` group is GID 992.** Read it; never assume they
match:

```bash
pct exec 200 -- getent group render
pct set 200 -dev0 /dev/dri/renderD128,gid=992,mode=0660
```

**`renderD128` only — never `card0`/`card1`.**

Verified with `vainfo`, after installing `vainfo` and
`intel-media-va-driver-non-free`:

- **H.264** Main / High
- **HEVC** Main / Main10 / Main422_10 / Main444 / Main444_10
- **VP9** profiles 0–3
- VC1, MPEG2, JPEG
- both `VLD` (decode) **and** `EncSliceLP` (encode) entrypoints

**No AV1** — exactly as the hardware inventory predicted. Jasper Lake predates
Intel's Gen-12 AV1 decode.

The device appears correctly inside the Plex and Jellyfin containers. The group
shows as a bare `992` there because neither image defines a `render` group —
**cosmetic; the numeric GID is what matters.**

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

### Still to do inside `media`

1. **Enable hardware transcoding in each app** — it is **off by default**, so
   the passthrough does nothing until it is switched on:
   - **Jellyfin:** Dashboard → Playback → Transcoding → VA-API,
     `/dev/dri/renderD128`; enable H.264 / HEVC / VP9, **leave AV1 off**.
   - **Plex:** Settings → Transcoder → enable hardware transcoding, temporary
     directory `/transcode`.
2. Point libraries at `/data/media/...`.
3. Confirm with a forced transcode — **Tautulli shows the decision.**
4. Add aggregarr if wanted.

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

### Local DNS records

Local `.lan` records live **here, on the primary**, and replicate to the
replica. Added so far: **`plex.lan → 10.0.0.30`**.

Still outstanding: jellyfin, tautulli, navidrome, posterizarr (all `.30`),
`pihole.lan → .33` (follows the VIP), and the four hosts — `rhea .10`,
`themis .11`, `hestia .12`, `tartarus .20`.

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
| uptime-kuma | `louislam/uptime-kuma` | `1.23.17` | 3001:3001 |
| beszel | `henrygd/beszel` | `0.20.0` | 8090:8090 |
| ntfy | `binwiederhier/ntfy` | `v2.28.0` | 8080:8080 |
| wud | `ghcr.io/getwud/wud` | `9.2.1` | 3000:3000 |
| dozzle | `amir20/dozzle` | `v11.1.3` | **8888:8080** |

**ntfy** runs with `NTFY_AUTH_DEFAULT_ACCESS=deny-all`. It **defaults to fully
open**, so without this anyone who can reach it could publish to or subscribe to
alert topics. Create a user after first start:

```bash
docker exec -it ntfy ntfy user add --role=admin <name>
```

**wud** requires `WUD_AUTH_ADMIN_USER` and `WUD_AUTH_ADMIN_PASSWORD` **or it
refuses to start**. Supplied via `env_file: .env`. It watches the local Docker
socket by default — no watcher config needed.

**dozzle** needs `/opt/appdata/monitor/dozzle:/data` mounted **or its users and
settings are lost on every recreate**. Server mode, with
`DOZZLE_REMOTE_AGENT=10.0.0.30:7007` pointing at the agent in `media`.

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

**Known-wrong metric:** the agent logs
`WARN Using most active device for root I/O ... device=sda` on **Rhea and
Hestia**, both of which boot from NVMe — so their disk I/O figures are
misleading. Themis correctly detected `nvme0n1`. Fix by setting `FILESYSTEM` in
the service file; [open](./OPEN-QUESTIONS.md#beszel-filesystem-override-on-rhea-and-hestia).

`no valid SMART data found` is **expected** — the sandboxed agent lacks the
privileges, and `sda` is the wrong device on two of three anyway.

### Uptime Kuma monitors to create

| Type | Target | Why |
|---|---|---|
| **DNS** (native type, not HTTP) | `10.0.0.31`, `10.0.0.32` | Tells you *which* Pi-hole is unhealthy |
| **DNS** | `10.0.0.33` | Whether clients can resolve at all — should stay green *through* a failover |
| **DNS** | a `.lan` name against `.32` specifically | Catches a replica that resolves public names but has silently lost its local records — the failure nebula-sync could produce |
| HTTP | each media service | |
| Ping | the four hosts | |
| HTTP | Beszel, wud | |

60s interval is plenty.

> **The off-Hestia notification path is still outstanding, and it is the piece
> that makes this layer meaningful.** Kuma and ntfy both live on Hestia, so a
> Hestia failure kills the alert and the alerting system together. Kuma needs a
> second channel that leaves the network entirely — email, Discord, Pushover —
> with ntfy kept as the everyday hub.
> [Open](./OPEN-QUESTIONS.md#uptime-kuma-off-hestia-notification-path).

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
