#!/bin/bash
# runner-watchdog.sh  (scoped read-only PAT, no gh)
#
# Asks GitHub which of our self-hosted runners are "offline" and restarts their
# systemd services. This catches the stuck state where Runner.Listener is alive
# locally but has lost its session with GitHub.
#
# Installed by setup-runner-linux.sh as /usr/local/sbin/github-runner-watchdog
# and run as root by github-runner-watchdog.timer every two minutes.
# Only runners named $RUNNER_PREFIX1..$RUNNER_PREFIX$RUNNER_COUNT are touched.
set -euo pipefail

STRIKES=2
STATE_DIR=/var/lib/github-runner-watchdog
TOKEN_FILE="$STATE_DIR/token"
# shellcheck source=/dev/null
source /etc/github-runners.conf   # SCOPE, RUNNER_PREFIX, RUNNER_COUNT, RUNNER_HOME
log() { logger -t github-runner-watchdog "$*"; }

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || exit 0
test -s "$TOKEN_FILE" || { log "Missing token at $TOKEN_FILE"; exit 1; }

response=$(curl -sS --max-time 20 -w '\n%{http_code}' \
  -H "Authorization: Bearer $(tr -d '[:space:]' <"$TOKEN_FILE")" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "https://api.github.com/$SCOPE/actions/runners?per_page=100" 2>/dev/null) || {
    log 'GitHub API unreachable; skipping check'
    exit 0
  }
code=${response##*$'\n'}
body=${response%$'\n'*}
if [ "$code" != 200 ]; then
  # 401/403 = bad or expired token; 404 = wrong SCOPE or token lacks permission.
  log "GitHub API returned HTTP $code; skipping check (check token/SCOPE)"
  exit 0
fi

for ((i=1; i<=RUNNER_COUNT; i++)); do
  name="$RUNNER_PREFIX$i"
  strikes_file="$STATE_DIR/$name.strikes"
  service_file="$RUNNER_HOME/actions-runner-$i/.service"
  # An absent API entry is not proof of an offline runner. Leave it alone.
  details=$(jq -r --arg name "$name" \
    '.runners[] | select(.name == $name) | [.status, (.busy|tostring)] | @tsv' <<<"$body")
  [ -n "$details" ] || continue
  read -r status busy <<<"$details"
  if [ "$status" = online ] || [ "$busy" = true ]; then
    rm -f "$strikes_file"
    continue
  fi
  strikes=$(cat "$strikes_file" 2>/dev/null || echo 0)
  [[ "$strikes" =~ ^[0-9]+$ ]] || strikes=0
  strikes=$((strikes + 1))
  printf '%s\n' "$strikes" >"$strikes_file"
  if [ "$strikes" -lt "$STRIKES" ]; then
    log "$name: offline (strike $strikes/$STRIKES)"
    continue
  fi
  if [ ! -s "$service_file" ]; then
    log "$name: no service file at $service_file; skipping"
    continue
  fi
  unit=$(cat "$service_file")
  log "$name: offline for $strikes consecutive checks; restarting $unit"
  if systemctl restart "$unit"; then
    rm -f "$strikes_file"
  else
    log "$name: restart of $unit failed"
  fi
done
