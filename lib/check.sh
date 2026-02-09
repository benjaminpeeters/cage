#!/usr/bin/env bash

# check.sh - Open session log in nvim
# Usage: cage check [session]

cage_check() {
    local session="$1"

    if [ "$session" = "--help" ] || [ "$session" = "-h" ]; then
        cat <<'EOF'
cage check - Open session log in nvim

Usage: cage check [session]

Arguments:
  session    Session ID (S0_1, cage_2026-01-05_1, etc.)
             If omitted, opens the most recent log.

Examples:
  cage check          # Open most recent log
  cage check S0_1     # Open specific session
EOF
        return 0
    fi

    local log_file=""

    if [ -n "$session" ]; then
        log_file=$(cage_get_session_file "$session" "log")
    else
        # Find most recent log across all cage directories
        log_file=$(find "${CAGE_STORAGE}"/cage_* -maxdepth 1 -name "*.log" -printf '%T@\t%p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -f2)
    fi

    if [ -z "$log_file" ] || [ ! -f "$log_file" ]; then
        echo -e "${RED}Error:${NC} No log file found${log_file:+: $log_file}"
        return 1
    fi

    echo -e "${CYAN}Opening:${NC} ${log_file}"
    nvim "$log_file"
}
