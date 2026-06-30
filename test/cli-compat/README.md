# CLI compatibility test

Gates Renovate's auto-merge of `@bitwarden/cli` **and** `vaultwarden/server`
bumps. On any PR that touches `docker/**` or `test/cli-compat/**` (Renovate's
bumps do), it runs entirely on the GitHub runner:

1. Starts a throwaway **Vaultwarden** (pinned, Renovate-managed image in
   [`docker-compose.yml`](docker-compose.yml)) from the committed seed volume.
2. Builds the image from the PR.
3. Runs one real sync: **source = the in-CI Vaultwarden**, **dest = Bitwarden
   Cloud** (throwaway account, via secrets).
4. Asserts `status=success`.

A green run means the candidate CLI **and** Vaultwarden versions still handle
both historical break points: source login/export (#50) and cloud import.

> ⚠️ The **destination** (cloud) account is **wiped and replaced** every run.
> Use a throwaway account with no real data. Both accounts must be throwaway.

## One-time setup

### 1. Seed the source Vaultwarden volume

Run Vaultwarden locally **with the same image tag pinned in `docker-compose.yml`**
(`vaultwarden/server:1.36.0`), create one throwaway **source** account with a
few sample items, and grab its API key — then commit the data dir.

```bash
cd test/cli-compat
docker run -d --name vw-seed -p 8000:80 \
  -e SIGNUPS_ALLOWED=true \
  -v "$PWD/vaultwarden-data:/data" \
  vaultwarden/server:1.36.0
# open http://localhost:8000 → sign up → add a few items
# → Settings → Security → Keys → View API Key → note client_id + client_secret
docker rm -f vw-seed            # clean shutdown checkpoints the SQLite WAL

# keep only the seed DB (+ JWT key); drop the WAL/SHM churn:
sqlite3 vaultwarden-data/db.sqlite3 'PRAGMA wal_checkpoint(TRUNCATE);' || true
rm -f vaultwarden-data/db.sqlite3-wal vaultwarden-data/db.sqlite3-shm
git add -f vaultwarden-data/db.sqlite3 vaultwarden-data/rsa_key.pem
```

If you bump `vaultwarden/server` later, Vaultwarden migrates the seed DB forward
on boot, so the fixture keeps working (regenerate only if a major schema change
breaks the test).

### 2. Create the throwaway Bitwarden Cloud destination

Sign up a fresh Bitwarden Cloud account (no real data) and generate its personal
API key.

### 3. Add 7 repository secrets

(GitHub → Settings → Secrets and variables → Actions)

| Secret                        | Value                                             |
| ----------------------------- | ------------------------------------------------- |
| `TEST_BW_CLIENTID_SOURCE`     | seeded Vaultwarden account `client_id` (`user.…`) |
| `TEST_BW_CLIENTSECRET_SOURCE` | seeded Vaultwarden account `client_secret`        |
| `TEST_BW_PASS_SOURCE`         | seeded Vaultwarden account master password        |
| `TEST_BW_SERVER_DEST`         | `https://vault.bitwarden.com` (or `.eu`)          |
| `TEST_BW_CLIENTID_DEST`       | cloud account `client_id`                         |
| `TEST_BW_CLIENTSECRET_DEST`   | cloud account `client_secret`                     |
| `TEST_BW_PASS_DEST`           | cloud account master password                     |

The source server is the in-CI Vaultwarden (`localhost`), so no source-server
secret is needed.

Renovate then bumps `@bitwarden/cli` / `vaultwarden/server`, this test runs the
candidate versions end-to-end, and Renovate auto-merges only once it's green
(`platformAutomerge: false` → Renovate waits for the check, no branch protection
required).

## Run it locally

```bash
export BW_CLIENTID_SOURCE=... BW_CLIENTSECRET_SOURCE=... BW_PASS_SOURCE=...
export BW_SERVER_DEST=https://vault.bitwarden.com
export BW_CLIENTID_DEST=...   BW_CLIENTSECRET_DEST=...   BW_PASS_DEST=...
bash test/cli-compat/run.sh
```
