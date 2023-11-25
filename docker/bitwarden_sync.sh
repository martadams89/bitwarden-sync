#!/bin/bash

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
bw logout

# Login to our Server
echo "# Logging into Source Bitwarden Server... #"
bw config server $BW_SERVER_SOURCE
bw login $BW_ACCOUNT_SOURCE --apikey --raw

# Because we're using an API Key, we need to unlock the vault to get a session ID
echo "# Unlocking the vault... #"
BW_SESSION_SOURCE=$(bw unlock $BW_PASS_SOURCE --raw)

# Export out all items
echo "# Exporting all items... #"
bw --session $BW_SESSION_SOURCE --raw export --format json > $SOURCE_OUTPUT_FILE_JSON

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
bw logout

# Logging into the destination server
echo "# Logging into Destination Bitwarden Server... #"
bw config server $BW_SERVER_DEST
bw login $BW_ACCOUNT_DEST --apikey --raw
BW_SESSION_DEST=$(bw unlock $BW_PASS_DEST --raw)

# Export what's currently in the vault, so we can remove it
echo "# Exporting current items from destination vault... #"
bw --session $BW_SESSION_DEST --raw export --format json > $DEST_OUTPUT_FILE

# Find and remove all folders, items, attachments, and org collections
echo "# Removing items from the destination vault... This might take some time. #"

for id in $(jq '.folders[]? | .id' $DEST_OUTPUT_FILE); do
  id=$(sed 's/"//g' <<< "$id")
  bw --session $BW_SESSION_DEST --raw delete -p folder $id
done

# Find and remove all items
for id in $(jq '.items[]? | .id' $DEST_OUTPUT_FILE); do
  id=$(sed 's/"//g' <<< "$id")
  bw --session $BW_SESSION_DEST --raw delete -p item $id
done

# Find and remove all attachments
for id in $(jq '.attachments[]? | .id' $DEST_OUTPUT_FILE); do
  id=$(sed 's/"//g' <<< "$id")
  bw --session $BW_SESSION_DEST --raw delete -p attachment $id
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
bw --session $BW_SESSION_DEST --raw import bitwardenjson $DEST_LATEST_BACKUP_JSON

# Clean up our item list to delete
rm $DEST_OUTPUT_FILE
rm -f $DEST_LATEST_BACKUP_JSON

echo "# End of Restore Process #"
echo "### Restore - End ###"

bw logout > /dev/null

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
