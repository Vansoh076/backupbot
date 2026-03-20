#!/bin/bash
# cliplogbackup.sh — backs up clipboard.log automatically with live echo

LOGFILE=/data/data/com.termux/files/home/md/sh/backupbot/tmp/clipboard.log
TG_BACKUP=/data/data/com.termux/files/home/md/sh/backupbot/tgbackup.sh

# Count logs
COUNT=$(wc -l < "$LOGFILE")

if [ "$COUNT" -gt 0 ]; then
    echo "📤 Backing up $COUNT clipboard logs..."

    # Use tgbackup with the log file
    bash "$TG_BACKUP" "$LOGFILE" <<EOF
$LOGFILE
2
EOF

    if [ $? -eq 0 ]; then
        echo "✅ Backed up $COUNT logs"

        # Add reset marker before clearing
        echo "==== Reset at $(date '+%Y-%m-%d %H:%M:%S') (backed up $COUNT logs) ====" >> "$LOGFILE"

        # Then clear log
        > "$LOGFILE"
    else
        echo "❌ Backup failed, log not cleared"
    fi
else
    echo "⚠️ Clipboard log is empty, nothing to back up"
fi
