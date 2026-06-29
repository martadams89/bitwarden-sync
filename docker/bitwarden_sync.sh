#!/bin/bash

# Shared CLI install helpers (provides reinstall_bw_old for auto-fallback).
# Present only inside the Docker image; guarded so the script still parses
# elsewhere.
if [ -f /app/bw-cli-lib.sh ]; then
  . /app/bw-cli-lib.sh
fi

resolve_destination_urls() {
  local server="${BW_SERVER_DEST%/}"

  if [[ ! "$server" =~ ^https?://[^/]+(/.*)?$ ]]; then
    echo "ERROR: BW_SERVER_DEST must be an absolute HTTP(S) URL" >&2
    return 1
  fi

  if [ -n "$BW_API_URL_DEST" ]; then
    DEST_API_URL="${BW_API_URL_DEST%/}"
  elif [[ "$server" =~ ^(https?://)vault\.bitwarden\.(com|eu)$ ]]; then
    DEST_API_URL="${BASH_REMATCH[1]}api.bitwarden.${BASH_REMATCH[2]}"
  else
    DEST_API_URL="$server/api"
  fi

  if [ -n "$BW_IDENTITY_URL_DEST" ]; then
    DEST_IDENTITY_URL="${BW_IDENTITY_URL_DEST%/}"
  elif [[ "$server" =~ ^(https?://)vault\.bitwarden\.(com|eu)$ ]]; then
    DEST_IDENTITY_URL="${BASH_REMATCH[1]}identity.bitwarden.${BASH_REMATCH[2]}"
  else
    DEST_IDENTITY_URL="$server/identity"
  fi

  if [[ ! "$DEST_API_URL" =~ ^https?:// ]] || [[ ! "$DEST_IDENTITY_URL" =~ ^https?:// ]]; then
    echo "ERROR: Destination API and identity URLs must be absolute HTTP(S) URLs" >&2
    return 1
  fi
}

curl_api() {
  curl --silent --show-error \
    --connect-timeout "${BW_API_CONNECT_TIMEOUT:-10}" \
    --max-time "${BW_API_MAX_TIME:-60}" \
    --retry "${BW_API_RETRIES:-3}" \
    --retry-delay 2 \
    "$@"
}

# Runs on exit (EXIT trap, installed once the run lock is held). Records the
# outcome to $BW_STATUS_FILE, prints a one-line run summary, and sends the
# healthcheck success/failure ping. Best-effort: never changes the exit code.
finish() {
  local rc=$?
  # Only act for the main shell — never for a command-substitution subshell that
  # happens to exit (e.g. resolve_secret runs inside $(...)).
  [ "${BASHPID:-$$}" = "${MAIN_PID:-$$}" ] || return 0
  local end_epoch duration finished
  end_epoch=$(date +%s 2>/dev/null || echo "${START_EPOCH:-0}")
  duration=$(( end_epoch - ${START_EPOCH:-end_epoch} ))
  [ "$duration" -lt 0 ] && duration=0
  finished=$(date 2>/dev/null || echo unknown)

  echo "### Run summary: status=$SYNC_STATUS stage=$SYNC_STAGE duration=${duration}s exit=$rc backup_items=$BACKUP_ITEMS backup_folders=$BACKUP_FOLDERS cli_source=$CLI_SOURCE_VERSION cli_dest=$CLI_DEST_VERSION ###"

  # Persist last-run status (best-effort; lives in the app-data volume).
  if [ -n "$BW_STATUS_FILE" ] && command -v jq >/dev/null 2>&1; then
    if jq -n \
        --arg status "$SYNC_STATUS" \
        --arg stage "$SYNC_STAGE" \
        --arg started "${START_TIME:-}" \
        --arg finished "$finished" \
        --argjson duration "$duration" \
        --argjson exit_code "$rc" \
        --argjson items "${BACKUP_ITEMS:-0}" \
        --argjson folders "${BACKUP_FOLDERS:-0}" \
        --arg cli_source "$CLI_SOURCE_VERSION" \
        --arg cli_dest "$CLI_DEST_VERSION" \
        '{status:$status, stage:$stage, started:$started, finished:$finished,
          duration_seconds:$duration, exit_code:$exit_code,
          backup:{items:$items, folders:$folders},
          cli:{source:$cli_source, destination:$cli_dest}}' \
        > "${BW_STATUS_FILE}.tmp" 2>/dev/null; then
      mv "${BW_STATUS_FILE}.tmp" "$BW_STATUS_FILE" 2>/dev/null || true
    fi
  fi

  # Healthcheck ping (success, or /fail with the failing stage).
  if [ -n "$HEALTHCHECK_URL" ] && [ -n "$HEALTHCHECK_PING" ]; then
    if [ "$SYNC_STATUS" = "success" ]; then
      echo "### Health Check - Success ###"
      curl -fsS -m 10 --retry 5 "$HEALTHCHECK_URL/$HEALTHCHECK_PING?rid=$RID" >/dev/null 2>&1 || true
    else
      echo "### Health Check - Failure (stage: $SYNC_STAGE, exit: $rc) ###"
      curl -fsS -m 10 --retry 5 \
        --data-raw "bitwarden-sync failed at stage '$SYNC_STAGE' (exit $rc)" \
        "$HEALTHCHECK_URL/$HEALTHCHECK_PING/fail?rid=$RID" >/dev/null 2>&1 || true
    fi
  fi
}

# Attempt config -> login -> unlock against the source with the currently
# installed bw-old, retrying transient transport failures (e.g. undici
# "Premature close") with backoff. The real CLI error is captured and surfaced
# instead of being swallowed. On success, sets BW_SESSION_SOURCE.
# Tunable via BW_LOGIN_RETRIES (default 3) and BW_LOGIN_RETRY_DELAY (default 5s).
# Return codes:
#   0 success
#   1 login failed with a transport-class error (worth trying another CLI version)
#   2 logged in but unlock failed (wrong master password — version change won't help)
#   3 login failed with a non-transport error (auth/config — version change won't help)
try_source_login_unlock() {
  local tries="${BW_LOGIN_RETRIES:-3}" delay="${BW_LOGIN_RETRY_DELAY:-5}"
  local attempt=1 err session
  while :; do
    bw-old logout >/dev/null 2>&1 || true
    bw-old config server "$BW_SERVER_SOURCE" >/dev/null 2>&1
    if err=$(bw-old login --apikey 2>&1); then
      if session=$(bw-old unlock "$BW_PASS_SOURCE" --raw 2>/dev/null) && [ -n "$session" ]; then
        BW_SESSION_SOURCE="$session"
        return 0
      fi
      echo "# ERROR: Logged in but failed to unlock the source vault (check BW_PASS_SOURCE) #" >&2
      return 2
    fi
    # Login failed — only transport-class errors are worth retrying/falling back.
    if ! printf '%s' "$err" | grep -qiE 'premature close|fetch failed|fetcherror|invalid response body|econnreset|etimedout|esockettimedout|socket hang up|enotfound|eai_again|und_err|network|terminated'; then
      echo "# ERROR: Source login failed (not a transport error): $err #" >&2
      return 3
    fi
    if [ "$attempt" -ge "$tries" ]; then
      echo "# Source login failed after $tries attempts on CLI $(bw-old --version 2>/dev/null): $err #" >&2
      return 1
    fi
    echo "# Source login attempt $attempt/$tries failed (transport): $err; retrying in ${delay}s... #" >&2
    attempt=$((attempt + 1))
    sleep "$delay"
    delay=$((delay * 2))
  done
}

# Log into the source vault, auto-falling back across known-good CLI versions
# on transport failures. The installed version is tried first, then each version
# in BW_CLI_OLD_FALLBACK_VERSIONS (space/comma separated; default below). On a
# password/auth error we stop immediately — cycling versions cannot help.
# Auto-fallback is Docker-only (requires the npm-managed CLI + reinstall_bw_old).
source_login_unlock() {
  local fallbacks="${BW_CLI_OLD_FALLBACK_VERSIONS:-2025.12.0 2024.9.0}"
  local installed candidates="" v rc first=1
  installed="$(bw-old --version 2>/dev/null || echo unknown)"

  # Candidate list: installed version first, then configured fallbacks (deduped).
  candidates="$installed"
  for v in ${fallbacks//,/ }; do
    case " $candidates " in *" $v "*) ;; *) candidates="$candidates $v" ;; esac
  done

  for v in $candidates; do
    if [ "$first" = 0 ]; then
      if ! command -v reinstall_bw_old >/dev/null 2>&1; then
        break  # no reinstall capability (e.g. outside Docker) — can't fall back
      fi
      echo "# Source login failing on CLI $installed; switching to CLI $v and retrying... #" >&2
      if ! reinstall_bw_old "$v"; then
        echo "# WARNING: Failed to install Bitwarden CLI $v; trying next candidate #" >&2
        continue
      fi
      installed="$(bw-old --version 2>/dev/null || echo "$v")"
    fi
    first=0

    try_source_login_unlock
    rc=$?
    case "$rc" in
      0) return 0 ;;
      2 | 3) return 1 ;;        # password/auth/config — version change won't help
      *) ;;                     # transport failure — try the next CLI version
    esac
  done

  echo "# ERROR: Source login failed on all CLI versions tried: $candidates #" >&2
  return 1
}

delete_api_resource() {
  local url="$1"
  shift
  local status

  if ! status=$(curl_api -X DELETE "$url" "$@" -w "%{http_code}" -o /dev/null); then
    return 1
  fi

  [[ "$status" =~ ^2[0-9][0-9]$ ]] || return 1
  printf '%s' "$status"
}

resolve_device_identifier() {
  local identifier_file="${BW_DEVICE_IDENTIFIER_FILE:-$BITWARDENCLI_APPDATA_DIR/device-identifier}"
  local identifier

  if [ -n "$BW_DEVICE_IDENTIFIER" ]; then
    DEST_DEVICE_IDENTIFIER="$BW_DEVICE_IDENTIFIER"
    return
  fi

  if [ -s "$identifier_file" ]; then
    IFS= read -r DEST_DEVICE_IDENTIFIER < "$identifier_file"
  else
    identifier=$(uuidgen)
    if [ -z "$identifier" ]; then
      echo "ERROR: Failed to generate a Bitwarden device identifier" >&2
      return 1
    fi

    umask 077
    if ! printf '%s\n' "$identifier" > "$identifier_file"; then
      echo "ERROR: Failed to persist Bitwarden device identifier: $identifier_file" >&2
      return 1
    fi
    DEST_DEVICE_IDENTIFIER="$identifier"
  fi

  if [ -z "$DEST_DEVICE_IDENTIFIER" ]; then
    echo "ERROR: Persisted Bitwarden device identifier is empty: $identifier_file" >&2
    return 1
  fi
}

# Persist Bitwarden CLI state to keep a stable device identity between runs.
export BITWARDENCLI_APPDATA_DIR="${BITWARDENCLI_APPDATA_DIR:-/app/data/bitwarden-cli}"
mkdir -p "$BITWARDENCLI_APPDATA_DIR"

# --- Run state + observability -------------------------------------------------
MAIN_PID="$$"
START_EPOCH=$(date +%s)
START_TIME=$(date)
RID=$(uuidgen)
SYNC_STATUS="error" # flipped to "success" only after a clean finish
SYNC_STAGE="init"   # last stage reached; recorded on failure for debugging
BACKUP_ITEMS=0
BACKUP_FOLDERS=0
CLI_SOURCE_VERSION="unknown"
CLI_DEST_VERSION="unknown"
BW_STATUS_FILE="${BW_STATUS_FILE:-$BITWARDENCLI_APPDATA_DIR/last-run.json}"
LOCK_FILE="${BW_LOCK_FILE:-$BITWARDENCLI_APPDATA_DIR/bitwarden-sync.lock}"

# Prevent overlapping runs (a manual `docker exec ... /app/script.sh` colliding
# with cron, or a run that outlasts the next scheduled tick). Best-effort.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE" || true
  if ! flock -n 9; then
    echo "# A bitwarden-sync run is already in progress (lock: $LOCK_FILE); skipping. #" >&2
    exit 0
  fi
fi

# From here on, finish() runs on exit to record status + ping the healthcheck.
trap finish EXIT
# ------------------------------------------------------------------------------

if ! resolve_device_identifier; then
  exit 1
fi

# Helper: resolve a password/secret from (in priority order):
#   1. An OpenSSL-encrypted file + keyfile  ({VAR}_ENC_FILE and {VAR}_KEYFILE)
#   2. A plain-text file (Docker secret)    ({VAR}_FILE)
#   3. A plain-text environment variable    ({VAR})
resolve_secret() {
  local var_name="$1"
  local enc_file_var="${var_name}_ENC_FILE"
  local keyfile_var="${var_name}_KEYFILE"
  local file_var="${var_name}_FILE"

  local enc_file_val="${!enc_file_var}"
  local keyfile_val="${!keyfile_var}"
  local file_val="${!file_var}"
  local plain_val="${!var_name}"

  if [ -n "$enc_file_val" ] && [ -n "$keyfile_val" ]; then
    if [ ! -f "$enc_file_val" ]; then
      echo "ERROR: Encrypted file not found: $enc_file_val" >&2
      exit 1
    fi
    if [ ! -f "$keyfile_val" ]; then
      echo "ERROR: Keyfile not found: $keyfile_val" >&2
      exit 1
    fi
    local decrypted
    decrypted=$(openssl enc -d -aes-256-cbc -in "$enc_file_val" -pass file:"$keyfile_val" 2>/dev/null)
    if [ $? -ne 0 ]; then
      echo "ERROR: Failed to decrypt $enc_file_val: $decrypted" >&2
      exit 1
    fi
    echo "$decrypted"
  elif [ -n "$file_val" ]; then
    if [ ! -r "$file_val" ]; then
      echo "ERROR: Secret file not found or not readable: $file_val" >&2
      exit 1
    fi
    cat "$file_val"
  else
    echo "$plain_val"
  fi
}

# Resolve sensitive values – supports plaintext env vars, plain files (Docker
# secrets), or OpenSSL-encrypted files, depending on what is configured.
BW_TAR_PASS=$(resolve_secret BW_TAR_PASS)
BW_PASS_SOURCE=$(resolve_secret BW_PASS_SOURCE)
BW_PASS_DEST=$(resolve_secret BW_PASS_DEST)

echo "### Bitwarden Script - Start ###"
echo "# Start Time: $START_TIME #"
echo "################################"

export BW_CLIENTID=${BW_CLIENTID_SOURCE}
export BW_CLIENTSECRET=${BW_CLIENTSECRET_SOURCE}

# Check if HEALTHCHECK_URL and HEALTHCHECK_PING are set
if [ -n "$HEALTHCHECK_URL" ] && [ -n "$HEALTHCHECK_PING" ]; then
    URL=$HEALTHCHECK_URL
    PING=$HEALTHCHECK_PING

    # Send a start ping, specify rid parameter:
    echo "### Health Check - Start ###"
    echo "# Heathcheck Ping URL: $URL/$PING/start?rid=$RID #"
    curl -fsS -m 10 --retry 5 "$URL/$PING/start?rid=$RID"
else
    echo "# Skipping health check as HEALTHCHECK_URL or HEALTHCHECK_PING is not set. #"
fi

##### Backup/Export from Source Bitwarden

echo "### Backup - Start ###"
echo "# Start of Backup Process #"

# We need a backups directory
mkdir -p /app/backups

# Set the filename for our json export as variable
SOURCE_EXPORT_OUTPUT_BASE="bw_export_"
TIMESTAMP=$(date "+%Y%m%d%H%M%S")
SOURCE_OUTPUT_FILE_JSON=/app/backups/$SOURCE_EXPORT_OUTPUT_BASE$TIMESTAMP.json

# Delete previous backups over 30 days old
echo "# Deleting previous backups older than 30 days... #"
current_date=$(date +%Y-%m-%d)
source_export_files=$(find /app/backups -type f -name "bw_export_*.tar.gz.enc")
find $source_export_files -type f -mtime +30 -exec rm -f {} +
rm -f -R $SOURCE_EXPORT_OUTPUT_BASE*.json

# Login to our Server (using old CLI for Vaultwarden compatibility) and unlock.
# source_login_unlock handles logout/config/login/unlock with retry + backoff.
SYNC_STAGE="source_login"
echo "# Logging into Source Bitwarden Server (using CLI $(bw-old --version 2>/dev/null || echo unknown))... #"
echo "# Unlocking the vault... #"
if ! source_login_unlock; then
  echo "# ERROR: Failed to unlock source vault #"
  exit 1
fi
CLI_SOURCE_VERSION="$(bw-old --version 2>/dev/null || echo unknown)"
echo "# Vault unlocked (source CLI $CLI_SOURCE_VERSION) #"

# Export out all items
SYNC_STAGE="source_export"
echo "# Exporting all items... #"
if ! bw-old --session "$BW_SESSION_SOURCE" --raw export --format json > "$SOURCE_OUTPUT_FILE_JSON"; then
  echo "# ERROR: Failed to export source vault #" >&2
  rm -f "$SOURCE_OUTPUT_FILE_JSON"
  exit 1
fi
BACKUP_ITEMS=$(jq '.items | length' "$SOURCE_OUTPUT_FILE_JSON" 2>/dev/null || echo 0)
BACKUP_FOLDERS=$(jq '.folders | length' "$SOURCE_OUTPUT_FILE_JSON" 2>/dev/null || echo 0)
echo "# Exported $BACKUP_ITEMS items, $BACKUP_FOLDERS folders #"

# Add file to encrypted tar
SYNC_STAGE="backup_encrypt"
file_to_compress="$SOURCE_OUTPUT_FILE_JSON"
tar -czf - "$file_to_compress" | \
  openssl enc -aes-256-cbc -pbkdf2 -pass pass:"$BW_TAR_PASS" -out "/app/backups/$SOURCE_EXPORT_OUTPUT_BASE$TIMESTAMP.tar.gz.enc"

# Cleanup
rm -f "$SOURCE_OUTPUT_FILE_JSON"

echo "# End of Backup Process #"
echo "### Backup - End ###"

### End of Backup

# Restoring process
echo "### Restore - Start ###"
echo "# Start of Restore Process #"

unset BW_CLIENTID
unset BW_CLIENTSECRET

# Export/Restore to Destination Bitwarden
export BW_CLIENTID=${BW_CLIENTID_DEST}
export BW_CLIENTSECRET=${BW_CLIENTSECRET_DEST}

if ! resolve_destination_urls; then
  exit 1
fi
echo "# Destination API: $DEST_API_URL #"
echo "# Destination identity: $DEST_IDENTITY_URL #"

# Logging out before work
echo "# Logging out from Bitwarden... #"
bw-new logout 2>/dev/null || true

# Logging into the destination server (using new CLI for Bitwarden Cloud)
SYNC_STAGE="dest_login"
CLI_DEST_VERSION="$(bw-new --version 2>/dev/null || echo unknown)"
echo "# Logging into Destination Bitwarden Server (using CLI $CLI_DEST_VERSION)... #"
bw-new logout 2>/dev/null || true
bw-new config server $BW_SERVER_DEST
bw-new login --apikey

BW_SESSION_DEST=$(bw-new unlock "$BW_PASS_DEST" --raw)

if [ -z "$BW_SESSION_DEST" ]; then
  echo "# ERROR: Failed to unlock destination vault #"
  exit 1
fi

# Find and decrypt the latest backup
DEST_LATEST_BACKUP_TAR=$(find /app/backups/bw_export_*.tar.gz.enc -type f -exec ls -t1 {} + | head -1)
echo "# Decrypting and extracting the latest backup... #"
openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$BW_TAR_PASS" -in "$DEST_LATEST_BACKUP_TAR" | \
  tar -xzf - -C /root
DEST_LATEST_BACKUP_JSON=$(find /root/app/backups/bw_export_*.json -type f -exec ls -t1 {} + | head -1)
echo "# Backup: $(jq '.items | length' "$DEST_LATEST_BACKUP_JSON") items, $(jq '.folders | length' "$DEST_LATEST_BACKUP_JSON") folders #"

# If BW_IMPORT_LIMIT is set, truncate to N items (one of each type) for testing
if [ -n "$BW_IMPORT_LIMIT" ]; then
  echo "# TEST MODE: Limiting import to $BW_IMPORT_LIMIT items per type #"
  jq --argjson n "$BW_IMPORT_LIMIT" '
    .items |= (group_by(.type) | map(.[0:$n]) | add // [])
  ' "$DEST_LATEST_BACKUP_JSON" > "${DEST_LATEST_BACKUP_JSON}.tmp" && \
    mv "${DEST_LATEST_BACKUP_JSON}.tmp" "$DEST_LATEST_BACKUP_JSON"
  echo "# Test import: $(jq '.items | length' "$DEST_LATEST_BACKUP_JSON") items #"
fi

# Clear the destination vault via Bitwarden REST API (no PTY/CLI needed for deletion).
# Bulk-deleting via API is orders of magnitude faster than per-item bw-new calls.
SYNC_STAGE="dest_token"
echo "# Getting API access token... #"
BW_CLIENT_VERSION=$(bw-new --version 2>/dev/null || printf '%s' "unknown")
if ! TOKEN_RESPONSE=$(curl_api --fail -X POST "$DEST_IDENTITY_URL/connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Bitwarden-Client-Version: $BW_CLIENT_VERSION" \
  -H "Bitwarden-Client-Name: cli" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=api" \
  --data-urlencode "client_id=${BW_CLIENTID_DEST}" \
  --data-urlencode "client_secret=${BW_CLIENTSECRET_DEST}" \
  --data-urlencode "deviceType=8" \
  --data-urlencode "deviceIdentifier=$DEST_DEVICE_IDENTIFIER" \
  --data-urlencode "deviceName=${BW_DEVICE_NAME:-bitwarden-sync}"); then
  echo "# ERROR: Failed to contact destination identity server: $DEST_IDENTITY_URL #" >&2
  rm -f "$DEST_LATEST_BACKUP_JSON"
  exit 1
fi
API_TOKEN=$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null)

if [ -z "$API_TOKEN" ]; then
  echo "# ERROR: Destination identity server returned no API access token #" >&2
  rm -f "$DEST_LATEST_BACKUP_JSON"
  exit 1
fi
echo "# API token obtained #"

SYNC_STAGE="dest_fetch"
echo "# Fetching existing vault contents... #"
if ! SYNC_DATA=$(curl_api --fail "$DEST_API_URL/sync?excludeDomains=true" \
  -H "Authorization: Bearer $API_TOKEN"); then
  echo "# ERROR: Failed to fetch destination vault from $DEST_API_URL #" >&2
  rm -f "$DEST_LATEST_BACKUP_JSON"
  exit 1
fi
if ! printf '%s' "$SYNC_DATA" | jq -e '
  type == "object" and
  (.ciphers | type == "array") and
  (.folders | type == "array")
' >/dev/null 2>&1; then
  echo "# ERROR: Destination sync endpoint returned an invalid vault response #" >&2
  rm -f "$DEST_LATEST_BACKUP_JSON"
  exit 1
fi

# Extract IDs — sync response uses lowercase keys; skip org ciphers (organizationId != null)
CIPHER_IDS=$(printf '%s' "$SYNC_DATA" | \
  jq '[.ciphers[]? | select(.organizationId == null) | .id] | map(select(. != null))' 2>/dev/null || echo '[]')
FOLDER_IDS=$(printf '%s' "$SYNC_DATA" | \
  jq '[.folders[]?.id | select(. != null and . != "")]' 2>/dev/null || echo '[]')
CIPHER_COUNT=$(printf '%s' "$CIPHER_IDS" | jq 'length')
FOLDER_COUNT=$(printf '%s' "$FOLDER_IDS" | jq 'length')
echo "# Existing destination: $CIPHER_COUNT ciphers, $FOLDER_COUNT folders #"

# Bulk delete all personal ciphers in batches of 500 (API limit)
# Soft-delete only; Bitwarden auto-purges trash after 30 days
SYNC_STAGE="dest_clear"
if [ "$CIPHER_COUNT" -gt 0 ]; then
  echo "# Bulk deleting $CIPHER_COUNT ciphers (batches of 500)... #"
  OFFSET=0
  TOTAL_DELETED=0
  while true; do
    BATCH=$(printf '%s' "$CIPHER_IDS" | jq ".[${OFFSET}:$((OFFSET+500))]")
    BATCH_SIZE=$(printf '%s' "$BATCH" | jq 'length')
    [ "$BATCH_SIZE" -eq 0 ] && break
    if STATUS=$(delete_api_resource "$DEST_API_URL/ciphers" \
      -H "Authorization: Bearer $API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"ids\": $BATCH}"); then
      TOTAL_DELETED=$((TOTAL_DELETED + BATCH_SIZE))
      echo "# Deleted batch $TOTAL_DELETED/$CIPHER_COUNT (HTTP $STATUS) #"
    else
      echo "# Bulk deletion unavailable; deleting this batch individually... #"
      mapfile -t BATCH_IDS < <(printf '%s' "$BATCH" | jq -r '.[]')
      for id in "${BATCH_IDS[@]}"; do
        if ! STATUS=$(delete_api_resource "$DEST_API_URL/ciphers/$id" \
          -H "Authorization: Bearer $API_TOKEN"); then
          echo "# ERROR: Failed to delete cipher $id #" >&2
          rm -f "$DEST_LATEST_BACKUP_JSON"
          exit 1
        fi
        TOTAL_DELETED=$((TOTAL_DELETED + 1))
      done
      echo "# Deleted individually $TOTAL_DELETED/$CIPHER_COUNT #"
    fi
    OFFSET=$((OFFSET + 500))
  done
fi

# Delete folders individually (no bulk endpoint)
mapfile -t DEST_FOLDER_IDS < <(printf '%s' "$FOLDER_IDS" | jq -r '.[]' 2>/dev/null)
for id in "${DEST_FOLDER_IDS[@]}"; do
  if ! STATUS=$(delete_api_resource "$DEST_API_URL/folders/$id" \
    -H "Authorization: Bearer $API_TOKEN"); then
    echo "# ERROR: Failed to delete folder $id #" >&2
    rm -f "$DEST_LATEST_BACKUP_JSON"
    exit 1
  fi
  echo "# Deleted folder $id (HTTP $STATUS) #"
done

# Import via a single PTY call — bw import prompts for master password exactly once
SYNC_STAGE="import"
echo "# Importing backup into destination vault... #"
IMPORT_OUT=$(printf "%s\n" "$BW_PASS_DEST" | \
  script -qfc "bw-new --session \"$BW_SESSION_DEST\" import bitwardenjson \"$DEST_LATEST_BACKUP_JSON\"" \
  /dev/null 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')

# Show only meaningful lines — filter echoed password, prompt noise, and blanks
printf '%s\n' "$IMPORT_OUT" | grep -vF "$BW_PASS_DEST" | grep -v '^. Master password' | grep -v '^[[:space:]]*$'

if ! printf '%s\n' "$IMPORT_OUT" | grep -qi "imported"; then
  echo "# ERROR: Import did not complete #"
  rm -f "$DEST_LATEST_BACKUP_JSON"
  exit 1
fi

rm -f "$DEST_LATEST_BACKUP_JSON"

echo "# End of Restore Process #"
echo "### Restore - End ###"

bw-old logout > /dev/null 2>&1 || true
bw-new logout > /dev/null 2>&1 || true

unset BW_CLIENTID
unset BW_CLIENTSECRET

# Mark success — finish() (EXIT trap) writes the status file, prints the run
# summary, and sends the healthcheck success ping.
SYNC_STAGE="done"
SYNC_STATUS="success"
