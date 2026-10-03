# Build Gotchas

**Read this before building any further LXC.** Each item below cost real time
during the `media` and `dns` builds.

Related: [build-record.md](./build-record.md) — what was actually built ·
[service-architecture.md](./service-architecture.md) — what is left to build

---

## Verify current versions; never pin from a guide or from memory

**Every image tag and install instruction assumed at the start of the `media`
and `dns` build was stale.** Not some — every one. The `monitor` build found the
same again.

Pull `:latest` once, read the version off the image, then pin that:

```bash
docker inspect -f '{{ index .Config.Labels "build_version" }}' \
  lscr.io/linuxserver/<image>:latest

docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' \
  <image>:latest
```

**Not every image carries a version label**, so have a fallback ready:

| Image | How to read its version |
|---|---|
| `louislam/uptime-kuma` | no label — read `/app/package.json` |
| `binwiederhier/ntfy` | no label — `docker run --rm <img> --version` |

**And the reported version is not always the tag.** ntfy reports `2.28.0` while
the tag is `v2.28.0`. Likewise **Beszel, Navidrome, Audiobookshelf and Recyclarr
Git tags carry a `v` their image tags do not** — if a pull of the Git tag fails,
try it without the `v`.

This applies to install procedures too, not only tags. The Pi-hole and Docker
install steps both differed from what the guides said.

---

## Projects move

`fmartinou/whats-up-docker` is now **`ghcr.io/getwud/wud`**.

Check the image's `org.opencontainers.image.source` label for the project's real
home before pinning something that may be unmaintained:

```bash
docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.source" }}' <image>:latest
```

---

## CT templates: check the architecture

`pveam available` lists **arm64 builds alongside amd64**, and the GUI picker
makes them easy to mis-click. An arm64 template on an N5095 fails at
`pct create`.

```bash
pveam list <storage>    # before creating anything
```

---

## Debian 13 templates ship `Components: contrib main`

Enabling non-free therefore means **rewriting the whole line, not appending to
`main`** — and the file is deb822 format, not the old one-line style:

```bash
sed -i -E 's/^Components:.*/Components: main contrib non-free non-free-firmware/' \
  /etc/apt/sources.list.d/debian.sources
```

**Symptom if missed:** `intel-media-va-driver-non-free` reports *"has no
installation candidate"*, and the `Get:` lines during `apt update` show only
`main` and `contrib`.

---

## `lxc.mount.entry` with tmpfs into an idmapped unprivileged container fails silently

Tried with and without `create=dir`, with the target pre-created and chowned.
**Proxmox accepts the line, `pct config` displays it, and the mount simply never
appears** — `df` reports the rootfs instead. No error anywhere.

**Use Docker-level `tmpfs:` in the compose instead.** It also scopes the scratch
to the containers that actually need it, rather than every process in the LXC:

```yaml
    tmpfs:
      - /transcode:rw,size=4g,uid=3004,gid=3004
```

---

## Multi-line heredocs through `pct exec` are fragile

Several failed outright. In one case **the directory, the config file and the
install command were all consumed as heredoc input and nothing ran at all** —
with no error.

**Prefer `pct enter` plus an editor for anything multi-line**, and always `cat`
the file back before depending on it.

---

## Node search domain propagates to containers only on restart

`pct set <id> --searchdomain lan` **does not rewrite `/etc/resolv.conf` on a
running guest.** PVE regenerates that block at container start.

Also check the node's own *System → DNS*: **Rhea's was set to `an`, not `lan`**,
and every guest created on it inherited the typo.

---

## Pi-hole v6 `--unattended` is ignored on a genuinely fresh system

The installer decides "fresh install" from the **absence** of
`/etc/pihole/setupVars.conf` or `pihole.toml` — and on that path it shows
whiptail dialogs regardless of the flag.

**Pre-create the config first.** This also sets the unbound upstream in one
step, so there is no second pass:

```bash
mkdir -p /etc/pihole
cat > /etc/pihole/pihole.toml <<'TOML'
[dns]
  upstreams = ["127.0.0.1#5335"]
  listeningMode = "LOCAL"
TOML
curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended
pihole setpassword
```

> **Keep that pre-seeded TOML minimal.** A `[webserver]` stanza with
> `api.app_sudo = true` written by hand produced a config **the installer would
> not start from**. Set that key *after* install, which writes whatever shape
> FTL actually wants:
>
> ```bash
> pihole-FTL --config webserver.api.app_sudo true
> ```
>
> (`dns2` needs that key so nebula-sync can apply config through the API.)

**Interactive install is not a workaround here.** Whiptail renders as an empty
blue box and exits in the Proxmox web shell, and the installer also exits at its
*"Static IP Needed"* dialog inside a Proxmox LXC — PVE configures the network, so
the installer finds nothing it recognises. This reproduced in Warp and kitty over
SSH as well, so it is **not** a terminal-rendering problem.

---

## Pi-hole paths and commands

- The `pihole` wrapper installs to **`/usr/local/bin`**, which is **not on
  root's default PATH in an LXC**.
- `pihole-FTL` is in **`/bin`**.
- The cache-flush command is **`pihole reloaddns`**. There is no `restartdns`.

> **FTL caches forwarded answers.** A domain queried *before* gravity was
> consulted keeps resolving until the cache is flushed. **Flush before
> concluding that blocking is broken** — otherwise you will debug a working
> system.

---

## ER605 DHCP rejects a single-label Default Domain

Both `lan` and `.lan` fail validation — *"Invalid domain format"*. The field
wants at least one dot. **It was left blank.**

**Consequence: the `.lan` search domain cannot be advertised via DHCP on this
router.** Two ways out, and neither is an improvisation:

- set the search domain per-client, or
- change the scheme to a two-label name such as `home.lan` — which would change
  **every local DNS record and every Caddy hostname**, and must therefore be a
  deliberate repo decision.

Tracked in [OPEN-QUESTIONS.md](./OPEN-QUESTIONS.md#er605-cannot-advertise-a-single-label-search-domain).

---

## Client-side DNS overrides defeat the cutover silently

A Mac with `1.1.1.1` set manually in network settings **never reached Pi-hole**.
`dig` against the Pi-hole IP directly looked perfect, while ordinary resolution
bypassed it entirely — the two tests disagree, and only one of them reflects
what the client actually does.

This is exactly what the **CRS310 NAT rules** in [DECISIONS.md](./DECISIONS.md)
D20 exist to prevent, and **they are still unbuilt**.

When verifying a DNS cutover, test the resolver the client *chose*, not the one
you hoped it chose:

```bash
scutil --dns | head            # macOS: what the client actually uses
dig doubleclick.net +short     # no @server — exercises the real path
```

---

## Unprivileged containers need an idmap to use the NFS share

The `sisyphus` export is mode `drwx------` owned `3004:3004`, so **only UID 3004
exactly** can read it. In an unprivileged container, UID 3004 inside maps to
103004 outside by default — which the NAS rejects.

Host, once per node:

```bash
echo 'root:3004:1' >> /etc/subuid
echo 'root:3004:1' >> /etc/subgid
```

Then in `/etc/pve/lxc/<id>.conf`, **with the container stopped**:

```
lxc.idmap: u 0 100000 3004
lxc.idmap: u 3004 3004 1
lxc.idmap: u 3005 103005 62531
lxc.idmap: g 0 100000 3004
lxc.idmap: g 3004 3004 1
lxc.idmap: g 3005 103005 62531
```

Verify — the numbers must be `3004 3004`, not `nobody` and not `103004`:

```bash
pct exec <id> -- ls -ln /mnt/sisyphus
```

A `/dev/dri` passthrough survives the idmap unchanged.

> **Hestia has this. Themis does not**, and needs it before `arr` or `grab` are
> built.

---

## NFS-before-container ordering at boot

If the NFS mount is not up when Proxmox starts a container at boot, **the bind
mount hands the guest an empty local directory** — and writes land on node-local
disk instead of the NAS. Silently.

`x-systemd.requires=network-online.target` in the fstab line helps. **Verify it
after the next reboot of each node rather than trusting it.**

---

## keepalived in an unprivileged LXC: plain VRRP only

`apt install keepalived` works and **needs no special container configuration** —
no capability grants, no `lxc.cap.drop` changes.

But **omit any `virtual_server` / LVS block.** That is the part that needs the
`ip_vs` and `xt_set` kernel modules, which an unprivileged LXC cannot load. Plain
VRRP with a `virtual_ipaddress` is all a floating IP requires.

### The weight arithmetic is the real trap

A `vrrp_script` weight has to actually push the priority *below* the backup's:

```
priority 150, weight -60  ->  90  < 100   VIP moves      correct
priority 150, weight -40  ->  110 > 100   VIP stays      WRONG
```

With `-40`, **FTL could die while the primary kept the VIP and pointed every
client at a dead resolver.** The health check was running correctly the whole
time — only the arithmetic was wrong, and nothing in the logs says so.

Test all four directions, not just one: stop keepalived, restart it, stop the
*watched process*, restart that. The third is the one that catches a bad weight.

---

## Dozzle listens on 8080 internally, not 8888

Map `8888:8080`.

**Symptom of getting it wrong:** container reports healthy, `docker ps` shows
`8080/tcp` unpublished, the UI is unreachable, and the log cheerfully says
`Accepting connections on :8080`.

**Dozzle also needs `/data` mounted**, or its users and settings are lost on
every recreate.

---

## Services that default to wide open, or refuse to start

Two opposite failure modes, both worth knowing before first run:

| Service | Behaviour |
|---|---|
| **ntfy** | **Defaults to fully open.** Without `NTFY_AUTH_DEFAULT_ACCESS=deny-all`, anyone who can reach it can publish to or subscribe to your alert topics |
| **wud** | **Refuses to start** without `WUD_AUTH_ADMIN_USER` and `WUD_AUTH_ADMIN_PASSWORD` |

---

## Beszel: the add-system dialog must be SAVED before its token is valid

Closing the hub's add-system dialog without clicking **Add** still gives you a
copyable install command — but the hub has **no record of that token**.

The agent then loops on:

```
WebSocket connection failed err="unexpected status code: 401"
```

with no further detail, which reads like a networking or firewall problem and is
not one.

**Fix:** add the system properly, then replace the `Environment="TOKEN=..."` line
in `/etc/systemd/system/beszel-agent.service`, `daemon-reload`, restart.

> A 401 immediately at agent start, followed by a successful connect about ten
> seconds later, is **normal**. Do not chase it.

**Beszel agents belong native on the node, not in an LXC** — an agent inside a
container reports that container's slice rather than the host.

Expect `no valid SMART data found`: the sandboxed agent lacks the privileges.
And check which device it picked for root I/O — on Rhea and Hestia it guessed
`sda` on NVMe-booting machines, making those figures misleading.

---

## `:latest` can lag a whole major version

Uptime Kuma's `:latest` gave **`1.23.17` while `2.5.0` was the current
release** — most likely kept on 1.x deliberately so existing installs don't hit a
database migration on their next pull.

**Reading the version off a `:latest` image only tells you what `:latest` points
to, not what is newest.** When the image and the releases page disagree, **the
releases page wins**: find the right tag, and treat a major-version jump as a
**migration** ([update-discipline.md](./update-discipline.md)), not an ordinary
pull.

Check every pin before building on it:

```bash
scripts/check-versions.sh            # all stacks
scripts/check-versions.sh arr grab   # just those
```

Notes on that script: `releases/latest` skips pre-releases; an empty "latest"
means no formal GitHub releases or the unauthenticated rate limit (60/hour, set
`GITHUB_TOKEN` to raise it). **For linuxserver images, a higher `-lsNN` with the
same app version is a rebuild of the same app, not a new release.**

---

## GPU device group in an idmapped LXC

linuxserver images normally add `abc` to the GPU device's group at startup.
**Inside an idmapped unprivileged LXC this does not happen**, so `abc` (3004)
could not open `renderD128` owned by group 992 — it could see the device but not
open it.

**Pass the device with `gid=3004` instead**, matching the UID every service in
the stack runs as.

Diagnose with:

```bash
docker exec <svc> id abc
docker exec <svc> ls -ln /dev/dri
```

> **A root-run `vainfo` succeeding proves nothing** about what the service user
> can open. That is exactly why this survived the original verification.

---

## Plex: settings hidden, and applied late

The transcoder temporary directory and the hardware-acceleration checkboxes only
appear under **Show Advanced** on Settings → Transcoder.

**Changes apply to NEW playback sessions only** — an already-running transcode
keeps its old path and mode, so a test that looks like a failure may just be a
stale session.

Confirm what Plex actually did from **its log**, not from a dashboard:

```bash
grep -i "hardware transcoding" \
  "/config/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log" | tail
```

Empty `final decoder` / `final encoder` fields mean **software fallback**.

---

## Restored app configs carry the old setup's paths AND ports

The SABnzbd backup restored a web port of **7777** while compose mapped 8080, and
every path pointed at the old `/downloads/...` layout — which surfaced as
`Permission denied: '/downloads'`.

**After any restore, grep the config for the port and every path before trusting
it.**

### Editing an app's ini with `sed`: match exactly, then chown

SAB's ini has a `port =` line for the web UI **and one per news server**
(`port = 563`), so a loose pattern rewrites them all. Match the full old value:

```bash
sed -i -E 's/^port = 7777$/port = 8080/' sabnzbd.ini
chown 3004:3004 sabnzbd.ini      # every time
```

**`sed -i` run as root writes a new root-owned file**, which the app (running as
3004) then cannot save.

---

## `docker compose logs --tail N` includes the previous run

Right after a restart, the tail can be the **old** run's errors and shutdown
messages. Use `--since 2m`, or check timestamps, before concluding a fix failed.

---

## Root can't write freely on sisyphus — use `setpriv`

The share has **no maproot**, so manual `mkdir`/`mv`/`rm` from an LXC shell must
run as 3004:

```bash
setpriv --reuid=3004 --regid=3004 --clear-groups <cmd>
```

Prefer **`mv -n`** (never overwrites) and **`rmdir`** (fails on non-empty), so an
unexpected file stops the chain instead of being silently lost. Preview deletes
with `find ... -print` before `-exec rm -rf {} +`.

### `.DS_Store` breaks folder merges

Globs (`dir/*`) **skip dotfiles**, so a macOS `.DS_Store` left behind makes the
following `rmdir` fail and stops the chain. Delete it first.

To stop the Mac creating them on shares:

```bash
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
# then log out
```

---

## Usenet imports are moves, not hardlinks

**A link count of 1 after a Usenet import is correct.** Radarr *moves* the file —
an instant rename on one filesystem — and SAB's job is removed, because Usenet
has nothing to seed.

The hardlink check (link count **2** on both copies) applies **only to torrents
that keep seeding.** Do not debug a working Usenet import against the wrong
expectation.

---

## Recyclarr: one config file per instance

`config create -t` writes **one file per template**, and **Recyclarr loads every
file in `configs/`** — so several files aimed at the same Radarr conflict.

Generate the templates, move them to `templates/`, and write **one merged file
per app** listing every profile `trash_id`. Default CF groups attach to the right
profiles automatically from TRaSH data; **optional groups need
`assign_scores_to`.**

Always `sync <app> --preview` first, and **check the scores are non-zero.**

---

## ghcr.io needs a CLASSIC PAT

**Fine-grained tokens cannot be granted package access.** Use a classic token
with **only `read:packages`**, and keep it out of shell history:

```bash
read -s GHCR_PAT
echo "$GHCR_PAT" | docker login ghcr.io -u <user> --password-stdin
```

Docker stores it **base64-encoded, not encrypted**, in
`/root/.docker/config.json`.

> **Note the expiry date.** When it lapses, running containers keep working but
> **the next pull fails** — which looks like a registry outage.
