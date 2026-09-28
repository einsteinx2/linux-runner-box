#!/bin/bash
# setup-runner-linux.sh  (no gh, no account sign-in on this machine)
# One-time setup for a Debian 13 machine (bare metal, VM, or VPS) as a
# dedicated GitHub Actions runner box.
#
# Run as the user that will own the runners; it sudos for packages, systemd
# units, and the watchdog. Safe to re-run: configured runners and the stored
# watchdog token are kept.
#
# Registration token: generate it on your own machine, not here.
#   Org:  Settings -> Actions -> Runners -> New self-hosted runner
#   (or: gh api -X POST orgs/ORG/actions/runners/registration-token --jq .token)
# It expires after 1 hour, and one token registers every runner in that
# window. The script prompts for it; pass REG_TOKEN=... to skip the prompt.
#
# Watchdog token: a fine-grained PAT with ONLY
#   org runners:  Organization permissions -> Self-hosted runners: Read-only
#   repo runners: Repository permissions   -> Administration: Read-only
# Stored root-owned in /var/lib/github-runner-watchdog/token (mode 600).
# Pass WATCHDOG_TOKEN=... to skip the prompt. Skipped if the file exists.
set -euo pipefail

# ---- edit these -------------------------------------------------------------
RUNNER_URL="https://github.com/YOUR_ORG"   # org URL, or https://github.com/OWNER/REPO
SCOPE="orgs/YOUR_ORG"                      # API path matching RUNNER_URL: orgs/ORG or repos/OWNER/REPO
RUNNER_COUNT=8
RUNNER_PREFIX="cachyos-sff-"
LABELS="self-hosted,Linux,X64,home-linux,cachyos-sff"
CACHE_DIR="/var/cache/github-runners"      # shared cache, exported to jobs as RUNNER_SHARED_CACHE
EXTRA_APT_PACKAGES=""                      # space-separated, e.g. "sqlite3 imagemagick"
# -----------------------------------------------------------------------------

HERE="$(cd "$(dirname "$0")" && pwd)"

[[ "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]] || { echo 'RUNNER_COUNT must be a positive integer' >&2; exit 1; }
[[ "$RUNNER_PREFIX" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*-$ ]] || { echo 'RUNNER_PREFIX must be a name ending in -' >&2; exit 1; }
[[ "$SCOPE" =~ ^(repos/[^/]+/[^/]+|orgs/[^/]+)$ ]] || { echo 'SCOPE must be orgs/ORG or repos/OWNER/REPO' >&2; exit 1; }
[[ "$RUNNER_URL" == "https://github.com/${SCOPE#repos/}" || "$RUNNER_URL" == "https://github.com/${SCOPE#orgs/}" ]] || {
  echo 'RUNNER_URL and SCOPE do not match' >&2; exit 1
}
[[ "$CACHE_DIR" =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo 'CACHE_DIR must be an absolute path without spaces' >&2; exit 1; }
test "$(id -u)" -ne 0 || { echo 'Run as the user who will own the runners, not root' >&2; exit 1; }
{ grep -q '^ID=debian$' /etc/os-release && grep -q '^VERSION_ID="\?13"\?$' /etc/os-release; } || {
  echo 'Debian 13 required' >&2; exit 1
}

case "$(uname -m)" in
  x86_64) ARCH=x64; ARCH_LABEL=X64 ;;
  aarch64) ARCH=arm64; ARCH_LABEL=ARM64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
if ! tr ',' '\n' <<<"$LABELS" | grep -qix "$ARCH_LABEL"; then
  echo "WARNING: LABELS does not contain $ARCH_LABEL, the architecture of this machine" >&2
fi

echo '== Host packages =='
# libicu76, libkrb5-3, libssl3t64, and zlib1g are the runner's own dependencies.
# docker.io holds only the daemon. The docker client is docker-cli, which
# docker.io only recommends, so --no-install-recommends skips it.
sudo apt-get update
# shellcheck disable=SC2086
sudo apt-get install -y --no-install-recommends \
  bash ca-certificates curl git git-lfs jq tar gzip unzip zip zstd xz-utils \
  build-essential pkg-config python3 python3-venv util-linux procps iproute2 \
  libicu76 libkrb5-3 libssl3t64 zlib1g docker.io docker-cli \
  $EXTRA_APT_PACKAGES
sudo systemctl enable --now docker
docker_group_added=0
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  # Container jobs need the socket. The runner services pick the group up when they start.
  sudo usermod -aG docker "$USER"
  docker_group_added=1
fi
if ! command -v uv >/dev/null; then
  # Debian 13 does not package uv.
  curl -LsSf https://astral.sh/uv/install.sh \
    | sudo env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh
fi

echo '== Shared cache =='
sudo install -d -m 755 -o "$(id -u)" -g "$(id -g)" "$CACHE_DIR"

echo '== Runner release =='
# Latest version from the unauthenticated releases redirect (no API token).
VER=$(curl -fsSI https://github.com/actions/runner/releases/latest \
  | awk -F'/tag/v' 'tolower($0) ~ /^location:/ {print $2}' | tr -d '\r\n')
[ -n "$VER" ] || { echo 'Could not determine runner version' >&2; exit 1; }
asset="actions-runner-linux-$ARCH-$VER.tar.gz"
TARBALL="$HOME/.cache/$asset"
if [ ! -f "$TARBALL" ]; then
  digest=$(curl -fsSL "https://api.github.com/repos/actions/runner/releases/tags/v$VER" \
    | jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .digest // empty')
  [[ "$digest" =~ ^sha256:[a-fA-F0-9]{64}$ ]] || { echo "Missing SHA256 digest for $asset" >&2; exit 1; }
  mkdir -p "$HOME/.cache"
  curl -fsSL -o "$TARBALL.part" "https://github.com/actions/runner/releases/download/v$VER/$asset"
  echo "${digest#sha256:}  $TARBALL.part" | sha256sum -c -
  mv "$TARBALL.part" "$TARBALL"
fi

echo '== Runners =='
need_token=0
for ((i=1; i<=RUNNER_COUNT; i++)); do
  [ -f "$HOME/actions-runner-$i/.runner" ] || need_token=1
done
if [ "$need_token" = 1 ] && [ -z "${REG_TOKEN:-}" ]; then
  read -rsp "Registration token for $RUNNER_URL: " REG_TOKEN; echo
fi

for ((i=1; i<=RUNNER_COUNT; i++)); do
  name="$RUNNER_PREFIX$i"
  dir="$HOME/actions-runner-$i"
  if [ -f "$dir/.runner" ]; then
    echo "$name already configured in $dir; skipping registration"
  else
    test -n "${REG_TOKEN:-}" || { echo 'Registration token is empty' >&2; exit 1; }
    mkdir -p "$dir"
    tar xzf "$TARBALL" -C "$dir"
    (cd "$dir" && ./config.sh --url "$RUNNER_URL" --token "$REG_TOKEN" --name "$name" \
      --labels "$LABELS" --work _work --unattended --replace)
  fi

  # The runner reads .env into every job's environment.
  env_changed=0
  touch "$dir/.env"
  if ! grep -qx "RUNNER_SHARED_CACHE=$CACHE_DIR" "$dir/.env"; then
    sed -i '/^RUNNER_SHARED_CACHE=/d' "$dir/.env"
    echo "RUNNER_SHARED_CACHE=$CACHE_DIR" >>"$dir/.env"
    env_changed=1
  fi

  if [ ! -s "$dir/.service" ]; then
    (cd "$dir" && sudo ./svc.sh install "$USER" && sudo ./svc.sh start)
  elif [ "$env_changed" = 1 ] || [ "$docker_group_added" = 1 ]; then
    sudo systemctl restart "$(cat "$dir/.service")"
  fi
done
unset REG_TOKEN

echo '== Watchdog =='
state=/var/lib/github-runner-watchdog
sudo install -d -m 700 "$state"
check_token() {
  curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $1" \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/$SCOPE/actions/runners?per_page=1"
}
# Check a new token before it is saved, so a bad paste is never stored.
if sudo test -s "$state/token"; then
  token=$(sudo cat "$state/token")
else
  token="${WATCHDOG_TOKEN:-}"
  [ -n "$token" ] || { read -rsp 'Watchdog PAT (read-only self-hosted runners): ' token; echo; }
  test -n "$token" || { echo 'Watchdog token is empty' >&2; exit 1; }
fi
unset WATCHDOG_TOKEN
code=$(check_token "$token")
if [ "$code" != 200 ]; then
  echo "Token check failed: HTTP $code for $SCOPE/actions/runners (401/403 = bad token, 404 = wrong SCOPE or missing permission)" >&2
  echo "To replace a stored token: sudo rm $state/token, then rerun." >&2
  exit 1
fi
printf '%s' "$token" | sudo tee "$state/token" >/dev/null
sudo chmod 600 "$state/token"
unset token

config=$(mktemp)
printf 'SCOPE=%q\nRUNNER_PREFIX=%q\nRUNNER_COUNT=%q\nRUNNER_HOME=%q\n' \
  "$SCOPE" "$RUNNER_PREFIX" "$RUNNER_COUNT" "$HOME" >"$config"
sudo install -m 600 "$config" /etc/github-runners.conf
rm -f "$config"
sudo install -m 755 "$HERE/runner-watchdog.sh" /usr/local/sbin/github-runner-watchdog
for unit in github-runner-watchdog.service github-runner-watchdog.timer; do
  sudo install -m 644 "$HERE/$unit" "/etc/systemd/system/$unit"
done
sudo systemctl daemon-reload
sudo systemctl enable --now github-runner-watchdog.timer

echo
echo 'Done. Check:'
echo "  systemctl list-units 'actions.runner.*'"
echo '  journalctl -t github-runner-watchdog -f'
