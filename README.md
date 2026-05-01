# Bitwarden/Vaultwarden Sync

🔐 backup and restore your Bitwarden vault between servers.

### [You will need your API Keys](https://bitwarden.com/help/personal-api-key/)

### NOTE: This does not currently sync Orgnisations or multiple users.

## Using Docker? See [docker-compose.yml](https://github.com/martadams89/bitwarden-sync/blob/main/docker/docker-compose.yml)

### Docker – Encrypted Passwords

Storing passwords as plaintext environment variables is convenient but not ideal.
The Docker image supports the same encrypted-file approach used by the standalone
script, as well as Docker secrets. Configure each password variable using **one**
of the three methods below (in decreasing order of security):

#### Option A – Plaintext environment variable (default)

```yaml
environment:
  - BW_PASS_SOURCE=mypassword
  - BW_PASS_DEST=mypassword
  - BW_TAR_PASS=mytarpassword
```

#### Option B – Docker secret / plain-text file

Mount a file that contains only the password (e.g. via Docker secrets or a bind
mount) and point to it with a `_FILE` variable:

```bash
# Create a secret file
echo 'mypassword' > /run/secrets/bw_pass_source
```

```yaml
environment:
  - BW_PASS_SOURCE_FILE=/run/secrets/bw_pass_source
  - BW_PASS_DEST_FILE=/run/secrets/bw_pass_dest
  - BW_TAR_PASS_FILE=/run/secrets/bw_tar_pass
volumes:
  - /run/secrets:/run/secrets:ro
```

#### Option C – OpenSSL-encrypted files (matches the standalone script)

Generate an encrypted file and a keyfile for each password:

```bash
# Generate a keyfile
openssl rand -base64 32 > /secrets/bw_source.key
chmod 400 /secrets/bw_source.key

# Encrypt the password
echo 'mypassword' | openssl enc -aes-256-cbc -salt \
  -out /secrets/bw_source_pass.enc -pass file:/secrets/bw_source.key
```

Then point the container to both files with `_ENC_FILE` and `_KEYFILE` variables:

```yaml
environment:
  - BW_PASS_SOURCE_ENC_FILE=/secrets/bw_source_pass.enc
  - BW_PASS_SOURCE_KEYFILE=/secrets/bw_source.key
  - BW_PASS_DEST_ENC_FILE=/secrets/bw_dest_pass.enc
  - BW_PASS_DEST_KEYFILE=/secrets/bw_dest.key
  - BW_TAR_PASS_ENC_FILE=/secrets/bw_tar_pass.enc
  - BW_TAR_PASS_KEYFILE=/secrets/bw_tar.key
volumes:
  - /secrets:/secrets:ro
```

> **Priority:** if both `_ENC_FILE`/`_KEYFILE` and `_FILE` are set for the same
> variable, the encrypted-file method takes precedence.  If neither is set, the
> plaintext variable is used (backward-compatible).

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
