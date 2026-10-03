# Hardware Inventory

Measured state of the cluster. **Every sizing decision depends on this table**, so
it lives in the repo rather than in a chat log.

Last verified: **2026-10-03**. Update this file when hardware changes — a stale
inventory is worse than none, because it gets trusted.

Related: [DECISIONS.md](./DECISIONS.md) · [rebuild-runbook.md](./rebuild-runbook.md) ·
[OPEN-QUESTIONS.md](./OPEN-QUESTIONS.md)

---

## Cluster nodes

Cluster name: **`gaia`** — 3 nodes, expected votes 3, quorum 2, quorate.

| | Rhea | Hestia | Themis |
|---|---|---|---|
| Machine | **Beelink Mini S** | **Beelink Mini S** | Lenovo ThinkCentre M720q |
| CPU | N5095, 4c | N5095, 4c | i7-8700T, 6c/12t |
| RAM | **16 GB** (15.40 GiB) | 32 GB | 32 GB |
| Boot disk | **500 GB M.2 SATA** (Timetec NMS04) | **1 TB M.2 SATA** (Fanxiang S201) | **500 GB WD SN550 NVMe** |
| Scratch pool | — | — | **`themis-500`: 500 GB WD5000LPLX HDD** |
| Second bay | empty (2.5" SATA) | empty (2.5" SATA) | now holds the old HDD |
| iGPU | UHD, 16 EU (Jasper Lake) | UHD, 16 EU (Jasper Lake) | **UHD 630, 24 EU** |
| IP | `10.0.0.10` | `10.0.0.12` | `10.0.0.11` |
| PVE | 9.2.2 | 9.2.2 | 9.2.2 |
| Filesystem | ZFS-on-root | ZFS-on-root | ZFS-on-root |

### What this table changes

- **Rhea and Hestia are the SAME machine** — Beelink Mini S, N5095 — differing
  only in RAM and disk. **Rhea is the light-infra node because of RAM and disk,
  not CPU.** They are therefore **interchangeable**, which is real resilience:
  either can take the other's role.
- **32 GB works on the N5095 board.** Hestia proves it despite Intel's official
  16 GB cap, so Rhea's upgrade is known-good rather than a gamble.
- **No AV1 anywhere.** Jasper Lake (Gen 11) and UHD 630 (Gen 9.5) both predate
  Intel AV1 decode, which arrives in Gen 12. All three do H.264 / HEVC / VP9.
  **Confirmed empirically** by `vainfo` inside CT 200 — H.264 Main/High, HEVC
  Main through Main444_10, VP9 profiles 0–3, VC1, MPEG2, JPEG, with both decode
  (`VLD`) and encode (`EncSliceLP`) entrypoints, and no AV1 entry at all.
  See [build-record.md](./build-record.md).
- **Rhea and Hestia boot from M.2 SATA, not NVMe** — corrected 2026-10-03.
  `lsblk` shows `sda`, `TRAN sata`, and `rpool` on `ata-...-part3`. **Only Themis
  has NVMe.** This retired a false alarm: Beszel reporting `sda` for root I/O on
  those two was **correct all along**, so no `FILESYSTEM` override is needed —
  and a hard-coded `sdX` could become wrong once a 2.5" bay is filled.
- **Jasper Lake encodes with the low-power encoder only** (`EncSliceLP` in
  `vainfo`), which depends on Intel's **HuC firmware** being loaded on the host.
  Relevant to the
  [parked hardware-transcoding failure](./OPEN-QUESTIONS.md#hardware-transcoding-fails--parked).
- **Themis has the strongest iGPU** (UHD 630, 24 EU) — and media still did **not**
  move there. See [service-architecture.md](./service-architecture.md).
- **Themis's scratch blocker is resolved** by the `themis-500` HDD pool. Rhea's
  and Hestia's 2.5" bays are still empty.

### Deferred upgrades

| Item | Status |
|---|---|
| Rhea RAM 16 → 32 GB | Deferred on cost. **Blocks nothing**, and **known-good** — Hestia runs 32 GB on the identical board. See [DECISIONS.md](./DECISIONS.md) D14. |
| Themis RAM → 64 GB | Possible later; M720q takes 2× SO-DIMM. |
| 2.5" SATA SSD for Rhea / Hestia | Bays empty. **Lower priority** now that `themis-500` exists. |

---

## Storage

| Host | Role | IP |
|---|---|---|
| Tartarus | TrueNAS SCALE (F4-423) | `10.0.0.20` |

Datasets and the identity model: [truenas-proxmox-storage.md](./truenas-proxmox-storage.md).

---

## Network

| Device | IP | Notes |
|---|---|---|
| ER605 | `10.0.0.1` | Gateway; keeps inter-VLAN routing and firewalling |
| OC200 | `10.0.0.2` | Reserved — faulty, RMA outstanding |
| MikroTik CRS310-8G+2S+IN | `10.0.0.3` | Core switch, RouterOS v7.24.4 stable |
| EAP650 | `10.0.0.4` | Access point |

Switch detail, port map, and the routing decision:
[network-core-crs310.md](./network-core-crs310.md).

**2.5G only materialises where both ends support it.** Tartarus (F4-423) does; the
M720q is gigabit; the N5095 boxes vary. Check negotiated rates in the switch's
Interfaces view rather than assuming.

---

## Non-cluster hardware

**The fourth machine (seedbox)** — same specs as the weakest node, deliberately
**outside** the `gaia` cluster. Explicitly non-production: experiments and
disposable workloads only, no snapshots, no backups. Nothing critical belongs on
it — see [DECISIONS.md](./DECISIONS.md) D8.

qBittorrent is **no longer blocked** on it: the `themis-500` HDD pool gives the
incomplete-downloads scratch it needed, so it moves into the `grab` LXC on
Themis.

---

## Node-specific fixes

### Rhea — `snd_hda_intel` must stay blacklisted

**Symptom.** Load average pinned at exactly `1.00` with ~0% CPU and 0% IO delay.
Reproduced across two clean installs.

**Cause.** The onboard Intel HDA audio controller times out
(`azx_get_response timeout`), wedging a kernel worker on the power-management
workqueue (`kworker/u16:2+pm`) in permanent D state. Linux counts D-state tasks
toward load average, so one stuck task pins load at exactly 1.00 forever.

**Fix.** `/etc/modprobe.d/blacklist-audio.conf`:

```
blacklist snd_hda_intel
blacklist snd_hda_codec_hdmi
```

then:

```bash
update-initramfs -u && reboot
```

Load dropped to normal (0.24 / 0.27 / 0.11).

> **This does not survive a reinstall. If Rhea is ever rebuilt, reapply it.**
>
> **Do NOT apply to Themis or Hestia** — they do not have the problem, and
> applying it there is pure config drift.

**Why it is recorded here rather than treated as a footnote:** a permanent +1.00
load baseline poisons every load-based alert in Uptime Kuma. Anyone tuning
monitoring thresholds against an unfixed Rhea would calibrate around a bug.

### Themis — `themis-500` scratch pool

The old mechanical boot disk was wiped and recreated as a single-disk ZFS pool,
`themis-500` (ashift 12, compress on), in the M720q's 2.5" SATA bay.

> **The Proxmox storage ENTRY was deliberately REMOVED.** The ZFS plugin only
> offers *Disk-image* and *Container* content types — both wrong here, and a
> rootfs footgun: it invites guests to land their root disks on a mechanical
> drive. The pool is used **directly**, via `zfs create` plus bind mounts.

Purpose: **incomplete-downloads scratch.** Sequential writes, no SSD wear, and
the data is disposable. See [DECISIONS.md](./DECISIONS.md) D21.

**Housekeeping done:** `themis-500/downloads` renamed to
`themis-500/incomplete`, and the orphaned `themis-500/transcode` destroyed —
transcode goes to tmpfs, not this pool.

**Per-client subfolders, owned `3004:3004`** (done): `incomplete/sabnzbd` (SAB
in `arr`), `incomplete/qbittorrent` (`grab`), and `incomplete/qbittorrent-vpn`
to come. Bind-mounted into both `arr` and `grab` as `/mnt/incomplete`.
