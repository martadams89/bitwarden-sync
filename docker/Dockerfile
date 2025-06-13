# Use a Node.js base image
FROM alpine:latest

# Set working directory
WORKDIR /app

# Install required packages
RUN apk --no-cache add python3 curl bash ca-certificates openssl ncurses coreutils make gcc g++ libgcc linux-headers grep util-linux binutils findutils uuidgen nodejs npm wget unzip tar openssl jq bash

# Suppress Node.js deprecation warnings
ENV NODE_OPTIONS="--no-deprecation"

# Install Bitwarden CLI
RUN npm install -g semver @bitwarden/cli

# Define cron schedule and script variables
CMD echo ${BW_TAR_PASS}
CMD echo ${BW_ACCOUNT_SOURCE}
CMD echo ${BW_PASS_SOURCE}
CMD echo ${BW_CLIENTID_SOURCE}
CMD echo ${BW_CLIENTSECRET_SOURCE}
CMD echo ${BW_SERVER_SOURCE}
CMD echo ${BW_ACCOUNT_DEST}
CMD echo ${BW_PASS_DEST}
CMD echo ${BW_CLIENTID_DEST}
CMD echo ${BW_CLIENTSECRET_SOURCE}
CMD echo ${BW_SERVER_DEST}

# Define a default cron schedule
ENV CRON_SCHEDULE="57 23 * * *"

# Create a cron job file with the defined schedule
RUN echo "$CRON_SCHEDULE root /app/script.sh > /var/log/cron.log 2>&1" > /etc/crontabs/root

# Copy your script and encryption files to the container
COPY docker/bitwarden_sync.sh /app/script.sh

# Make your script executable
RUN chmod +x /app/script.sh

# Start cron and log output to console
CMD ["sh", "-c", "echo \"$CRON_SCHEDULE /app/script.sh > /proc/1/fd/1 2>&1\" > /etc/crontabs/root && crond -f -L /dev/stdout"]