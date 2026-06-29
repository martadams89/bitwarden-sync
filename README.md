# 🔐 Bitwarden / Vaultwarden Sync

[![Build](https://github.com/martadams89/bitwarden-sync/actions/workflows/bitwarden_sync_docker.yml/badge.svg)](https://github.com/martadams89/bitwarden-sync/actions/workflows/bitwarden_sync_docker.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/martadams89/bitwarden-sync)](https://hub.docker.com/r/martadams89/bitwarden-sync)
[![Image Size](https://img.shields.io/docker/image-size/martadams89/bitwarden-sync/latest)](https://hub.docker.com/r/martadams89/bitwarden-sync)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Automatically back up one Bitwarden/Vaultwarden vault and mirror it into another —
for example, a nightly copy of your self-hosted **Vaultwarden** into **Bitwarden
Cloud** (or vice-versa). Runs as a scheduled Docker container or a standalone
shell script.

Each run exports the **source** vault to a timestamped, encrypted archive, then
replaces the contents of the **destination** vault with that backup.

## Features

- 🗓️ **Scheduled sync** via cron (Docker) or your own crontab (standalone).
- 🔒 **Encrypted local backups** — every export is stored as an AES-256 (OpenSSL) `.tar.gz.enc` archive, kept for 30 days.
- 🔑 **Flexible secrets** — plaintext env vars, Docker secrets / plain files, or OpenSSL-encrypted files.
- ⚡ **Fast restore** — clears the destination via the Bitwarden **REST API** in bulk (batches of 500) instead of slow per-item CLI calls.
- 🛡️ **Resilient source login** — retries with backoff, surfaces the real CLI error, and **auto-falls-back across known-good CLI versions** when a release breaks Vaultwarden (see [#50](https://github.com/martadams89/bitwarden-sync/issues/50)).
- 🧱 **Multi-arch image** — `linux/amd64` and `linux/arm64`.
- 📟 **Healthchecks.io** ping support.

> [!NOTE]
> This tool syncs a **single user's** personal vault. It does **not** currently
> sync Organisations or multiple users.

## Table of Contents

- [How It Works](#how-it-works)
- [Requirements](#requirements)
- [Quick Start (Docker)](#quick-start-docker)
- [Docker Configuration](#docker-configuration)
  - [Passwords & secrets](#passwords--secrets)
  - [Persisting CLI state](#persisting-cli-state)
  - [Bitwarden CLI versions](#bitwarden-cli-versions)
  - [Source login resilience](#source-login-resilience)
- [Standalone Script](#standalone-script)
- [Server Endpoints](#server-endpoints)
- [Configuration Reference](#configuration-reference)
- [Testing with a Subset](#testing-with-a-subset)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## How It Works

**Backup (source → encrypted archive)**

1. Log in to the source server with an [API key](https://bitwarden.com/help/personal-api-key/) and unlock the vault.
2. Export every item to JSON (`bw export`).
3. Compress and encrypt it to `backups/bw_export_<timestamp>.tar.gz.enc` (AES-256, OpenSSL).
4. Prune archives older than 30 days.

**Restore (archive → destination)**

1. Authenticate to the destination identity server and obtain a REST access token.
2. Fetch existing cipher/folder IDs via `/sync`.
3. Bulk soft-delete existing ciphers in batches of 500 via `DELETE /ciphers` (Bitwarden auto-purges trash after 30 days), and delete folders via `DELETE /folders/{id}`.
4. Import the decrypted backup with `bw import bitwardenjson` in a single call.

REST requests use bounded timeouts and retries, responses are validated before
anything is deleted, and cipher deletion falls back to individual requests if
the destination has no bulk endpoint.

> The import uses a PTY (`script`, or `expect` on macOS) to satisfy the single
> master-password prompt that **Bitwarden CLI 2026.x** introduced for vault data
> operations.

## Requirements

- A **source** and **destination** Bitwarden/Vaultwarden account, each with a
  personal **API key** (`client_id` + `client_secret`) and its master password.
- **Docker** (recommended), or for the standalone script: `bash`, `openssl`,
  `curl`, `jq`, `tar`, `uuidgen` (util-linux), Node.js/npm, and either
  util-linux `script` **or** `expect`.

## Quick Start (Docker)

1. Grab [docker/docker-compose.yml](docker/docker-compose.yml) and edit the
   source/destination accounts, API keys, servers, and passwords.
2. Start it:

   ```bash
   docker compose up -d
   ```

3. (Optional) Validate against a subset first with
   [`BW_IMPORT_LIMIT`](#testing-with-a-subset) before a full sync.

A minimal configuration:

```yaml
services:
  bitwarden-sync:
    image: martadams89/bitwarden-sync:latest
    container_name: bitwarden-sync
    restart: always
    environment:
      - CRON_SCHEDULE=0 0 * * *
      # Source (e.g. self-hosted Vaultwarden)
      - BW_SERVER_SOURCE=https://vault.example.com
      - BW_CLIENTID_SOURCE=user.xxxxxxxx
      - BW_CLIENTSECRET_SOURCE=xxxxxxxx
      - BW_PASS_SOURCE=source-master-password
      # Destination (e.g. Bitwarden Cloud)
      - BW_SERVER_DEST=https://vault.bitwarden.com
      - BW_CLIENTID_DEST=user.yyyyyyyy
      - BW_CLIENTSECRET_DEST=yyyyyyyy
      - BW_PASS_DEST=dest-master-password
      # Password for the encrypted local backup archives
      - BW_TAR_PASS=backup-archive-password
    volumes:
      - ./config/backups:/app/backups
      - ./config/bitwarden-cli:/app/data/bitwarden-cli
```

See [docker/docker-compose.yml](docker/docker-compose.yml) for the fully
commented template, and the [Configuration Reference](#configuration-reference)
for every variable.

## Docker Configuration

### Passwords & secrets

Configure each password (`BW_PASS_SOURCE`, `BW_PASS_DEST`, `BW_TAR_PASS`) with
**one** of the methods below. Priority: encrypted file → plain file → plaintext
variable.

<details>
<summary><b>Option A — Plaintext environment variable</b> (simplest)</summary>

```yaml
environment:
  - BW_PASS_SOURCE=mypassword
  - BW_PASS_DEST=mypassword
  - BW_TAR_PASS=mytarpassword
```

</details>

<details>
<summary><b>Option B — Docker secret / plain-text file</b></summary>

Mount a file containing only the password and point to it with a `_FILE` variable:

```bash
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

</details>

<details>
<summary><b>Option C — OpenSSL-encrypted files</b> (matches the standalone script)</summary>

Generate an encrypted file and a keyfile for each password:

```bash
openssl rand -base64 32 > /secrets/bw_source.key
chmod 400 /secrets/bw_source.key
echo 'mypassword' | openssl enc -aes-256-cbc -salt \
  -out /secrets/bw_source_pass.enc -pass file:/secrets/bw_source.key
```

Then point to both files with `_ENC_FILE` and `_KEYFILE` variables:

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

</details>

### Persisting CLI state

Bitwarden Cloud sends a _"new client logged in"_ email whenever it sees a fresh
device. Persist the CLI app-data directory (which also stores the REST device
identifier) so the same device identity is reused across runs:

```yaml
environment:
  - BITWARDENCLI_APPDATA_DIR=/app/data/bitwarden-cli
volumes:
  - ./config/bitwarden-cli:/app/data/bitwarden-cli
```

The first run creates the identifier; later runs reuse it. You can instead pin a
fixed identity:

```yaml
environment:
  - BW_DEVICE_IDENTIFIER=bitwarden-sync-production
  - BW_DEVICE_NAME=bitwarden-sync
```

> Keep `BW_DEVICE_IDENTIFIER` stable. Changing it, deleting the persisted
> `device-identifier` file, or removing the volume makes Bitwarden see a new
> client again.

### Bitwarden CLI versions

The image installs **two** Bitwarden CLI versions side by side, because the
source and destination have different compatibility needs:

| Wrapper  | Used for                          | Default     | Build arg            |
| -------- | --------------------------------- | ----------- | -------------------- |
| `bw-old` | Source (Vaultwarden) login/export | `2025.12.0` | `BW_CLI_OLD_VERSION` |
| `bw-new` | Destination (Bitwarden cloud)     | `latest`    | `BW_CLI_NEW_VERSION` |

The source is pinned to a known-good version because newer CLIs have repeatedly
broken against self-hosted Vaultwarden — most recently with
`FetchError: ... /identity/connect/token: Premature close` ([#50](https://github.com/martadams89/bitwarden-sync/issues/50)).
`2025.12.0` is the current confirmed-working version. Pinning also makes builds
reproducible.

**Override at runtime** (recommended — works on the published image, no rebuild).
The entrypoint reinstalls a CLI only when a _concrete_ version differs from the
baked-in default, so default startups do no extra work:

```yaml
environment:
  - BW_CLI_OLD_VERSION=2025.12.0 # source / Vaultwarden
  - BW_CLI_NEW_VERSION=latest # destination / Bitwarden cloud
```

`latest` (or unset) keeps the baked-in build; pinning a concrete version triggers
a one-time reinstall at container start (needs network access).

**Override at build time** (bakes into a locally built image):

```bash
docker build -f docker/Dockerfile \
  --build-arg BW_CLI_OLD_VERSION=2025.12.0 \
  --build-arg BW_CLI_NEW_VERSION=latest \
  -t bitwarden-sync .
```

### Source login resilience

The source login (`config` → `login` → `unlock`) is retried with exponential
backoff, and the actual CLI error is logged instead of being swallowed:

```yaml
environment:
  - BW_LOGIN_RETRIES=3 # attempts per CLI version (default 3)
  - BW_LOGIN_RETRY_DELAY=5 # initial delay (s), doubles each retry (default 5)
```

**Automatic CLI version fallback.** No server advertises which CLI version it
supports — `Premature close` is a transport-level bug in a given CLI build's
bundled Node, so compatibility is empirical. If the source login keeps failing
with a _transport_ error, the container reinstalls the next known-good version
and retries. The installed version is tried first, then each entry in
`BW_CLI_OLD_FALLBACK_VERSIONS`:

```yaml
environment:
  - BW_CLI_OLD_FALLBACK_VERSIONS=2025.12.0 2024.9.0 # default; space/comma separated
```

A wrong master password or an auth/API-key error stops immediately — cycling
versions cannot fix those. This fallback is **Docker-only** (it relies on the
image's npm-managed CLI).

### Manual runs & monitoring

**Force a run now** (no need to wait for cron):

```bash
docker compose exec bitwarden-sync /app/script.sh
# or: docker exec -it bitwarden-sync /app/script.sh
```

A `flock` guard ensures a manual run can't overlap a scheduled one (two
concurrent runs both clearing+importing the destination would be bad). Set
`RUN_ON_START=true` to run one sync automatically at container start.

**Run status.** Every run writes a summary line to the logs and a machine-readable
`last-run.json` into the CLI state directory
(`<BITWARDENCLI_APPDATA_DIR>/last-run.json`), e.g.:

```json
{
  "status": "success",
  "stage": "done",
  "duration_seconds": 42,
  "exit_code": 0,
  "backup": { "items": 312, "folders": 9 },
  "cli": { "source": "2025.12.0", "destination": "2026.6.0" }
}
```

On failure, `status` is `error` and `stage` shows where it stopped (e.g.
`source_login`, `import`) — handy for debugging.

**Logs & alerting.** The container logs everything to stdout, so `docker logs`
(or [Dozzle](https://dozzle.dev) / Loki) gives you live logs and history.
Configure `HEALTHCHECK_URL` / `HEALTHCHECK_PING` ([Healthchecks.io](https://healthchecks.io)
or self-hosted) for run history and alerting — the container pings `start` on
launch, the success URL when done, and `/fail` if a run errors out.

## Standalone Script

Prefer the [standalone script](bitwarden_sync.sh) over Docker? It behaves the
same but runs directly on a host.

### 1. Install the CLI wrappers

The script invokes `bw-old` (source) and `bw-new` (destination) rather than `bw`
directly, so you can pin different versions for each side. Create the wrappers
once:

<details open>
<summary><b>Simplest — one version for both</b></summary>

```bash
npm install -g @bitwarden/cli@2025.12.0
sudo ln -sf "$(command -v bw)" /usr/local/bin/bw-old
sudo ln -sf "$(command -v bw)" /usr/local/bin/bw-new
```

</details>

<details>
<summary><b>Advanced — pin the source and destination separately</b></summary>

```bash
# Destination CLI: latest -> bw-new
npm install -g @bitwarden/cli
sudo ln -sf "$(command -v bw)" /usr/local/bin/bw-new

# Source CLI: pinned, isolated under /opt/bw-old -> bw-old
npm install -g --prefix /opt/bw-old @bitwarden/cli@2025.12.0
sudo tee /usr/local/bin/bw-old >/dev/null <<'EOF'
#!/bin/sh
exec /opt/bw-old/bin/bw "$@"
EOF
sudo chmod +x /usr/local/bin/bw-old
```

</details>

### 2. Set up passwords and keyfiles

The standalone script reads its passwords from OpenSSL-encrypted files. Create
them next to the script:

```bash
# Backup (source) password + keyfile
echo 'Password from Backup Source' > bitwarden_backup_password
chmod 400 bitwarden_backup_password
openssl rand -base64 32 > bitwarden_backup_keyfile
chmod 400 bitwarden_backup_keyfile
openssl enc -aes-256-cbc -salt -in bitwarden_backup_password \
  -out bitwarden_backup_password.enc -pass file:bitwarden_backup_keyfile
rm -f bitwarden_backup_password

# Restore (destination) password + keyfile
echo 'Password from Backup Destination' > bitwarden_restore_password
chmod 400 bitwarden_restore_password
openssl rand -base64 32 > bitwarden_restore_keyfile
chmod 400 bitwarden_restore_keyfile
openssl enc -aes-256-cbc -salt -in bitwarden_restore_password \
  -out bitwarden_restore_password.enc -pass file:bitwarden_restore_keyfile
rm -f bitwarden_restore_password
```

### 3. Configure the script

Edit the environment variables near the top of [bitwarden_sync.sh](bitwarden_sync.sh):

```bash
export BW_TAR_PASS=$(openssl enc -d -aes-256-cbc -in bitwarden_backup_password.enc -pass file:bitwarden_backup_keyfile)

# Source
export BW_PASS_SOURCE=$(openssl enc -d -aes-256-cbc -in bitwarden_backup_password.enc -pass file:bitwarden_backup_keyfile)
export BW_CLIENTID_SOURCE=user.xxxxxxxx
export BW_CLIENTSECRET_SOURCE=xxxxxxxx
export BW_SERVER_SOURCE=https://vault.example.com

# Destination
export BW_PASS_DEST=$(openssl enc -d -aes-256-cbc -in bitwarden_restore_password.enc -pass file:bitwarden_restore_keyfile)
export BW_CLIENTID_DEST=user.yyyyyyyy
export BW_CLIENTSECRET_DEST=yyyyyyyy
export BW_SERVER_DEST=https://vault.bitwarden.com
```

The script stores its REST device identity in `.bitwarden-sync/device-identifier`
beside the script — keep it to avoid repeated "new client" emails. Override the
state directory with `BITWARDEN_SYNC_STATE_DIR`, the backups directory with
`BW_BACKUP_DIR`, or pin a fixed `BW_DEVICE_IDENTIFIER`.

### 4. Run it

```bash
chmod +x bitwarden_sync.sh
./bitwarden_sync.sh
```

Backups land in the `backups/` folder as timestamped encrypted archives. To run
on a schedule, add a crontab entry (every 6 hours shown):

```bash
0 */6 * * * /path/to/bitwarden_sync.sh > /dev/null 2>&1
```

## Server Endpoints

Normally you set only `BW_SERVER_SOURCE` / `BW_SERVER_DEST`; the scripts derive
the identity and API endpoints from them:

| Destination                    | `BW_SERVER_*` example         | API endpoint                    | Identity/token endpoint              |
| ------------------------------ | ----------------------------- | ------------------------------- | ------------------------------------ |
| Vaultwarden                    | `https://vault.example.com`   | `https://vault.example.com/api` | `https://vault.example.com/identity` |
| Self-hosted official Bitwarden | `https://vault.example.com`   | `https://vault.example.com/api` | `https://vault.example.com/identity` |
| Bitwarden Cloud US             | `https://vault.bitwarden.com` | `https://api.bitwarden.com`     | `https://identity.bitwarden.com`     |
| Bitwarden Cloud EU             | `https://vault.bitwarden.eu`  | `https://api.bitwarden.eu`      | `https://identity.bitwarden.eu`      |

Only override the derived destination URLs for a non-standard reverse proxy that
exposes these services at different paths:

```yaml
environment:
  - BW_API_URL_DEST=https://vault.example.com/api
  - BW_IDENTITY_URL_DEST=https://vault.example.com/identity
```

## Configuration Reference

| Variable                                                        | Scope      | Default                   | Description                                                                    |
| --------------------------------------------------------------- | ---------- | ------------------------- | ------------------------------------------------------------------------------ |
| `BW_SERVER_SOURCE` / `BW_SERVER_DEST`                           | both       | —                         | Source / destination base URLs                                                 |
| `BW_CLIENTID_SOURCE` / `BW_CLIENTSECRET_SOURCE`                 | both       | —                         | Source API key                                                                 |
| `BW_CLIENTID_DEST` / `BW_CLIENTSECRET_DEST`                     | both       | —                         | Destination API key                                                            |
| `BW_PASS_SOURCE` / `BW_PASS_DEST`                               | both       | —                         | Master passwords (also `_FILE`, `_ENC_FILE`/`_KEYFILE`)                        |
| `BW_TAR_PASS`                                                   | both       | —                         | Encryption password for backup archives (also `_FILE`, `_ENC_FILE`/`_KEYFILE`) |
| `BW_API_URL_DEST` / `BW_IDENTITY_URL_DEST`                      | both       | derived                   | Override destination endpoints (non-standard proxies only)                     |
| `CRON_SCHEDULE`                                                 | Docker     | `57 23 * * *`             | Cron expression for the scheduled run                                          |
| `RUN_ON_START`                                                  | Docker     | unset                     | Run one sync at container start, then continue on cron                         |
| `BITWARDENCLI_APPDATA_DIR`                                      | Docker     | `/app/data/bitwarden-cli` | CLI state directory (persist via volume)                                       |
| `BW_STATUS_FILE`                                                | Docker     | `<appdata>/last-run.json` | Where the per-run status JSON is written                                       |
| `BW_LOCK_FILE`                                                  | Docker     | `<appdata>/…sync.lock`    | flock file preventing overlapping runs                                         |
| `BITWARDEN_SYNC_STATE_DIR`                                      | standalone | `./.bitwarden-sync`       | State directory beside the script                                              |
| `BW_BACKUP_DIR`                                                 | standalone | `./backups`               | Where encrypted archives are written                                           |
| `BW_DEVICE_IDENTIFIER` / `BW_DEVICE_NAME`                       | both       | generated                 | Fixed REST device identity                                                     |
| `BW_CLI_OLD_VERSION` / `BW_CLI_NEW_VERSION`                     | Docker     | `2025.12.0` / `latest`    | Source / destination CLI version (build arg + runtime)                         |
| `BW_CLI_OLD_FALLBACK_VERSIONS`                                  | Docker     | `2025.12.0 2024.9.0`      | Source CLI versions tried on transport failure                                 |
| `BW_LOGIN_RETRIES` / `BW_LOGIN_RETRY_DELAY`                     | both       | `3` / `5`                 | Source login retry count / initial backoff (s)                                 |
| `BW_API_CONNECT_TIMEOUT` / `BW_API_MAX_TIME` / `BW_API_RETRIES` | both       | `10` / `60` / `3`         | REST `curl` connect timeout / max time / retries                               |
| `BW_IMPORT_LIMIT`                                               | both       | unset                     | Import only N items per type (testing)                                         |
| `HEALTHCHECK_URL` / `HEALTHCHECK_PING`                          | both       | unset                     | [Healthchecks.io](https://healthchecks.io) pings (Docker also pings `/fail`)   |

## Testing with a Subset

Set `BW_IMPORT_LIMIT=N` to import only N items per type (login, secure note,
card, identity) instead of the full vault — useful for validating a setup before
a full sync:

```yaml
environment:
  - BW_IMPORT_LIMIT=1
```

Remove it (or leave it unset) for a full sync.

## Troubleshooting

- **`FetchError: ... Premature close` on source login.** A CLI/Vaultwarden
  transport incompatibility. The container retries and auto-falls-back across
  `BW_CLI_OLD_FALLBACK_VERSIONS`; if it still fails, pin a known-good version
  with `BW_CLI_OLD_VERSION` (see [Bitwarden CLI versions](#bitwarden-cli-versions)).
- **`bw-old: command not found` (standalone).** Create the CLI wrappers — see
  [Install the CLI wrappers](#1-install-the-cli-wrappers).
- **"New client logged in" emails.** Persist the CLI state directory or set a
  fixed `BW_DEVICE_IDENTIFIER` — see [Persisting CLI state](#persisting-cli-state).
- **`Logged in but failed to unlock`.** The master password (`BW_PASS_SOURCE` /
  `BW_PASS_DEST`) is wrong for that server.

## License

[MIT](LICENSE) © martadams89
