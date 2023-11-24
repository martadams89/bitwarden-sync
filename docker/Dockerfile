# Use a Node.js base image
FROM alpine:latest

# Set working directory
WORKDIR /app

# Install required packages
RUN apk --no-cache add python3 curl bash ca-certificates openssl ncurses coreutils make gcc g++ libgcc linux-headers grep util-linux binutils findutils uuidgen nodejs npm wget unzip tar openssl jq bash

# Install Bitwarden CLI
RUN npm install -g @bitwarden/cli

# Copy your script and encryption files to the container
COPY docker/bitwarden_sync.sh /app/script.sh

# Make your script executable
RUN chmod +x /app/script.sh

# Create a cron job file with the defined schedule
RUN cat ${CRON_SCHEDULE} > /app/crontab.txt
RUN echo -n " root /app/script.sh > /var/log/cron.log 2>&1" >> /app/crontab.txt
RUN chmod 0644 /app/crontab.txt

RUN cat /app/crontab.txt > /etc/crontabs/root

# Start cron
CMD ["crond", "-f", "-l", "2"]