# Hardware Inventory

Measured state of the cluster. **Every sizing decision depends on this table**, so
it lives in the repo rather than in a chat log.

Last verified: **2026-09-26**. Update this file when hardware changes — a stale
inventory is worse than none, because it gets trusted.

Related: [DECISIONS.md](./DECISIONS.md) · [rebuild-runbook.md](./rebuild-runbook.md) ·
[OPEN-QUESTIONS.md](./OPEN-QUESTIONS.md)

---

## Cluster nodes

Cluster name: **`gaia`** — 3 nodes, expected votes 3, quorum 2, quorate.

| | Rhea | Hestia | Themis |
|---|---|---|---|
| Machine | N5095 mini-PC | N5095 mini-PC | Lenovo ThinkCentre M720q |
| CPU | 4× N5095 @ 2.0 GHz | 4× N5095 @ 2.0 GHz | i7-8700T, 6c/12t, up to 4.0 GHz |
| RAM | **15.40 GiB** | 31.13 GiB | 31.21 GiB |
| Boot disk | 500 GB NVMe | **1 TB** | 500 GB |
| Usable pool | ~457 GiB | **~915 GiB** | ~446 GiB |
| Second bay | **empty** (2.5" SATA) | **empty** (2.5" SATA) | **empty** (2.5" SATA) |
| QuickSync | H.265 | H.265 | H.265 (UHD 630) |
| IP | `10.0.0.10` | `10.0.0.12` | `10.0.0.11` |
| PVE | 9.2.2 | 9.2.2 | 9.2.2 |
| Filesystem | ZFS-on-root | ZFS-on-root | ZFS-on-root |

### What this table corrects

Earlier planning assumed a uniform upgrade that did not happen. Three corrections
matter for placement and sizing:

- **Not 1 TB everywhere.** Rhea and Themis are 500 GB; only Hestia is 1 TB.
  **Hestia is the largest-disk node by 2×** — that, not exclusive transcode
  ability, is its real advantage.
- **No second drives exist.** All three 2.5" bays are **empty**. Second-tier
  storage is a **purchase (3× 2.5" SATA SSD)**, not a re-use of existing disks.
  Anything depending on a second local pool is blocked until then — including
  bringing qBittorrent back onto the cluster.
- **Rhea's old 54 GiB pool constraint is gone.** At 500 GB it is a peer on disk.
  Its only remaining weakness is the **N5095 CPU**, which is why it hosts light
  infrastructure by choice rather than by force.

### Deferred upgrades

| Item | Status |
|---|---|
| Rhea RAM 15.4 → 32 GiB | Deferred on cost (single-SO-DIMM N5095 modules are expensive). **Blocks nothing** — see [DECISIONS.md](./DECISIONS.md) D14. |
| Themis RAM → 64 GiB | Possible later; M720q takes 2× SO-DIMM. |
| 3× 2.5" SATA SSD | **Purchase required.** Gates qBittorrent's return and VM-disk/scratch tiering. |

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
disposable workloads only, no snapshots, no backups. qBittorrent currently lives
here as a workaround and stays until the SATA SSDs are purchased. Nothing
critical belongs on it — see [DECISIONS.md](./DECISIONS.md) D8.

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
