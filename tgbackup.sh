#!/bin/bash
# Load config or exit
source ~/.tgconfig 2>/dev/null || { echo "❌ Missing ~/.tgconfig"; exit 1; }

# --- 1. Settings & State ---
mkdir -p "$HOME/tmp"
STATE_FILE="$HOME/.backup_state"
SPLIT_SIZE="49m" 
DATESTAMP="$(date +%Y-%m-%d_%H%M)"
START_TIME_ALL=$(date +%s)

# --- 2. Notification Function (Fixed New Lines) ---
tg_send() {
    local TEXT="$1"
    # Using --data-urlencode with actual new lines for perfect Telegram rendering
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$TEXT" \
        --data-urlencode "parse_mode=Markdown" > /dev/null
}

# --- 3. The EXIT TRAP (Guarantees Cleanup & Final Message) ---
finish() {
    DONE_COUNT=$(wc -l < "$STATE_FILE" 2>/dev/null || echo 0)
    TOTAL_PARTS=${#ALL_PARTS[@]}
    
    # Only trigger completion if the loop actually finished
    if [ "$DONE_COUNT" -eq "$TOTAL_PARTS" ] && [ "$TOTAL_PARTS" -gt 0 ]; then
        echo -e "\n🏁 Sending final Telegram notifications..."
        DUR=$(( $(date +%s) - START_TIME_ALL ))
        
        tg_send "✅ *BACKUP COMPLETE* ✅
📁 *Folder:* $TARGET_NAME
🏁 *Status:* All $TOTAL_PARTS parts sent
🕒 *Total Time:* $((DUR / 60))m $((DUR % 60))s"

        # Upload Restore Helper
        [ -f "./tgrestore.sh" ] && curl -s -F document=@"./tgrestore.sh" \
            "https://api.telegram.org/bot$TOKEN/sendDocument?chat_id=$CHAT_ID&caption=🛠️ Restore Helper for $TARGET_NAME" > /dev/null
        
        # Final Cleanup of this specific folder's chunks
        rm -f "$HOME/tmp/${TARGET_NAME}"*
        rm -f "$STATE_FILE"
        echo "✨ Done!"
    fi
}
trap finish EXIT
trap 'exit 1' SIGINT SIGTERM

# --- 4. Path Input ---
echo "📂 Enter path to back up:"
read -r P
P="${P/#\~/$HOME}"
[ ! -e "$P" ] && { echo "❌ Path not found"; exit 1; }

TARGET_NAME=$(basename "$P")
PARENT_DIR=$(dirname "$P")

# --- 5. Smart Resume Check ---
# Check for existing chunks from a previous force-stop
EXISTING_CHUNKS=$(ls "$HOME/tmp/${TARGET_NAME}"*.z01 2>/dev/null | wc -l)
RESUME_ACTIVE=false

if [ "$EXISTING_CHUNKS" -gt 0 ]; then
    echo "⚠️  Found $EXISTING_CHUNKS existing chunks for $TARGET_NAME."
    read -p "Resume upload? (y = Yes / n = Delete & Start Fresh): " choice
    if [[ "$choice" =~ ^[yY]$ ]]; then
        RESUME_ACTIVE=true
    else
        echo "🧹 Clearing old data..."
        rm -f "$HOME/tmp/${TARGET_NAME}"* "$STATE_FILE"
    fi
fi

# --- 6. Zipping & Start Notifications ---
cd "$PARENT_DIR" || exit

if [ "$RESUME_ACTIVE" = false ]; then
    # Instant "Starting Fresh" Notification
    tg_send "🚀 *BACKUP INITIALIZED* 🚀
📁 *Folder:* $TARGET_NAME
🔄 *Status:* Zipping fresh..."
    
    ZIPFILE="$HOME/tmp/${TARGET_NAME}_${DATESTAMP}.zip"
    RAW_SIZE=$(du -sh "$TARGET_NAME" | awk '{print $1}')
    echo "📦 Zipping $RAW_SIZE into 49MB chunks..."
    zip -s "$SPLIT_SIZE" -r -q "$ZIPFILE" "$TARGET_NAME"
fi

# Gather all parts (zip and z01, z02, etc.)
ALL_PARTS=( $(ls "$HOME/tmp/${TARGET_NAME}"* 2>/dev/null | grep -E '\.z[0-9]+$|\.zip$' | sort -V) )
TOTAL_PARTS=${#ALL_PARTS[@]}

# If resuming, notify Telegram of exactly how many parts are left
if [ "$RESUME_ACTIVE" = true ]; then
    ALREADY_DONE=$(wc -l < "$STATE_FILE" 2>/dev/null || echo 0)
    LEFT=$((TOTAL_PARTS - ALREADY_DONE))
    tg_send "🔄 *RESUMING BACKUP* 🚀
📁 *Folder:* $TARGET_NAME
📦 *Remaining:* $LEFT of $TOTAL_PARTS parts"
fi

# --- 7. Upload Loop ---
for i in "${!ALL_PARTS[@]}"; do
    PART="${ALL_PARTS[$i]}"
    PART_NUM=$((i + 1))
    
    # Skip if already logged in state file
    grep -qsxF "$PART" "$STATE_FILE" && continue
    
    SIZE_MB=$(echo "scale=2; $(stat -c%s "$PART")/1048576" | bc)
    echo -ne "📤 [$PART_NUM/$TOTAL_PARTS] $(basename "$PART") ($SIZE_MB MB) | Uploading...\r"
    
    # Send to Telegram
    RESPONSE=$(curl -s -F document=@"$PART" "https://api.telegram.org/bot$TOKEN/sendDocument?chat_id=$CHAT_ID")
    
    if [[ "$RESPONSE" == *"\"ok\":true"* ]]; then
        echo -e "\n✅ [$PART_NUM/$TOTAL_PARTS] Done"
        echo "$PART" >> "$STATE_FILE" # Log success
    else
        echo -e "\n❌ UPLOAD FAILED for $PART"; exit 1
    fi
done
