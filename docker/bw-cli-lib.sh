# Shared helpers for managing the dual Bitwarden CLI install (POSIX sh).
# Sourced by docker/entrypoint.sh (boot-time version reconcile) and
# docker/bitwarden_sync.sh (run-time auto-fallback). Not executable on its own.

# Reinstall the isolated "old" CLI (used for the Vaultwarden source) at the
# given version, then restore the global "new" CLI (used for the cloud
# destination). Builds into a temp dir and swaps, so a failure mid-install can't
# leave /opt/bw-old broken. Returns non-zero on failure.
#   $1 = exact Bitwarden CLI version to install for bw-old (e.g. 2025.12.0)
# Reads BW_CLI_NEW_VERSION (default "latest") to restore the destination CLI.
reinstall_bw_old() {
  bw_old_ver="$1"
  bw_old_tmp="/opt/.bw-old.new"

  npm install -g "@bitwarden/cli@$bw_old_ver" >/dev/null 2>&1 || return 1
  rm -rf "$bw_old_tmp" || return 1
  mkdir -p "$bw_old_tmp" || return 1
  cp -r /usr/local/lib/node_modules/@bitwarden/cli "$bw_old_tmp/" || return 1
  cp -r /usr/local/lib/node_modules "$bw_old_tmp/node_modules" || return 1
  rm -rf /opt/bw-old || return 1
  mv "$bw_old_tmp" /opt/bw-old || return 1

  # The install above left the global CLI at the source version; restore the
  # destination ("new") CLI to its intended version.
  npm install -g "@bitwarden/cli@${BW_CLI_NEW_VERSION:-latest}" >/dev/null 2>&1 || return 1
}

# Reinstall the global "new" CLI (used for the Bitwarden cloud destination) at
# the given version. bw-new is just a symlink to the global `bw`, so a global
# reinstall is all that's needed; the isolated bw-old under /opt is untouched.
#   $1 = exact Bitwarden CLI version to install for bw-new (e.g. 2025.12.0)
reinstall_bw_new() {
  npm install -g "@bitwarden/cli@$1" >/dev/null 2>&1 || return 1
}
