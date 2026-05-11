#!/bin/bash

# --- CONFIGURATION ---
LOG_FILE="logs/enshrouded_server.log" 
MSG_ID_FILE="discord_message_id.txt"
LIST_FILE="current_players.tmp"
FLAG_FILE="shutdown.flag"

# --- WEBHOOKS ---
DISCORD_WEBHOOK="${DISCORD_WEBHOOK}"
CHAT_WEBHOOK="${CHAT_WEBHOOK}"
LOG_WEBHOOK="${LOG_WEBHOOK}"

# --- BRANDING ---
BOT_NAME="Skye Serve Enshrouded Monitor"
BOT_LOGO="https://raw.githubusercontent.com/skye-serve/Enshrouded/refs/heads/main/EnshroudedBackground.png" 

# --- GHOST KILLER ---
for pid in $(pgrep -f tracker.sh); do
    if [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ]; then
        kill -9 "$pid" 2>/dev/null
    fi
done

# 1. CLEAN RESET
rm -f "payload.json"
rm -f "$FLAG_FILE"
> "$LIST_FILE" 

echo "--- Stable Tracker & Chat Relay Started: $(date) ---" > tracker_debug.log

DISPLAY_MAP="Embervale"

# --- Background Listener (Status + Chat) ---
tail -F -n 0 "$LOG_FILE" 2>/dev/null | while read -r line; do
    line="${line//$'\r'/}"

    # === 💬 CHAT RELAY LOGIC ===
    if [[ "$line" == *"[server] Chat:"* ]] || [[ "$line" == *"[Server] Chat:"* ]]; then
        echo "[CHAT DEBUG] Seen in log: $line" >> tracker_debug.log
        
        if [[ "$line" != *"[Discord]"* ]]; then
            RAW_CHAT=$(echo "$line" | sed -n 's/.*Chat: \(.*\)/\1/p')
            P_NAME=$(echo "$RAW_CHAT" | cut -d':' -f1 | xargs)
            P_MSG=$(echo "$RAW_CHAT" | cut -d':' -f2- | xargs)

            if [ -n "$P_NAME" ] && [ -n "$P_MSG" ]; then
                TEMP_SNAME=$(echo "${SERVER_NAME:-Enshrouded Server}" | tr -d '"' | tr -dc '[:print:]')
                CLEAN_MSG=$(echo "$P_MSG" | sed 's/"/\\"/g')

                curl -s --max-time 8 -X POST -H "Content-Type: application/json" \
                -d "{\"username\": \"$P_NAME [$TEMP_SNAME]\", \"content\": \"$CLEAN_MSG\"}" \
                "$CHAT_WEBHOOK"
            fi
        fi
    fi

    # Trigger: Catch the shutdown command to update status embed before exit
    if [[ "$line" == *"Shutting down server"* ]] || [[ "$line" == *"Server stopped"* ]]; then
        echo "[SHUTDOWN] Exit sequence detected!" >> tracker_debug.log
        touch "$FLAG_FILE"
        pkill -P $$ sleep 2>/dev/null
    fi

    # --- Player Connection Logs (Joins) ---
    if [[ "$line" == *"logged in"* ]]; then
        # Extracts everything between "Player '" and "' logged in"
        JOIN_NAME=$(echo "$line" | sed -n "s/.*Player '\(.*\)' logged in.*/\1/p" | xargs)
        
        if [ -n "$JOIN_NAME" ]; then
            if ! grep -qx "$JOIN_NAME" "$LIST_FILE"; then
                echo "$JOIN_NAME" >> "$LIST_FILE"
            fi

            if [ -n "$LOG_WEBHOOK" ]; then
                TEMP_SNAME=$(echo "${SERVER_NAME:-Enshrouded Server}" | tr -d '"' | tr -dc '[:print:]')
                
                cat <<EOF > join_payload.json
{
  "embeds": [{
    "title": "🟢 Player Joined",
    "color": 3066993,
    "fields": [
      {"name": "Player", "value": "$JOIN_NAME", "inline": true},
      {"name": "Server", "value": "$TEMP_SNAME", "inline": false}
    ]
  }]
}
EOF
                curl -s --max-time 5 -H "Content-Type: application/json" -X POST -d @join_payload.json "$LOG_WEBHOOK"
            fi
        fi
    fi

    # --- Player Connection Logs (Leaves) ---
    if [[ "$line" == *"logged out"* ]] || [[ "$line" == *"disconnected"* ]]; then
        # Extracts name for either logged out or disconnected states
        LEAVE_NAME=$(echo "$line" | sed -n "s/.*Player '\(.*\)' logged out.*/\1/p" | xargs)
        if [ -z "$LEAVE_NAME" ]; then
            LEAVE_NAME=$(echo "$line" | sed -n "s/.*Player '\(.*\)' disconnected.*/\1/p" | xargs)
        fi
        
        if [ -n "$LEAVE_NAME" ]; then
            sed -i "/^${LEAVE_NAME}$/d" "$LIST_FILE"
            sed -i '/^$/d' "$LIST_FILE"

            if [ -n "$LOG_WEBHOOK" ]; then
                TEMP_SNAME=$(echo "${SERVER_NAME:-Enshrouded Server}" | tr -d '"' | tr -dc '[:print:]')
                cat <<EOF > leave_payload.json
{
  "embeds": [{
    "title": "🔴 Player Left",
    "color": 15548997,
    "fields": [
      {"name": "Player", "value": "$LEAVE_NAME", "inline": true},
      {"name": "Server", "value": "$TEMP_SNAME", "inline": false}
    ]
  }]
}
EOF
                curl -s --max-time 5 -H "Content-Type: application/json" -X POST -d @leave_payload.json "$LOG_WEBHOOK"
            fi
        fi
    fi
done &
TAIL_PID=$!

# --- Main Discord Loop (Status Embed) ---
while true; do
    CUR_TIME=$(date +'%T')
    CLEAN_SNAME=$(echo "${SERVER_NAME:-Enshrouded Server}" | tr -d '"' | tr -dc '[:print:]')
    
    echo "[HEARTBEAT] Monitor Loop active at $CUR_TIME" >> tracker_debug.log

    if [ -f "$FLAG_FILE" ]; then
        cat <<EOF > payload.json
{
  "username": "$BOT_NAME",
  "avatar_url": "$BOT_LOGO",
  "embeds": [{
    "title": "🎮 Enshrouded Live Server Status",
    "color": 15548997, 
    "fields": [
      {"name": "Server Name", "value": "$CLEAN_SNAME", "inline": false},
      {"name": "Status", "value": "🔴 Offline / Restarting", "inline": true},
      {"name": "Map", "value": "$DISPLAY_MAP", "inline": true},
      {"name": "Current Players", "value": "0", "inline": true},
      {"name": "Online Players", "value": "\`\`\`\nServer is currently offline\n\`\`\`", "inline": false}
    ],
    "footer": {"text": "Last Updated: $CUR_TIME | Skye Serve"}
  }]
}
EOF
        if [ -s "$MSG_ID_FILE" ]; then
            MESSAGE_ID=$(cat "$MSG_ID_FILE")
            curl -s -o /dev/null -X PATCH -H "Content-Type: application/json" \
            -d @payload.json "${DISCORD_WEBHOOK}/messages/${MESSAGE_ID}"
        fi
        rm -f "$FLAG_FILE"
        exit 0
    fi

    PLAYERS=$(grep -c "[^[:space:]]" "$LIST_FILE" | awk '{print $1}')
    [ -z "$PLAYERS" ] && PLAYERS=0

    if [ "$PLAYERS" -eq 0 ]; then
        FINAL_LIST="None online"
    else
        FINAL_LIST=$(sed '/^$/d' "$LIST_FILE" | tr -d '"' | paste -sd ',' - | sed 's/,/\\n/g')
    fi

    cat <<EOF > payload.json
{
  "username": "$BOT_NAME",
  "avatar_url": "$BOT_LOGO",
  "embeds": [{
    "title": "🎮 Enshrouded Live Server Status",
    "color": 5763719,
    "fields": [
      {"name": "Server Name", "value": "$CLEAN_SNAME", "inline": false},
      {"name": "Status", "value": "🟢 Online", "inline": true},
      {"name": "Map", "value": "$DISPLAY_MAP", "inline": true},
      {"name": "Current Players", "value": "$PLAYERS", "inline": true},
      {"name": "Online Players", "value": "\`\`\`\n$FINAL_LIST\n\`\`\`", "inline": false}
    ],
    "footer": {"text": "Last Updated: $CUR_TIME | Skye Serve"}
  }]
}
EOF

    if [ ! -s "$MSG_ID_FILE" ]; then
        RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d @payload.json "${DISCORD_WEBHOOK}?wait=true")
        NEW_ID=$(echo "$RESPONSE" | grep -o '"id":"[0-9]*"' | head -n 1 | cut -d'"' -f4)
        if [[ "$NEW_ID" =~ ^[0-9]+$ ]]; then echo "$NEW_ID" > "$MSG_ID_FILE"; fi
    else
        MESSAGE_ID=$(cat "$MSG_ID_FILE")
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH -H "Content-Type: application/json" \
        -d @payload.json "${DISCORD_WEBHOOK}/messages/${MESSAGE_ID}")
        if [ "$HTTP_CODE" == "404" ]; then rm -f "$MSG_ID_FILE"; fi
    fi

    sleep 5
done
