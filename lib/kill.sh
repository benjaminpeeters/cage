#!/usr/bin/env bash

# kill.sh - Kill a running session
# Usage: cage kill <session>

cage_kill() {
    local session="$1"

    if [ -z "$session" ] || [ "$session" = "--help" ] || [ "$session" = "-h" ]; then
        cat <<'EOF'
cage kill - Kill a running session

Usage: cage kill <session>

Arguments:
  session    Session ID (S0_1, cage_2026-01-05_1, etc.)

Examples:
  cage kill S0_1
  cage kill cage_2026-01-05_1
EOF
        return 0
    fi

    local pid=$(cage_get_pid "$session")

    if [ -z "$pid" ]; then
        echo -e "${YELLOW}Session $session is not running${NC}"
        return 1
    fi

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        echo -e "${GREEN}✓${NC} Killed session $session (PID: $pid)"

        # Clean up pid file
        local pid_file=$(cage_get_session_file "$session" "pid")
        rm -f "$pid_file"
    else
        echo -e "${YELLOW}Process $pid is not running${NC}"

        # Clean up stale pid file
        local pid_file=$(cage_get_session_file "$session" "pid")
        rm -f "$pid_file"
    fi
}
