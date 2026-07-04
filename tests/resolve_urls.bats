#!/usr/bin/env bats
#
# Unit tests for the URL-resolution logic in bitwarden_sync.sh.
#
# We extract ONLY the resolve_destination_urls function and source that, rather
# than sourcing the whole script (which would execute the live sync). This keeps
# the tests hermetic — no Bitwarden CLI, network or secrets required.

setup() {
  eval "$(sed -n '/^resolve_destination_urls()/,/^}/p' "${BATS_TEST_DIRNAME}/../bitwarden_sync.sh")"
  unset BW_API_URL_DEST BW_IDENTITY_URL_DEST DEST_API_URL DEST_IDENTITY_URL
}

@test "bitwarden.com cloud derives api/identity subdomains" {
  BW_SERVER_DEST="https://vault.bitwarden.com"
  resolve_destination_urls
  [ "$DEST_API_URL" = "https://api.bitwarden.com" ]
  [ "$DEST_IDENTITY_URL" = "https://identity.bitwarden.com" ]
}

@test "bitwarden.eu cloud derives .eu api/identity subdomains" {
  BW_SERVER_DEST="https://vault.bitwarden.eu"
  resolve_destination_urls
  [ "$DEST_API_URL" = "https://api.bitwarden.eu" ]
  [ "$DEST_IDENTITY_URL" = "https://identity.bitwarden.eu" ]
}

@test "self-hosted server appends /api and /identity (trailing slash stripped)" {
  BW_SERVER_DEST="https://vault.example.com/"
  resolve_destination_urls
  [ "$DEST_API_URL" = "https://vault.example.com/api" ]
  [ "$DEST_IDENTITY_URL" = "https://vault.example.com/identity" ]
}

@test "explicit override URLs are respected" {
  BW_SERVER_DEST="https://vault.example.com"
  BW_API_URL_DEST="https://api.example.com/"
  BW_IDENTITY_URL_DEST="https://id.example.com"
  resolve_destination_urls
  [ "$DEST_API_URL" = "https://api.example.com" ]
  [ "$DEST_IDENTITY_URL" = "https://id.example.com" ]
}

@test "a non-URL destination is rejected" {
  BW_SERVER_DEST="not-a-url"
  run resolve_destination_urls
  [ "$status" -ne 0 ]
}
