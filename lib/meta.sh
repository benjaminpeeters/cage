#!/usr/bin/env bash

# meta.sh - Read session metadata
# Usage: cage meta <session> [field]

cage_meta() {
    local session="$1"
    local field="$2"

    if [ -z "$session" ] || [ "$session" = "--help" ] || [ "$session" = "-h" ]; then
        cat <<'EOF'
cage meta - Read session metadata

Usage: cage meta <session> [field]

Arguments:
  session    Session ID (S0_1, cage_2026-01-05_1, etc.)
  field      Optional jq field selector (.uuid, .profile, etc.)

Metadata Fields:
  uuid        Session UUID for resume
  profile     Tool profile used
  task        Original task text
  start_time  ISO timestamp
  model       Model used
  tools       Allowed tools

Examples:
  cage meta S0_1           # Full metadata
  cage meta S0_1 .uuid     # Just the UUID
  cage meta S0_1 .profile  # Profile name
EOF
        return 0
    fi

    local meta_file=$(cage_get_session_file "$session" "meta.json")

    if [ ! -f "$meta_file" ]; then
        echo "{}"
        return 1
    fi

    if [ -n "$field" ]; then
        jq -r "$field" "$meta_file"
    else
        jq '.' "$meta_file"
    fi
}
