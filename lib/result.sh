#!/usr/bin/env bash

# result.sh - Read session result JSON
# Usage: cage result <session> [field]

cage_result() {
    local session="$1"
    local field="$2"

    if [ -z "$session" ] || [ "$session" = "--help" ] || [ "$session" = "-h" ]; then
        cat <<'EOF'
cage result - Read session result JSON

Usage: cage result <session> [field]

Arguments:
  session    Session ID (S0_1, cage_2026-01-05_1, etc.)
  field      Optional jq field selector (.status, .data.key, etc.)

Result JSON Schema:
{
  "status": "success|error|partial",
  "summary": "Brief description of what was accomplished",
  "files_created": ["path/to/file1.py"],
  "files_modified": ["path/to/existing.py"],
  "files_read": ["path/to/reference.py"],
  "errors": ["Error message if any"],
  "data": {"key": "value"},
  "next_steps": ["Suggested follow-up actions"]
}

Examples:
  cage result S0_1                # Full JSON
  cage result S0_1 .status        # "success", "error", or "partial"
  cage result S0_1 .summary       # Summary text
  cage result S0_1 .files_created # Array of created files
  cage result S0_1 .data.key      # Nested field
EOF
        return 0
    fi

    local result_file=$(cage_get_session_file "$session" "result.json")

    if [ ! -f "$result_file" ]; then
        echo "{}"
        return 1
    fi

    if [ -n "$field" ]; then
        jq -r "$field" "$result_file"
    else
        jq '.' "$result_file"
    fi
}
