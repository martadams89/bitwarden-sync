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
mkdir -p backups

# Set the filename for our json export as variable
SOURCE_EXPORT_OUTPUT_BASE="bw_export_"
TIMESTAMP=$(date "+%Y%m%d%H%M%S")
SOURCE_OUTPUT_FILE_JSON=backups/$SOURCE_EXPORT_OUTPUT_BASE$TIMESTAMP.json

# Delete previous backups over 30 days old
echo "# Deleting previous backups older than 30 days... #"
current_date=$(date +%Y-%m-%d)
source_export_files=$(find backups -type f -name "bw_export_*.tar.gz.enc")
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


echo "# End of Restore Process #"
echo "### Restore - End ###"

bw logout > /dev/null

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