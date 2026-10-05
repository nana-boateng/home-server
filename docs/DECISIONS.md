# Decision Log

Locked architectural decisions for the homelab, with the reasoning behind each.

**This repo is the source of truth.** Chat sessions and assistant memory are not
a handoff mechanism and do not carry across surfaces. A decision that is not
written down here did not happen.

**Append, don't rediscover.** New decisions go at the bottom with the date they
were locked. If a decision is reversed, leave the original entry in place and add
a superseding entry that says what changed and why. Superseded entries keep their
original text and gain a pointer at the top — the history is the point.

Things that were raised but *not* ratified live in
[Open Questions / Known Risks](./homelab-network-plan.md#open-questions--known-risks),
not here.

---

## 2026-09-04

### D1 — Addressing scheme: flat `10.0.0.0/24`

> **Extended by [D10](#d10--vlan-ready-addressing-under-a-1000016-supernet) (2026-09-26)**
> — the VLAN scheme moved to the third octet, and the CRS310 and EAP650 were
> assigned. The ranges and the not-node-encoded rule below still stand.

The LAN is `10.0.0.0/24`, gateway `10.0.0.1` (TP-Link ER605). DHCP pool
`.100–.254`, configured and live on the router. Statics live in `.1–.99`.

| Range | Purpose |
|-------|---------|
| `.1` | ER605 router / gateway |
| `.2–.9` | Core network gear (`.2` reserved for OC200) |
| `.10–.29` | Physical hosts |
| `.30–.99` | Services, VMs, LXCs — assigned by service, not by node |
| `.100–.254` | DHCP pool |

Live assignments: Rhea `10.0.0.10`, Themis `10.0.0.11`, Hestia `10.0.0.12`,
Tartarus `10.0.0.20`, OC200 reserved at `10.0.0.2`.

**Rationale.** Service IPs are deliberately **not node-encoded**. An IP must not
imply which node a service runs on, because HA migration would immediately make
that encoding a lie. Node identity belongs in the host range; service identity
belongs in DNS and the reverse proxy.

Suggested (not yet assigned) grouping inside `.30–.99`: `.30–.49` media,
`.50–.69` infrastructure, `.70–.99` everything else. Pi-hole primary `.50` and
secondary `.51` fit the infrastructure band.

Full detail: [homelab-network-plan.md](./homelab-network-plan.md#addressing-scheme).

### D2 — Search domain is `.lan`

All host and service names are `*.lan`. **`.local` must not be used anywhere.**

**Rationale.** `.local` is reserved for mDNS (RFC 6762) and causes intermittent
resolution failures on macOS and Linux that are painful to diagnose.

Outstanding: the TrueNAS box is currently configured with domain `local` and
needs to be moved to `lan`.

### D3 — Pi-hole runs as a Proxmox LXC, not a Docker container

Pi-hole runs in its own Proxmox LXC, with Unbound behind it inside the same LXC.

**Rationale.** A bridged Docker container conflicts on port 53 and reports the
Docker gateway as the client for every query, destroying per-device statistics.
`macvlan` fixes client attribution but blocks host↔container traffic. An LXC
avoids both problems.

Additional rules:

- DNS must not be entangled with the Compose stacks — restarting a stack must not
  take down DNS.
- Pi-hole serves **split-horizon DNS**: internal hostnames resolve to LAN IPs.

### D4 — Caddy is the reverse proxy, in its own LXC

**Caddy**, not Traefik, running in a dedicated Proxmox LXC.

**Rationale.** A static, version-controllable Caddyfile is preferred over
Traefik's label-driven dynamic discovery. Configuration that lives in git can be
reviewed, diffed, and restored.

- **One central Caddy instance fronts every service on every node.** The
  Caddyfile is a static `hostname → 10.0.0.x:port` map and **belongs in this
  repo**.
- **Caddy Cloudflare DNS plugin** for DNS-01 challenges, so internal-only
  services get real Let's Encrypt certificates without any inbound exposure.
  Domains are on Cloudflare.

### D5 — Public access via Cloudflare Tunnel; Jellyfin behind auth; Plex native

> **Extended by [D19](#d19--immich-gets-https-before-anyone-is-onboarded) (2026-09-27)**
> — Immich's exposure model is settled, and the Plex rationale is sharpened
> below in D18.

- **Public services** (Jellyfin, and any remote-user-facing service) go out via
  **Cloudflare Tunnel** — no port forwards, no open inbound ports on the home IP.
- **Jellyfin must sit behind an auth layer** — Cloudflare Access or Authentik.
  Auth terminates at the proxy, **before** Jellyfin sees the request.
- **Plex keeps its own native remote access.** Do not proxy it.

**Rationale.** Unlike Plex, Jellyfin has no brokered remote-access model, and
some of its API endpoints do not require authentication. App-level login alone is
therefore not sufficient protection for an internet-exposed instance. Plex's own
relay/direct-connect model is purpose-built and does not benefit from being put
behind the proxy.

### D6 — Caddy and Pi-hole are infrastructure, not applications

> **Superseded by [D13](#d13--infrastructure-runs-on-rhea-supersedes-d6) (2026-09-26).**
> The infrastructure/application split below still holds, but the node choice is
> reversed: infrastructure now runs **on Rhea**, not on Themis or Hestia.

Both:

- run as **LXCs on the Proxmox cluster**, outside Docker Compose
- go on a **quieter node — Themis or Hestia**, **not** Rhea
- must **not** go on the fourth non-clustered machine

**Rationale.** The reverse proxy and DNS are the two components whose failure
takes down access to everything else. They belong on managed, snapshotted,
always-on hardware with `vzdump` coverage. The fourth machine sits outside the
cluster, gets no snapshots or backups, and is expected to be repurposed and
rebooted freely — that is the wrong home for a front door.

### D7 — Remote access is Tailscale with subnet routing

Tailscale, advertising `10.0.0.0/24` as a subnet route from a stable, always-on
node or LXC — **not** the fourth machine. The route must be approved in the
Tailscale admin console.

**Rationale.** Gives full LAN reachability off-site with no open inbound ports,
and survives ISP changes and house moves without re-architecting. Headscale is
**not** used; earlier notes mentioning it are obsolete.

### D8 — The fourth machine is explicitly non-production

Same specs as the weakest node. Stays **outside** the Proxmox cluster. Reserved
for experiments, tinkering, and disposable workloads.

**Rationale.** It gets no snapshots and no backups, and is expected to be
repurposed and rebooted freely. Documented as non-production so future work does
not quietly drift onto it. Nothing critical goes here — explicitly including
Caddy, Pi-hole, and the Tailscale subnet router.

### D9 — This repo is the source of truth

Every decision must land in this repo to survive. Chat sessions and assistant
memory are not a handoff mechanism and do not carry across surfaces.

**Rationale.** Decisions that live only in a conversation get rediscovered,
re-argued, and silently reversed. Future sessions should append here rather than
re-derive.

---

## 2026-09-26

Context: the infrastructure layer is now **built, not planned**. All three nodes
are clean-installed on PVE 9.2.2 with ZFS-on-root, correct IPs, and joined into a
working cluster named **`gaia`**. A MikroTik CRS310 is the core switch. The
decisions below reflect measured state — see
[hardware-inventory.md](./hardware-inventory.md) and
[rebuild-runbook.md](./rebuild-runbook.md).

### D10 — VLAN-ready addressing under a `10.0.0.0/16` supernet

Extends [D1](#d1--addressing-scheme-flat-1000024). Main stays `10.0.0.0/24`;
future VLANs use the **third octet** under one `10.0.0.0/16` supernet.

| VLAN ID | Name | Subnet |
|---|---|---|
| 10 | Main | `10.0.0.0/24` |
| 20 | IoT | `10.0.20.0/24` |
| 30 | Guest | `10.0.30.0/24` |

VLAN IDs mirror the third octet. Main is the exception — VLAN **10**, because
VLAN 0 is reserved. **Avoid VLAN 1 entirely.**

Newly assigned and live: **CRS310 `10.0.0.3`**, **EAP650 `10.0.0.4`**. `.2`
remains reserved for the OC200.

**Rationale.** The old scheme encoded VLANs in the *second* octet
(`10.1`–`10.4`), which would have forced every live machine to re-IP the moment
VLANs arrived. Moving to the third octet under one supernet means **Main never
re-IPs**, one Tailscale route covers every VLAN, and firewall rules stay simple.

**Running flat today.** VLANs are no longer blocked on a working Omada
controller — the MikroTik does VLAN tagging itself ([D15](#d15--network-core-mikrotik-crs310-router-on-a-stick)).
They are deferred only by the deliberate choice to prove the flat 2.5G network
first. See [OPEN-QUESTIONS.md](./OPEN-QUESTIONS.md#vlan-rollout).

### D11 — Runtime config on node-local ZFS; NFS carries bulk data only

- **Runtime config and state live on node-local ZFS**, at
  `/opt/appdata/<stack>/<service>` inside the guest.
- **NFS (`/mnt/storage` on `sisyphus`) carries bulk data only:** `downloads/`,
  `media/`, `shared/`.
- **Databases and `/config` never touch NFS.**
- **Compose files and `.env` are the source of truth in Git** — declarative
  configuration, *not* a state backup. State is backed up by
  [D12](#d12--app-state-backup-restic-per-node-agents).

**Rationale.** SQLite over NFS has unreliable locking and a well-known corruption
mode, and Radarr, Sonarr, Prowlarr, Bazarr, Immich, and Paperless all keep
SQLite or Postgres databases. The previous documented convention actively
prescribed config volumes on NFS — that was the corruption path, and it is
reversed here. `appdata/` is removed from the `sisyphus` layout entirely so the
wrong thing is not merely discouraged but unavailable.

The storage identity model is unchanged: `sisyphus` UID/GID `3004` for shared
writes, `ixion` UID/GID `3000` for personal data, read-only to containers by
default.

### D12 — App-state backup: Restic, per-node agents

- **Restic runs on each node**, backing up **its own** local appdata to **one
  shared, deduplicated, encrypted Restic repo on Tartarus**. Agents write **out**
  — there is no central puller.
- **Quiesce via ZFS snapshot** — snapshot the appdata dataset, back up the
  snapshot, release it. Atomic, no downtime.
- **Retention** via `restic forget` — e.g. 7 daily / 4 weekly / 6 monthly.
- **Keep the repo password off-cluster.** Lose it and the backups are
  unrecoverable.
- **Notify success *and* failure to ntfy.**
- **Test a real restore** before relying on it.
- **Keep one copy off Tartarus** (`restic copy` to an external drive).

**Rationale.** A hot-copied SQLite or Postgres database is a corrupt backup — the
ZFS snapshot is what makes the copy atomic, and it is uniform now that ZFS is
live on all three nodes ([D14](#d14--zfs-on-root-on-all-three-nodes)). Silent
backups fail silently, hence the notification requirement. Tartarus is a single
box, so RAID plus one-way rsync is not a backup, hence the off-box copy.

Restore or move a service = pull the repo on the target node → restore that
service's config from Tartarus → `docker compose up`.

### D13 — Infrastructure runs on Rhea (supersedes D6)

> **Refined by [D22](#d22--service-layer-11-lxcs--1-vm-grouped-by-failure-domain) (2026-09-27)**
> — the node-level rule stands; the full service map is now in
> [service-architecture.md](./service-architecture.md).

Caddy and Pi-hole remain infrastructure rather than applications, and still run
as **LXCs on the cluster, never on the fourth non-clustered box**. What changes
is the node: **they run on Rhea.**

**Rhea is the light always-on infrastructure node** — Pi-hole + Unbound, Caddy,
Uptime Kuma, ntfy, the Omada software controller, and the Tailscale subnet
router. Small LXCs with tiny configs.

**Do not put the heavy ~29-service control plane on Rhea.**

**Rationale.** [D6](#d6--caddy-and-pi-hole-are-infrastructure-not-applications)
routed infrastructure away from Rhea because Rhea was then the busiest node and
had a 54 GiB pool. Both premises are gone: the stacks move to Themis under the
placement rule, and Rhea now has ~457 GiB. Its remaining weakness is the N5095
CPU, which is exactly what light infrastructure does not stress. Infrastructure
still belongs on managed, always-on, snapshotted hardware — that part of D6 was
never in question.

**Placement rule, in full:**

| Node | Role | Workloads |
|---|---|---|
| **Rhea** | Light always-on infrastructure (weakest CPU) | Pi-hole + Unbound, Caddy, Uptime Kuma, ntfy, Omada controller, Tailscale subnet router |
| **Hestia** | Media / storage hub (1 TB — 2× any other node) | Plex, Jellyfin, Tautulli, the `apollo` stack |
| **Themis** | Compute / appliance + heavy stacks (6c/12t, fastest) | `io`, `asteria`, Immich, Paperless, Home Assistant VM, `helios` |

Hestia's real edge is **disk capacity**, not exclusive transcode ability — both
it and Themis do H.265, and Themis's iGPU is in fact the stronger one.

> **Settled by [D22](#d22--service-layer-11-lxcs--1-vm-grouped-by-failure-domain)
> (2026-09-27):** media stays on Hestia. It keeps load on the idle node, and
> Hestia's blast radius now includes other people. No longer an open question.

### D14 — ZFS-on-root on all three nodes

All three nodes are installed with ZFS-on-root: `ashift 12`, compress on,
checksum on, copies 1.

**All three are single-disk, so this is single-disk ZFS — no RAID redundancy.**
Snapshots and checksums *detect* corruption but cannot repair it, and are not a
substitute for [D12](#d12--app-state-backup-restic-per-node-agents).

**Rationale, and a resolved objection.** ZFS on Rhea was previously believed to
be gated on a 32 GiB RAM upgrade. **It is not.** PVE ZFS-root installs cap ARC at
**10% of RAM, max 16 GiB** — on Rhea's 15.4 GiB that is ~1577 MiB, set
automatically by the installer. Rhea runs ZFS fine as-is. The RAM upgrade is a
nice-to-have, not a dependency, and this should not be re-litigated.

ZFS is what makes the D12 snapshot-quiesce uniform across the cluster, and it
puts **ZFS replication between nodes** on the table as a lighter alternative to
full Proxmox HA.

### D15 — Network core: MikroTik CRS310, router-on-a-stick

The CRS310-8G+2S+IN is the core switch, management on `10.0.0.3` on the
**bridge** interface. **The MikroTik owns all VLAN tagging and port assignment;
the ER605 keeps inter-VLAN routing and firewalling.**

**Rationale, recorded because the opposite is tempting.** The CRS310 *can*
hardware-offload L3 routing — but **offloaded traffic bypasses the CPU and
therefore bypasses the firewall**. You get speed or filtering, not both on the
same traffic. These VLANs exist to *isolate* IoT and Guest, and isolation is a
firewall function, so L3 switching would optimise precisely the traffic that is
meant to be blocked. Keeping routing on the ER605 also keeps `10.0.0.1` as the
gateway, so Main never re-IPs.

Port map, rollout ordering, and the two operational traps (enable
`vlan-filtering` **last**; learn WinBox MAC-connect **first**):
[network-core-crs310.md](./network-core-crs310.md).

### D16 — Hardware inventory lives in the repo

The measured hardware table, the deferred-upgrade list, and node-specific fixes
are a permanent doc: [hardware-inventory.md](./hardware-inventory.md).

**Rationale.** Every sizing and placement decision depends on this data, and it
previously lived nowhere. Planning that assumed a uniform "1 TB NVMe on every
node" upgrade was wrong in three ways at once — disks are not uniform, no second
drives exist, and Rhea's RAM was never upgraded. Decisions made against
remembered hardware are decisions made against fiction.

The same file carries the **Rhea `snd_hda_intel` blacklist**, which does not
survive a reinstall and must be reapplied if Rhea is ever rebuilt.

---

## 2026-09-27

Context: two full service-layer passes are complete — pass 1 evaluated all ~46
services individually, pass 2 pressure-tested each grouping. The result is
[service-architecture.md](./service-architecture.md).

### D17 — No VPN: gluetun and the killswitch design are removed

> **Partially reversed by [D30](#d30--one-vpn-instance-two-qbittorrents) (2026-10-03).**
> The premise below — "nothing here needs IP concealment" — does not hold for
> arr-driven grabs from **public** trackers. A second, VPN-only qBittorrent is
> added; **this instance stays VPN-free**, and that remains deliberate.

gluetun is deleted. **qBittorrent becomes an ordinary container with its own IP
and port.**

**Rationale.** qBittorrent is not used for anything needing IP concealment, so
the tunnel has no job. Per-downloader analysis, recorded so it is not
re-litigated: **only qBittorrent would ever have needed it**, since BitTorrent
announces your IP to peers; sabnzbd, jdownloader and metube neither need nor
benefit from one.

A note on what was actually there: the gluetun service existed, carried a live
Mullvad key, and was included in the `io` stack — but **no container ever set
`network_mode: "service:gluetun"`**, so qBittorrent had been torrenting over the
raw WAN since April. The choice was to wire it up or remove it; removal follows
from the rationale above.

> **Consequence for reading guides.** Nearly every arr and qBittorrent guide
> binds the download client behind gluetun/WireGuard and runs Watchtower.
> **SKIP those sections.** Both were deliberately removed. Isolating qBittorrent
> into `grab` with no VPN is a considered divergence from the reference pattern,
> not a mistake to correct.

### D18 — Plex keeps native remote access; Caddy needs a custom build

Two refinements to [D4](#d4--caddy-is-the-reverse-proxy-in-its-own-lxc) and
[D5](#d5--public-access-via-cloudflare-tunnel-jellyfin-behind-auth-plex-native).

**Plex stays unproxied.** Two friends stream remotely, plus owner travel, and
**Plex's own relay handles that better than Caddy would**. A manual 32400 port
forward is a fallback only, not the design.

**Caddy needs a custom build carrying the Cloudflare DNS plugin** — `xcaddy` or
a bundling image. The stock image does not have it, so DNS-01 will not work out
of the box. This is a build-time prerequisite, not a configuration step.

**Traefik is structurally unavailable in this topology**, which retires the
Caddy-vs-Traefik question permanently: Traefik discovers services through the
Docker socket, and there is one socket per daemon. With daemons spread across
many LXCs, a single Traefik cannot see them. Caddy's static Caddyfile does not
care where a service runs.

### D19 — Immich gets HTTPS before anyone is onboarded

**Stand up HTTPS in front of Immich before onboarding any family or friends.**
Retrofitting it means touching every phone twice.

The real Immich stays **internal-only and off Cloudflare Tunnel**. Two purpose-
built services carry the outside traffic instead: **immich-drop** for inbound
zero-login uploads, and **immich public proxy** for outbound password-protected
share links. Running both is what keeps the main instance unexposed.

Immich holds the most irreplaceable data in the lab, and needs **both** the
database and the media filesystem protected.

### D20 — Force all DNS through Pi-hole; never list a public resolver as secondary

> **Mechanism changed by [D31](#d31--dns-enforcement-lives-on-the-er605-and-blocks-rather-than-redirects)
> (2026-10-03):** enforcement moved from CRS310 NAT to an **ER605 block rule**.
> The rule below that a public secondary is never listed is unchanged.

Clients are forced through Pi-hole.

> **Never list a public resolver as secondary DNS in DHCP.**

**Rationale.** "Secondary DNS" is not failover. Clients query both resolvers
unpredictably, or wait an age, or cache the primary and never try the backup —
so a public secondary means queries leak past Pi-hole at random. Real redundancy
needs a **second Pi-hole plus a Keepalived VRRP floating VIP**, with clients and
DHCP pointing only at the VIP.

> **Built in [D27](#d27--dns-redundancy-two-pi-holes-behind-a-keepalived-vip-primary-only-edits)
> (2026-10-04).** DHCP now advertises the VIP `10.0.0.33`.

> **Never update both Pi-holes at once.** A bad update with both down means zero
> redundancy at exactly the wrong moment —
> [update-discipline.md](./update-discipline.md).

Extends [D2](#d2--search-domain-is-lan) and
[D3](#d3--pi-hole-runs-as-a-proxmox-lxc-not-a-docker-container).

### D21 — The download flow is load-bearing

> **The path string is `/mnt/sisyphus`** — fixed by
> [D24](#d24--lxc-address-block-3059-with-statics-in-the-container-config) and
> the live build. See [build-record.md](./build-record.md).

Extends [D11](#d11--runtime-config-on-node-local-zfs-nfs-carries-bulk-data-only).
Holds identically for Radarr, Sonarr and abs-arr:

```text
incomplete  ->  themis-500/incomplete   (local HDD scratch)
complete    ->  sisyphus/downloads      (NFS)
import      ->  sisyphus/media          (NFS — same filesystem)
```

Complete and import share a filesystem, **so hardlinks work and seeding
continues**.

Two rules that break the pipeline silently when violated:

- **Completed torrents from `grab` must land on the shared `sisyphus` path
  mounted at an IDENTICAL path string in both `grab` and `arr`.** A different
  path string on either side and hardlinks fail.
- **Mount storage as a SINGLE unified root**, never separate `/downloads` and
  `/movies`. Split mounts break atomic moves and hardlinks.

**Incomplete goes on the HDD scratch pool**, not the NVMe: sequential writes, no
SSD wear, and the data is disposable.

**Mount first, then wire.**

### D22 — Service layer: 11 LXCs + 1 VM, grouped by failure domain

> **Count superseded by [D34](#d34--the-plan-is-12-lxcs-not-11) (2026-10-03)** —
> `dns2` was added after this was written, so the plan is **12 LXCs**. The
> grouping principle below is unchanged.

The full map, with per-service build notes and the grouping rationale, is
[service-architecture.md](./service-architecture.md). The governing principle:

**Isolation is bought deliberately, and a Docker daemon is a shared-fate unit** —
splitting compose files on one daemon buys nothing. So: **one Docker daemon per
coupling group, in its own LXC**. The bill is networking: same LXC → container
name, different LXC → IP and port.

Node placement:

| Node | Carries |
|---|---|
| **Rhea** | `dns`, `proxy`, `tailscale`, `omada` — native daemons, deliberately underloaded |
| **Hestia** | `media`, `monitor`, `apps`, `immich` |
| **Themis** | `arr`, `grab`, `sandbox`, `homeassistant` (VM) |

Consequences worth stating on their own:

- **The seven old stacks are not the deployment unit.** `aeos`, `helios`,
  `atlas` and `hera` dissolve; `io`, `asteria` and `apollo` survive as `grab`,
  `arr` and `media`. `stacks/<name>/` in this repo is an **inventory, not a
  placement map**.
- **`monitor` resolves via `10.0.0.1`, not Pi-hole**, so it can still alert when
  Rhea is down. Uptime Kuma must also have an **off-Hestia notification path**
  for host-down events.
- **Media stays on Hestia** despite Themis having the stronger iGPU — it keeps
  load on the idle node, and Hestia's blast radius now includes other people.
- **Watchtower is dropped** for what's-up-docker (notify-only). Auto-`:latest`
  recreate is the top self-inflicted-downtime cause.
- **HAOS must be a VM**, not an LXC — it needs UEFI, its own kernel, and
  Supervisor access.

Services added, dropped and replaced in this pass are listed in
[service-architecture.md](./service-architecture.md); rejections carry their
reasons so they are not re-proposed.

### D23 — Reclaimerr runs report-only until off-box backup exists

**Reclaimerr is the only tool in the stack that permanently deletes media.**
Build it, configure it, and run **DRY-RUN / REPORT-ONLY ONLY**.

**Scheduled deletion stays OFF until a genuine off-box backup exists.**

**Rationale.** [D12](#d12--app-state-backup-restic-per-node-agents)'s
Restic-to-Tartarus is **on-box**. It protects against disk and container loss; it
does **not** protect against a bad Reclaimerr rule, because the deletion
propagates to the backup. Enabling scheduled deletion before the off-box copy
exists would make a single misconfigured rule unrecoverable.

This makes [off-box backup](./OPEN-QUESTIONS.md#backup-off-box)
a gating dependency rather than a nice-to-have.

---

## 2026-10-01

Context: the first two LXCs — `media` and `dns` — are **built, verified and in
service**. See [build-record.md](./build-record.md) for what was built and
[build-gotchas.md](./build-gotchas.md) for what it cost.

### D24 — LXC address block `.30–.59`, with statics in the container config

Guests take statics from **`.30–.59`**, set in the container config
(`/etc/pve/lxc/<id>.conf`) — **not** as DHCP reservations on the router.

| Address | Host | What |
|---|---|---|
| `10.0.0.30` | Hestia | `media` (CT 200) |
| `10.0.0.31` | Rhea | `dns` (CT 100) — Pi-hole **primary** |
| `10.0.0.32` | Hestia | `dns2` (CT 201) — Pi-hole **replica** |
| `10.0.0.33` | **floating** | **DNS VIP** (keepalived VRRP) — what DHCP advertises |
| `10.0.0.34` | Hestia | `monitor` (CT 202) |
| `10.0.0.35` | Themis | `arr` (CT 300) |
| `10.0.0.36` | Themis | `grab` (CT 301) |
| `.37–.59` | | unassigned |

> **CT ID numbering is undefined**, and the current IDs grew by node (1xx Rhea,
> 2xx Hestia) — which puts the DNS pair in different ranges (`dns` is 100,
> `dns2` is 201) even though the pair is one logical unit deliberately split
> across nodes. **`arr` = 300 and `grab` = 301 were chosen because they fit
> *both* candidate schemes** (node-based: Themis = 3xx; service-based:
> arr/grab = 3xx), so they defer the decision rather than compound it.
> Not renumbered;
> [recorded as open](./OPEN-QUESTIONS.md#ct-id-numbering-scheme) so the
> remaining six LXCs do not compound it.

**Rationale.** Services reach each other **by IP and port across LXC boundaries**
([D22](#d22--service-layer-11-lxcs--1-vm-grouped-by-failure-domain)), so these
addresses are referenced by Caddy, Homepage and others. That makes them
configuration, and configuration belongs in the repo rather than in a router's
web UI ([D9](#d9--this-repo-is-the-source-of-truth)). Putting them in the
container config also means the address travels with the container definition
and is captured by `vzdump`.

Extends [D1](#d1--addressing-scheme-flat-1000024) and
[D10](#d10--vlan-ready-addressing-under-a-1000016-supernet), which reserved
`.30–.99` for services generally; `.30–.59` is the LXC/VM slice of that.

### D25 — The shared NFS path string is `/mnt/sisyphus`, everywhere

One string, identical on the host and inside **every** LXC:

```
10.0.0.20:/mnt/tartarus/sisyphus  ->  /mnt/sisyphus   (host, /etc/fstab)
pct set <id> -mp0 /mnt/sisyphus,mp=/mnt/sisyphus       (guest, same string)
```

**Rationale.** [D21](#d21--the-download-flow-is-load-bearing) requires an
identical path string in `grab` and `arr` or hardlinks fail silently and imports
double disk usage. Fixing the string once, for every guest including those that
do not need hardlinks, removes the chance of getting it wrong in the two that
do.

**Unprivileged containers need an idmap to use it at all.** The export is mode
`drwx------` owned `3004:3004`, so only UID 3004 exactly can read it, and an
unprivileged container maps 3004 → 103004 by default. The `root:3004:1`
subuid/subgid entries plus six `lxc.idmap` lines are **mandatory, not optional**
— the exact block is in
[build-gotchas.md](./build-gotchas.md#unprivileged-containers-need-an-idmap-to-use-the-nfs-share).

### D26 — Pin every image to a version actually pulled

Image tags are pinned to versions **read off the image after pulling**, never
copied from a guide or from memory.

**Rationale.** Every image tag and install instruction assumed at the start of
the `media`/`dns` build was stale — not some of them, all of them. The pinning
discipline is cheap; the alternative is debugging a tag that never existed.

```bash
docker inspect -f '{{ index .Config.Labels "build_version" }}' <image>:latest
```

This extends to install procedures, not just tags: the documented Pi-hole
`--unattended` flag does not work on a fresh system, and Docker's repo format is
now deb822. Both are recorded in
[build-gotchas.md](./build-gotchas.md).

---

## 2026-10-04

Context: **DNS redundancy is built and the monitoring layer is complete.** Five
of eleven LXCs are live. The DNS single point of failure that was flagged urgent
is **closed**. See [build-record.md](./build-record.md).

### D27 — DNS redundancy: two Pi-holes behind a keepalived VIP, primary-only edits

**Built, not planned.** Two Pi-holes, each with **its own local unbound**, behind
a keepalived VRRP floating IP at **`10.0.0.33`**. DHCP advertises the VIP only.

| | |
|---|---|
| `dns` — CT 100, Rhea, `10.0.0.31` | Pi-hole **primary** + unbound + nebula-sync |
| `dns2` — CT 201, Hestia, `10.0.0.32` | Pi-hole **replica** + its own unbound |
| `10.0.0.33` | the VIP clients actually use |

**The replica is deliberately on Hestia, not Rhea.** That separation is the
entire point — it refines [D13](#d13--infrastructure-runs-on-rhea-supersedes-d6),
which otherwise puts infrastructure on Rhea.

**The replica runs its own unbound and must never forward to Rhea's.** If it
did, a Rhea failure would take the replica's upstream with it: the replica would
hold the VIP and resolve nothing, which is worse than no redundancy because it
looks healthy.

**The health check moves the VIP on FTL death, not just container death** — a
Pi-hole whose FTL has died is still pingable and still holds the IP.

> **`10.0.0.31` is the ONLY Pi-hole you edit.** nebula-sync is **one-way**;
> anything changed on the replica is overwritten at the next hourly sync.
> Blocklists, local DNS records, allowlist entries, settings — all go in at the
> primary.

nebula-sync is the **Pi-hole v6** tool; Orbital Sync is v5-era, built around the
old API and Teleporter workflow, with one repo archived March 2025. It is
addressed at `10.0.0.31`, **not the VIP** — sync must push from the real primary,
never from whoever happens to hold `.33`.

**Preemption is left ON.** `nopreempt` was rejected: silently running on the
replica for weeks is the worse failure, because every edit made there vanishes.
The accepted cost is that an FTL restart on the primary briefly moves the VIP and
moves it back.

> **Never update both Pi-holes at once** — a bad update with both down means zero
> redundancy. Replica first, confirm it answers, then the primary.
> [update-discipline.md](./update-discipline.md).

Configs: [`infra/dns/`](../infra/dns/). What remains unbuilt is the
**CRS310 NAT-rule half** of [D20](#d20--force-all-dns-through-pi-hole-never-list-a-public-resolver-as-secondary),
whose absence was demonstrated during the first cutover when a Mac with a manual
`1.1.1.1` bypassed Pi-hole entirely.

### D28 — Nothing auto-updates, and three pairs are version-coupled

Extends the Watchtower decision in
[D22](#d22--service-layer-11-lxcs--1-vm-grouped-by-failure-domain). **The rule
now explicitly covers agent auto-updaters, not just container images.**

Three pairs must be version-matched or upgraded in a set order:

| Pair | Rule |
|---|---|
| **Beszel hub + agents** (`0.20.0` × 4) | Not independently upgradable. Upgrade all four together. **Decline the installer's daily auto-update offer.** |
| **Dozzle server + agent** (`v11.1.3`) | Must match. Every future stack adds another agent to keep in step |
| **The two Pi-holes** | **Never both at once.** Replica first, confirm, then primary |

**Rationale.** Beszel agents silently drifting ahead of the hub breaks
monitoring — and the thing that would tell you is the thing that stopped. That
failure mode is the whole argument against auto-update in a monitoring stack: it
is self-concealing.

Full procedure: [update-discipline.md](./update-discipline.md).

### D29 — Dozzle stays a log viewer: actions and shell off

Dozzle runs in server/agent mode with **actions and shell deliberately not
enabled**.

**Rationale.** Enabling them turns a log viewer into a **remote control for every
connected Docker daemon**. It also duplicates `docker compose` from the host
shell, where the repo is the source of truth
([D9](#d9--this-repo-is-the-source-of-truth)) — so the capability adds reach
without adding anything you cannot already do more safely. And it is premature
while [the auth layer is unsolved](./OPEN-QUESTIONS.md#unified-auth-layer):
the Dozzle agent is currently unauthenticated on the LAN.

**Agent mode is both the topology and the security answer** for reaching other
nodes' daemons — and note an agent **cannot** sit behind a socket-proxy, so
agents are the mechanism rather than a workaround.

---

## 2026-10-03

Context: **the Themis half of the media pipeline is built.** `arr` (CT 300) and
`grab` (CT 301) are live, taking the lab to **six of twelve LXCs**. The share
was reorganised, and the no-VPN decision is partially reversed. See
[build-record.md](./build-record.md).

### D30 — One VPN instance: two qBittorrents

[D17](#d17--no-vpn-gluetun-and-the-killswitch-design-are-removed) dropped gluetun
on the premise that nothing here needs IP concealment. **That premise does not
hold for arr-driven grabs from public trackers**, so the decision is reversed
**for one new instance only**.

| Instance | Used by | Network | Seeding |
|---|---|---|---|
| `qbittorrent` (**built**) | owner, **abs-arr** (MyAnonymouse) | own connection, 6881 forwarded on the ER605 | unlimited, permanent |
| `qbittorrent-vpn` (**to build**) | Radarr, Sonarr — public trackers only | **only** via gluetun, kill switch | limited by ratio/time, then removed |

**abs-arr stays on the VPN-free instance.** MyAnonymouse wants long-term,
connectable seeding and ties the account to the IPs you seed from — a rotating
VPN exit is actively wrong there.

**Provider: Proton VPN Plus, WireGuard.** Chosen because gluetun's native
automatic port forwarding (`VPN_PORT_FORWARDING=on`) works with **Proton and PIA
only** — Mullvad dropped port forwarding in 2023. Proton assigns a *random*
forwarded port, so a helper must push it into qBittorrent's listening port.

Build requirements: `/dev/net/tun` passed into CT 301, `NET_ADMIN` on gluetun,
`network_mode: "service:gluetun"` on qbittorrent-vpn (its Web UI port is
published on gluetun), the same `/data` mount for hardlinks, its own incomplete
folder. **Verify the kill switch** by stopping gluetun and confirming
qbittorrent-vpn loses connectivity.

The per-downloader analysis still holds for everything else: **SABnzbd,
JDownloader and MeTube neither need nor benefit from a VPN.**

> **Guide-reading rule, narrowed.** "Skip the gluetun sections" now applies only
> to the **VPN-free** `qbittorrent`. **Watchtower stays dropped everywhere.**

### D31 — DNS enforcement lives on the ER605, and blocks rather than redirects

Enforcement moves from the CRS310 to the **ER605**, as a **block**, not a
redirect: **deny LAN → WAN TCP/UDP 53 and 853 from every source except
`10.0.0.31` and `10.0.0.32`** (each Pi-hole's unbound queries root servers
directly).

**Why the ER605 and not the switch.** Rules about which resolvers clients may use
are **firewall policy**, and [D15](#d15--network-core-mikrotik-crs310-router-on-a-stick)
puts firewalling on the ER605. Filtering on the CRS310 would mean pushing all
bridged traffic through its CPU and giving up hardware switching — the same
speed-versus-filtering trade-off D15 already rejected. Every client's internet
traffic crosses the ER605 anyway, so **one rule there covers wired and wireless
alike**, and once VLANs exist the IoT/Guest DNS rules sit beside the inter-VLAN
rules.

**Why block, not redirect.** A client with a hard-coded resolver then **fails
loudly** instead of silently bypassing Pi-hole — better for a lab where
misconfiguration should surface. The ER605's NAT is built for inbound port
forwarding and probably cannot do LAN-side DNS redirection anyway.

Unaffected: the ER605's own upstream lookups originate on the router, and
`monitor` talks only to `10.0.0.1`, which never leaves the LAN.

> **DNS over HTTPS (443) is out of scope.** It cannot be blocked by port. Pi-hole
> blocks Firefox's canary domain by default; other DoH clients are not covered.

Still unbuilt — and its absence is demonstrated: during the first cutover a Mac
with a manual `1.1.1.1` bypassed Pi-hole entirely.

### D32 — Container paths: `/data` inside, least privilege outside

Extends [D21](#d21--the-download-flow-is-load-bearing) and
[D25](#d25--the-shared-nfs-path-string-is-mntsisyphus-everywhere).

**Inside Docker containers the shared path is `/data`.** Every container that
must hardlink — Radarr, Sonarr, SABnzbd, abs-arr, both qBittorrents — mounts
`/mnt/sisyphus:/data` as **one bind**, so a path reported by a download client
exists unchanged in the importer and **no remote path mappings are needed**.

**Least privilege for everything else:**

| Service | Mounts |
|---|---|
| Bazarr, Audiobookshelf | only `/mnt/sisyphus/media:/data/media` |
| JDownloader, MeTube | only their own `downloads/direct/<app>` folder |
| Prowlarr, Byparr, Recyclarr, Reclaimerr | **no media at all** |

**Incomplete downloads** live on the HDD scratch pool with **per-client
subfolders**, bind-mounted as `/mnt/incomplete` in both `arr` and `grab`:
`incomplete/sabnzbd`, `incomplete/qbittorrent`, `incomplete/qbittorrent-vpn`.

**Usenet imports are moves; torrent imports are hardlinks.** A link count of 1
after a Usenet import is **correct** — Radarr renames the file on one filesystem
and SAB's job is removed, because Usenet has nothing to seed. The link-count-2
check applies only to torrents that keep seeding.

**Writing to sisyphus by hand:** root is restricted on the share (no maproot), so
manual moves and mkdirs run as 3004:

```bash
setpriv --reuid=3004 --regid=3004 --clear-groups <cmd>
```

which also gets ownership right.

### D33 — `sisyphus` layout

```text
sisyphus/
├── downloads/
│   ├── torrents/   complete/<category>, watch/, 00-myanonymouse/ (MAM seeds)
│   ├── usenet/     complete/{movies,tv,music,software}, watch/
│   ├── direct/     jdownloader/, metube/     (anything not torrent or Usenet)
│   └── complete/   manual-sort leftovers from the old setup — outside every pipeline
├── media/
│   ├── audio/      audiobooks/, music/, playlists/, podcasts/, projects/,
│   │               radio shows/, ingest/ (abs-arr inbox), temp/ (music staging)
│   ├── docs/       books/, comics/, manga/, ingest/{books,comics}, temp/
│   ├── misc/       ROMs/, tutorials/, temp/, PowerGrades
│   └── video/      movies/, tv/, channels/, misc/, temp/
└── shared/
```

The reasoning, because several of these look arbitrary:

- **`direct/` is named for what it is, not the tool** that fills it — it was
  `jdownloader/`, which would have had to be renamed every time the tool changed.
- **`comix/` + `graphix/` merged into `docs/comics/`** — that split was drift.
  **Manga stays separate**: right-to-left reading and different metadata.
- **`video/uhd` removed — 4K films share `video/movies` with 1080p**, and the
  quality profile decides per film. One root folder per app is what lets Radarr
  pick per title.
- **`audio/temp` sits outside `audio/music` on purpose** — Navidrome scans
  `audio/music`, so staging material must not be inside it.
- **One ingest folder per app.** Two apps watching one folder fight over it: a
  book app will happily grab a `.cbz` and delete what it processed.
- Typos fixed: `torrrents/` merged into `torrents/`, `video/mixc` → `video/misc`.
- Top-level `downloads/incomplete/` removed — incomplete lives on `themis-500`.

`usenet/incomplete` and `torrents/incomplete` on the NAS are **legacy**; clear
them once nothing references them.

### D34 — The plan is 12 LXCs, not 11

Supersedes the count in
[D22](#d22--service-layer-11-lxcs--1-vm-grouped-by-failure-domain) — the
grouping principle is unchanged, but `dns2` was added after that decision was
written.

| Node | LXCs |
|---|---|
| **Rhea** (4) | `dns`, `proxy`, `tailscale`, `omada` |
| **Hestia** (5) | `media`, `dns2`, `monitor`, `apps`, `immich` |
| **Themis** (3) | `arr`, `grab`, `sandbox` |

Plus the **Home Assistant VM**. Six LXCs are built.

**Cross-LXC wiring is by IP:** `arr` reaches qBittorrent at `10.0.0.36:8080`;
Reclaimerr reaches Plex and Jellyfin at `10.0.0.30`. Within an LXC, by container
name.

---

## 2026-10-05

### D35 — The hosts deploy from the repo

Each Docker LXC clones the repo to `/opt/home-server` and deploys with
`scripts/deploy.sh <stack>`, which is `git pull --ff-only` followed by
`docker compose -p <stack> --env-file /opt/stacks/<stack>/.env
-f stacks/<stack>/compose.yaml up -d`.

**Rationale.** [D9](#d9--this-repo-is-the-source-of-truth) declared the repo the
source of truth, but the mechanism ran the other way: things were built, then
described, then transcribed into the repo. The 2026-10-04 export measured the
cost of that — six image tags never recorded, a vestigial `group_add` nobody
knew about, Recyclarr configs in the wrong schema, and a keepalived weight fixed
on the primary but not the replica. None of those were catchable from the repo
side. After the flip, drift is `git status` on the host and image pins are what
is actually deployed, so `scripts/check-versions.sh` compares reality against
upstream rather than comparing a transcription against upstream.

**`git pull --ff-only` is chosen for its failure mode:** it refuses a dirty
clone instead of merging or stashing, so a hand-edit on the host surfaces loudly
at the next deploy.

Two requirements this places on every compose file, both now applied:

- **`name: <stack>`** — the project name must stay what it was when the stack
  deployed out of `/opt/stacks/<stack>/`, or Compose orphans the running
  containers rather than adopting them.
- **`env_file:` absolute**, under `/opt/stacks/<stack>/` — a relative path would
  resolve inside the clone, where secrets must never be.

**Secrets do not move.** `.env` stays on the host at mode 600; only
`.env.template` is committed. `arr` and `grab` have no `.env`, so `deploy.sh`
passes `--env-file` only when the file exists.

**Access for the audit was a one-time export, not standing SSH.** A root-owned
wrapper with no sudo wildcards remains available if continuous checking is ever
wanted; `pct exec` was rejected as an allowlist entry because it runs arbitrary
commands and is therefore equivalent to granting root.

**Deploy keys: one per LXC**, generated on that LXC, read-only, titled by
hostname — so one can be revoked without touching the others.

Cutover order **`grab` → `arr` → `media` → `monitor`**: loosest grouping first,
and the stack that would conceal its own failure last. `dns`/`dns2` are native
daemons and come later via an install script, **replica first**.

Procedure: [deploy-from-repo.md](./deploy-from-repo.md).
