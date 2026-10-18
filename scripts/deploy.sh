#!/usr/bin/env bash
# deploy.sh - publish the latest commit of $BRANCH on this server.
#
# Steps: lock -> fetch -> reset to origin/$BRANCH -> stamp version.json ->
#        health check -> (roll back to the previous commit if the check fails)
#
# Run by GitHub Actions over SSH, by the systemd timer, or by hand:
#   bash /var/www/cns3205/scripts/deploy.sh          # deploy if there is something new
#   FORCE=1 bash /var/www/cns3205/scripts/deploy.sh  # redeploy even if up to date
set -euo pipefail

REPO_DIR="${REPO_DIR:-/var/www/cns3205}"
BRANCH="${BRANCH:-main}"
HEALTH_URL="${HEALTH_URL:-http://localhost/}"
LOG_FILE="${LOG_FILE:-$HOME/deploy.log}"
HISTORY_FILE="${HISTORY_FILE:-$HOME/deploy-history.jsonl}"
FAILED_FILE="${FAILED_FILE:-$HOME/.deploy-last-failed}"
LOCK_FILE="/tmp/cns3205-deploy.lock"

log() { echo "$(date '+%F %T') [deploy] $*" | tee -a "$LOG_FILE"; }

# Write site/version.json (shown on the page), append the result to the history
# log and publish the last 10 entries as site/history.json.
# Both JSON files are git-ignored, so git never overwrites them.
stamp_version() {
  local status="$1"   # checking | deployed | failed | rolled-back
  python3 - "$status" "$HISTORY_FILE" <<'PY'
import json, subprocess, sys, socket, datetime, pathlib
status, history_file = sys.argv[1], pathlib.Path(sys.argv[2])
git = lambda *a: subprocess.check_output(["git", *a], text=True).strip()
entry = {
    "commit": git("rev-parse", "--short", "HEAD"),
    "message": git("log", "-1", "--pretty=%s"),
    "author": git("log", "-1", "--pretty=%an"),
    "deployed_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "host": socket.gethostname(),
    "status": status,
}
pathlib.Path("site/version.json").write_text(json.dumps(entry, indent=2))
if status == "checking":
    sys.exit(0)        # not a result yet - keep it out of the history
with history_file.open("a") as f:
    f.write(json.dumps(entry) + "\n")
recent = [json.loads(l) for l in history_file.read_text().splitlines() if l.strip()][-10:]
pathlib.Path("site/history.json").write_text(json.dumps(recent[::-1], indent=2))
PY
}

healthy() {
  local expected="$1"
  # The page must load AND serve the commit we just checked out.
  curl -fsS --max-time 5 "$HEALTH_URL" | grep -q 'id="app"' &&
  curl -fsS --max-time 5 "${HEALTH_URL%/}/version.json" | grep -q "\"commit\": \"$expected\""
}

main() {
  exec 9>"$LOCK_FILE"
  # Wait (up to 2 min) for any deployment in progress, then re-check: if it
  # already deployed our commit we simply report "Already at ...".
  flock -w 120 9 || { log "Timed out waiting for another deployment"; exit 1; }

  cd "$REPO_DIR"
  local previous target short
  previous=$(git rev-parse HEAD)
  git fetch --quiet --prune origin "$BRANCH"
  target=$(git rev-parse "origin/$BRANCH")

  if [[ "$previous" == "$target" && "${FORCE:-0}" != "1" ]]; then
    log "Already at ${target:0:7} - nothing to deploy"
    exit 0
  fi
  if [[ "$(cat "$FAILED_FILE" 2>/dev/null)" == "$target" && "${FORCE:-0}" != "1" ]]; then
    log "${target:0:7} already failed its health check - waiting for a new push"
    exit 0
  fi

  log "Deploying ${previous:0:7} -> ${target:0:7} ($(git log -1 --pretty=%s "$target"))"
  git reset --hard --quiet "$target"
  git clean -fdq            # remove stray untracked files (ignored files are kept)
  short=$(git rev-parse --short HEAD)
  stamp_version "checking"

  if healthy "$short"; then
    stamp_version "deployed"
    rm -f "$FAILED_FILE"
    log "SUCCESS - ${short} is live at $HEALTH_URL"
    exit 0
  fi

  stamp_version "failed"
  echo "$target" > "$FAILED_FILE"
  log "FAILED health check for ${short} - rolling back to ${previous:0:7}"
  git reset --hard --quiet "$previous"
  stamp_version "rolled-back"
  log "Rolled back. Site is serving $(git rev-parse --short HEAD) again"
  exit 1
}

# Everything runs inside main(): bash reads the whole function before running it,
# so it is safe for 'git reset' to replace this very file mid-deployment.
main "$@"
