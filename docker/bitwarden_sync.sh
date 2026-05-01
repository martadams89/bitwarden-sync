#!/bin/bash

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
    decrypted=$(openssl enc -d -aes-256-cbc -in "$enc_file_val" -pass file:"$keyfile_val" 2>&1)
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
BW_SESSION_SOURCE=$(bw-old unlock $BW_PASS_SOURCE --raw)

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
  openssl enc -aes-256-cbc -pass pass:"$BW_TAR_PASS" -out "/app/backups/$SOURCE_EXPORT_OUTPUT_BASE$TIMESTAMP.tar.gz.enc"

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

# We want to remove items later, so we set a base filename now
DEST_EXPORT_OUTPUT_BASE="bw_vault_items_to_remove"
DEST_OUTPUT_FILE=$DEST_EXPORT_OUTPUT_BASE$TIMESTAMP.json

# Logging out before work
echo "# Logging out from Bitwarden... #"
bw-new logout 2>/dev/null || true

# Logging into the destination server (using new CLI for Bitwarden Cloud)
echo "# Logging into Destination Bitwarden Server (using latest CLI)... #"
bw-new logout 2>/dev/null || true
bw-new config server $BW_SERVER_DEST
bw-new login --apikey

BW_SESSION_DEST=$(bw-new unlock $BW_PASS_DEST --raw)

if [ -z "$BW_SESSION_DEST" ]; then
  echo "# ERROR: Failed to unlock destination vault #"
  exit 1
fi

# Export what's currently in the vault, so we can remove it
echo "# Exporting current items from destination vault... #"
bw-new --session $BW_SESSION_DEST --raw export --format json > $DEST_OUTPUT_FILE

# Find and remove all folders, items, attachments, and org collections
echo "# Removing items from the destination vault... This might take some time. #"

for id in $(jq '.folders[]? | .id' $DEST_OUTPUT_FILE); do
  id=$(sed 's/"//g' <<< "$id")
  bw-new --session $BW_SESSION_DEST --raw delete -p folder $id
done

# Find and remove all items
for id in $(jq '.items[]? | .id' $DEST_OUTPUT_FILE); do
  id=$(sed 's/"//g' <<< "$id")
  bw-new --session $BW_SESSION_DEST --raw delete -p item $id
done

# Find and remove all attachments
for id in $(jq '.attachments[]? | .id' $DEST_OUTPUT_FILE); do
  id=$(sed 's/"//g' <<< "$id")
  bw-new --session $BW_SESSION_DEST --raw delete -p attachment $id
done

echo "# Item removal completed. #"

# Find the latest backup file
DEST_LATEST_BACKUP_TAR=$(find /app/backups/bw_export_*.tar.gz.enc -type f -exec ls -t1 {} + | head -1)

# Set your encrypted file and password
encrypted_source_tar="$DEST_LATEST_BACKUP_TAR"
source_tar_password="$BW_TAR_PASS"

# Decrypt the file and extract it
echo "# Decrypting and extracting the latest backup... #"
openssl enc -d -aes-256-cbc -pass pass:"$source_tar_password" -in "$encrypted_source_tar" | \
  tar -xzf -

echo "# Decompression completed successfully. #"

# Find the latest backup file
DEST_LATEST_BACKUP_JSON=$(find /root/app/backups/bw_export_*.json -type f -exec ls -t1 {} + | head -1)

# Import the latest backup
echo "# Importing the latest backup... #"
bw-new --session $BW_SESSION_DEST --raw import bitwardenjson $DEST_LATEST_BACKUP_JSON

# Clean up our item list to delete
rm $DEST_OUTPUT_FILE
rm -f $DEST_LATEST_BACKUP_JSON

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
