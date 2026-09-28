# Service Architecture

The deployment map: **11 LXCs + 1 VM**, grouped by failure domain.

Two full passes produced this. Pass 1 walked all ~46 services one by one
(keep / drop / replace). Pass 2 pressure-tested each *grouping* against 2026
community architecture; every grouping came out structurally validated, so the
shape below is deliberate rather than inherited.

Related: [DECISIONS.md](./DECISIONS.md) · [OPEN-QUESTIONS.md](./OPEN-QUESTIONS.md) ·
[hardware-inventory.md](./hardware-inventory.md)

---

## The principle: blast radius, spent only where it pays

Isolation is not free, so it is bought deliberately:

| Boundary | Strength | Cost |
|---|---|---|
| **Node** | The only true boundary | Hardware |
| **LXC** | Filesystem, IP, resource isolation on a shared kernel | An IP, a daemon, an update surface |
| **Docker daemon** | **Shared-fate unit** | — |
| **Container** | Softest | — |

The load-bearing consequence: **splitting compose files on one daemon buys
nothing.** Services on the same Docker daemon start, stop, break and get updated
together whether or not they share a file. So the rule is **one Docker daemon per
coupling group, in its own LXC**.

The bill for that isolation is networking: **same LXC → reach by container name;
different LXC → reach by IP and port.** Pay it knowingly.

Substrate selection:

```text
needs its own kernel / UEFI / Supervisor   ->  VM            (Home Assistant)
single native daemon, infra-critical       ->  system LXC    (DNS, proxy, Tailscale)
cohesive group of Docker services          ->  Docker-host LXC
needs the iGPU                             ->  LXC with /dev/dri bind-mount
```

The biggest blast radii — **Tartarus, the CRS310, the ER605** — sit outside this
layer entirely. Nothing here mitigates them.

> **`stacks/<name>/` in this repo is a service inventory, not a placement map.**
> The directory names predate this architecture. The mapping is at the bottom of
> this document.

---

## Rhea — infrastructure only, deliberately underloaded

Lean-infra-concentrated-on-one-node is the endorsed 2026 pattern. All four are
**native daemons in system LXCs**, not Docker.

| LXC | Service | RAM | Notes |
|---|---|---|---|
| `dns` | Pi-hole + Unbound | ~512 MB | **Locked.** Technitium rejected. |
| `proxy` | Caddy | ~512 MB | Needs a **custom build** carrying the Cloudflare DNS plugin |
| `tailscale` | Tailscale | ~256 MB | Subnet router advertising `10.0.0.0/24`, free plan |
| `omada` | Omada controller | ~2 GB | **Parked** pending the OC200 RMA |

**Caddy needs a custom build.** The stock image has no Cloudflare DNS plugin, so
DNS-01 will not work out of the box — use `xcaddy` or a bundling image. See
[DECISIONS.md](./DECISIONS.md) D4.

**Traefik is structurally unavailable here.** It discovers services through the
Docker socket, and there is one socket per daemon — with daemons spread across
many LXCs, a single Traefik cannot see them. Caddy's static Caddyfile is
indifferent to where a service runs.

**The hardware and software Omada controllers are functionally identical**, so
the OC200 RMA is not urgent.

> **The SPOF is DNS specifically.** Proxy and Tailscale failing is annoying and
> recoverable; DNS failing takes the whole network with it. Redundancy plan —
> a second Pi-hole plus a Keepalived VRRP floating VIP — is
> [open, not built](./OPEN-QUESTIONS.md#dns-redundancy).

---

## Hestia — media, monitoring, apps, immich

### `media` (Docker) ~8 GB — **`/dev/dri` passthrough**, transcode → **tmpfs**

| Service | Notes |
|---|---|
| plex | Lifetime Plex Pass → hardware transcoding. Keeps **native remote access, unproxied** |
| jellyfin | QuickSync handles multiple sessions across containers |
| tautulli | Plex activity |
| posterizarr | Needs TMDB at minimum, plus Fanart.tv / TVDB keys. Owns artwork. Run big jobs off-hours |
| aggregarr | Plex-only |
| **navidrome** | Music serving. Single Go binary, <50 MB RAM. Subsonic API unlocks polished third-party mobile clients |

Grouping validated: **Plex + Jellyfin against one library on one iGPU is
textbook**, precisely because QuickSync does multi-session across containers.

Sequencing: stand up the core servers first, then layer Tautulli / Posterizarr.

Navidrome **serves, it does not acquire** — library on `sisyphus`, DB and config
node-local plus Restic.

> **Tdarr rejected** — it would contend for Hestia's iGPU while friends are
> streaming.

> **Media stays on Hestia despite Themis having the stronger iGPU.** It keeps
> load on the idle node, and Hestia's blast radius now includes other people.

### `monitor` (Docker) ~2 GB

> **`resolv.conf` here points at `10.0.0.1` / `1.1.1.1`, NOT Pi-hole**, so
> monitoring can still alert when Rhea is down.

| Service | Job |
|---|---|
| uptime-kuma | *Is it up.* **Must have an off-Hestia notification path** for host-down events |
| **beszel** | *Is it healthy* — CPU / RAM / disk creep. Hub here, ~10–15 MB agent per node, alerts via ntfy |
| ntfy | Everyday notification hub — critical alerts deliberately bypass it |
| what's-up-docker | Update notifications only. Wants each daemon's socket → one instance per LXC, or a socket-proxy |
| dozzle | Live logs. **Agent mode** is both the topology and the security answer |

The review found a real hole here: **availability and resource metrics are
different jobs and do not overlap**, which is why most people run both. Uptime
Kuma alone structurally cannot see disk creep.

- **Prometheus + Grafana deliberately skipped** — overkill at this size.
- **A Dozzle agent cannot sit behind a socket-proxy**; agent mode is the answer.
- **No log persistence anywhere** — Dozzle shows live logs only.
- Proxmox owns the infra layer (quorum detects node-down); Kuma owns the service
  layer.

### `apps` (Docker) ~6 GB — the densest shared-fate unit in the lab

**Update discipline matters most here.** Everything below shares one daemon, so
sequence updates carefully.

| Service | Build note |
|---|---|
| homepage | Live widgets via API keys; read-only tokens in an uncommitted `.env` |
| jellyseerr | **At build time, check whether the image moved from `jellyseerr` to `seerr`** after the Feb-2026 merger |
| wizarr | One invite link → auto account. Covers Plex, Jellyfin, Emby, Audiobookshelf, Komga, Kavita, Romm |
| speedtest-tracker | Official Ookla CLI. **Native Discord notifications are deprecated** — use an Apprise sidecar. Hourly is plenty |
| nextexplorer | Replaces filebrowser, **archived 1 Sep 2026**, whose JWT sessions cannot be revoked. FileBrowser Quantum (`gtstef/filebrowser`) is the OIDC-capable fallback |
| pairdrop | WebRTC, stateless. **Avoid the public Snapdrop** — acquired by LimeWire in 2025 |
| tandoor + Postgres | **Pin the Postgres major, never `:latest`.** Set Django `ALLOWED_HOSTS` to the Caddy hostname up front or you get cryptic 400s |
| kitchenowl | Everyday shopping list; native iOS/Android apps |
| opengist | Snippets backed by a real Git repo. Behind Caddy with auth |
| immich-drop | Inbound zero-login uploads |
| immich public proxy | Outbound password-protected share links |
| paperless-ngx + Postgres + Redis | **The most important service to get right** — tax and legal documents |
| stirling-pdf | Moved here from `sandbox` |

**immich-drop + immich public proxy together keep the real Immich internal-only
and off Cloudflare Tunnel.** That is the point of running both.

**paperless-ngx:** pin the Postgres major. **Back up BOTH the database and the
document store** — one without the other is not a restore. OCR is CPU-bursty, so
run bulk imports off-hours.

**stirling-pdf:** 50+ operations including server-side OCR, which is why it beat
BentoPDF. **Disable analytics and telemetry on first launch, before feeding it
sensitive files.** The Java backend eats RAM even idle — fine here, which is why
it moved out of RAM-tight `sandbox`.

**Kitchen stack:** Tandoor = recipes and planning, KitchenOwl = shopping list,
Grocy = on trial in `sandbox`. **None has native cross-sync. Do not attempt to
sync them.**

The one gap a reviewer would name is **a unified auth layer** (Authentik /
Authelia), which is [open](./OPEN-QUESTIONS.md#unified-auth-layer).

### `immich` (dedicated Docker LXC) ~8 GB+

Four containers: **server, machine-learning, Postgres, Valkey.**

A dedicated LXC is the endorsed pattern — Immich is heavy, has its own database,
and does ML.

- The Postgres image now ships **VectorChord** (successor to pgvecto-rs) —
  verify and pin whatever the official Compose specifies.
- Requires **x86-64-v2**; the N5095 is fine.
- **Initial ML scan is CPU-bound** — roughly 2–4h per 10k photos with a RAM
  spike. Run it off-hours.
- **Hardware acceleration covers video transcoding only.** ML inference gets no
  GPU path.
- **Postgres and Valkey on node-local ZFS; only photo blobs on `sisyphus`.** The
  performance and reliability gap for the database specifically is large enough
  to matter.

> **Stand up HTTPS in front of Immich before onboarding any family or friends.**
> Retrofitting it means touching every phone twice.

Immich holds **the most irreplaceable data in the lab** and needs *both* the
database and the media filesystem protected, ideally 3-2-1.

Optional later: immich-power-tools (bulk library organization) shares Immich's
network and database, so it would live in this LXC. Not day-one.

---

## Themis — heavy compute

### `arr` (Docker) ~6 GB — the priority pipeline, treated as ONE system

The reference pattern is literally *"treat the arr apps as one system: single
Compose file, one shared network, matching PUID/PGID."* This matches. Wiring is
by **container name**, on **one unified `/data` mount** so hardlinks work.

Bazarr and the media servers only ever need the media path, never downloads.

| Service | Build note |
|---|---|
| prowlarr | **Keystone. Stand it up and configure indexers FIRST**, then add each arr app as an application inside it |
| radarr, sonarr | **Mount storage as a SINGLE unified root.** Split mounts break atomic moves and hardlinks |
| bazarr | Core only. Whisper AI subtitles **deferred** — wants a GPU, and Themis's UHD 630 is not passed into `arr` |
| byparr | Drop-in FlareSolverr replacement — same API, same port 8191. **Still add it in Prowlarr as a "FlareSolverr" proxy type.** Heaviest thing in the LXC while solving. Solvearr is the lightweight fallback |
| sabnzbd | Requires a paid Usenet provider |
| abs-arr | Own project, private ghcr image. Port 8788 |
| audiobookshelf | Used daily |
| reclaimerr | **The only tool in the stack that permanently deletes media** |
| **recyclarr** | Syncs TRaSH Guides quality profiles and custom formats into Radarr and Sonarr |

**sabnzbd build order** — its #1 failure mode is category-path mismatch, and
living in the same LXC as the arrs is what makes paths line up:

1. Give SAB the `sisyphus` complete mount.
2. Set category folders to match the arr apps.
3. Add SAB as a download client with its API key.
4. **Cap connections at the provider limit** (20–30).

**abs-arr:** create a PAT with `read:packages` and run `docker login ghcr.io` on
Themis **before** bringing up the compose. Pin your own tested tag.

**audiobookshelf:** library on `sisyphus/media`; `/config` and `/metadata`
node-local plus Restic — they hold listening bookmarks.

> **reclaimerr: build it, configure it, and run DRY-RUN / REPORT-ONLY ONLY.**
> Scheduled deletion stays **OFF** until a genuine off-box backup exists.
> Restic-to-Tartarus is on-box and does not protect against a bad rule.

**recyclarr is not a long-running container** — it is a scheduled sync job that
exits, so it has zero idle cost: `ghcr.io/recyclarr/recyclarr:latest sync`,
config from trash-guides.info. It prevents profile drift that silently degrades
releases or wastes storage.

Dropped here: **lidarr** (metadata provider problems; the 2026 pattern needs
Lidarr + slskd + Soularr, and slskd exposes IP P2P), whisparr, kapowarr, linkarr,
boxarr. **Cleanuparr rejected** — maintenance for maintenance's sake until dead
torrents are a felt problem. Huntarr and Checkrr likewise known-for-later.

### `grab` (Docker) ~4 GB — a convenience bucket, not a coupled system

Grouped by *what they are*, not by working together. **There is no integration to
get right here**, which is why it tolerates being the loosest grouping in the lab.

| Service | Notes |
|---|---|
| qbittorrent + **VueTorrent** | 2026 consensus client. Its **category system maps cleanly to arr categories** — Deluge needs a Label plugin. VueTorrent is a Vue.js reskin **enabled inside qBittorrent**, not an extra service |
| jdownloader | Miscellaneous web downloads, deliberately outside the media pipeline — **no hardlink flow, no shared sisyphus path needed** |
| metube | yt-dlp web UI. Occasional paste, not auto-archiving |

**jdownloader:** the jlesage image runs the desktop Java app headless and streams
its GUI to the browser on port 5800 — a remote-desktop feel, not a native web UI.
`/config` node-local plus Restic.

**metube:** Pinchflat, TubeSync and TubeArchivist were rejected as
subscription/archival-first. Storage stays unentangled.

**qui dropped** — it exists for multi-instance management and cross-seeding,
neither of which applies. Reopen only if private-tracker cross-seeding becomes a
thing.

> **Completed torrents must land on the shared `sisyphus` path mounted at an
> IDENTICAL path string in both `grab` and `arr`, or hardlinks fail.**
> **Mount first, then wire.**

### `sandbox` (Docker) ~2 GB — staged by TRUST LEVEL, not by function

Not a functional grouping at all. Nothing here integrates with anything else.
**Each service has a graduation trigger and leaves when it becomes load-bearing**
— you do not want something you depend on sharing a daemon with something you are
actively redeploying. The graduation rules *are* the design.

| Service | Status / trigger |
|---|---|
| changedetection.io | Category leader, no real self-hosted rival. Ships Apprise natively (85+ destinations) → fires straight at ntfy with no glue |
| comet-editor | Own Bun project. Port 3000, own tag pinned |
| grocy | On trial — clunky in-store entry, no official mobile apps, demands constant logging |

> **changedetection.io fails SILENTLY** — the thing that would alert you is the
> thing that stopped. Put Uptime Kuma on watch-the-watcher duty. **If it
> graduates from trial to relied-upon, move it into `apps` or `monitor`.**

Optional Playwright/Chrome sidecar only for JS-heavy pages.

**comet-editor** has zero dependencies on other services — import is manual or
via a watched folder. Watched folder and comic library on `sisyphus`; database
and config node-local plus Restic, never on NFS.

**Open WebUI dropped** — it is only a frontend. Ollama is the actual inference
engine, and UHD 630 gives no ML acceleration, so it would be CPU-only inference.
Reopen only if a box with a real GPU joins the lab.

### `homeassistant` (VM) ~4 GB

> **HAOS MUST be a VM, not an LXC.** It needs UEFI boot, a dedicated kernel and
> Supervisor access that LXC cannot provide.

VM overhead is a rounding error — roughly 1–2 W idle and 150–200 MB RAM.

Full HAOS buys the Supervisor, the add-on store and automatic OS updates.
**MQTT (Mosquitto), Zigbee2MQTT, Node-RED and ESPHome all run INSIDE the VM as
Supervisor add-ons** — the smart-home stack is self-contained, not spread across
the lab.

**USB passthrough.** Find the dongle with `lsusb`, then pass it **by
vendor:product ID**, never by port — port passthrough breaks on unplug/replug:

```bash
qm set <vmid> --usb0 host=<vendor:product>
```

Add the USB device **before** configuring Zigbee inside HA, and reboot the VM
after adding passthrough. Verify under *Settings → System → Hardware*.

> **Gotcha: the ID identifies the USB-serial CHIP, not the radio.** A Sonoff
> ZBDongle-P shows as `10c4:ea60` (Silicon Labs); a ZBDongle-E shows as
> `1a86:55d4` (CH9102). **Run `lsusb` and use what YOUR dongle prints — do not
> copy an ID out of a guide.**

The dongle **pins the VM to one node** — no free live migration, and if that node
dies, home automation dies with it. Physical placement matters too: a coordinator
buried in a rack may not reach upstairs sensors. Consider a USB extension cable.

**Enable BOTH HAOS's own Supervisor-level backups and Proxmox VM backups.**

---

## Cross-cutting decisions

- **Watchtower dropped.** Auto-`:latest` recreate is the top self-inflicted-
  downtime cause. Replaced by what's-up-docker (notify-only); pull deliberately
  after a snapshot.
- **No VPN anywhere.** See [DECISIONS.md](./DECISIONS.md) D17.
- **sabnzbd lives WITH `arr`** — Usenet is primary and reliable, so they go up or
  down together, insulated from qBittorrent. **qBittorrent is isolated in
  `grab`**; `arr` reaches it by IP:port. If `grab` dies, torrents queue but Sab
  keeps flowing.
- **Logseq needs no container.** It is a desktop/mobile app; the homelab only
  hosts the Git remote for sync.

> **Reading guides: nearly every arr and qBittorrent guide binds the download
> client behind gluetun/WireGuard and runs Watchtower. SKIP those sections.**
> Both were removed deliberately. Isolating qBittorrent into `grab` with no VPN
> is a considered divergence from the reference pattern, not a mistake to
> correct.

---

## Inventory → grouping map

`stacks/` directory names predate this architecture and are **inventory, not
placement**. Old `aeos`, `helios`, `atlas` and `hera` dissolve; `io`, `asteria`
and `apollo` survive as `grab`, `arr` and `media`.

| LXC / VM | Node | From `stacks/` | Not yet in the repo |
|---|---|---|---|
| `dns`, `proxy`, `tailscale`, `omada` | Rhea | — (native, no compose) | all four |
| `media` | Hestia | `apollo/*`, `asteria/aggregarr` | navidrome |
| `monitor` | Hestia | `atlas/{uptime-kuma,dozzle}`, `hera/ntfy` | beszel, what's-up-docker |
| `apps` | Hestia | `aeos/*`, `hera/pairdrop`, `helios/{opengist,stirling-pdf,tracktor,shipshipship,listinglab}`, `io/immich-drop` | nextexplorer, tandoor, kitchenowl, paperless-ngx, immich public proxy |
| `immich` | Hestia | — | all four containers |
| `arr` | Themis | `asteria/{prowlarr,radarr,sonarr,bazarr}`, `io/sabnzbd` | byparr, abs-arr, audiobookshelf, reclaimerr, recyclarr |
| `grab` | Themis | `io/{qbittorrent,jdownloader,metube}` | — |
| `sandbox` | Themis | `aeos/changedetection`, `helios/grocy` | comet-editor |
| `homeassistant` | Themis | — (VM) | — |

**`atlas/sisyphus-migrator` is not covered by the rev-7 service review.** It is a
profile-gated one-shot rsync helper for the migration itself, not a running
service. Retire it once the migration is done.

Services in the **"not yet in the repo"** column are decided but unbuilt — their
compose files do not exist yet. They are recorded here so the decision survives;
adding them is build work, not documentation.
