#!/bin/bash

RID=`uuidgen`
# Check if HEALTHCHECK_URL and HEALTHCHECK_PING are set
if [ -n "$HEALTHCHECK_URL" ] && [ -n "$HEALTHCHECK_PING" ]; then
    URL=$HEALTHCHECK_URL
    PING=$HEALTHCHECK_PING

    # Send a start ping, specify rid parameter:
    curl -fsS -m 10 --retry 5 "$URL/$PING/start?rid=$RID"
else
    echo "Skipping health check as HEALTHCHECK_URL or HEALTHCHECK_PING is not set."
fi

##### Backup/Export from Source Bitwarden

# We need a backups directory
mkdir -p /app/backups

# Set the filename for our json export as variable
SOURCE_EXPORT_OUTPUT_BASE="bw_export_"
TIMESTAMP=$(date "+%Y%m%d%H%M%S")
SOURCE_OUTPUT_FILE_JSON=/app/backups/$SOURCE_EXPORT_OUTPUT_BASE$TIMESTAMP.json

# Delete previous backups over 30 days old
#
# Get the current date
current_date=$(date +%Y-%m-%d)

# Find all tar.gz.enc files starting with "bw_export_" in the backups folder
source_export_files=$(find /app/backups -type f -name "bw_export_*.tar.gz.enc")

# Delete any files older than 30 days
find $source_export_files -type f -mtime +30 -exec rm -f {} +

# Delete any bw_export json files that have been left over
rm -f -R $SOURCE_EXPORT_OUTPUT_BASE*.json

# Lets make sure we're logged out before we get to work
bw logout

# Login to our Server
bw config server $BW_SERVER_SOURCE
bw login $BW_ACCOUNT_SOURCE --apikey --raw

# Because we're using an API Key, we need to unlock the vault to get a session ID
BW_SESSION_SOURCE=$(bw unlock $BW_BACKUP_PASS_SOURCE --raw)

# Export out all items
bw --session $BW_SESSION_SOURCE --raw export --format json > $SOURCE_OUTPUT_FILE_JSON

# Add file to encrypted tar
file_to_compress="$SOURCE_OUTPUT_FILE_JSON"

tar -czf - "$file_to_compress" | \
  openssl enc -aes-256-cbc -pass pass:"$BW_TAR_PASS" -out "/app/backups/$SOURCE_EXPORT_OUTPUT_BASE$TIMESTAMP.tar.gz.enc"

rm -f $SOURCE_OUTPUT_FILE_JSON

### End of Backup

### Start of Restore

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
bw logout

# Logging into the destination server
echo "# Logging into Destination Bitwarden Server... #"
bw config server $BW_SERVER_DEST
bw login $BW_ACCOUNT_DEST --apikey --raw
BW_SESSION_DEST=$(bw unlock $BW_PASS_DEST --raw)

# Find the latest backup file
DEST_LATEST_BACKUP_TAR=$(find /app/backups/bw_export_*.tar.gz.enc -type f -exec ls -t1 {} + | head -1)

# Set your encrypted file and password
encrypted_source_tar="$DEST_LATEST_BACKUP_TAR"
source_tar_password="$BW_TAR_PASS"

# Decrypt the file and extract it
echo "# Decrypting and extracting the latest backup... #"
decrypted_tar="/app/backups/decrypted_backup.tar.gz"
openssl enc -d -aes-256-cbc -pass pass:"$source_tar_password" -in "$encrypted_source_tar" | \
  tar -xzf - -C /app/backups/

# Find the latest backup file
DEST_LATEST_BACKUP_JSON=$(find /app/backups/bw_export_*.json -type f -exec ls -t1 {} + | head -1)

# Compare the source and destination JSON files and extract new entries
echo "# Comparing source and destination JSON files... #"
NEW_ENTRIES_FILE="/app/backups/new_entries.json"
jq -s 'unique_by(.id) | .[0] + .[1]' $DEST_LATEST_BACKUP_JSON $SOURCE_OUTPUT_FILE_JSON > $NEW_ENTRIES_FILE

# Import the new entries
echo "# Importing new entries... #"
bw --session $BW_SESSION_DEST --raw import bitwardenjson $NEW_ENTRIES_FILE

# Cleanup
rm -f $DEST_LATEST_BACKUP_JSON
rm -f $decrypted_tar
rm -f $NEW_ENTRIES_FILE

### End of Restore

bw logout > /dev/null

# Check if HEALTHCHECK_URL and HEALTHCHECK_PING are set
if [ -n "$HEALTHCHECK_URL" ] && [ -n "$HEALTHCHECK_PING" ]; then

    # send the success ping, use same rid parameter:
    curl -fsS -m 10 --retry 5 $URL/$PING?rid=$RID
else
    echo "Skipping health check as HEALTHCHECK_URL or HEALTHCHECK_PING is not set."
fi