# TrueNAS to Proxmox Container Storage

This document defines the clean storage layout for Proxmox LXC containers using
TrueNAS SCALE on `tartarus` (`<TRUENAS_IP>`). It replaces the old mixed
`/mnt/tartarus/storage` pattern with two purpose-specific exports:

- `sisyphus`: container/app storage
- `ixion`: personal storage

The goal is to make future Proxmox nodes mount the same storage consistently,
with predictable ownership and without depending on old CIFS-era permissions.

## Naming

Use these names everywhere:

| Name | Purpose | TrueNAS path | Proxmox mount |
| --- | --- | --- | --- |
| `sisyphus` | Container/app writable storage | `/mnt/tartarus/sisyphus` | `/mnt/lxc_shares/sisyphus` |
| `ixion` | Personal/human data | `/mnt/tartarus/ixion` | `/mnt/lxc_shares/ixion` |

Do not reuse `/mnt/tartarus/storage` for new container workloads.

## Identity Model

Use `sisyphus` as the container storage identity:

| User/group | UID | GID | Use |
| --- | ---: | ---: | --- |
| `sisyphus` | `3004` | `3004` | Owns and writes `sisyphus` |
| `nana` | `3000` | `3000` | Owns/administers `ixion` |

For LXC containers that need write access to `sisyphus`, pass through UID/GID
`3004` on the Proxmox host and run the relevant container processes as
UID/GID `3004`.

Do not rely on UID `1000` for this storage unless the TrueNAS dataset ownership
is intentionally changed to match.

## TrueNAS Datasets

Create two datasets under pool/dataset `tartarus`:

```text
tartarus/sisyphus
tartarus/ixion
```

Expected paths:

```text
/mnt/tartarus/sisyphus
/mnt/tartarus/ixion
```

Recommended subdirectories for `sisyphus`:

```text
/mnt/tartarus/sisyphus/downloads
/mnt/tartarus/sisyphus/media
/mnt/tartarus/sisyphus/appdata
/mnt/tartarus/sisyphus/shared
```

These are plain directories inside one dataset, not child ZFS datasets.

Recommended subdirectories for `ixion` are user-data specific. Keep them separate
from container write paths.

## TrueNAS Permissions

### `sisyphus`

Set ownership:

```text
owner: sisyphus
group: sisyphus
uid: 3004
gid: 3004
```

Recommended permissions:

```text
mode: 770
```

Recommended ACL intent:

```text
owner/group rwx only
nana: Full Control, for manual administration
```

All container-created files should remain owned by `3004:3004` unless there is
a deliberate reason to use a different identity.

### `ixion`

Set ownership:

```text
owner: nana
group: nana
uid: 3000
gid: 3000
```

Recommended ACL intent:

```text
nana: Full Control
sisyphus: no access by default
```

Treat `ixion` as personal/human storage. Do not give containers write access by
default. If a container needs access, prefer a narrow read-only mount or a
dedicated subdirectory with an explicit ACL.

## TrueNAS NFS Shares

Create separate NFS exports:

```text
/mnt/tartarus/sisyphus
/mnt/tartarus/ixion
```

Network:

```text
<LAN_SUBNET>
```

Recommended `sisyphus` export mapping:

```text
mapall_user: sisyphus
mapall_group: sisyphus
```

This makes writes through the export land as `3004:3004`.

Recommended `ixion` export mapping:

```text
maproot_user: root
maproot_group: root
```

Do not use `mapall_user=sisyphus` on `ixion`, because that would blur the
boundary between personal data and container/app data.

## Proxmox Host Setup

On each Proxmox node, create local mountpoints:

```sh
mkdir -p /mnt/lxc_shares/sisyphus
mkdir -p /mnt/lxc_shares/ixion
```

Add fstab entries:

```fstab
<TRUENAS_IP>:/mnt/tartarus/sisyphus /mnt/lxc_shares/sisyphus nfs vers=3,soft,timeo=30,retrans=2,_netdev 0 0
<TRUENAS_IP>:/mnt/tartarus/ixion /mnt/lxc_shares/ixion nfs vers=3,soft,timeo=30,retrans=2,_netdev 0 0
```

Mount and verify:

```sh
mount /mnt/lxc_shares/sisyphus
mount /mnt/lxc_shares/ixion
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /mnt/lxc_shares/sisyphus
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /mnt/lxc_shares/ixion
ls -lan /mnt/lxc_shares/sisyphus
ls -lan /mnt/lxc_shares/ixion
```

Use NFSv3 for these exports unless the TrueNAS/Proxmox NFSv4 pseudo-root setup
has been intentionally redesigned and tested. The previous NFSv4 child-export
mount presented an empty-looking mountpoint from inside Proxmox.

## LXC ID Mapping

For unprivileged containers that need to write to `sisyphus`, allow root on the
Proxmox host to map UID/GID `3004`:

```text
/etc/subuid:
root:3004:1

/etc/subgid:
root:3004:1
```

Then split the container idmap so UID/GID `3004` passes through directly.

Example idmap:

```text
lxc.idmap: u 0 100000 1000
lxc.idmap: u 1000 1000 1
lxc.idmap: u 1001 101001 2003
lxc.idmap: u 3004 3004 1
lxc.idmap: u 3005 103005 62531
lxc.idmap: g 0 100000 1000
lxc.idmap: g 1000 1000 1
lxc.idmap: g 1001 101001 2003
lxc.idmap: g 3004 3004 1
lxc.idmap: g 3005 103005 62531
```

This preserves the existing UID/GID `1000` passthrough while also allowing
`sisyphus` (`3004:3004`) to be represented inside the container.

After changing idmaps, restart the container:

```sh
pct shutdown <ctid> --timeout 30 || pct stop <ctid>
pct start <ctid>
```

## LXC Mounts

Mount `sisyphus` into containers that need app/media storage:

```text
mp0: /mnt/lxc_shares/sisyphus,mp=/mnt/storage
```

Mount `ixion` only when needed, and prefer read-only for containers:

```text
mp1: /mnt/lxc_shares/ixion,mp=/mnt/personal,ro=1
```

Only make `ixion` writable in a container if that container has a clear,
intentional reason to modify personal data.

## Verification

From the Proxmox host:

```sh
ls -lan /mnt/lxc_shares/sisyphus
touch /mnt/lxc_shares/sisyphus/.host_write_test
rm /mnt/lxc_shares/sisyphus/.host_write_test
```

From inside a container:

```sh
pct exec <ctid> -- ls -lan /mnt/storage
pct exec <ctid> -- setpriv --reuid=3004 --regid=3004 --clear-groups sh -c 'id; touch /mnt/storage/downloads/.ct_write_test && rm /mnt/storage/downloads/.ct_write_test && echo WRITE_OK'
```

Expected:

```text
uid=3004 gid=3004
WRITE_OK
```

If files show as `65534:65534`, the relevant UID/GID is not mapped into the
container. Either map the owner ID or fix the dataset ownership/ACL to match
the selected container identity.

## Future Node Checklist

For each new Proxmox node:

1. Install/configure NFS client support.
2. Create `/mnt/lxc_shares/sisyphus` and `/mnt/lxc_shares/ixion`.
3. Add the two fstab entries using NFSv3.
4. Mount and verify both exports.
5. Add `root:3004:1` to `/etc/subuid` and `/etc/subgid` if containers will use
   `sisyphus`.
6. Add the `3004` passthrough idmap to any unprivileged CT that writes to
   `sisyphus`.
7. Mount `sisyphus` into those CTs as `/mnt/storage`.
8. Mount `ixion` only when needed, preferably read-only.
9. Test write as UID/GID `3004` from inside the CT.
10. Do not migrate old `/mnt/tartarus/storage` permissions forward blindly.

## Migration Guidance

Migrate gradually:

1. Create and verify `sisyphus`.
2. Point one low-risk app or download path at `sisyphus`.
3. Confirm new files are created as `3004:3004`.
4. Move media/app data in stages.
5. Keep personal data in `ixion`, not in `sisyphus`.

Avoid recursive ownership changes on old storage unless the target ownership and
application impact are clear.

## Container Path Conventions

Use these paths consistently inside LXC containers:

```text
/mnt/storage/downloads
/mnt/storage/media
/mnt/storage/appdata
/mnt/storage/shared
```

Recommended service mapping:

```text
io
- Sabnzbd downloads -> /mnt/storage/downloads/sabnzbd
- qBittorrent downloads -> /mnt/storage/downloads/qbittorrent
- JDownloader downloads -> /mnt/storage/downloads/jdownloader
- MeTube downloads -> /mnt/storage/downloads/metube

asteria
- Sonarr root/library paths -> /mnt/storage/media/tv
- Radarr root/library paths -> /mnt/storage/media/movies
- Lidarr root/library paths -> /mnt/storage/media/music
- Prowlarr/Bazarr/supporting config -> /mnt/storage/appdata/asteria/<service>

aeos
- Homepage config -> /mnt/storage/appdata/aeos/homepage
- Tautulli config -> /mnt/storage/appdata/aeos/tautulli
- Jellyseerr config -> /mnt/storage/appdata/aeos/jellyseerr
- Shared artifacts -> /mnt/storage/shared
```

For Dockerized services, prefer `PUID=3004` and `PGID=3004` when the service
needs write access to `sisyphus`.

## Docker Notes

For Dockerized services inside LXC containers:

- Prefer real absolute bind mount paths such as
  `/mnt/storage/appdata/asteria/sonarr` rather than symlinked paths under a
  home directory.
- Pre-create bind mount source directories before `docker compose up` so Docker
  does not attempt to create and `chown` NFS-backed paths on its own.
- Keep Docker image / overlay / container runtime storage local to the
  container root disk. Do not move `/var/lib/docker` or `/var/lib/containerd`
  onto the NFS share unless you intentionally accept the tradeoffs.

Example:

```yaml
volumes:
  - /mnt/storage/appdata/asteria/sonarr:/config
  - /mnt/storage/media:/media
  - /mnt/storage/downloads:/downloads
```

If image pulls fail with `no space left on device` under
`/var/lib/containerd/...`, that is a local container disk capacity problem, not
an NFS permission problem.

## SMB Access

Use SMB for human-facing access and NFS for Proxmox / LXC mounts.

Recommended SMB shares:

```text
ixion               -> /mnt/tartarus/ixion
sisyphus-media      -> /mnt/tartarus/sisyphus/media
sisyphus-downloads  -> /mnt/tartarus/sisyphus/downloads
```

Recommended access model:

- `nana` authenticates to SMB shares
- `sisyphus` remains the service/write identity for containers
- avoid SMB-sharing `appdata` unless there is a specific admin need
