# Decision Log

Locked architectural decisions for the homelab, with the reasoning behind each.

**This repo is the source of truth.** Chat sessions and assistant memory are not
a handoff mechanism and do not carry across surfaces. A decision that is not
written down here did not happen.

**Append, don't rediscover.** New decisions go at the bottom with the date they
were locked. If a decision is reversed, leave the original entry in place and add
a superseding entry that says what changed and why.

Things that were raised but *not* ratified live in
[Open Questions / Known Risks](./homelab-network-plan.md#open-questions--known-risks),
not here.

---

## 2026-09-04

### D1 — Addressing scheme: flat `10.0.0.0/24`

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
