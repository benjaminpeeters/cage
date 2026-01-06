#!/usr/bin/env bash

# status.sh - List Claude sessions
# Usage: cage status [max_logs]

cage_status() {
    local max_logs="${1:-10}"

    # Enable nullglob for this function (restore at end)
    local old_nullglob=$(shopt -p nullglob 2>/dev/null)
    shopt -s nullglob

    echo -e "${BOLD}${CYAN}=== Active Sessions ===${NC}"
    local found=false
    local today=$(date +%Y%m%d)

    # Check for active sessions
    local pid_files=("${CAGE_STORAGE}"/cage_*/*.pid)
    for pid_file in "${pid_files[@]}"; do
        [ -f "$pid_file" ] || continue
        local pid=$(cat "$pid_file")
        local session_num=$(basename "$pid_file" .pid | sed 's/cage_//')
        local day_dir=$(dirname "$pid_file")
        local day_raw=$(basename "$day_dir" | sed 's/cage_//')

        # Format date for display
        local day_display=$day_raw

        # Calculate session ID
        local session_id="S$(( ($(date -d "$today" +%s) - $(date -d "${day_raw//-/}" +%s)) / 86400 ))_${session_num}"
        local log_file="${day_dir}/cage_${session_num}.log"

        # Read metadata
        local meta_file="${day_dir}/cage_${session_num}.meta.json"
        local uuid="" profile=""
        if [ -f "$meta_file" ]; then
            uuid=$(jq -r '.uuid // ""' "$meta_file" 2>/dev/null)
            profile=$(jq -r '.profile // "default"' "$meta_file" 2>/dev/null)
        fi

        if kill -0 "$pid" 2>/dev/null; then
            echo -e "• ${GREEN}${session_id}${NC} (${BLUE}${day_display}${NC}) - ${BOLD}${GREEN}RUNNING${NC} (PID: ${YELLOW}$pid${NC})"
            [ -n "$uuid" ] && echo -e "  ${DIM}UUID:${NC} ${CYAN}${uuid}${NC}  ${DIM}Profile:${NC} ${PURPLE}${profile}${NC}"
            echo -e "  ${DIM}Log:${NC} ${CYAN}$log_file${NC}"
            echo -e "  ${DIM}Kill:${NC} cage kill $session_id"
            found=true
        else
            [ -n "$uuid" ] && echo -e "• ${YELLOW}${session_id}${NC} (${BLUE}${day_display}${NC}) - ${DIM}FINISHED${NC}"
            [ -n "$uuid" ] && echo -e "  ${DIM}UUID:${NC} ${CYAN}${uuid}${NC}  ${DIM}Profile:${NC} ${PURPLE}${profile}${NC}"
            rm -f "$pid_file"
            found=true
        fi
        echo ""
    done

    if [ "$found" = false ]; then
        echo -e "${DIM}No active sessions${NC}"
        echo ""
    fi

    echo -e "${BOLD}${PURPLE}=== Recent Logs ===${NC}"
    local count=0

    # Get log files sorted by modification time (newest first)
    local log_files=()
    while IFS= read -r -d '' file; do
        log_files+=("$file")
    done < <(find "${CAGE_STORAGE}"/cage_* -maxdepth 1 -name "*.log" -printf '%T@\t%p\0' 2>/dev/null | sort -rzn | cut -zf2)

    for log_file in "${log_files[@]:0:$max_logs}"; do
        [ -f "$log_file" ] || continue
        local session_num=$(basename "$log_file" .log | sed 's/cage_//')
        local day_dir=$(dirname "$log_file")
        local day_raw=$(basename "$day_dir" | sed 's/cage_//')

        local day_display=$day_raw
        local session_id="S$(( ($(date -d "$today" +%s) - $(date -d "${day_raw//-/}" +%s)) / 86400 ))_${session_num}"
        local size=$(du -h "$log_file" 2>/dev/null | cut -f1)
        local time=$(stat -c '%y' "$log_file" 2>/dev/null | cut -d' ' -f2 | cut -d'.' -f1)

        # Read metadata
        local meta_file="${day_dir}/cage_${session_num}.meta.json"
        local uuid="" profile="" resumable=""
        if [ -f "$meta_file" ]; then
            uuid=$(jq -r '.uuid // ""' "$meta_file" 2>/dev/null)
            profile=$(jq -r '.profile // "default"' "$meta_file" 2>/dev/null)
            [ -n "$uuid" ] && resumable=" ${GREEN}[R]${NC}"
        fi

        echo -e "• ${GREEN}${session_id}${NC} (${BLUE}${day_display} ${time}${NC}) - ${YELLOW}${size}${NC}${resumable}"
        if [ -n "$uuid" ]; then
            echo -e "  ${DIM}UUID:${NC} ${CYAN}${uuid}${NC}  ${DIM}Profile:${NC} ${PURPLE}${profile}${NC}"
            echo -e "  ${DIM}Resume:${NC} cage resume ${session_id}"
        fi
        ((count++))
    done

    if [ $count -eq 0 ]; then
        echo -e "${DIM}No log files found${NC}"
    fi

    # Restore nullglob setting
    eval "$old_nullglob"
}
