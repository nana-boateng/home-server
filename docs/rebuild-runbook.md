# Cluster Rebuild Runbook — PVE 9 + `gaia`

Record of the from-scratch rebuild of the three Proxmox nodes, completed
**2026-09-26**, plus the Themis NVMe rebuild and TrueNAS work completed
**2026-09-27**. Written as a runbook so it is repeatable, and so the decisions
and dead ends inside it are not re-litigated.

**Framing: this was a rebuild, not a live migration.** Services and LXCs are
being recreated rather than moved. Placement is therefore a fresh design
decision, not an inherited constraint — see [DECISIONS.md](./DECISIONS.md) D13
and the placement rule in
[homelab-architecture-notes.md](./homelab-architecture-notes.md).

A few services with hard-to-recreate configuration (SABnzbd is the notable one)
are restored from backup. For those: build the container fresh with a local-disk
config path, then drop the restored config in **before first start**.

---

## Why clean-install rather than upgrade

**PVE 8.4 reached end of life on 2026-08-31.** All three nodes were
clean-installed on PVE 9 rather than upgraded in place.

**Cluster teardown was deliberately skipped.** No `pvecm delnode`, no manual
`pmxcfs -l` surgery. The reasoning, recorded so it is not re-argued:

- The old cluster was formed on the **old IPs**.
- Corosync binds by IP, so that cluster was **already broken**.
- A clean install wipes cluster configuration anyway.

Tearing down a cluster that was already non-functional, on machines about to be
wiped, would have been ceremony rather than work.

---

## Completed sequence

All six steps are **done** on all three nodes.

### 1. Back up keeper configs

Done before the wipe.

### 2. Clean-install PVE 9 with ZFS-on-root

> **Gotcha that cost a full install round.** ZFS is selected via the **Options
> button on the Target Harddisk screen** — filesystem `zfs (RAID0)`. It is *not*
> a screen of its own. Missing the button silently produces ext4/LVM, which is
> what happened on the first attempt.

Settings used: `ashift 12`, compress on, checksum on, copies 1.

**All three nodes are single-disk, so this is single-disk ZFS — no RAID
redundancy.** Snapshots and checksums detect corruption but cannot repair it.
They are not a substitute for the Restic backups in
[DECISIONS.md](./DECISIONS.md) D12.

### 3. Fix repositories

Disable `pve-enterprise` **and** `ceph-squid` enterprise; enable
`pve-no-subscription`.

> **Gotcha.** Having enterprise and no-subscription enabled *simultaneously*
> still returns 401. **Both** enterprise rows must be off — disabling only
> `pve-enterprise` is not enough.

### 4. Full upgrade

```bash
apt update && apt full-upgrade
```

All three nodes on **9.2.2**.

### 5. Static IPs

Rhea `10.0.0.10`, Themis `10.0.0.11`, Hestia `10.0.0.12`. Gateway and DNS both
`10.0.0.1`.

**The Proxmox hosts deliberately resolve via the router, not Pi-hole.** This
keeps DNS recovery non-circular: if the Pi-hole LXC is down, the hosts that need
to start it can still resolve names.

### 6. Form the cluster

Cluster name **`gaia`**. Created on Rhea; Themis and Hestia joined via the GUI
Join Information flow. Result: 3 nodes, expected votes 3, quorum 2, **Quorate:
Yes**.

> **Gotcha.** The joining node's web session breaks mid-join, because its
> certificate is replaced. Reload and re-login. **This is not a failure** — it
> looks alarming and is expected.

---

## Themis NVMe rebuild — DONE (2026-09-27)

Themis was rebuilt onto a new **WD SN550 NVMe** in its single M.2 slot. The
M720q has **one M.2 plus one 2.5" SATA bay**, so the old mechanical disk moved to
the SATA bay and became the `themis-500` scratch pool.

### Sequence

**1. Remove the node from the cluster BEFORE reinstalling.**

```bash
# from a surviving node
pvecm delnode themis
```

> This drops `gaia` to 2/3 with **zero fault tolerance for the duration of the
> window**. Do it deliberately, and rejoin promptly.

**2. Clean-install PVE 9 over the prior Windows + Arch EFI.**

> **Installer gotcha: both disks are pre-selected for the ZFS RAID0 root.**
> Set Harddisk 1 (the HDD) to **"do not use"** so root lands on the NVMe alone.
> Missing this stripes root across an NVMe and a mechanical disk.

**3. Clear stale NVRAM boot entries** left by the old operating systems:

```bash
efibootmgr            # list
efibootmgr -b <N> -B  # delete each stale entry
```

**4. Rejoin the cluster** via the GUI Join Information flow.

Result: `gaia` whole again — 3 nodes, config version 5, Themis node ID 2,
445.78 GiB `local-zfs`.

**5. Recreate the old HDD as the `themis-500` pool** — see
[hardware-inventory.md](./hardware-inventory.md#themis--themis-500-scratch-pool)
for why its Proxmox storage entry is deliberately absent.

---

## TrueNAS — DONE (2026-09-27)

- **Domain changed `local` → `lan`.** `.local` is reserved for mDNS; see
  [DECISIONS.md](./DECISIONS.md) D2.
- **`sisyphus` NFS export** scoped to `10.0.0.0/24`, **no maproot** — identity
  comes from UID/GID 3004.
- **`tantalus` dataset + NFS export** added, with **maproot root**.
- **Proxmox storage `tantalus`** = ISO + CT template + Backup.
  **Disk image is deliberately OFF** — no VM disks over NFS.
- Verified: write test passed, CT template download succeeded.

---

## Other gotchas worth keeping

- **PVE 9 will not run containers with pre-2016 systemd** (CentOS 7 / Ubuntu
  16.04 era). Current templates are fine; ancient ones silently fail to start.
- **Rhea needs its audio blacklist reapplied after any reinstall.** See
  [hardware-inventory.md](./hardware-inventory.md#rhea--snd_hda_intel-must-stay-blacklisted).
  Without it, Rhea sits at a permanent 1.00 load average and every load-based
  alert is calibrated against a bug.

---

## Still to do

Items 1–3 of the previous list are **done** — see
[build-record.md](./build-record.md) for the `themis-500` cleanup, the
`/mnt/sisyphus` host mounts, and the verified `/dev/dri` passthrough.

### 1. Finish the two built LXCs

- **Point `media` at the live resolver:** `pct set 200 --nameserver 10.0.0.31`,
  then restart. It was built before `dns` existed.
- **Enable hardware transcoding inside Plex and Jellyfin** — it is off by
  default, so the verified passthrough does nothing until switched on. Confirm
  with a forced transcode; **Tautulli shows the decision.**
- **Add local `.lan` records in Pi-hole** so split-horizon actually resolves.

### 2. Build `monitor` on Hestia — the natural next LXC

Same node as `media`, and Kuma watching the media stack pays off immediately.

> **Set its resolver to `10.0.0.1`, not Pi-hole:**
> `pct set <id> --nameserver 10.0.0.1`, then restart. `dns` is live and the whole
> network points at it, so a `monitor` resolving through Pi-hole would go blind
> at exactly the moment Rhea died.

### 3. Prepare Themis, then build `arr` and `grab`

```bash
# on Themis — Hestia already has this, Themis does not
echo 'root:3004:1' >> /etc/subuid
echo 'root:3004:1' >> /etc/subgid
```

Plus the six `lxc.idmap` lines in each container config —
[build-gotchas.md](./build-gotchas.md#unprivileged-containers-need-an-idmap-to-use-the-nfs-share).

Then `arr` (Prowlarr's indexers first), then `grab`. **Chown
`/themis-500/incomplete` to `3004:3004` as part of the `grab` build** — it is
`root:root` today and qBittorrent runs as 3004.

Also check **Themis's node search domain**; Rhea's was `an`, not `lan`.

### 4. Build the rest of the service layer

Per [service-architecture.md](./service-architecture.md) — 9 LXCs and the VM
remain. Many of those services **have no compose file in this repo yet**; the map
records the decision, not the implementation. As each LXC is built, its real
compose lands in `stacks/<lxc>/`.

### 5. Restic

Per [DECISIONS.md](./DECISIONS.md) D12: per-node agents, ZFS-snapshot quiesce,
shared deduplicated repo on Tartarus, ntfy notification, and a **real restore
test**.

> The **off-box copy** gates Reclaimerr's scheduled deletion (D23).

### 6. Verify NFS-before-container ordering

On the next reboot of each node, confirm the bind mounts actually carry NFS
content and not an empty local directory —
[OPEN-QUESTIONS.md](./OPEN-QUESTIONS.md#nfs-before-container-ordering-at-boot).
