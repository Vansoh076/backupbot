#!/bin/bash
# tgbackup.sh — High-Performance Uploader

# --- 1. Auto-Heal Config Load ---
if [ -f "$HOME/.tgconfig" ]; then
    source "$HOME/.tgconfig"
else
    echo "❌ Config missing. Please run manage.sh first."
    exit 1
fi

# --- 2. Settings & State ---
mkdir -p "$HOME/tmp"
STATE_FILE="$HOME/.backup_state"
MANIFEST="$HOME/.tg_manifest"
SPLIT_SIZE="49m" 
DATESTAMP="$(date +%Y-%m-%d_%H%M)"
MAX_RETRIES=3

tg_send() {
    local TEXT="$1"
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$TEXT" \
        --data-urlencode "parse_mode=Markdown" > /dev/null
}

# --- 3. Input & Path Logic ---
# Use argument if provided by manage.sh, otherwise prompt
if [ -n "$1" ]; then
    P="$1"
else
    echo "📂 Enter path to back up:"
    read -r P
fi

P="${P/#\~/$HOME}"
[ ! -e "$P" ] && { echo "❌ Path not found"; exit 1; }
TARGET_NAME=$(basename "$P")
PARENT_DIR=$(dirname "$P")

# --- 4. Zipping & Resume Check ---
cd "$PARENT_DIR" || exit
EXISTING_CHUNKS=$(ls "$HOME/tmp/${TARGET_NAME}"*.z01 2>/dev/null | wc -l)
RESUME_ACTIVE=false
if [ "$EXISTING_CHUNKS" -gt 0 ]; then
    echo "⚠️  Found existing chunks for $TARGET_NAME."
    read -p "Resume upload? (y/n): " choice
    [[ "$choice" =~ ^[yY]$ ]] && RESUME_ACTIVE=true
fi

if [ "$RESUME_ACTIVE" = false ]; then
    rm -f "$HOME/tmp/${TARGET_NAME}"* "$STATE_FILE"
    tg_send "🚀 *BACKUP INITIALIZED* 🚀
📁 *Folder:* $TARGET_NAME"
    zip -s "$SPLIT_SIZE" -r -q "$HOME/tmp/${TARGET_NAME}_${DATESTAMP}.zip" "$TARGET_NAME"
fi

ALL_PARTS=( $(ls "$HOME/tmp/${TARGET_NAME}"* 2>/dev/null | grep -E '\.z[0-9]+$|\.zip$' | sort -V) )
TOTAL_PARTS=${#ALL_PARTS[@]}

# --- 5. Upload Loop ---
START_TIME_UPLOADS=$(date +%s)
PARTS_SENT_THIS_SESSION=0

for i in "${!ALL_PARTS[@]}"; do
    PART="${ALL_PARTS[$i]}"
    PART_NUM=$((i + 1))
    grep -qsxF "$PART" "$STATE_FILE" && continue
    
    # Progress Bar & ETA Logic
    PERCENT=$(( (PART_NUM * 100) / TOTAL_PARTS ))
    BAR=$(printf "%0.s#" $(seq 1 $((PERCENT / 5))))
    
    SUCCESS=false; TRY=1
    while [ $TRY -le $MAX_RETRIES ] && [ "$SUCCESS" = false ]; do
        echo -ne "\r📤 [$BAR] $PERCENT% | Part $PART_NUM/$TOTAL_PARTS (Try $TRY)"
        
        S_CHK=$(date +%s)
        RESPONSE=$(curl -s -F document=@"$PART" "https://api.telegram.org/bot$TOKEN/sendDocument?chat_id=$CHAT_ID")
        
        if [[ "$RESPONSE" == *"\"ok\":true"* ]]; then
            # MANIFEST LOGGING (Crucial for Restore)
            FILE_ID=$(echo "$RESPONSE" | grep -oP '"file_id":"[^"]+"' | cut -d'"' -f4)
            echo "$(date +%F) | $TARGET_NAME | $(basename "$PART") | $FILE_ID" >> "$MANIFEST"

            echo -e "\n✅ Done"
            echo "$PART" >> "$STATE_FILE"
            SUCCESS=true; ((PARTS_SENT_THIS_SESSION++))
        else
            echo -e "\n⚠️  Retrying in 5s..."
            ((TRY++)); sleep 5
        fi
    done
done

# Cleanup
rm -f "$HOME/tmp/${TARGET_NAME}"* "$STATE_FILE"
echo "✨ Session Complete!"