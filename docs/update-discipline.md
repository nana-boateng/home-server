# Update Discipline

**Nothing in this lab auto-updates.** wud notifies; you pull deliberately after
a snapshot.

That rule comes from the Watchtower decision ([D17](./DECISIONS.md),
[D22](./DECISIONS.md)): auto-`:latest` recreate is the top cause of
self-inflicted downtime. Every image is pinned to a version actually pulled and
read off the image ([D26](./DECISIONS.md)).

This page covers the cases where *order* matters as much as the decision to
update at all.

---

## Version-coupled pairs

Three pairs must be version-matched or upgraded in a specific order. **Getting
this wrong breaks things quietly, which is worse than breaking them loudly.**

### Beszel hub + agents — must match exactly

| Component | Where | Version |
|---|---|---|
| hub | `monitor` (CT 202) | `0.20.0` |
| agent | Rhea, native systemd | `0.20.0` |
| agent | Hestia, native systemd | `0.20.0` |
| agent | Themis, native systemd | `0.20.0` |

**Not independently upgradable. Upgrade all four together.**

> **Decline the installer's daily auto-update offer.** Agents silently drifting
> ahead of the hub breaks monitoring — and the thing that would tell you is the
> thing that stopped.

Agents run **native on each node, not in containers**: an agent inside an LXC
reports that container's slice, not the node.

### Dozzle server + agents — must match exactly

| Component | Where | Version |
|---|---|---|
| server | `monitor` (CT 202) | `v11.1.3` |
| agent | `media` (CT 200) | `v11.1.3` |
| agent | `arr` (CT 300) | `v11.1.3` |
| agent | `grab` (CT 301) | `v11.1.3` |

**Upgrade all four together, and every future stack adds another agent to keep
in step.** The coupling grows with the lab.

### The two Pi-holes — never both at once

> **Update the replica first, confirm it still answers, then the primary.**

A bad update with both down means **zero redundancy** at exactly the moment you
need it. The whole point of `dns2` is that it is not on the same node as `dns`;
updating them together throws that away for the duration.

Confirm the replica directly before touching the primary:

```bash
dig google.com @10.0.0.32            # replica resolves public names
dig plex.lan @10.0.0.32              # and still has its local records
```

The second query matters: a replica that resolves public names but has silently
lost its local records is the failure nebula-sync could produce.

---

## The DNS pair also has an edit rule

Not an update rule, but it fails the same way — silently.

> **`10.0.0.31` is the ONLY Pi-hole you edit.** nebula-sync is one-way, so
> anything changed on the replica is overwritten at the next hourly sync.

Blocklists, local DNS records, allowlist entries, settings — all go in at the
primary. See [D27](./DECISIONS.md).

This is also why keepalived keeps **preemption on**: `nopreempt` would let the
lab run on the replica for weeks without anyone noticing, and every edit made in
that window would vanish.

---

## Docker version drift

| LXC | Docker |
|---|---|
| `media` (CT 200) | 29.8.1 |
| `monitor` (CT 202), `arr` (CT 300), `grab` (CT 301) | 29.8.2 |

Harmless — they were built days apart. Worth a deliberate bump policy before
there are a dozen of them. Tracked in
[OPEN-QUESTIONS.md](./OPEN-QUESTIONS.md#other-standing-items).

---

## Major-version upgrades

Any jump the releases page shows as a new major — Uptime Kuma 1 → 2, say — in
this order:

1. **Read the project's migration notes.**
2. **Snapshot the whole LXC from its host:** `pct snapshot <id> pre-<thing>`.
   > **App-level exports are not a safe rollback** — Uptime Kuma 2.0 changed its
   > own backup feature, so the thing you would restore with is itself part of
   > what changed.
3. Pull the exact new tag and confirm its version.
4. Change the tag in the compose, `docker compose up -d <svc>`, and **follow the
   logs through the migration without restarting it partway.**
5. Verify in the UI.
6. If broken: `pct rollback <id> pre-<thing>`.
   If good: `pct delsnapshot <id> pre-<thing>`, so the snapshot doesn't pin old
   data on ZFS.

---

## Things that update themselves anyway

Known exceptions to "nothing auto-updates", all deliberate:

| Thing | Behaviour |
|---|---|
| **JDownloader** | Updates its own core at runtime, by design. The image stays pinned |
| **VueTorrent** | Installed from a release zip, so it **never** updates itself — record the installed version and re-download deliberately |
| **Recyclarr's daily sync** | Changes Radarr/Sonarr profiles whenever TRaSH changes its guides. That is **configuration, not code**, and is the point of running it — review `docker compose logs recyclarr` occasionally |

> **wud currently sees only `monitor`'s Docker daemon**, so `media`, `arr` and
> `grab` get **no update notifications at all**. Until that is fixed, check them
> by hand with `scripts/check-versions.sh`.

---

## Update procedure

For anything not listed above:

1. **Snapshot first.** `vzdump` or a ZFS snapshot of the LXC.
2. Read the new version off the image before pinning it — never off a guide:
   ```bash
   docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' <image>:latest
   ```
   Not every image carries a label; [build-gotchas.md](./build-gotchas.md) lists
   the ones that need a different method.
3. **Update the pin in this repo**, not just on the host — the repo is the source
   of truth ([D9](./DECISIONS.md)).
4. Pull, recreate, verify the service actually works.

> **`apps` is the densest shared-fate unit in the lab.** When it exists,
> sequence its updates one service at a time — everything in it shares a Docker
> daemon, so a bad pull takes the whole utility layer with it.
