# Deploy from the repo

Making [D9](./DECISIONS.md) mechanically true: the hosts read the repo instead
of the repo describing the hosts.

Until now the repo was **downstream** — things were built, described in a brief,
and transcribed. Transcription is lossy, and the 2026-10-04 export proved it:
six unfilled image tags, a `group_add` nobody knew was vestigial, a Recyclarr
schema in the wrong shape, and a keepalived weight that was fixed on one node
and not the other. After the flip, drift is `git status` on the host.

---

## Layout

| Path | What | In git |
|---|---|---|
| `/opt/home-server` | the clone | — |
| `/opt/home-server/stacks/<stack>/compose.yaml` | **what actually deploys** | yes |
| `/opt/stacks/<stack>/.env` | secrets, mode 600 | **never** |
| `/opt/stacks/<stack>/compose.yaml.bak` | the pre-flip file, kept | no |

Two rules make this work, and both are already applied to every compose file:

- **`name: <stack>` at the top.** The project name must stay what it was when
  the stack was deployed from `/opt/stacks/<stack>/` — which was the directory
  name. Change it and Compose orphans the running containers instead of
  adopting them.
- **`env_file:` is an absolute path** under `/opt/stacks/<stack>/`. A relative
  `.env` would resolve next to the compose file — i.e. inside the clone, where
  it must not be.

---

## Cutover, one LXC at a time

Order: **`grab` → `arr` → `media` → `monitor`.** Loosest grouping first; the one
that would hide its own failure last.

`dns` and `dns2` come later and separately — they are native daemons, not
Compose, so they need an install script rather than this. **Replica first.**

### 1. Deploy key

Generate **on that LXC**, ed25519, read-only, titled by hostname. One per LXC so
a single key can be revoked without touching the others.

```bash
ssh-keygen -t ed25519 -C "$(hostname)" -f /root/.ssh/id_ed25519 -N ""
cat /root/.ssh/id_ed25519.pub     # -> GitHub repo -> Settings -> Deploy keys
```

Leave **Allow write access unchecked.**

### 2. Clone

```bash
git clone git@github.com:nana-boateng/home-server.git /opt/home-server
```

### 3. Keep the old file

```bash
cp /opt/stacks/<stack>/compose.yaml /opt/stacks/<stack>/compose.yaml.bak
```

### 4. The switch-over test

```bash
/opt/home-server/scripts/deploy.sh <stack> --dry-run
```

> **It must report nothing to recreate.** That is the whole test. The repo file
> was verified byte-for-byte against the export, so a recreate means something
> changed on the host since 2026-10-04 — find out what before proceeding.

### 5. Deploy

```bash
/opt/home-server/scripts/deploy.sh <stack>
```

Then confirm the containers are the same ones, not replacements:

```bash
docker ps --format '{{.Names}}\t{{.RunningFor}}'
```

Uptimes should be unchanged. A container that just restarted was recreated.

---

## After the flip

**Edit in git, never on the host.** `deploy.sh` runs `git pull --ff-only`, which
**fails on a dirty clone** rather than merging or stashing. That failure is the
drift detector — it is the point, not an obstacle.

When it fails:

```bash
git -C /opt/home-server status --porcelain
git -C /opt/home-server diff
```

Then move the change into the repo properly, rather than discarding it — a
hand-edit on the host usually means someone fixed something real.

**Secrets never move.** `.env` stays on the host, and
`stacks/<stack>/.env.template` in the repo documents the key names. `arr` and
`grab` have no `.env` at all; `deploy.sh` only passes `--env-file` when the file
exists.

---

## What this does not cover

- **`dns` / `dns2`** — native daemons. The configs are in
  [`infra/dns/`](../infra/dns/), but installing them needs a script, not
  Compose.
- **Host-level state** — fstab, subuid/subgid, `pct` config, the Rhea audio
  blacklist. Recorded in [build-record.md](./build-record.md) and
  [hardware-inventory.md](./hardware-inventory.md); applied by hand.
- **App configuration inside containers** — Prowlarr indexers, SAB categories,
  Kuma monitors. Lives in each app's own database, covered by Restic
  ([D12](./DECISIONS.md)) once that exists, which it does not yet.
