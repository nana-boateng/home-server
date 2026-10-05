# Recyclarr configuration

Goes to `/opt/appdata/arr/recyclarr/` inside the `arr` LXC:

```
/opt/appdata/arr/recyclarr/
├── configs/
│   ├── radarr.yml      <- from this directory
│   └── sonarr.yml      <- from this directory
├── templates/          <- original TRaSH templates, kept for reference
└── secrets.yml         <- mode 600, NOT IN THIS REPO
```

> **One merged config file per app.** `recyclarr config create -t` writes one
> file *per template*, and **Recyclarr loads every file in `configs/`** — so
> several files aimed at the same Radarr conflict. Generate the templates, move
> them to `templates/`, and keep one merged file per app.

> **`secrets.yml` is never committed.** It holds the Radarr and Sonarr API keys
> and is referenced with `!secret`. Create it at mode 600 on the host.

Always preview before syncing, and **check the scores come out non-zero**:

```bash
docker compose exec recyclarr recyclarr sync radarr --preview
```

## Schema note

These files use `quality_profiles` keyed by **`trash_id`**, not by `name`, and
the newer **`custom_format_groups: add:`** block rather than `include:`
templates. That is what the live install uses — the templates were flattened
into explicit trash_ids rather than referenced. Keep that shape; mixing the two
styles is how you end up with files that conflict.

The Sonarr audio group is `e9a1944a254e6f8a9da63083f7ae15cb`
(**[Audio] Audio Formats**), assigned to the two remux profiles. TRaSH leaves
Sonarr audio scoring optional, so without this it simply would not be applied —
which matters because the Zidoo bitstreams TrueHD/Atmos to the receiver rather
than relying on the server to decode.

## Why these profiles

The owner plays remuxes on a **Zidoo** player that bitstreams TrueHD/Atmos and
DTS-HD to the receiver, and 4K files rely on **direct play** while hardware
transcoding is parked. The profiles are chosen for that: remux-first, with audio
formats scored explicitly.

**4K and 1080p share one root folder per app** — the quality profile decides per
title, which is why there is no separate `video/uhd`.

**Never edit synced custom formats by hand.** Recyclarr overwrites them on its
next daily run.

## Available but not enabled

- **DV Boost / HDR10+ Boost** — only if the TV supports them.
- **Movie Versions.**

Both are off until decided.
