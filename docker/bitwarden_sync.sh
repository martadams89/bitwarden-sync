#!/bin/bash

# Persist Bitwarden CLI state to keep a stable device identity between runs.
export BITWARDENCLI_APPDATA_DIR="${BITWARDENCLI_APPDATA_DIR:-/app/data/bitwarden-cli}"
mkdir -p "$BITWARDENCLI_APPDATA_DIR"

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

# Set start time
START_TIME=$(date)
echo "### Bitwarden Script - Start ###"
echo "# Start Time: $START_TIME #"
echo "################################"

export BW_CLIENTID=${BW_CLIENTID_SOURCE}
export BW_CLIENTSECRET=${BW_CLIENTSECRET_SOURCE}

RID=`uuidgen`

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

# Lets make sure we're logged out before we get to work
echo "# Logging out from Bitwarden... #"
bw-old logout 2>/dev/null || true

# Login to our Server (using old CLI for Vaultwarden compatibility)
echo "# Logging into Source Bitwarden Server (using CLI 2024.9.0)... #"
bw-old logout 2>/dev/null || true
bw-old config server $BW_SERVER_SOURCE
bw-old login --apikey

echo "# Unlocking the vault... #"
BW_SESSION_SOURCE=$(bw-old unlock "$BW_PASS_SOURCE" --raw)

if [ -z "$BW_SESSION_SOURCE" ]; then
  echo "# ERROR: Failed to unlock source vault #"
  exit 1
fi

# Export out all items
echo "# Exporting all items... #"
bw-old --session $BW_SESSION_SOURCE --raw export --format json > $SOURCE_OUTPUT_FILE_JSON

# Add file to encrypted tar
file_to_compress="$SOURCE_OUTPUT_FILE_JSON"
tar -czf - "$file_to_compress" | \
  openssl enc -aes-256-cbc -pbkdf2 -pass pass:"$BW_TAR_PASS" -out "/app/backups/$SOURCE_EXPORT_OUTPUT_BASE$TIMESTAMP.tar.gz.enc"

# Cleanup
rm -f $SOURCE_OUTPUT_FILE_JSON

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

# Logging out before work
echo "# Logging out from Bitwarden... #"
bw-new logout 2>/dev/null || true

# Logging into the destination server (using new CLI for Bitwarden Cloud)
echo "# Logging into Destination Bitwarden Server (using latest CLI)... #"
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
echo "# Getting API access token... #"
API_TOKEN=$(curl -sf -X POST "https://identity.bitwarden.com/connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Bitwarden-Client-Version: 2026.4.1" \
  -H "Bitwarden-Client-Name: cli" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=api" \
  --data-urlencode "client_id=${BW_CLIENTID_DEST}" \
  --data-urlencode "client_secret=${BW_CLIENTSECRET_DEST}" \
  --data-urlencode "deviceType=8" \
  --data-urlencode "deviceIdentifier=$(uuidgen)" \
  --data-urlencode "deviceName=bitwarden-sync" \
  | jq -r '.access_token // empty')

if [ -z "$API_TOKEN" ]; then
  echo "# ERROR: Failed to get Bitwarden API access token #"
  rm -f "$DEST_LATEST_BACKUP_JSON"
  exit 1
fi
echo "# API token obtained #"

echo "# Fetching existing vault contents... #"
SYNC_DATA=$(curl -sf "https://api.bitwarden.com/sync?excludeDomains=true" \
  -H "Authorization: Bearer $API_TOKEN")

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
if [ "$CIPHER_COUNT" -gt 0 ]; then
  echo "# Bulk deleting $CIPHER_COUNT ciphers (batches of 500)... #"
  OFFSET=0
  TOTAL_DELETED=0
  while true; do
    BATCH=$(printf '%s' "$CIPHER_IDS" | jq ".[${OFFSET}:$((OFFSET+500))]")
    BATCH_SIZE=$(printf '%s' "$BATCH" | jq 'length')
    [ "$BATCH_SIZE" -eq 0 ] && break
    STATUS=$(curl -sf -X DELETE "https://api.bitwarden.com/ciphers" \
      -H "Authorization: Bearer $API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"ids\": $BATCH}" \
      -w "%{http_code}" -o /dev/null 2>/dev/null)
    TOTAL_DELETED=$((TOTAL_DELETED + BATCH_SIZE))
    echo "# Deleted batch $TOTAL_DELETED/$CIPHER_COUNT (HTTP $STATUS) #"
    OFFSET=$((OFFSET + 500))
  done
fi

# Delete folders individually (no bulk endpoint)
printf '%s' "$FOLDER_IDS" | jq -r '.[]' 2>/dev/null | while read -r id; do
  [ -z "$id" ] && continue
  STATUS=$(curl -sf -X DELETE "https://api.bitwarden.com/folders/$id" \
    -H "Authorization: Bearer $API_TOKEN" \
    -w "%{http_code}" -o /dev/null 2>/dev/null)
  echo "# Deleted folder $id (HTTP $STATUS) #"
done

# Import via a single PTY call — bw import prompts for master password exactly once
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

# Check if HEALTHCHECK_URL and HEALTHCHECK_PING are set
if [ -n "$HEALTHCHECK_URL" ] && [ -n "$HEALTHCHECK_PING" ]; then
    # send the success ping, use the same rid parameter:
    echo "### Health Check - Success ###"
    echo "# Success Ping URL: $URL/$PING?rid=$RID #"
    curl -fsS -m 10 --retry 5 $URL/$PING?rid=$RID
    echo "### Health Check - End ###"
else
    echo "# Skipping health check as HEALTHCHECK_URL or HEALTHCHECK_PING is not set. #"
fi
