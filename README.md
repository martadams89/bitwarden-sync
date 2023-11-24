# Bitwarden Backup and Restore Script

🔐 backup and restore your Bitwarden vault between servers.

## Pre-Task: Set Up Passwords and Keyfiles

### Bitwarden CLI must be already installed

### [You will need your API Keys](https://bitwarden.com/help/personal-api-key/)

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

## Backup Script

### Instructions
1. Open `1-bitwarden_backup.sh` and set your Bitwarden server details and API information in the environment variables at the top of the script.

```bash
export BW_ACCOUNT=xxxxx@yyy.com
export BW_BACKUP_PASS=password=$(openssl enc -d -aes-256-cbc -in bitwarden_backup_password.enc -pass file:bitwarden_backup_keyfile)
export BW_CLIENTID=xxxx
export BW_CLIENTSECRET=xxxx
export BW_SERVER=https://vaultwarden.mydomain.com
```

2. Make the script executable
```
chmod +x 1-bitwarden_backup.sh
```

3. Run the backup script.
```
./1-bitwarden_backup.sh
```

4. The backup will be stored in the `backups` folder with a timestamped filename.


## Restore Script

#### NOTE: Restoring will take awhile as it purges the vault

### Instructions

1. Open `2-bitwarden_restore.sh` and set your Bitwarden server details and API information in the environment variables at the top of the script.

```bash
export BW_ACCOUNT=XXXX@yyy.com
export BW_RESTORE_PASS=restorepassword=$(openssl enc -d -aes-256-cbc -in bitwarden_restore_password.enc -pass file:bitwarden_restore_keyfile)
export BW_CLIENTID=XXXXX
export BW_CLIENTSECRET=XXXX
export BW_SERVER=https://vault.bitwarden.com
```

2. Make the script executable
```
chmod +x 2-bitwarden_restore.sh
```

3. Run the restore script.
```bash
./2-bitwarden_restore.sh
```
The restore script will remove existing items and restore from the latest backup in the backups folder.

## Cron Job Setup

Add the following cron job entries to run the scripts every 6 hours with a 10-minute interval:


```bash
# Run backup every 6 hours with a 10-minute interval
0 */6 * * * /path/to/1-bitwarden_backup.sh > /dev/null

# Run restore every 6 hours with a 10-minute interval, starting 10 minutes after the first script
10 */6 * * * /path/to/2-bitwarden_restore.sh > /dev/null
```

🚀 Your Bitwarden Backup and Restore setup is now complete!