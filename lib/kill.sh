#!/usr/bin/env bash

# kill.sh - Kill a running session
# Usage: cage kill <session>

# TERM a process and ALL its descendants, deepest first. claude sits two
# levels below the recorded pid (wrapper bash -> command-substitution subshell
# -> claude), so neither kill nor pkill -P reaches it on their own.
_cage_kill_tree() {
    local p
    for p in $(pgrep -P "$1"); do
        _cage_kill_tree "$p"
    done
    kill -TERM "$1" 2>/dev/null
}

cage_kill() {
    local session="$1"

    if [ -z "$session" ] || [ "$session" = "--help" ] || [ "$session" = "-h" ]; then
        cat <<'EOF'
cage kill - Kill a running session

Usage: cage kill <session>

Arguments:
  session    Session reference (s0-1, cage-2026-01-05-1, a UUID, or a /rename'd name)

Examples:
  cage kill s0-1
  cage kill cage-2026-01-05-1
EOF
        return 0
    fi

    local pid=$(cage_get_pid "$session")

    if [ -z "$pid" ]; then
        echo -e "${YELLOW}Session $session is not running${NC}"
        return 1
    fi

    if kill -0 "$pid" 2>/dev/null; then
        # Kill the whole descendant tree: an orphaned claude would keep
        # writing the transcript while the pid-file removal below unblocks
        # cage_refuse_if_running (the double-claude case the guard prevents).
        _cage_kill_tree "$pid"
        echo -e "${GREEN}✓${NC} Killed session $session (PID: $pid)"

        # Clean up pid file
        local pid_file=$(cage_get_session_file "$session" "pid")
        rm -f "$pid_file"
    else
        echo -e "${YELLOW}Process $pid is not running${NC}" >&2

        # Clean up stale pid file
        local pid_file=$(cage_get_session_file "$session" "pid")
        rm -f "$pid_file"
        return 1
    fi
}
