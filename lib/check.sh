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
  session    Session reference (s0-1, cage-2026-01-05-1, a UUID, or a /rename'd name)
             If omitted, opens the most recent log.

Examples:
  cage check          # Open most recent log
  cage check s0-1     # Open specific session
EOF
        return 0
    fi

    local log_file=""

    if [ -n "$session" ]; then
        log_file=$(cage_get_session_file "$session" "log")
    else
        # Find most recent log across all cage directories. find gets the
        # storage root itself (never a glob): an unmatched glob under nullglob
        # would leave find with zero operands and it defaults to '.'
        log_file=$(find "${CAGE_STORAGE}" -mindepth 2 -maxdepth 2 -name "*.log" -printf '%T@\t%p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -f2)
    fi

    if [ -z "$log_file" ] || [ ! -f "$log_file" ]; then
        echo -e "${RED}Error:${NC} No log file found${log_file:+: $log_file}" >&2
        return 1
    fi

    echo -e "${CYAN}Opening:${NC} ${log_file}"
    nvim "$log_file"
}
