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
  session    Session reference (s0-1, cage-2026-01-05-1, a UUID, or a /rename'd name)
  field      Optional jq field selector (.uuid, .profile, etc.)

Metadata Fields:
  uuid        Session UUID for resume
  profile     Tool profile used
  task        Original task text
  start_time  ISO timestamp
  model       Model used
  tools       Allowed tools

Examples:
  cage meta s0-1           # Full metadata
  cage meta s0-1 .uuid     # Just the UUID
  cage meta s0-1 .profile  # Profile name
EOF
        return 0
    fi

    local meta_file=$(cage_get_session_file "$session" "meta.json")

    if [ ! -f "$meta_file" ]; then
        echo -e "${RED}Error:${NC} no metadata for session $session ($meta_file)" >&2
        return 1
    fi

    if [ -n "$field" ]; then
        jq -r "$field" "$meta_file"
    else
        jq '.' "$meta_file"
    fi
}
