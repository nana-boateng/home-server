# Cluster Rebuild Runbook — PVE 9 + `gaia`

Record of the from-scratch rebuild of the three Proxmox nodes, completed
**2026-09-26**. Written as a runbook so it is repeatable, and so the decisions
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

## Other gotchas worth keeping

- **PVE 9 will not run containers with pre-2016 systemd** (CentOS 7 / Ubuntu
  16.04 era). Current templates are fine; ancient ones silently fail to start.
- **Rhea needs its audio blacklist reapplied after any reinstall.** See
  [hardware-inventory.md](./hardware-inventory.md#rhea--snd_hda_intel-must-stay-blacklisted).
  Without it, Rhea sits at a permanent 1.00 load average and every load-based
  alert is calibrated against a bug.

---

## Still to do

1. **NFS mounts to Tartarus `10.0.0.20`** on all three nodes.
2. **Rebuild the stacks** per the placement rule, using the local-appdata layout
   from [DECISIONS.md](./DECISIONS.md) D11 — configs on node-local ZFS at
   `/opt/appdata/<stack>/<service>`, NFS for bulk data only.
3. **Stand up the infrastructure LXCs on Rhea** — Pi-hole + Unbound, Caddy,
   Uptime Kuma, ntfy, Tailscale subnet router, Omada software controller.
4. **Set up Restic** per D12: per-node agents, ZFS-snapshot quiesce, shared
   deduplicated repo on Tartarus, ntfy notification, and a real restore test.

Not in this phase, and blocked on hardware: bringing qBittorrent back onto the
cluster. It needs the 2.5" SATA SSDs that do not exist yet — see
[OPEN-QUESTIONS.md](./OPEN-QUESTIONS.md).
