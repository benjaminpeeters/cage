#!/usr/bin/env bash

# tail.sh - Tail session log
# Usage: cage tail <session>

cage_tail() {
    local session="$1"

    if [ -z "$session" ] || [ "$session" = "--help" ] || [ "$session" = "-h" ]; then
        cat <<'EOF'
cage tail - Tail session log

Usage: cage tail <session>

Arguments:
  session    Session ID (S0_1, cage_2026-01-05_1, etc.)

Examples:
  cage tail S0_1
  cage tail cage_2026-01-05_1
EOF
        return 0
    fi

    local log_file=$(cage_get_session_file "$session" "log")

    if [ ! -f "$log_file" ]; then
        echo -e "${RED}Error:${NC} Log file not found: $log_file"
        return 1
    fi

    echo -e "${CYAN}Tailing session ${session}:${NC} ${log_file}"

    # Calculate header highlight range (from first --- to second ---)
    local header_end=$(head -20 "$log_file" | grep -n "^---$" | sed -n '2p' | cut -d: -f1)
    local highlight_range="2:$((${header_end:-5} - 1))"

    # Calculate terminal width (max 125)
    local term_width=$(($(tput cols) < 125 ? $(tput cols) : 125))

    # Use batcat for markdown highlighting
    tail -n 200 -f "$log_file" | batcat -P -l md -H "$highlight_range" \
        --style grid,snip --theme markdown-custom --terminal-width "$term_width"
}
