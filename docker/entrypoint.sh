#!/bin/sh
# Reconcile the installed Bitwarden CLI versions with the requested ones, then
# hand off to the container CMD (cron).
#
# This lets BW_CLI_OLD_VERSION (source / Vaultwarden) and BW_CLI_NEW_VERSION
# (destination / Bitwarden cloud) be overridden at RUNTIME on the published
# image — e.g. via docker-compose `environment:` — without rebuilding. Useful
# if a future CLI release breaks Vaultwarden again (issue #50) and you need to
# pin a known-good version yourself.
#
# A concrete version that differs from the baked-in one triggers a reinstall.
# An empty value or "latest" keeps the baked-in version, so default startups do
# no work and need no network access.

. /app/bw-cli-lib.sh

reconcile_clis() {
  old_want="${BW_CLI_OLD_VERSION:-}"
  new_want="${BW_CLI_NEW_VERSION:-}"
  old_have="$(bw-old --version 2>/dev/null || echo none)"
  new_have="$(bw-new --version 2>/dev/null || echo none)"
  old_change=0
  new_change=0

  # Only reconcile when a concrete version is requested that differs from what
  # is installed. Empty / "latest" keeps the baked-in build.
  case "$old_want" in ""|latest) ;; *) [ "$old_want" != "$old_have" ] && old_change=1 ;; esac
  case "$new_want" in ""|latest) ;; *) [ "$new_want" != "$new_have" ] && new_change=1 ;; esac

  [ "$old_change" = 0 ] && [ "$new_change" = 0 ] && return 0

  if [ "$old_change" = 1 ]; then
    echo "# Reinstalling source Bitwarden CLI: $old_have -> $old_want #"
    # reinstall_bw_old also restores the destination CLI to BW_CLI_NEW_VERSION.
    reinstall_bw_old "$old_want" || return 1
  elif [ "$new_change" = 1 ]; then
    echo "# Reinstalling destination Bitwarden CLI: $new_have -> $new_want #"
    npm install -g "@bitwarden/cli@$new_want" >/dev/null 2>&1 || return 1
  fi

  echo "# Bitwarden CLI versions: source $(bw-old --version 2>/dev/null), destination $(bw-new --version 2>/dev/null) #"
  return 0
}

if ! reconcile_clis; then
  echo "# WARNING: Failed to reconcile Bitwarden CLI versions; using baked-in (source $(bw-old --version 2>/dev/null), destination $(bw-new --version 2>/dev/null)) #" >&2
fi

# Optionally run one sync immediately at container start (useful for first-time
# setup / testing) before handing off to cron.
case "${RUN_ON_START:-}" in
  1 | true | TRUE | yes | YES | on | ON)
    echo "# RUN_ON_START set — running an initial sync now #"
    /app/script.sh || echo "# Initial sync exited non-zero (rc=$?) #" >&2
    ;;
esac

exec "$@"
