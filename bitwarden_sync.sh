#!/bin/bash

set -o pipefail

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
  local identifier_file="${BW_DEVICE_IDENTIFIER_FILE:-$BITWARDEN_SYNC_STATE_DIR/device-identifier}"
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

run_import() {
  if script --version 2>&1 | grep -qi 'util-linux'; then
    printf "%s\n" "$BW_PASS_DEST" | \
      script -qfc "bw-new --session \"$BW_SESSION_DEST\" import bitwardenjson \"$DEST_LATEST_BACKUP_JSON\"" \
      /dev/null
  elif command -v expect >/dev/null 2>&1; then
    BW_IMPORT_PASSWORD="$BW_PASS_DEST" \
    BW_IMPORT_SESSION="$BW_SESSION_DEST" \
    BW_IMPORT_FILE="$DEST_LATEST_BACKUP_JSON" \
      expect <<'EXPECT_SCRIPT'
set timeout -1
spawn bw-new --session $env(BW_IMPORT_SESSION) import bitwardenjson $env(BW_IMPORT_FILE)
expect {
  -nocase -re {master password} {
    send -- "$env(BW_IMPORT_PASSWORD)\r"
    exp_continue
  }
  eof
}
catch wait result
exit [lindex $result 3]
EXPECT_SCRIPT
  else
    echo "ERROR: Import requires util-linux 'script' or 'expect' for the master-password prompt" >&2
    return 1
  fi
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1
BACKUP_DIR="${BW_BACKUP_DIR:-$SCRIPT_DIR/backups}"
BITWARDEN_SYNC_STATE_DIR="${BITWARDEN_SYNC_STATE_DIR:-$SCRIPT_DIR/.bitwarden-sync}"
mkdir -p "$BACKUP_DIR" "$BITWARDEN_SYNC_STATE_DIR"
if ! resolve_device_identifier; then
  exit 1
fi

# We need to set some variables
# Set your account name, Vault master password and API Info
# Set the BitWarden Server we want to use

export LC_CTYPE=C
export LC_ALL=C

export BW_TAR_PASS=$(openssl enc -d -aes-256-cbc -in bitwarden_backup_password.enc -pass file:bitwarden_backup_keyfile)

#Source Variables
export BW_ACCOUNT_SOURCE=xxxxx@yyy.com
export BW_PASS_SOURCE=$(openssl enc -d -aes-256-cbc -in bitwarden_backup_password.enc -pass file:bitwarden_backup_keyfile)
export BW_CLIENTID_SOURCE=xxxx
export BW_CLIENTSECRET_SOURCE=xxxx
export BW_SERVER_SOURCE=https://vaultwarden.mydomain.com

# Destination Variables
export BW_ACCOUNT_DEST=xxxxx@yyy.com
export BW_PASS_DEST=$(openssl enc -d -aes-256-cbc -in bitwarden_restore_password.enc -pass file:bitwarden_restore_keyfile)
export BW_CLIENTID_DEST=XXXXX
export BW_CLIENTSECRET_DEST=XXXX
export BW_SERVER_DEST=https://vault.bitwarden.com

# Set start time
START_TIME=$(date)
echo "### Bitwarden Script - Start ###"
echo "# Start Time: $START_TIME #"
echo "################################"

export BW_CLIENTID=${BW_CLIENTID_SOURCE}
export BW_CLIENTSECRET=${BW_CLIENTSECRET_SOURCE}

##### Backup/Export from Source Bitwarden

echo "### Backup - Start ###"
echo "# Start of Backup Process #"

# We need a backups directory
mkdir -p "$BACKUP_DIR"

# Set the filename for our json export as variable
SOURCE_EXPORT_OUTPUT_BASE="bw_export_"
TIMESTAMP=$(date "+%Y%m%d%H%M%S")
SOURCE_OUTPUT_FILE_JSON="$BACKUP_DIR/$SOURCE_EXPORT_OUTPUT_BASE$TIMESTAMP.json"

# Delete previous backups over 30 days old
echo "# Deleting previous backups older than 30 days... #"
current_date=$(date +%Y-%m-%d)
find "$BACKUP_DIR" -type f -name "bw_export_*.tar.gz.enc" -mtime +30 -exec rm -f {} +
rm -f "$BACKUP_DIR"/"$SOURCE_EXPORT_OUTPUT_BASE"*.json

# Lets make sure we're logged out before we get to work
echo "# Logging out from Bitwarden... #"
bw-old logout 2>/dev/null || true

# Login to our Server (using old CLI for Vaultwarden compatibility)
echo "# Logging into Source Bitwarden Server (using CLI 2024.9.0)... #"
bw-old logout 2>/dev/null || true
bw-old config server "$BW_SERVER_SOURCE"
bw-old login --apikey

echo "# Unlocking the vault... #"
BW_SESSION_SOURCE=$(bw-old unlock "$BW_PASS_SOURCE" --raw)

if [ -z "$BW_SESSION_SOURCE" ]; then
  echo "# ERROR: Failed to unlock source vault #"
  exit 1
fi

# Export out all items
echo "# Exporting all items... #"
if ! bw-old --session "$BW_SESSION_SOURCE" --raw export --format json > "$SOURCE_OUTPUT_FILE_JSON"; then
  echo "# ERROR: Failed to export source vault #" >&2
  rm -f "$SOURCE_OUTPUT_FILE_JSON"
  exit 1
fi

# Add file to encrypted tar
SOURCE_ARCHIVE="$BACKUP_DIR/$SOURCE_EXPORT_OUTPUT_BASE$TIMESTAMP.tar.gz.enc"
if ! tar -C "$BACKUP_DIR" -czf - "$(basename "$SOURCE_OUTPUT_FILE_JSON")" | \
  openssl enc -aes-256-cbc -pbkdf2 -pass pass:"$BW_TAR_PASS" -out "$SOURCE_ARCHIVE"; then
  echo "# ERROR: Failed to create encrypted backup #" >&2
  rm -f "$SOURCE_OUTPUT_FILE_JSON" "$SOURCE_ARCHIVE"
  exit 1
fi

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
echo "# Logging into Destination Bitwarden Server (using latest CLI)... #"
bw-new logout 2>/dev/null || true
bw-new config server "$BW_SERVER_DEST"
bw-new login --apikey

BW_SESSION_DEST=$(bw-new unlock "$BW_PASS_DEST" --raw)

if [ -z "$BW_SESSION_DEST" ]; then
  echo "# ERROR: Failed to unlock destination vault #"
  exit 1
fi

# Find the latest backup file
DEST_LATEST_BACKUP_TAR=$(find "$BACKUP_DIR" -type f -name "bw_export_*.tar.gz.enc" -exec ls -t1 {} + | head -1)
if [ -z "$DEST_LATEST_BACKUP_TAR" ]; then
  echo "# ERROR: No encrypted backup was found #" >&2
  exit 1
fi

# Decrypt the file and extract it
echo "# Decrypting and extracting the latest backup... #"
if ! openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$BW_TAR_PASS" -in "$DEST_LATEST_BACKUP_TAR" | \
  tar -xzf - -C "$BACKUP_DIR"; then
  echo "# ERROR: Failed to decrypt or extract the latest backup #" >&2
  exit 1
fi

echo "# Decompression completed successfully. #"

# Find the latest backup file
DEST_LATEST_BACKUP_JSON=$(find "$BACKUP_DIR" -type f -name "bw_export_*.json" -exec ls -t1 {} + | head -1)
if [ -z "$DEST_LATEST_BACKUP_JSON" ]; then
  echo "# ERROR: Extracted backup JSON was not found #" >&2
  exit 1
fi
echo "# Backup: $(jq '.items | length' "$DEST_LATEST_BACKUP_JSON") items, $(jq '.folders | length' "$DEST_LATEST_BACKUP_JSON") folders #"

# If BW_IMPORT_LIMIT is set, truncate to N items (one of each type) for testing
if [ -n "$BW_IMPORT_LIMIT" ]; then
  echo "# TEST MODE: Limiting import to $BW_IMPORT_LIMIT items per type #"
  jq --argjson n "$BW_IMPORT_LIMIT" '
    .items |= (group_by(.type) | map(.[0:$n]) | add // [])
  ' "$DEST_LATEST_BACKUP_JSON" > "${DEST_LATEST_BACKUP_JSON}.tmp" && \
    mv "${DEST_LATEST_BACKUP_JSON}.tmp" "$DEST_LATEST_BACKUP_JSON"
fi

# Clear the destination vault via the REST API.
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

CIPHER_IDS=$(printf '%s' "$SYNC_DATA" | \
  jq '[.ciphers[]? | select(.organizationId == null) | .id] | map(select(. != null))')
FOLDER_IDS=$(printf '%s' "$SYNC_DATA" | \
  jq '[.folders[]?.id | select(. != null and . != "")]')
CIPHER_COUNT=$(printf '%s' "$CIPHER_IDS" | jq 'length')
FOLDER_COUNT=$(printf '%s' "$FOLDER_IDS" | jq 'length')
echo "# Existing destination: $CIPHER_COUNT ciphers, $FOLDER_COUNT folders #"

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
      while IFS= read -r id; do
        if ! STATUS=$(delete_api_resource "$DEST_API_URL/ciphers/$id" \
          -H "Authorization: Bearer $API_TOKEN"); then
          echo "# ERROR: Failed to delete cipher $id #" >&2
          rm -f "$DEST_LATEST_BACKUP_JSON"
          exit 1
        fi
        TOTAL_DELETED=$((TOTAL_DELETED + 1))
      done < <(printf '%s' "$BATCH" | jq -r '.[]')
      echo "# Deleted individually $TOTAL_DELETED/$CIPHER_COUNT #"
    fi
    OFFSET=$((OFFSET + 500))
  done
fi

while IFS= read -r id; do
  if ! STATUS=$(delete_api_resource "$DEST_API_URL/folders/$id" \
    -H "Authorization: Bearer $API_TOKEN"); then
    echo "# ERROR: Failed to delete folder $id #" >&2
    rm -f "$DEST_LATEST_BACKUP_JSON"
    exit 1
  fi
  echo "# Deleted folder $id (HTTP $STATUS) #"
done < <(printf '%s' "$FOLDER_IDS" | jq -r '.[]')

# Bitwarden CLI 2026.x prompts for the master password during import.
echo "# Importing backup into destination vault... #"
if ! IMPORT_OUT=$(run_import 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g'); then
  echo "# ERROR: Import command failed #" >&2
  rm -f "$DEST_LATEST_BACKUP_JSON"
  exit 1
fi
printf '%s\n' "$IMPORT_OUT" | grep -vF "$BW_PASS_DEST" | grep -v '^. Master password' | grep -v '^[[:space:]]*$'

if ! printf '%s\n' "$IMPORT_OUT" | grep -qi "imported"; then
  echo "# ERROR: Import did not complete #" >&2
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

unset BW_TAR_PASS
unset BW_ACCOUNT_SOURCE
unset BW_PASS_SOURCE
unset BW_CLIENTID_SOURCE
unset BW_CLIENTSECRET_SOURCE
unset BW_SERVER_SOURCE
unset BW_ACCOUNT_DEST
unset BW_PASS_DEST
unset BW_CLIENTSECRET_DEST
unset BW_SERVER_DEST
