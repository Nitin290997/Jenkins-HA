#!/bin/bash

# Define variables
SOURCE_SERVER="<IP_address_of_Jenkins_1>"
DEST_SERVER="<IP_address_of_Jenkins_2>"
BASE_DIR="/var/lib/jenkins"
LOG_FILE="/var/log/jenkins_reload.log"
JENKINS_URL="http://$SOURCE_SERVER:8080/login"
JENKINS_IDENTITY_FILE="$BASE_DIR/identity.key.enc"
SSH_PORT="22"
SSH_KEY="<path_to_your_private_key>"  # Updated SSH key file path
SYNC_SUCCESS=true  # Initialize as true, will change to false if any step fails
REVERSE_SYNC_DONE_FLAG="/var/log/reverse_sync_done.flag"

# Log function for cleaner output
log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" >> "$LOG_FILE"
}

# Perform Forward Sync
forward_sync() {
    log "Starting Jenkins directories synchronization from $SOURCE_SERVER to $DEST_SERVER"
    log "Syncing $BASE_DIR/"
    rsync -avz --exclude "$(basename "$JENKINS_IDENTITY_FILE")" -e "ssh -i $SSH_KEY -p $SSH_PORT" root@$SOURCE_SERVER:$BASE_DIR/ $BASE_DIR/ >> "$LOG_FILE" 2>&1
    if [ $? -eq 0 ]; then
        log "Successfully synced $BASE_DIR/"
    else
        log "Failed to sync $BASE_DIR/"
        SYNC_SUCCESS=false  # Mark as failed
    fi
}

# Perform Reverse Sync
reverse_sync() {
    log "Starting Jenkins directories synchronization from $DEST_SERVER to $SOURCE_SERVER"
    log "Syncing $BASE_DIR/"
    rsync -avz --exclude "$(basename "$JENKINS_IDENTITY_FILE")" -e "ssh -i $SSH_KEY -p $SSH_PORT" $BASE_DIR/ root@$SOURCE_SERVER:$BASE_DIR/ >> "$LOG_FILE" 2>&1
    if [ $? -eq 0 ]; then
        log "Successfully performed reverse sync from $DEST_SERVER to $SOURCE_SERVER"
        touch "$REVERSE_SYNC_DONE_FLAG"  # Mark reverse sync as done
    else
        log "Failed to perform reverse sync from $DEST_SERVER to $SOURCE_SERVER"
        SYNC_SUCCESS=false  # Mark as failed
    fi
}

# Check if Jenkins server is available
log "Checking availability of Jenkins server at $JENKINS_URL"
RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$JENKINS_URL")

if [[ $RESPONSE_CODE =~ ^[2-3] ]]; then
    log "Jenkins server is available with response code $RESPONSE_CODE. Proceeding with sync."

    # Check if reverse sync has been performed
    REVERSE_SYNC_DONE=$(cat "$REVERSE_SYNC_DONE_FLAG" 2>/dev/null)
    if [ "$REVERSE_SYNC_DONE" != "true" ]; then
        log "Performing reverse sync from $DEST_SERVER to $SOURCE_SERVER"
        reverse_sync # Perform reverse sync
        echo "true" > "$REVERSE_SYNC_DONE_FLAG"  # Mark reverse sync as done

        # Remote restart of Jenkins on the source server
        log "Restarting Jenkins service on $SOURCE_SERVER"
        ssh -i "$SSH_KEY" -p "$SSH_PORT" root@$SOURCE_SERVER "systemctl restart jenkins.service" >> "$LOG_FILE" 2>&1
        if [ $? -eq 0 ]; then
            log "Jenkins service on $SOURCE_SERVER restarted successfully"
        else
            log "Failed to restart Jenkins service on $SOURCE_SERVER"
            SYNC_SUCCESS=false
        fi
    fi

    # Perform forward sync
    log "Performing forward sync from $SOURCE_SERVER to $DEST_SERVER"
    forward_sync # Perform forward sync"

else
    log "Jenkins server is not available. Response code: $RESPONSE_CODE"

    # Check SSH connectivity
    log "Checking SSH connectivity to $SOURCE_SERVER"
    ssh -o BatchMode=yes -o ConnectTimeout=5 -i "$SSH_KEY" -p "$SSH_PORT" root@$SOURCE_SERVER exit
    if [ $? -eq 0 ]; then
        log "SSH connectivity to $SOURCE_SERVER is successful."
        reverse_sync # Perform reverse sync
        echo "true" > "$REVERSE_SYNC_DONE_FLAG"  # Mark reverse sync as done
    else
        log "SSH connectivity to $SOURCE_SERVER failed. Aborting sync."
        echo "false" > "$REVERSE_SYNC_DONE_FLAG"  # Mark reverse sync as false
        exit 1
    fi
fi

# Remove Jenkins Identity Key file
log "Removing Jenkins Identity Key file"
rm -f "$JENKINS_IDENTITY_FILE"

# Jenkins reload
log "Triggering Jenkins reload"
systemctl restart jenkins.service
if [ $? -eq 0 ]; then
    log "Jenkins reload triggered successfully"
else
    log "Failed to trigger Jenkins reload"
    SYNC_SUCCESS=false
fi

# Final log entry
if [ "$SYNC_SUCCESS" = true ]; then
    log "Jenkins synchronization and reload process completed successfully."
else
    log "Jenkins synchronization and reload process failed."
fi
