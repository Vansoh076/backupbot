#!/bin/bash
# tgrestore.sh — The Final "Fetch & Heal" Tool

source ~/.tgconfig 2>/dev/null || { echo "❌ Missing ~/.tgconfig"; exit 1; }
MANIFEST="$HOME/.tg_manifest"
RESTORE_ROOT="$HOME/Restored_Files"

[ ! -f "$MANIFEST" ] && { echo "❌ No manifest found. Run a backup first!"; exit 1; }

# --- 1. Show & Search ---
echo -e "\n\033[1;34m📂 Available Backups:\033[0m"
echo "------------------------------------------------"
# List unique folder names from the manifest
BACKUPS=($(grep "|" "$MANIFEST" | awk -F ' | ' '{print $3}' | sort -u))

for i in "${!BACKUPS[@]}"; do
    echo "$((i+1)). ${BACKUPS[$i]}"
done
echo "------------------------------------------------"

read -p "🔍 Enter folder name (or number): " INPUT

# Handle numeric selection or name
if [[ "$INPUT" =~ ^[0-9]+$ ]]; then
    CHOSEN_NAME="${BACKUPS[$((INPUT-1))]}"
else
    CHOSEN_NAME="$INPUT"
fi

# --- 2. Validation & Setup ---
FILE_ENTRIES=$(grep "| $CHOSEN_NAME |" "$MANIFEST")
[ -z "$FILE_ENTRIES" ] && { echo "❌ Backup '$CHOSEN_NAME' not found."; exit 1; }

TEMP_DIR="$RESTORE_ROOT/${CHOSEN_NAME}_chunks"
mkdir -p "$TEMP_DIR"

# --- 3. Download Loop ---
echo -e "\n\033[1;32m📥 Downloading parts for $CHOSEN_NAME...\033[0m"
while read -r line; do
    PART_NAME=$(echo "$line" | awk -F ' | ' '{print $5}')
    FILE_ID=$(echo "$line" | awk -F ' | ' '{print $7}')
    
    echo -n "   -> Fetching $PART_NAME... "
    FILE_INFO=$(curl -s "https://api.telegram.org/bot$TOKEN/getFile?file_id=$FILE_ID")
    REMOTE_PATH=$(echo "$FILE_INFO" | grep -oP '"file_path":"[^"]+"' | cut -d'"' -f4)
    
    if [ -n "$REMOTE_PATH" ]; then
        curl -s -L "https://api.telegram.org/file/bot$TOKEN/$REMOTE_PATH" -o "$TEMP_DIR/$PART_NAME"
        echo "✅"
    else
        echo "❌ (Expired/Not Found)"
    fi
done <<< "$FILE_ENTRIES"

# --- 4. Reassembly & Extraction ---
echo -e "\n\033[1;33m📦 Reassembling and Extracting...\033[0m"
cd "$TEMP_DIR" || exit
MAIN_ZIP=$(ls *.zip 2>/dev/null | head -n 1)

if [ -n "$MAIN_ZIP" ]; then
    # Merge splits into one valid zip (Essential for split archives)
    zip -s- "$MAIN_ZIP" --out "healed.zip" > /dev/null
    
    # Extract to final destination
    mkdir -p "$RESTORE_ROOT/$CHOSEN_NAME"
    unzip -q "healed.zip" -d "$RESTORE_ROOT/$CHOSEN_NAME"
    
    echo -e "✨ \033[1;32mDone!\033[0m Files are in $RESTORE_ROOT/$CHOSEN_NAME"
    rm -rf "$TEMP_DIR"
else
    echo "❌ Error: Could not find the main .zip file to start reassembly."
fi