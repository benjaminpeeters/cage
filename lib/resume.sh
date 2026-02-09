#!/usr/bin/env bash

# resume.sh - Resume an existing Claude session
# Usage: cage resume <session> [options]

_cage_resume_help() {
    cat <<'EOF'
cage resume - Resume an existing Claude session

Usage: cage resume <session> [options]

Arguments:
  session    Session ID (S0_1, cage_2026-01-05_1, etc.)

Options:
  -p, --prompt TEXT    Non-interactive mode with prompt
  -f, --fork           Fork session (new branch, preserves original)
  -m, --md             Markdown output (default: JSON)
  -t, --tail           Tail log after starting (non-interactive only)
  -h, --help           Show this help

Examples:
  cage resume S0_3                         # Interactive
  cage resume S0_3 -p "add tests"          # Non-interactive
  cage resume S0_3 -p "task" --fork        # Fork session
  cage resume S0_3 -p "task" -mt           # Markdown + tail
EOF
}

cage_resume() {
    local session=""
    local prompt=""
    local fork_mode=false
    local tail_mode=false
    local md_mode=false

    # Parse options with GNU getopt
    local opts
    opts=$(getopt -o p:tfmh \
                  --long prompt:,tail,fork,md,help \
                  -n 'cage resume' -- "$@") || return 1
    eval set -- "$opts"

    while true; do
        case "$1" in
            -p|--prompt) prompt="$2"; shift 2 ;;
            -t|--tail) tail_mode=true; shift ;;
            -f|--fork) fork_mode=true; shift ;;
            -m|--md) md_mode=true; shift ;;
            -h|--help) _cage_resume_help; return 0 ;;
            --) shift; break ;;
            *) echo "Internal error"; return 1 ;;
        esac
    done

    # Remaining argument is the session
    session="$1"

    if [ -z "$session" ]; then
        echo "Error: No session provided"
        echo "Usage: cage resume <session> [options]"
        return 1
    fi

    local uuid=$(cage_resolve_uuid "$session")
    if [ -z "$uuid" ]; then
        echo -e "${RED}Error:${NC} Session not found: $session"
        echo "Use 'cage status' to see available sessions."
        return 1
    fi

    # Mode 1: Interactive (no prompt)
    if [ -z "$prompt" ]; then
        local meta_file=$(cage_get_session_file "$session" "meta.json")
        if [ -f "$meta_file" ]; then
            local task=$(jq -r '.task' "$meta_file" 2>/dev/null)
            local profile=$(jq -r '.profile' "$meta_file" 2>/dev/null)
            echo -e "${CYAN}Resuming session:${NC} $session"
            echo -e "${CYAN}UUID:${NC} $uuid"
            echo -e "${CYAN}Profile:${NC} $profile"
            echo -e "${CYAN}Original task:${NC} ${task:0:80}..."
            echo ""
        fi
        claude --resume "$uuid"
        return
    fi

    # Mode 2: Non-interactive with prompt
    local meta_file=$(cage_get_session_file "$session" "meta.json")
    local orig_profile=$(jq -r '.profile // "default"' "$meta_file" 2>/dev/null)
    local orig_tools=$(jq -r '.tools // "Bash,Write,Read,Edit,Glob,Grep"' "$meta_file" 2>/dev/null)

    # Create new session for tracking
    local day=$(date +%Y-%m-%d)
    local log_dir="${CAGE_STORAGE}/cage_${day}"
    mkdir -p "$log_dir"

    local session_num=$(cage_next_session_num)
    local new_session="cage_${day}_${session_num}"
    local new_session_id="S0_${session_num}"
    local new_uuid=$(uuidgen)
    local log_file="${log_dir}/cage_${session_num}.log"
    local pid_file="${log_dir}/cage_${session_num}.pid"
    local result_file="${log_dir}/cage_${session_num}.result.json"
    local new_meta_file="${log_dir}/cage_${session_num}.meta.json"
    local status_file="${log_dir}/cage_${session_num}.status"

    # Build fork flag
    local fork_flag=""
    [ "$fork_mode" = true ] && fork_flag="--fork-session"

    # Build output flags
    local output_flags
    if [ "$md_mode" = true ]; then
        output_flags="--output-format text"
    else
        output_flags='--output-format json --json-schema {"type":"object","properties":{"status":{"type":"string","enum":["success","error","partial"]},"summary":{"type":"string"},"files_created":{"type":"array","items":{"type":"string"}},"files_modified":{"type":"array","items":{"type":"string"}},"files_read":{"type":"array","items":{"type":"string"}},"errors":{"type":"array","items":{"type":"string"}},"data":{"type":"object"},"next_steps":{"type":"array","items":{"type":"string"}}},"required":["status","summary"]}'
    fi

    # Store metadata
    jq -n \
        --arg uuid "$new_uuid" \
        --arg profile "$orig_profile" \
        --arg task "$prompt" \
        --arg start_time "$(date -Iseconds)" \
        --arg model "opus" \
        --arg tools "$orig_tools" \
        --arg parent_session "$session" \
        --arg parent_uuid "$uuid" \
        '{uuid: $uuid, profile: $profile, task: $task, start_time: $start_time, model: $model, tools: $tools, parent_session: $parent_session, parent_uuid: $parent_uuid}' \
        > "$new_meta_file"

    # Create wrapper script
    local wrapper_script="/tmp/cage_wrapper_${new_session}.sh"
    cat > "$wrapper_script" << WRAPPER_EOF
#!/bin/bash
LOG_FILE="$log_file"
RESULT_FILE="$result_file"
STATUS_FILE="$status_file"
PID_FILE="$pid_file"

{
    echo "---"
    echo "Start: \$(date)"
    echo "PID: \$\$"
    echo "UUID: $new_uuid"
    echo "Parent UUID: $uuid"
    echo "Task: $prompt"
    echo "---"
} > "\$LOG_FILE"

OUTPUT=\$(claude -p "$prompt" \\
    --resume "$uuid" \\
    $fork_flag \\
    --model opus \\
    --allowedTools "$orig_tools" \\
    $output_flags 2>&1)
EXIT_CODE=\$?

echo "\$OUTPUT" >> "\$LOG_FILE"
echo "\$OUTPUT" > "\$RESULT_FILE"
echo "\$EXIT_CODE" > "\$STATUS_FILE"

{
    echo "~~~"
    echo "Exit code: \$EXIT_CODE"
    echo "Session ended at \$(date)"
} >> "\$LOG_FILE"

rm -f "\$PID_FILE"
rm -f "\$0"
WRAPPER_EOF

    chmod +x "$wrapper_script"

    # Run in background
    nohup "$wrapper_script" < /dev/null > /dev/null 2>&1 &

    local pid=$!
    echo $pid > "$pid_file"
    disown

    echo -e "${GREEN}✓${NC} Resumed from: ${BOLD}$session${NC}"
    echo -e "${GREEN}✓${NC} New session: ${BOLD}$new_session${NC}"
    echo -e "${GREEN}✓${NC} PID: ${YELLOW}$pid${NC}"
    echo -e "${GREEN}✓${NC} UUID: ${CYAN}${new_uuid}${NC}"
    echo -e "${GREEN}✓${NC} Log: ${CYAN}$log_file${NC}"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${BLUE}Check logs:${NC}    tail -f $log_file"
    echo -e "  ${BLUE}Read result:${NC}   cage result $new_session_id"

    if [ "$tail_mode" = true ]; then
        echo ""
        echo -e "${DIM}Launching tail mode in 2s...${NC}"
        sleep 2
        source "$CAGE_ROOT/lib/tail.sh"
        cage_tail "$new_session_id"
    fi
}
