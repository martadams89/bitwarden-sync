#!/usr/bin/env bash

# We need to set some variables
# Set your account name, Vault master password and API Info
# Set the BitWarden Server we want to use

export LC_CTYPE=C
export LC_ALL=C
export BW_ACCOUNT=xxxxx@yyy.com
export BW_BACKUP_PASS=$(openssl enc -d -aes-256-cbc -in bitwarden_backup_password.enc -pass file:bitwarden_backup_keyfile)
export BW_CLIENTID=xxxx
export BW_CLIENTSECRET=xxxx
export BW_SERVER=https://vaultwarden.mydomain.com
export BW_TAR_PASS=$(openssl enc -d -aes-256-cbc -in bitwarden_backup_password.enc -pass file:bitwarden_backup_keyfile)

mkdir -p backups

# Set the filename for our json export as variable
EXPORT_OUTPUT_BASE="bw_export_"
TIMESTAMP=$(date "+%Y%m%d%H%M%S")
ENC_OUTPUT_FILE=backups/$EXPORT_OUTPUT_BASE$TIMESTAMP.json

# Delete previous backups over 30 days old

# Get the current date
current_date=$(date +%Y-%m-%d)

# Find all tar.gz.enc files starting with "bw_export_" in the backups folder
backup_files=$(find backups -type f -name "bw_export_*.tar.gz.enc")

# Delete any files older than 30 days
find $backup_files -type f -mtime +30 -exec rm -f {} +

# Lets make sure we're logged out before we get to work
bw logout

# Login to our Server
bw config server $BW_SERVER
bw login $BW_ACCOUNT --apikey --raw

# Because we're using an API Key, we need to unlock the vault to get a session ID
BW_SESSION=$(bw unlock $BW_BACKUP_PASS --raw)

# Export out all items
bw --session $BW_SESSION --raw export --format json > $ENC_OUTPUT_FILE

# Add file to encrypted tar
file_to_compress="$ENC_OUTPUT_FILE"

tar -czf - "$file_to_compress" | \
  openssl enc -aes-256-cbc -pass pass:"$BW_TAR_PASS" -out "backups/$EXPORT_OUTPUT_BASE$TIMESTAMP.tar.gz.enc"

rm -f $ENC_OUTPUT_FILE

bw logout > /dev/null
unset BW_SESSION
unset BW_BACKUP_PASS
unset BW_ACCOUNT
unset BW_CLIENTID
unset BW_SECRET
unset BW_SERVER
unset BW_TAR_PASS