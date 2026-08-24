#!/usr/bin/env bash
# Regression test for issue #103: an empty backup directory must never make the
# cleanup search fall back to /app (or to any other working directory).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

# shellcheck source=../../docker/bw-cli-lib.sh
. "$ROOT/docker/bw-cli-lib.sh"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

APP_DIR="$TEST_ROOT/app"
BACKUP_DIR="$APP_DIR/backups"
mkdir -p "$BACKUP_DIR"

# These model the image's baked-in scripts. Make them old enough that the
# original unscoped find command would delete them.
touch "$APP_DIR/entrypoint.sh" "$APP_DIR/script.sh" "$APP_DIR/bw-cli-lib.sh"
touch -d "45 days ago" \
  "$APP_DIR/entrypoint.sh" "$APP_DIR/script.sh" "$APP_DIR/bw-cli-lib.sh"

(
  cd "$APP_DIR"
  cleanup_backup_files "$BACKUP_DIR"
)

for script in entrypoint.sh script.sh bw-cli-lib.sh; do
  [ -f "$APP_DIR/$script" ] || fail "empty backup cleanup deleted $script"
done

# Confirm the cleanup remains selective: only expired encrypted archives and
# stale plaintext exports are removed.
touch "$BACKUP_DIR/bw_export_old.tar.gz.enc"
touch -d "45 days ago" "$BACKUP_DIR/bw_export_old.tar.gz.enc"
touch "$BACKUP_DIR/bw_export_recent.tar.gz.enc"
touch "$BACKUP_DIR/bw_export_interrupted.json"
touch "$BACKUP_DIR/unrelated-old-file.txt"
touch -d "45 days ago" "$BACKUP_DIR/unrelated-old-file.txt"

cleanup_backup_files "$BACKUP_DIR"

[ ! -e "$BACKUP_DIR/bw_export_old.tar.gz.enc" ] || fail "expired archive was retained"
[ ! -e "$BACKUP_DIR/bw_export_interrupted.json" ] || fail "stale JSON export was retained"
[ -e "$BACKUP_DIR/bw_export_recent.tar.gz.enc" ] || fail "recent archive was deleted"
[ -e "$BACKUP_DIR/unrelated-old-file.txt" ] || fail "unrelated backup file was deleted"

echo "Backup cleanup regression test PASSED"
