# Bitwarden/Vaultwarden Sync

🔐 backup and restore your Bitwarden vault between servers.

### [You will need your API Keys](https://bitwarden.com/help/personal-api-key/)

### NOTE: This does not currently sync Orgnisations or multiple users.

## Using Docker? See [docker-compose.yml](https://github.com/martadams89/bitwarden-sync/blob/main/docker/docker-compose.yml)

## Pre-Task: Set Up Passwords and Keyfiles

### Bitwarden CLI must be already installed

Before running the backup and restore scripts, you need to set up your passwords and keyfiles securely.

```bash
# Backup Password
echo 'Password from Backup Source' > bitwarden_backup_password
chmod 400 bitwarden_backup_password

# Backup Keyfile
openssl rand -base64 32 > bitwarden_backup_keyfile
chmod 400 bitwarden_backup_keyfile

# Encrypt the Backup password file using the keyfile
openssl enc -aes-256-cbc -salt -in bitwarden_backup_password -out bitwarden_backup_password.enc -pass file:bitwarden_backup_keyfile

# Delete the plain-text Backup password
rm -f bitwarden_backup_password

# Restore Password
echo 'Password from Backup Destination' > bitwarden_restore_password
chmod 400 bitwarden_restore_password

# Restore Keyfile
openssl rand -base64 32 > bitwarden_restore_keyfile
chmod 400 bitwarden_restore_keyfile

# Encrypt the password file using the keyfile
openssl enc -aes-256-cbc -salt -in bitwarden_restore_password -out bitwarden_restore_password.enc -pass file:bitwarden_restore_keyfile

# Delete the plain-text Restore password
rm -f bitwarden_restore_password
```

## Backup and Restore Script

### Instructions
1. Open `bitwarden_sync.sh` and set your Bitwarden server details and API information in the environment variables at the top of the script.

```bash
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
```

2. Make the script executable
```
chmod +x bitwarden_backup_and_restore.sh
```

3. Run the script.
```
./bitwarden_sync.sh
```

#### NOTE: Restoring will take awhile as it purges the vault

### The backup will be stored as a tar in the `backups` folder with a timestamped filename.

## Cron Job Setup

Add the following cron job entry to run the script every 6 interval:

```bash
# Run backup every 6 hours with a 10-minute interval
0 */6 * * * /path/to/bitwarden_backup_and_restore.sh > /dev/null 2&>1
```

🚀 Your Bitwarden Backup and Restore setup is now complete!
