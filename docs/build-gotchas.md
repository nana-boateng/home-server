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
the tag is `v2.28.0`.

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
