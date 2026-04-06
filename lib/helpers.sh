#!/usr/bin/env bash

# helpers.sh - Shared utilities for cage CLI
# Provides session resolution, file path helpers, and color definitions

# Color definitions
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'

# Session storage location
CAGE_STORAGE="/tmp/cage"

# JSON output schema for background sessions
CAGE_JSON_OUTPUT_FLAGS='--output-format json --json-schema {"type":"object","properties":{"status":{"type":"string","enum":["success","error","partial"]},"summary":{"type":"string"},"files_created":{"type":"array","items":{"type":"string"}},"files_modified":{"type":"array","items":{"type":"string"}},"files_read":{"type":"array","items":{"type":"string"}},"errors":{"type":"array","items":{"type":"string"}},"data":{"type":"object"},"next_steps":{"type":"array","items":{"type":"string"}}},"required":["status","summary"]}'

# Parse session ID and return full path to a session file
# Usage: cage_get_session_file "S0_1" "result.json" -> /tmp/cage/2026-01-05/cage_1.result.json
cage_get_session_file() {
    local session="$1"
    local file_type="$2"  # log, pid, status, meta.json, result.json

    local today=$(date +%Y-%m-%d)
    local days_ago=""
    local session_num=""

    # Parse S<days>_<num> format (e.g., S0_1, S1_3)
    if [[ $session =~ ^S([0-9]+)_([0-9]+)$ ]]; then
        days_ago=${BASH_REMATCH[1]}
        session_num=${BASH_REMATCH[2]}
    # Parse cage_YYYY-MM-DD_N format (e.g., cage_2026-01-05_1)
    elif [[ $session =~ ^cage_([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]+)$ ]]; then
        local session_date=${BASH_REMATCH[1]}
        session_num=${BASH_REMATCH[2]}
        # Calculate days ago
        local session_ts=$(date -d "${session_date}" +%s 2>/dev/null)
        local today_ts=$(date +%s)
        days_ago=$(( (today_ts - session_ts) / 86400 ))
    # UUID format: search meta.json files for matching uuid
    elif [[ $session =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        local meta_file
        meta_file=$(grep -l "\"uuid\": \"$session\"" "${CAGE_STORAGE}"/*/*.meta.json 2>/dev/null | head -1)
        if [ -z "$meta_file" ]; then
            echo "No session found for UUID: $session" >&2
            return 1
        fi
        # Extract date and number from meta file path
        local base=$(basename "$meta_file" .meta.json)
        session_num=${base#cage_}
        local dir_date=$(basename "$(dirname "$meta_file")")
        local session_ts=$(date -d "${dir_date}" +%s 2>/dev/null)
        local today_ts=$(date +%s)
        days_ago=$(( (today_ts - session_ts) / 86400 ))
    else
        echo "Invalid session ID format: $session" >&2
        return 1
    fi

    # Calculate target date
    local target_date=$(date -d "$today - $days_ago days" +%Y-%m-%d)

    # Build file path
    local log_dir="${CAGE_STORAGE}/${target_date}"
    local base_path="${log_dir}/cage_${session_num}"

    case "$file_type" in
        log)         echo "${base_path}.log" ;;
        pid)         echo "${base_path}.pid" ;;
        status)      echo "${base_path}.status" ;;
        meta.json)   echo "${base_path}.meta.json" ;;
        result.json) echo "${base_path}.result.json" ;;
        *)           echo "${base_path}.${file_type}" ;;
    esac
}

# Resolve session ID to UUID
# Usage: cage_resolve_uuid "S0_1" -> 351f41fe-ac51-4cfd-8e4f-a8105e0adf8a
cage_resolve_uuid() {
    local session="$1"
    local meta_file=$(cage_get_session_file "$session" "meta.json")

    if [ -f "$meta_file" ]; then
        jq -r '.uuid' "$meta_file" 2>/dev/null
    else
        echo ""
        return 1
    fi
}

# Get session log directory for a given date offset
# Usage: cage_get_log_dir 0 -> /tmp/cage/2026-01-05 (today)
cage_get_log_dir() {
    local days_ago="${1:-0}"
    local today=$(date +%Y-%m-%d)
    local target_date=$(date -d "$today - $days_ago days" +%Y-%m-%d)
    echo "${CAGE_STORAGE}/${target_date}"
}

# Get next available session number for today
# Usage: cage_next_session_num -> 1 (or next available)
cage_next_session_num() {
    local log_dir=$(cage_get_log_dir 0)
    mkdir -p "$log_dir"

    local session_num=1
    while [ -f "${log_dir}/cage_${session_num}.log" ] || [ -f "${log_dir}/cage_${session_num}.pid" ] || [ -f "${log_dir}/cage_${session_num}.meta.json" ]; do
        ((session_num++))
    done
    echo "$session_num"
}

# Print session info header before launching claude
# Usage: cage_print_session_header "cage_2026-04-04_2 (S0_2)" profile model cwd
cage_print_session_header() {
    local session_display="$1"
    local profile="$2"
    local model="$3"
    local cwd="$4"
    echo -e "${GREEN}✓${NC} Session: ${BOLD}${session_display}${NC}"
    echo -e "${GREEN}✓${NC} Profile: ${PURPLE}${profile}${NC}  Model: ${CYAN}${model}${NC}  CWD: ${CYAN}${cwd}${NC}"
    echo ""
}

# Print resume hint after claude exits
# Usage: cage_print_resume_hint session_id
cage_print_resume_hint() {
    local session_id="$1"
    echo -e "${CYAN}Resume with:${NC} cage resume ${session_id}"
}

# Check if Claude stored a conversation for a session
# Returns 0 if conversation file exists, 1 otherwise
# Usage: cage_has_conversation cwd uuid
cage_has_conversation() {
    local cwd="$1" uuid="$2"
    [ -n "$cwd" ] && [ -n "$uuid" ] || return 1
    local slug="${cwd//\//-}"
    [ -f "${HOME}/.claude/projects/${slug}/${uuid}.jsonl" ]
}

# Resolve session status label from pid/status/log files
# Sets globals: _cage_status (colored label), _cage_running (true/false), _cage_pid (PID if running)
# Usage: cage_resolve_status pid_file status_file log_file
cage_resolve_status() {
    local pid_file="$1" status_file="$2" log_file="$3"
    _cage_running=false
    _cage_status="${DIM}FINISHED${NC}"
    _cage_pid=""

    local pid=""
    [ -f "$pid_file" ] && read -r pid < "$pid_file"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        _cage_status="${BOLD}${GREEN}RUNNING${NC}"
        _cage_running=true
        _cage_pid="$pid"
    elif [ -f "$status_file" ]; then
        local exit_code=""
        read -r exit_code < "$status_file"
        if [ "$exit_code" = "0" ]; then
            if [ -f "$log_file" ]; then
                local size; size=$(du -h "$log_file" 2>/dev/null | cut -f1)
                _cage_status="${GREEN}SUCCESS${NC} (${size})"
            else
                _cage_status="${GREEN}FINISHED${NC}"
            fi
        elif [ -n "$exit_code" ]; then
            _cage_status="${RED}FAILED${NC} (exit $exit_code)"
        fi
    elif [ -f "$log_file" ]; then
        local size; size=$(du -h "$log_file" 2>/dev/null | cut -f1)
        _cage_status="${DIM}UNKNOWN${NC} (${size})"
    fi
}

# Wrap interactive claude session with PID tracking and terminal background color
# Usage: cage_interactive_start "$pid_file"; ...; cage_interactive_end "$pid_file"
cage_interactive_start() {
    local pid_file="$1"
    echo $$ > "$pid_file"
    [ -t 1 ] && printf '\e]11;%s\a' "${COLOR_bg_claude:-#301000}"
}

cage_interactive_end() {
    local pid_file="$1"
    [ -t 1 ] && printf '\e]11;%s\a' "${COLOR_bg_shell:-#300020}"
    rm -f "$pid_file"
}

# Check if a session is currently running
# Usage: cage_is_running "S0_1" -> 0 (running) or 1 (not running)
cage_is_running() {
    local session="$1"
    local pid_file=$(cage_get_session_file "$session" "pid")

    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Get session PID if running
# Usage: cage_get_pid "S0_1" -> 12345 or empty
cage_get_pid() {
    local session="$1"
    local pid_file=$(cage_get_session_file "$session" "pid")

    if [ -f "$pid_file" ]; then
        cat "$pid_file"
    fi
}
