#!/bin/bash
# auto_create.sh — THE ULTIMATE MASTER VERSION
# Features: Manifest Database, Progress Bar, Overall ETA, Speed, Retries, SIGINT Confirmation

cat << 'EOF' > tgbackup1.sh
#!/bin/bash
source ~/.tgconfig 2>/dev/null || { echo "❌ Missing ~/.tgconfig"; exit 1; }

# --- 1. Settings & State ---
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

# --- 2. Graceful Exit & Confirmation ---
finish() {
    DONE_COUNT=$(wc -l < "$STATE_FILE" 2>/dev/null || echo 0)
    TOTAL_PARTS=${#ALL_PARTS[@]}
    if [ "$DONE_COUNT" -eq "$TOTAL_PARTS" ] && [ "$TOTAL_PARTS" -gt 0 ]; then
        echo -e "\n🏁 Sending final Telegram notifications..."
        DUR=$(( $(date +%s) - START_TIME_UPLOADS ))
        tg_send "✅ *BACKUP COMPLETE* ✅
📁 *Folder:* $TARGET_NAME
🏁 *Status:* All $TOTAL_PARTS parts sent
🕒 *Total Upload Time:* $((DUR / 60))m $((DUR % 60))s"
        [ -f "./tgrestore.sh" ] && curl -s -F document=@"./tgrestore.sh" "https://api.telegram.org/bot$TOKEN/sendDocument?chat_id=$CHAT_ID&caption=🛠️ Restore Helper" > /dev/null
        rm -f "$HOME/tmp/${TARGET_NAME}"* "$STATE_FILE"
        echo "✨ Done!"
    fi
}

confirm_exit() {
    echo -e "\n"
    read -p "⚠️  Stop backup? (y = Exit / n = Continue): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] && { echo "🛑 Stopping..."; exit 1; } || echo "▶️  Resuming..."
}

trap finish EXIT
trap confirm_exit SIGINT

# --- 3. Input & Resume Logic ---
echo "📂 Enter path to back up:"
read -r P
P="${P/#\~/$HOME}"
[ ! -e "$P" ] && exit 1
TARGET_NAME=$(basename "$P")
PARENT_DIR=$(dirname "$P")

EXISTING_CHUNKS=$(ls "$HOME/tmp/${TARGET_NAME}"*.z01 2>/dev/null | wc -l)
RESUME_ACTIVE=false
if [ "$EXISTING_CHUNKS" -gt 0 ]; then
    echo "⚠️  Found existing chunks for $TARGET_NAME."
    read -p "Resume upload? (y/n): " choice
    [[ "$choice" =~ ^[yY]$ ]] && RESUME_ACTIVE=true || rm -f "$HOME/tmp/${TARGET_NAME}"* "$STATE_FILE"
fi

# --- 4. Zipping ---
cd "$PARENT_DIR" || exit
if [ "$RESUME_ACTIVE" = false ]; then
    tg_send "🚀 *BACKUP INITIALIZED* 🚀
📁 *Folder:* $TARGET_NAME
🔄 *Status:* Zipping fresh..."
    zip -s "$SPLIT_SIZE" -r -q "$HOME/tmp/${TARGET_NAME}_${DATESTAMP}.zip" "$TARGET_NAME"
fi

ALL_PARTS=( $(ls "$HOME/tmp/${TARGET_NAME}"* 2>/dev/null | grep -E '\.z[0-9]+$|\.zip$' | sort -V) )
TOTAL_PARTS=${#ALL_PARTS[@]}

if [ "$RESUME_ACTIVE" = true ]; then
    ALREADY_DONE=$(wc -l < "$STATE_FILE" 2>/dev/null || echo 0)
    tg_send "🔄 *RESUMING BACKUP* 🚀
📁 *Folder:* $TARGET_NAME
📦 *Remaining:* $((TOTAL_PARTS - ALREADY_DONE)) of $TOTAL_PARTS parts"
fi

# --- 5. Upload Loop with Bar, ETA, Speed, and Manifest Logging ---
START_TIME_UPLOADS=$(date +%s)
PARTS_SENT_THIS_SESSION=0

for i in "${!ALL_PARTS[@]}"; do
    PART="${ALL_PARTS[$i]}"
    PART_NUM=$((i + 1))
    grep -qsxF "$PART" "$STATE_FILE" && continue
    
    SIZE_MB=$(echo "scale=2; $(stat -c%s "$PART")/1048576" | bc)
    
    PERCENT=$(( (PART_NUM * 100) / TOTAL_PARTS ))
    BAR_WIDTH=20
    FILLED=$(( (PERCENT * BAR_WIDTH) / 100 ))
    EMPTY=$(( BAR_WIDTH - FILLED ))
    BAR=$(printf "%${FILLED}s" | tr ' ' '#')$(printf "%${EMPTY}s" | tr ' ' '-')

    if [ $PARTS_SENT_THIS_SESSION -gt 0 ]; then
        ELAPSED=$(( $(date +%s) - START_TIME_UPLOADS ))
        AVG_TIME=$(echo "scale=2; $ELAPSED / $PARTS_SENT_THIS_SESSION" | bc)
        REMAINING=$(( TOTAL_PARTS - i ))
        ETA_SEC=$(echo "$REMAINING * $AVG_TIME" | bc | cut -d. -f1)
        ETA_STR="$((ETA_SEC / 60))m $((ETA_SEC % 60))s"
    else
        ETA_STR="Calculating..."
    fi

    SUCCESS=false; TRY=1
    while [ $TRY -le $MAX_RETRIES ] && [ "$SUCCESS" = false ]; do
        echo -ne "\r📤 [$BAR] $PERCENT% | Part $PART_NUM/$TOTAL_PARTS | ⏳ ETA: $ETA_STR (Try $TRY)"
        
        S_CHK=$(date +%s)
        RESPONSE=$(curl -s -F document=@"$PART" "https://api.telegram.org/bot$TOKEN/sendDocument?chat_id=$CHAT_ID")
        
        # Check if Telegram returned "ok":true
        if [[ "$RESPONSE" == *"\"ok\":true"* ]]; then
            # Extract File ID for the Manifest (The Database Way)
            FILE_ID=$(echo "$RESPONSE" | grep -oP '"file_id":"[^"]+"' | cut -d'"' -f4)
            echo "$(date +%Y-%m-%d) | $TARGET_NAME | $(basename "$PART") | $FILE_ID" >> "$MANIFEST"

            E_CHK=$(date +%s); DIFF=$((E_CHK - S_CHK)); [ $DIFF -eq 0 ] && DIFF=1
            SPEED=$(echo "scale=2; $SIZE_MB / $DIFF" | bc)
            
            echo -e "\n✅ Done | Speed: $SPEED MB/s | Time: ${DIFF}s"
            echo "$PART" >> "$STATE_FILE"
            SUCCESS=true; ((PARTS_SENT_THIS_SESSION++))
        else
            echo -e "\n⚠️  Failed. Retrying in 5s... ($TRY/$MAX_RETRIES)"
            ((TRY++)); sleep 5
        fi
    done
    [ "$SUCCESS" = false ] && { echo "❌ Critical Failure"; exit 1; }
done
EOF

chmod +x tgbackup.sh
echo "✅ Master Upload Script with Manifest Database Logic is ready!"