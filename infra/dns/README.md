# `dns` / `dns2` — native LXC configuration

These two LXCs run **native daemons, not Docker**, so their configuration lives
here rather than in `stacks/`.

| LXC | CT | Node | IP | Role |
|---|---|---|---|---|
| `dns` | 100 | Rhea | `10.0.0.31` | Pi-hole **primary** + unbound + nebula-sync |
| `dns2` | 201 | Hestia | `10.0.0.32` | Pi-hole **replica** + its own unbound |
| — | — | floating | **`10.0.0.33`** | keepalived VRRP VIP — what DHCP advertises |

> **`10.0.0.31` is the ONLY Pi-hole you edit.** nebula-sync is one-way;
> anything changed on the replica is overwritten at the next sync. Blocklists,
> local DNS records, allowlist entries, settings — all go in at the primary.
> See [D27](../../docs/DECISIONS.md).

> **Never update both Pi-holes at once.** Replica first, confirm it answers,
> then the primary. [docs/update-discipline.md](../../docs/update-discipline.md).

Build record and verification: [docs/build-record.md](../../docs/build-record.md).

## Files

| File | Goes to | Notes |
|---|---|---|
| `unbound-pi-hole.conf` | `/etc/unbound/unbound.conf.d/pi-hole.conf` on **both** | Each has its OWN unbound |
| `keepalived-primary.conf` | `/etc/keepalived/keepalived.conf` on `dns` | `state MASTER`, priority 150 |
| `keepalived-replica.conf` | `/etc/keepalived/keepalived.conf` on `dns2` | `state BACKUP`, priority 100 |
| `nebula-sync.env.template` | `/opt/nebula-sync.env` on `dns`, mode **600** | Plaintext admin passwords |
| `nebula-sync.service` | `/etc/systemd/system/nebula-sync.service` on `dns` | |

## Why the replica runs its own unbound

It must **not** forward to Rhea's. If it did, a Rhea failure would take the
replica's upstream with it and defeat the entire design — the replica would hold
the VIP and resolve nothing.
