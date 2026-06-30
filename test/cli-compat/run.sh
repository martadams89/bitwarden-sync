#!/usr/bin/env bash
# CLI compatibility test — runs entirely on the CI runner.
#
# 1. Starts a throwaway Vaultwarden (pinned, Renovate-managed image) from the
#    committed seed volume (the source account + sample items).
# 2. Builds the bitwarden-sync image from the current checkout (so it uses the
#    CLI versions pinned in docker/Dockerfile — including a Renovate PR's bump).
# 3. Runs one real sync: source = the in-CI Vaultwarden, dest = Bitwarden Cloud.
# 4. Asserts the run reported success.
#
# This exercises both historical break points on the candidate CLI *and* the
# candidate Vaultwarden version:
#   - bw-old login/export   (issue #50: "Premature close")
#   - bw-new import          ("decryption operation failed")
#
# A green run is what Renovate waits for before auto-merging an @bitwarden/cli
# or vaultwarden/server bump. Account credentials come from the environment
# (CI injects them from repo secrets). See test/cli-compat/README.md.
#
# ⚠️ The destination account is WIPED and replaced. Both accounts are throwaway.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
COMPOSE="$HERE/docker-compose.yml"
IMAGE_TAG="${IMAGE_TAG:-bitwarden-sync:cli-compat}"
PORT="${PORT:-8000}"

fail() { echo "::error::$*" >&2; exit 1; }

# Source = the in-CI Vaultwarden (seeded volume); dest = real Bitwarden Cloud.
[ -f "$HERE/vaultwarden-data/db.sqlite3" ] || fail "Missing seed volume at test/cli-compat/vaultwarden-data/db.sqlite3 — see test/cli-compat/README.md"
: "${BW_CLIENTID_SOURCE:?set TEST_BW_CLIENTID_SOURCE}"
: "${BW_CLIENTSECRET_SOURCE:?set TEST_BW_CLIENTSECRET_SOURCE}"
: "${BW_PASS_SOURCE:?set TEST_BW_PASS_SOURCE}"
: "${BW_SERVER_DEST:?set TEST_BW_SERVER_DEST (e.g. https://vault.bitwarden.com)}"
: "${BW_CLIENTID_DEST:?set TEST_BW_CLIENTID_DEST}"
: "${BW_CLIENTSECRET_DEST:?set TEST_BW_CLIENTSECRET_DEST}"
: "${BW_PASS_DEST:?set TEST_BW_PASS_DEST}"

# Copy the committed seed to a writable temp dir so the test never mutates the repo.
VW_DATA_DIR=$(mktemp -d)
cp -a "$HERE/vaultwarden-data/." "$VW_DATA_DIR/"
export VW_DATA_DIR

# The bw CLI rejects http:// servers, so Vaultwarden serves HTTPS with a throwaway
# self-signed cert (referenced by ROCKET_TLS in docker-compose.yml).
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "$VW_DATA_DIR/key.pem" -out "$VW_DATA_DIR/cert.pem" \
  -subj "/CN=localhost" >/dev/null 2>&1

cleanup() {
  docker compose -f "$COMPOSE" down >/dev/null 2>&1 || true
  rm -rf "$VW_DATA_DIR"
}
trap cleanup EXIT

# 1. Start Vaultwarden and wait for readiness (HTTPS, self-signed → curl -k).
docker compose -f "$COMPOSE" up -d
echo "# Waiting for Vaultwarden... #"
for _ in $(seq 1 30); do
  curl -fsSk "https://localhost:$PORT/alive" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsSk "https://localhost:$PORT/alive" >/dev/null || fail "Vaultwarden did not become ready"

# 2. Build the image from the current checkout (uses the PR's pinned CLI versions).
docker build -f "$ROOT/docker/Dockerfile" -t "$IMAGE_TAG" "$ROOT"

# 3. Run one sync: source = in-CI Vaultwarden, dest = Bitwarden Cloud.
# Container DNS is unusable on GitHub's Azure runners (stub resolver in
# /etc/resolv.conf, public DNS egress blocked, Azure's 168.63.129.16 not routable
# from containers). But the *host* resolves fine and TCP egress works — so resolve
# the destination's hostnames on the host and pin them into the container's
# /etc/hosts via --add-host. The container then connects by IP with no DNS, and
# TLS still uses the hostname (SNI) so the real cloud certs validate.
# --network host provides egress + the localhost source.
ADD_HOSTS=()
dest_host=$(printf '%s' "${BW_SERVER_DEST:-}" | sed -E 's#^[a-z]+://##; s#[:/].*$##')
for h in "$dest_host" "${dest_host/vault./api.}" "${dest_host/vault./identity.}"; do
  [ -n "$h" ] || continue
  ip=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')
  [ -n "$ip" ] && ADD_HOSTS+=(--add-host "$h:$ip")
done
echo "# Pinned destination hosts: ${ADD_HOSTS[*]:-none} #"

LOG=$(mktemp)
set +e
docker run --rm --network host \
  "${ADD_HOSTS[@]}" \
  -e BW_SERVER_SOURCE="https://localhost:$PORT" \
  -e BW_CLIENTID_SOURCE -e BW_CLIENTSECRET_SOURCE -e BW_PASS_SOURCE \
  -e BW_SERVER_DEST -e BW_CLIENTID_DEST -e BW_CLIENTSECRET_DEST -e BW_PASS_DEST \
  -e BW_TAR_PASS="cli-compat-test" \
  -e BITWARDENCLI_APPDATA_DIR="/tmp/bw" \
  -e NODE_TLS_REJECT_UNAUTHORIZED=0 \
  -e NODE_OPTIONS="--no-deprecation --no-warnings" \
  "$IMAGE_TAG" /app/script.sh 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e

# 4. Assert.
[ "$rc" -eq 0 ] || fail "sync exited with code $rc"
grep -q "status=success" "$LOG" || fail "sync did not report 'status=success'"
echo "CLI compatibility test PASSED ($(grep -o 'cli_source=[^ ]*' "$LOG" | tail -1), $(grep -o 'cli_dest=[^ ]*' "$LOG" | tail -1))"
