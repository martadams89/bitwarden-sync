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

install_bw_old() {
  # Reinstall the isolated "old" CLI used for the Vaultwarden source. Build into
  # a temp dir and swap, so a failure mid-install can't leave bw-old broken.
  local ver="$1"
  local tmp="/opt/.bw-old.new"
  npm install -g "@bitwarden/cli@$ver" || return 1
  rm -rf "$tmp" || return 1
  mkdir -p "$tmp" || return 1
  cp -r /usr/local/lib/node_modules/@bitwarden/cli "$tmp/" || return 1
  cp -r /usr/local/lib/node_modules "$tmp/node_modules" || return 1
  rm -rf /opt/bw-old || return 1
  mv "$tmp" /opt/bw-old || return 1
}

reconcile_clis() {
  local old_want="${BW_CLI_OLD_VERSION:-}"
  local new_want="${BW_CLI_NEW_VERSION:-}"
  local old_have new_have old_change=0 new_change=0

  old_have="$(bw-old --version 2>/dev/null || echo none)"
  new_have="$(bw-new --version 2>/dev/null || echo none)"

  # Only reconcile when a concrete version is requested that differs from what
  # is installed. Empty / "latest" keeps the baked-in build.
  case "$old_want" in ""|latest) ;; *) [ "$old_want" != "$old_have" ] && old_change=1 ;; esac
  case "$new_want" in ""|latest) ;; *) [ "$new_want" != "$new_have" ] && new_change=1 ;; esac

  [ "$old_change" = 0 ] && [ "$new_change" = 0 ] && return 0

  if [ "$old_change" = 1 ]; then
    echo "# Reinstalling source Bitwarden CLI: $old_have -> $old_want #"
    install_bw_old "$old_want" || return 1
    # install_bw_old leaves the global CLI at the source version; restore the
    # destination CLI to its intended version afterwards.
    npm install -g "@bitwarden/cli@${new_want:-latest}" || return 1
  elif [ "$new_change" = 1 ]; then
    echo "# Reinstalling destination Bitwarden CLI: $new_have -> $new_want #"
    npm install -g "@bitwarden/cli@$new_want" || return 1
  fi

  echo "# Bitwarden CLI versions: source $(bw-old --version 2>/dev/null), destination $(bw-new --version 2>/dev/null) #"
  return 0
}

if ! reconcile_clis; then
  echo "# WARNING: Failed to reconcile Bitwarden CLI versions; using baked-in (source $(bw-old --version 2>/dev/null), destination $(bw-new --version 2>/dev/null)) #" >&2
fi

exec "$@"
