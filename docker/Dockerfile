# Alpine base image. Pinned for reproducible builds; Renovate keeps it current.
FROM alpine:3.21

# Set working directory
WORKDIR /app

# Install required packages
RUN apk --no-cache add python3 curl bash ca-certificates openssl ncurses coreutils make gcc g++ libgcc linux-headers grep util-linux binutils findutils uuidgen nodejs npm wget unzip tar openssl jq bash

# Suppress Node.js deprecation warnings
ENV NODE_OPTIONS="--no-deprecation"

# Bitwarden CLI versions. Override at build time with --build-arg, or at runtime
# by setting the matching env var (the entrypoint reconciles a concrete version
# that differs from the baked-in one). Keep comments on their own lines: Docker
# does NOT strip an inline "# ..." after an ARG value.
# Both are pinned to a known-good version (Renovate proposes bumps, gated by the
# CLI compatibility test) — 2026.x has broken both Vaultwarden login (#50) and
# Bitwarden Cloud import.
# Source / Vaultwarden compatibility (issue #50):
# renovate: datasource=npm depName=@bitwarden/cli
ARG BW_CLI_OLD_VERSION=2025.12.0
# Destination / Bitwarden cloud:
# renovate: datasource=npm depName=@bitwarden/cli
ARG BW_CLI_NEW_VERSION=2025.12.0
# Bridge the build args to env vars so they can be overridden at runtime too.
ENV BW_CLI_OLD_VERSION=${BW_CLI_OLD_VERSION} \
    BW_CLI_NEW_VERSION=${BW_CLI_NEW_VERSION}

# Install both versions of Bitwarden CLI in separate locations.
# Install the pinned "old" CLI into an isolated path for the source, then the
# "new" CLI globally for the destination.
RUN npm install -g semver && \
    npm install -g @bitwarden/cli@${BW_CLI_OLD_VERSION} && \
    mkdir -p /opt/bw-old && \
    cp -r /usr/local/lib/node_modules/@bitwarden/cli /opt/bw-old/ && \
    cp -r /usr/local/lib/node_modules /opt/bw-old/node_modules && \
    npm install -g @bitwarden/cli@${BW_CLI_NEW_VERSION}

# Create wrapper scripts for both versions
RUN echo '#!/bin/sh' > /usr/local/bin/bw-old && \
    echo 'NODE_PATH=/opt/bw-old/node_modules exec node /opt/bw-old/cli/build/bw.js "$@"' >> /usr/local/bin/bw-old && \
    chmod +x /usr/local/bin/bw-old && \
    ln -s $(which bw) /usr/local/bin/bw-new

# Define a default cron schedule
ENV CRON_SCHEDULE="57 23 * * *"

# Create a cron job file with the defined schedule
RUN echo "$CRON_SCHEDULE root /app/script.sh > /var/log/cron.log 2>&1" > /etc/crontabs/root

# Copy your script, entrypoint, shared CLI helpers, and encryption files
COPY docker/bitwarden_sync.sh /app/script.sh
COPY docker/entrypoint.sh /app/entrypoint.sh
COPY docker/bw-cli-lib.sh /app/bw-cli-lib.sh

# Make your scripts executable
RUN chmod +x /app/script.sh /app/entrypoint.sh

# The entrypoint reconciles CLI versions (if overridden) then execs the CMD.
ENTRYPOINT ["/app/entrypoint.sh"]

# Start cron and log output to console
CMD ["sh", "-c", "echo \"$CRON_SCHEDULE /app/script.sh > /proc/1/fd/1 2>&1\" > /etc/crontabs/root && crond -f -L /dev/stdout"]