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
  session    Session reference (s0-1, cage-2026-01-05-1, a UUID, or a /rename'd name)
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
  cage result s0-1                # Full JSON
  cage result s0-1 .status        # "success", "error", or "partial"
  cage result s0-1 .summary       # Summary text
  cage result s0-1 .files_created # Array of created files
  cage result s0-1 .data.key      # Nested field
EOF
        return 0
    fi

    local result_file=$(cage_get_session_file "$session" "result.json")

    if [ ! -f "$result_file" ]; then
        echo -e "${RED}Error:${NC} no result for session $session ($result_file)" >&2
        return 1
    fi

    # claude --output-format json wraps the schema'd payload in a result
    # envelope under .structured_output; unwrap so fields match the schema
    # documented above (files that already hold the bare payload pass through).
    if [ -n "$field" ]; then
        jq -r ".structured_output // . | $field" "$result_file"
    else
        jq '.structured_output // .' "$result_file"
    fi
}
