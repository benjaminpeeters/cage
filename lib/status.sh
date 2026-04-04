#!/usr/bin/env bash

# status.sh - List Claude sessions
# Usage: cage status [session|max_logs]

# Display details for a single session
_cage_status_single() {
    local session="$1"
    local today=$(date +%Y%m%d)

    local meta_file=$(cage_get_session_file "$session" "meta.json")
    if [ ! -f "$meta_file" ]; then
        echo -e "${RED}Error:${NC} Session not found: $session"
        return 1
    fi

    local log_file=$(cage_get_session_file "$session" "log")
    local pid_file=$(cage_get_session_file "$session" "pid")
    local status_file=$(cage_get_session_file "$session" "status")
    local result_file=$(cage_get_session_file "$session" "result.json")

    local uuid name profile task start_time model tools
    eval "$(jq -r '
        "uuid=" + (.uuid // "" | @sh) + " " +
        "name=" + (.name // "" | @sh) + " " +
        "profile=" + (.profile // "default" | @sh) + " " +
        "task=" + (.task // "" | @sh) + " " +
        "start_time=" + (.start_time // "" | @sh) + " " +
        "model=" + (.model // "" | @sh) + " " +
        "tools=" + (.tools // "" | @sh)
    ' "$meta_file" 2>/dev/null)"

    # Determine status
    cage_resolve_status "$pid_file" "$status_file" "$log_file"
    local status="$_cage_status"
    local running="$_cage_running"
    local pid="$_cage_pid"
    # Clean up stale pid files
    if [ "$running" = false ] && [ -f "$pid_file" ]; then
        rm -f "$pid_file"
    fi

    # Calculate duration
    local duration=""
    if [ -n "$start_time" ]; then
        local start_ts=$(date -d "$start_time" +%s 2>/dev/null)
        if [ -n "$start_ts" ]; then
            local end_ts
            if [ "$running" = true ]; then
                end_ts=$(date +%s)
            elif [ -f "$log_file" ]; then
                end_ts=$(stat -c '%Y' "$log_file" 2>/dev/null)
            else
                end_ts=$(date +%s)
            fi
            local elapsed=$((end_ts - start_ts))
            if [ $elapsed -ge 3600 ]; then
                duration="$((elapsed / 3600))h$((elapsed % 3600 / 60))m"
            elif [ $elapsed -ge 60 ]; then
                duration="$((elapsed / 60))m$((elapsed % 60))s"
            else
                duration="${elapsed}s"
            fi
            [ "$running" = true ] && duration="${duration} (ongoing)"
        fi
    fi

    # Resolve session ID for display
    local day_dir=$(dirname "$log_file")
    local day_raw=$(basename "$day_dir")
    local session_num=$(basename "$log_file" .log | sed 's/cage_//')
    local session_id="S$(( ($(date -d "$today" +%s) - $(date -d "${day_raw//-/}" +%s)) / 86400 ))_${session_num}"

    echo -e "${BOLD}Session: ${GREEN}${session_id}${NC} ${DIM}(${name})${NC}"
    echo -e "  ${DIM}Status:${NC}   $status"
    [ -n "$duration" ] && echo -e "  ${DIM}Duration:${NC} ${YELLOW}$duration${NC}"
    [ -n "$pid" ] && [ "$running" = true ] && echo -e "  ${DIM}PID:${NC}      ${YELLOW}$pid${NC}"
    [ -n "$uuid" ] && echo -e "  ${DIM}UUID:${NC}     ${CYAN}$uuid${NC}"
    [ -n "$profile" ] && echo -e "  ${DIM}Profile:${NC}  ${PURPLE}$profile${NC}"
    [ -n "$model" ] && echo -e "  ${DIM}Model:${NC}    $model"
    [ -n "$tools" ] && echo -e "  ${DIM}Tools:${NC}    $tools"
    [ -n "$start_time" ] && echo -e "  ${DIM}Started:${NC}  $start_time"
    echo -e "  ${DIM}Task:${NC}     ${task:0:120}"
    echo -e "  ${DIM}Log:${NC}      ${CYAN}$log_file${NC}"
    [ -f "$result_file" ] && echo -e "  ${DIM}Result:${NC}  ${CYAN}$result_file${NC}"
}

# Resolve a PID to a session by searching pid files
_cage_resolve_pid() {
    local target_pid="$1"
    local pid_file
    for pid_file in "${CAGE_STORAGE}"/*/*.pid; do
        [ -f "$pid_file" ] || continue
        local pid=""
        read -r pid < "$pid_file" 2>/dev/null
        if [ "$pid" = "$target_pid" ]; then
            local session_num=$(basename "$pid_file" .pid | sed 's/cage_//')
            local day_raw=$(basename "$(dirname "$pid_file")")
            local today=$(date +%Y-%m-%d)
            local session_ts=$(date -d "${day_raw}" +%s 2>/dev/null)
            local today_ts=$(date +%s)
            local days_ago=$(( (today_ts - session_ts) / 86400 ))
            echo "S${days_ago}_${session_num}"
            return 0
        fi
    done
    return 1
}

cage_status() {
    local arg="$1"

    # Enable nullglob for this function (restore on return)
    local old_nullglob=$(shopt -p nullglob 2>/dev/null)
    shopt -s nullglob
    trap 'eval "$old_nullglob"' RETURN

    # If argument looks like a session identifier, show single session
    if [ -n "$arg" ]; then
        local resolved=""
        # S<n>_<n> or cage_YYYY-MM-DD_N or UUID
        if [[ $arg =~ ^S[0-9]+_[0-9]+$ ]] || \
           [[ $arg =~ ^cage_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]+$ ]] || \
           [[ $arg =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            resolved="$arg"
        # Pure number: could be max_logs or a PID (PIDs are > 100)
        elif [[ $arg =~ ^[0-9]+$ ]] && [ "$arg" -gt 100 ]; then
            # Try as PID first
            resolved=$(_cage_resolve_pid "$arg")
            if [ -z "$resolved" ]; then
                _cage_status_list "$arg"
                return
            fi
        fi

        if [ -n "$resolved" ]; then
            _cage_status_single "$resolved"
            return
        fi
    fi

    _cage_status_list "${arg:-10}"
}

_cage_status_list() {
    local max_logs="$1"
    local today=$(date +%Y%m%d)

    echo -e "${BOLD}${PURPLE}=== Sessions ===${NC}"
    local count=0

    # Scan meta.json files (covers both interactive and background sessions)
    local meta_files=()
    while IFS= read -r -d '' file; do
        meta_files+=("$file")
    done < <(find "${CAGE_STORAGE}"/* -maxdepth 1 -name "*.meta.json" -printf '%T@\t%p\0' 2>/dev/null | sort -rzn | cut -zf2)

    for meta_file in "${meta_files[@]:0:$max_logs}"; do
        [ -f "$meta_file" ] || continue
        local session_num=$(basename "$meta_file" .meta.json | sed 's/cage_//')
        local day_dir=$(dirname "$meta_file")
        local day_raw=$(basename "$day_dir")
        local session_id="S$(( ($(date -d "$today" +%s) - $(date -d "${day_raw//-/}" +%s)) / 86400 ))_${session_num}"

        local uuid="" profile="" start_time=""
        eval "$(jq -r '
            "uuid=" + (.uuid // "" | @sh) + " " +
            "profile=" + (.profile // "default" | @sh) + " " +
            "start_time=" + (.start_time // "" | @sh)
        ' "$meta_file" 2>/dev/null)"

        local time="${start_time:0:19}"; time="${time/T/ }"
        [ -z "$time" ] && time=$(stat -c '%y' "$meta_file" 2>/dev/null | cut -d'.' -f1)

        local log_file="${day_dir}/cage_${session_num}.log"
        local status_file="${day_dir}/cage_${session_num}.status"
        local pid_file="${day_dir}/cage_${session_num}.pid"

        # Determine status label
        cage_resolve_status "$pid_file" "$status_file" "$log_file"
        local status_label="$_cage_status"

        echo -e "• ${GREEN}${session_id}${NC} (${BLUE}${time}${NC}) - ${status_label}"
        echo -e "  ${DIM}UUID:${NC} ${CYAN}${uuid}${NC}  ${DIM}Profile:${NC} ${PURPLE}${profile}${NC}"
        echo -e "  ${DIM}Resume:${NC} cage resume ${session_id}"
        ((count++))
    done

    if [ $count -eq 0 ]; then
        echo -e "${DIM}No sessions found${NC}"
    fi
}
