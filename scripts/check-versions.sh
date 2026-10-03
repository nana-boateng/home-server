#!/usr/bin/env bash
# Compare every pinned image version against the project's latest GitHub release.
#
# WHY THIS EXISTS: reading a version off a :latest image only tells you what
# :latest points to, not what is newest. Uptime Kuma's :latest sat on 1.23.17
# while 2.5.0 was current — most likely kept there deliberately so existing
# installs don't hit a DB migration on their next pull. When the image and the
# releases page disagree, THE RELEASES PAGE WINS: find the right tag, and treat
# a major-version jump as a migration (docs/update-discipline.md), not a pull.
#
# Usage:  scripts/check-versions.sh            all stacks
#         scripts/check-versions.sh arr grab   only those
#
# Notes:
#  - releases/latest skips pre-releases.
#  - An empty "latest" means no formal GitHub releases, or the unauthenticated
#    rate limit (60/hour). Set GITHUB_TOKEN to raise it.
#  - For linuxserver images, a higher -lsNN with the SAME app version is a
#    rebuild of the same app, not a new release.
#  - Some projects publish image tags WITHOUT the Git tag's leading `v`
#    (Audiobookshelf, Recyclarr, Beszel, Navidrome). If pulling the Git tag
#    fails, try it without the v.
#  - abs-arr is a private image in a private repo; check it directly.

set -uo pipefail

# Note the ${AUTH[@]+...} form: under `set -u`, bash 3.2 (macOS default)
# errors on an empty array expansion, so guard it rather than quoting directly.
AUTH=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

check() {
  local repo=$1 name=$2 pinned=$3 latest
  latest=$(curl -fsSL ${AUTH[@]+"${AUTH[@]}"} \
    "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
    | grep -o '"tag_name": *"[^"]*"' | head -n1 | cut -d'"' -f4)
  # The grep -o form is required: some API responses come back as single-line
  # JSON, and a plain `grep -m1 | cut` then returns the release URL, not the tag.
  printf '  %-16s pinned %-34s latest %s\n' "$name" "$pinned" "${latest:-<none>}"
}

# want <stack> "$@"  — true if no filters were given, or <stack> is among them.
want() {
  local s=$1; shift
  [[ $# -eq 0 ]] && return 0          # no filters -> check everything
  local a; for a in "$@"; do [[ $a == "$s" ]] && return 0; done
  return 1
}

if want media "$@"; then echo "media (CT 200, Hestia, 10.0.0.30)"
  check linuxserver/docker-plex        plex           1.43.4.10903-e5521bd8c-ls326
  check linuxserver/docker-jellyfin    jellyfin       12.1ubu2604-ls50
  check Tautulli/Tautulli              tautulli       v2.18.2-ls245
  check navidrome/navidrome            navidrome      0.64.2
  check fscorrupt/posterizarr          posterizarr    3.3.6
  check amir20/dozzle                  dozzle-agent   v11.1.3
fi

if want monitor "$@"; then echo "monitor (CT 202, Hestia, 10.0.0.34)"
  check louislam/uptime-kuma           uptime-kuma    2.5.0
  check henrygd/beszel                 beszel         0.20.0
  check binwiederhier/ntfy             ntfy           v2.28.0
  check getwud/wud                     wud            9.2.1
  check amir20/dozzle                  dozzle         v11.1.3
fi

if want arr "$@"; then echo "arr (CT 300, Themis, 10.0.0.35)"
  check linuxserver/docker-prowlarr    prowlarr       2.6.5.5623-ls162
  check linuxserver/docker-radarr      radarr         PIN-ME
  check linuxserver/docker-sonarr      sonarr         PIN-ME
  check linuxserver/docker-sabnzbd     sabnzbd        5.1.3-ls275
  check ThePhaseless/Byparr            byparr         PIN-ME
  check recyclarr/recyclarr            recyclarr      PIN-ME
  check linuxserver/docker-bazarr      bazarr         PIN-ME
  check advplyr/audiobookshelf         audiobookshelf 2.37.1
  check jessielw/reclaimerr            reclaimerr     PIN-ME
  check amir20/dozzle                  dozzle-agent   v11.1.3
  echo "  abs-arr          pinned 0.2.1                              latest <private repo>"
fi

if want grab "$@"; then echo "grab (CT 301, Themis, 10.0.0.36)"
  check linuxserver/docker-qbittorrent qbittorrent    5.2.4_v2.0.15-ls479
  check jlesage/docker-jdownloader-2   jdownloader    PIN-ME
  check alexta69/metube                metube         PIN-ME
  check amir20/dozzle                  dozzle-agent   v11.1.3
  echo "  gluetun          not built yet (D30)"
fi

if want dns "$@"; then echo "dns / dns2 (CT 100 Rhea, CT 201 Hestia) — native, not images"
  check pi-hole/pi-hole                pi-hole        v6.4.3
  check pi-hole/FTL                    pihole-FTL     v6.7.1
  check lovelaze/nebula-sync           nebula-sync    v0.11.2
  echo "  unbound / keepalived   from Debian 13 apt — track with apt, not here"
fi

cat <<'NOTE'

PIN-ME rows are versions not yet recorded in this repo. Read them off the live
host and replace both here and in the stack's compose file:
  pct exec <ct> -- docker inspect -f '{{index .Config.Labels "build_version"}}' <image>

wud currently watches only monitor's Docker daemon, so media, arr and grab get
no update notifications at all — this script is the stopgap until that is fixed.
NOTE
