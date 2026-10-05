#!/usr/bin/env bash
# Deploy a stack from the repo clone. Run ON the LXC that owns the stack.
#
#   deploy.sh <stack> [--dry-run] [--no-pull]
#
# The repo is the source of truth (D9): compose files come from the clone,
# secrets stay on the host and never enter it.
#
#   /opt/home-server/stacks/<stack>/compose.yaml   <- git, this is what deploys
#   /opt/stacks/<stack>/.env                       <- host only, mode 600
#
# SWITCH-OVER TEST, the first time you point a stack at the clone:
#
#   deploy.sh <stack> --dry-run
#
# It must report NOTHING to recreate. If it wants to recreate a container,
# stop and find out why before running it for real — the old file is still at
# /opt/stacks/<stack>/compose.yaml.bak.
#
# `git pull --ff-only` is deliberate: it FAILS on a dirty clone rather than
# merging or stashing. That failure is the drift detector — a hand-edit on the
# host is exactly what this setup exists to surface.

set -euo pipefail

REPO=${REPO:-/opt/home-server}
SECRETS_DIR=${SECRETS_DIR:-/opt/stacks}

die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }

stack=""; dry=false; pull=true
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) dry=true ;;
    --no-pull) pull=false ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  [[ -n $stack ]] && die "one stack at a time"; stack=$1 ;;
  esac
  shift
done
[[ -n $stack ]] || die "usage: deploy.sh <stack> [--dry-run] [--no-pull]"

compose_file="$REPO/stacks/$stack/compose.yaml"
env_file="$SECRETS_DIR/$stack/.env"

[[ -d $REPO/.git ]]     || die "no git clone at $REPO"
[[ -f $compose_file ]]  || die "no compose file at $compose_file"

if $pull; then
  echo "==> git pull --ff-only"
  if ! git -C "$REPO" pull --ff-only; then
    echo >&2
    echo "deploy: pull failed. If the clone is dirty, something was edited on" >&2
    echo "        this host instead of in the repo. Inspect before discarding:" >&2
    echo "          git -C $REPO status --porcelain" >&2
    echo "          git -C $REPO diff" >&2
    exit 1
  fi
fi

args=(--project-name "$stack" --file "$compose_file")
# arr and grab have no .env — passing a missing one is a hard error, so only
# add the flag when the file is actually there.
if [[ -f $env_file ]]; then
  args+=(--env-file "$env_file")
  echo "==> using secrets from $env_file"
else
  echo "==> no $env_file (stack has no secrets)"
fi
$dry && args+=(--dry-run)

echo "==> docker compose ${dry:+(dry run) }up -d"
docker compose "${args[@]}" up -d --remove-orphans

if ! $dry; then
  echo "==> running containers"
  docker compose --project-name "$stack" --file "$compose_file" ps
fi
