#!/bin/bash
#
# syslog-cleanup.sh - free disk space on the syslog server by deleting
# the OLDEST rotated router logs when the disk is close to full.
#
# Install:
#   cp syslog-cleanup.sh /usr/local/bin/ && chmod 755 /usr/local/bin/syslog-cleanup.sh
#   echo '*/15 * * * * root /usr/local/bin/syslog-cleanup.sh' > /etc/cron.d/syslog-cleanup
#
# Every action is written to /var/log/messages with the tag "syslog-cleanup".

LOG_DIR="${LOG_DIR:-/var/log/syslogs}"                          # where router logs are kept
THRESHOLD="${THRESHOLD:-80}"                                    # start cleaning above this % used
TARGET="${TARGET:-70}"                                          # stop cleaning at or below this % used
LOGROTATE_CONF="${LOGROTATE_CONF:-/etc/logrotate.d/syslogs}"    # used to force a rotation if needed
LOCK_FILE="${LOCK_FILE:-/var/run/syslog-cleanup.lock}"

log() { logger -t syslog-cleanup -- "$*"; echo "$*"; }

usage() { df -P "$LOG_DIR" | awk 'NR==2 { gsub("%", "", $5); print $5 }'; }

# Oldest rotated file (e.g. 10.1.1.1.log-20261101-1762000000.gz); never the live *.log files
oldest_archive() {
    find "$LOG_DIR" -type f -name '*.log-*' -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | head -n 1 | cut -d' ' -f2-
}

[ -d "$LOG_DIR" ] || { log "ERROR: $LOG_DIR does not exist"; exit 1; }

# Only one copy at a time
exec 9>"$LOCK_FILE" || exit 1
flock -n 9 || exit 0

used=$(usage)
[ "$used" -gt "$THRESHOLD" ] || exit 0

log "Disk ${used}% used (threshold ${THRESHOLD}%), deleting oldest logs in $LOG_DIR until ${TARGET}%"

forced=0
while [ "$used" -gt "$TARGET" ]; do
    file=$(oldest_archive)

    if [ -z "$file" ]; then
        # No archives left: rotate the live logs once so they become deletable archives
        if [ "$forced" -eq 0 ] && [ -f "$LOGROTATE_CONF" ]; then
            log "No archives left, forcing log rotation"
            logrotate -f "$LOGROTATE_CONF"
            forced=1
            continue
        fi
        log "WARNING: nothing left to delete and disk still ${used}% used - check what else is using the disk"
        exit 2
    fi

    size=$(du -h "$file" | cut -f1)
    rm -f -- "$file" && log "Deleted $file ($size)"
    used=$(usage)
done

log "Done, disk now ${used}% used"
