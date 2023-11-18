#!/usr/bin/env bash

# We need to set some variables
# Set your account name, Vault master password and API Info
# Set the BitWarden Server we want to use

export LC_CTYPE=C
export LC_ALL=C
export BW_RESTORE_PASS=$(openssl enc -d -aes-256-cbc -in bitwarden_restore_password.enc -pass file:bitwarden_restore_keyfile)
export BW_CLIENTID=XXXXX
export BW_CLIENTSECRET=XXXX
export BW_SERVER=https://vault.bitwarden.com

# We want to remove itms later, so we set a base filename now
EXPORT_OUTPUT_BASE="bw_vault_items_to_remove"
TIMESTAMP=$(date "+%Y%m%d%H%M%S")

# Combine the items to remove file with timestamp, and use that as the filename
ENC_OUTPUT_FILE=$EXPORT_OUTPUT_BASE$TIMESTAMP.json

# Lets make sure we're logged out before we get to work
bw logout

# Login to the server using our API key, and unlock the vault to get a session ID
bw config server $BW_SERVER
bw login $BW_ACCOUNT --apikey --raw
BW_SESSION=$(bw unlock $BW_RESTORE_PASS --raw)

# Export what's currenty in the vault, so we can remove it
bw --session $BW_SESSION --raw export --format json > $ENC_OUTPUT_FILE

# Find and remove all folders, items, attachments and org collections
for id in $(jq '.folders[]? | .id' $ENC_OUTPUT_FILE); do
  # Remove quotes from the ID
  id=$(sed 's/"//g' <<< "$id")
  # Run your command here, replacing "$id" with the actual ID
  (bw --session $BW_SESSION --raw delete -p folder $id &)
done
wait

# Find and remove all items
for id in $(jq '.items[]? | .id' $ENC_OUTPUT_FILE); do
  # Remove quotes from the ID
  id=$(sed 's/"//g' <<< "$id")
  # Run your command here, replacing "$id" with the actual ID
  (bw --session $BW_SESSION --raw delete -p item $id &)
done
wait

# Find and remove all attachments
for id in $(jq '.attachments[]? | .id' $ENC_OUTPUT_FILE); do
  # Remove quotes from the ID
  id=$(sed 's/"//g' <<< "$id")
  # Run your command here, replacing "$id" with the actual ID
  (bw --session $BW_SESSION --raw delete -p attachment $id &)
done
wait

# Find the latest backup file
LATEST_BACKUP=$(find backups/bw_export_*.json -type f -exec ls -t1 {} + | head -1)

# import the latest backup
bw --session $BW_SESSION --raw import bitwardenjson $LATEST_BACKUP

# Clean up our item list to delete
rm $ENC_OUTPUT_FILE

# Logout and unset variables
bw logout > /dev/null
unset BW_SESSION
unset BW_RESTORE_PASS
unset BW_ACCOUNT
unset BW_CLIENTID
unset BW_SECRET
unset BW_SERVER