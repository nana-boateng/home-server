# Build Gotchas

**Read this before building any further LXC.** Each item below cost real time
during the `media` and `dns` builds.

Related: [build-record.md](./build-record.md) — what was actually built ·
[service-architecture.md](./service-architecture.md) — what is left to build

---

## Verify current versions; never pin from a guide or from memory

**Every image tag and install instruction assumed at the start of the rev-8
build was stale.** Not some — every one.

Pull `:latest` once, read the version off the image, then pin that:

```bash
docker inspect -f '{{ index .Config.Labels "build_version" }}' \
  lscr.io/linuxserver/<image>:latest

docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' \
  <image>:latest
```

This applies to install procedures too, not only tags. The Pi-hole and Docker
install steps both differed from what the guides said.

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
