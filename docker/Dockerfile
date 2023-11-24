# Use a Node.js base image
FROM alpine:latest

# Set working directory
WORKDIR /app

# Install required packages
RUN apk --no-cache add python3 curl bash ca-certificates openssl ncurses coreutils python2 make gcc g++ libgcc linux-headers grep util-linux binutils findutils uuidgen nodejs npm wget unzip tar openssl jq bash

# Install Bitwarden CLI
RUN npm install -g @bitwarden/cli

# Set environment variables
ENV LC_CTYPE=C
ENV LC_ALL=C

# Define cron schedule and script variables
ENV CRON_SCHEDULE=${CRON_SCHEDULE}
ENV BW_TAR_PASS=${BW_TAR_PASS}
ENV BW_ACCOUNT_SOURCE=${BW_ACCOUNT_SOURCE}
ENV BW_PASS_SOURCE=${BW_PASS_SOURCE}
ENV BW_CLIENTID_SOURCE=${BW_CLIENTID_SOURCE}
ENV BW_CLIENTSECRET_SOURCE=${BW_CLIENTSECRET_SOURCE}
ENV BW_SERVER_SOURCE=${BW_SERVER_SOURCE}
ENV BW_ACCOUNT_DEST=${BW_ACCOUNT_DEST}
ENV BW_PASS_DEST=${BW_PASS_DEST}
ENV BW_CLIENTID_DEST=${BW_CLIENTID_DEST}
ENV BW_CLIENTSECRET_DEST=${BW_CLIENTSECRET_SOURCE}
ENV BW_SERVER_DEST=${BW_SERVER_DEST}

# Copy your script and encryption files to the container
COPY bitwarden_sync.sh /app/script.sh

# Make your script executable
RUN chmod +x /app/script.sh

# Create a cron job file with the defined schedule
RUN echo "$CRON_SCHEDULE root /app/script.sh > /var/log/cron.log 2>&1" > /app/crontab.txt
RUN chmod 0644 /app/crontab.txt

RUN /usr/bin/crontab /app/crontab.txt

# Start cron
CMD /usr/bin/crontab && tail -f /var/log/cron.log