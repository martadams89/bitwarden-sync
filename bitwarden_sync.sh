#!/bin/bash

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


##### Backup/Export from Source Bitwarden

# We need a backups directory
mkdir -p backups

# Set the filename for our json export as variable
SOURCE_EXPORT_OUTPUT_BASE="bw_export_"
TIMESTAMP=$(date "+%Y%m%d%H%M%S")
SOURCE_OUTPUT_FILE=backups/$SOURCE_EXPORT_OUTPUT_BASE$TIMESTAMP.json

# Delete previous backups over 30 days old
#
# Get the current date
current_date=$(date +%Y-%m-%d)

# Find all tar.gz.enc files starting with "bw_export_" in the backups folder
source_export_files=$(find backups -type f -name "bw_export_*.tar.gz.enc")

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
bw --session $BW_SESSION_SOURCE --raw export --format json > $SOURCE_OUTPUT_JSON

# Add file to encrypted tar
file_to_compress="$SOURCE_OUTPUT_JSON"

tar -czf - "$file_to_compress" | \
  openssl enc -aes-256-cbc -pass pass:"$BW_TAR_PASS" -out "backups/$SOURCE_EXPORT_OUTPUT_BASE$TIMESTAMP.tar.gz.enc"

rm -f $SOURCE_OUTPUT_JSON

### End of Backup

### Start of Restore

# We want to remove itms later, so we set a base filename now
DEST_EXPORT_OUTPUT_BASE="bw_vault_items_to_remove"
TIMESTAMP=$(date "+%Y%m%d%H%M%S")

# Combine the items to remove file with timestamp, and use that as the filename
DEST_OUTPUT_FILE=$EXPORT_OUTPUT_BASE$TIMESTAMP.json

# Lets make sure we're logged out before we get to work
bw logout

# Login to the server using our API key, and unlock the vault to get a session ID
bw config server $BW_SERVER_DEST
bw login $BW_ACCOUNT_DEST --apikey --raw
BW_SESSION_DEST=$(bw unlock $BW_PASS_DEST --raw)

# Export what's currenty in the vault, so we can remove it
bw --session $BW_SESSION_DEST --raw export --format json > $DEST_OUTPUT_FILE

# Find and remove all folders, items, attachments and org collections
for id in $(jq '.folders[]? | .id' $DEST_OUTPUT_FILE); do
  # Remove quotes from the ID
  id=$(sed 's/"//g' <<< "$id")
  # Run your command here, replacing "$id" with the actual ID
  bw --session $BW_SESSION_DEST --raw delete -p folder $id
done

# Find and remove all items
for id in $(jq '.items[]? | .id' $DEST_OUTPUT_FILE); do
  # Remove quotes from the ID
  id=$(sed 's/"//g' <<< "$id")
  # Run your command here, replacing "$id" with the actual ID
  bw --session $BW_SESSION_DEST --raw delete -p item $id
done

# Find and remove all attachments
for id in $(jq '.attachments[]? | .id' $DEST_OUTPUT_FILE); do
  # Remove quotes from the ID
  id=$(sed 's/"//g' <<< "$id")
  # Run your command here, replacing "$id" with the actual ID
  bw --session $BW_SESSION_DEST --raw delete -p attachment $id
done

# Find the latest backup file
DEST_LATEST_BACKUP_TAR=$(find backups/bw_export_*.tar.gz.enc -type f -exec ls -t1 {} + | head -1)

# Set your encrypted file and password
encrypted_source_tar="$DEST_LATEST_BACKUP_TAR"
source_tar_password="$BW_TAR_PASS"

# Decrypt the file and extract it
openssl enc -d -aes-256-cbc -pass pass:"$source_tar_password" -in "$encrypted_source_tar" | \
  tar -xzf -

echo "Decompression completed successfully."

# Find the latest backup file
DEST_LATEST_BACKUP_JSON=$(find backups/bw_export_*.json -type f -exec ls -t1 {} + | head -1)

# import the latest backup
bw --session $BW_SESSION_DEST --raw import bitwardenjson $DEST_LATEST_BACKUP_JSON

# Clean up our item list to delete
rm $DEST_OUTPUT_FILE

rm -f $DEST_LATEST_BACKUP_JSON

### End of Restore

bw logout > /dev/null

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