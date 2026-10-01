# Build Record

What has actually been built and verified, with the commands that proved it.
**Reproduce from here, not from memory.**

Read [build-gotchas.md](./build-gotchas.md) before building the next LXC — it is
the higher-value page of the two.

Status against the [service architecture](./service-architecture.md):
**2 of 11 LXCs built.**

| LXC | Node | IP | Status |
|---|---|---|---|
| `media` | Hestia | `10.0.0.30` | **Live** |
| `dns` | Rhea | `10.0.0.31` | **Live** |
| `monitor` | Hestia | — | Next |
| `proxy`, `tailscale`, `omada` | Rhea | — | Not built |
| `apps`, `immich` | Hestia | — | Not built |
| `arr`, `grab`, `sandbox`, `homeassistant` | Themis | — | Not built |

---

## `media` — CT 200 on Hestia, `10.0.0.30`

### Container

Debian 13 (trixie) amd64, **unprivileged**, `nesting=1,keyctl=1`, 4 cores,
8192 MB, `swap 0`, 32 GB rootfs on `local-zfs`, `onboot 1`, static IP in the
container config.

> **`nameserver` is still `10.0.0.1` and should now be `10.0.0.31`** — `dns` is
> live and `media` is an ordinary client. Only `monitor` keeps the bypass.
> `pct set 200 --nameserver 10.0.0.31`, then restart.

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

### Pi-hole

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

### Still to do inside `dns`

**Local `.lan` DNS records** for split-horizon ([D20](./DECISIONS.md)) so
`plex.lan` and friends resolve internally. **Not yet added.**

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
