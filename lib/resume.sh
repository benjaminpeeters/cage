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
        local session_name="" profile="" orig_cwd="" orig_model=""
        if [ -f "$meta_file" ]; then
            eval "$(jq -r '
                "session_name=" + (.name // "" | @sh) + " " +
                "profile=" + (.profile // "" | @sh) + " " +
                "orig_cwd=" + (.cwd // "" | @sh) + " " +
                "orig_model=" + (.model // "sonnet" | @sh)
            ' "$meta_file" 2>/dev/null)"
        else
            echo -e "${YELLOW}Warning:${NC} metadata file missing for session $session"
        fi

        local display
        if [ -n "$session_name" ]; then display="$session_name ($session)"; else display="$session"; fi
        cage_print_session_header "$display" "$profile" "$orig_model" "${orig_cwd:-$(pwd)}"
        local effective_cwd
        if [ -n "$orig_cwd" ] && [ -d "$orig_cwd" ]; then effective_cwd="$orig_cwd"; else effective_cwd="$(pwd)"; fi
        (cd "$effective_cwd" && claude --resume "$uuid" ${orig_model:+--model "$orig_model"})
        local _exit_code=$?
        local status_file=$(cage_get_session_file "$session" "status")
        if cage_has_conversation "${orig_cwd:-$effective_cwd}" "$uuid"; then
            echo "$_exit_code" > "$status_file"
            cage_print_resume_hint "$session"
        else
            rm -f "$meta_file" "$status_file"
            echo -e "${YELLOW}Session $session had no conversation and has been removed.${NC}"
            echo -e "Start a new session: ${CYAN}cage new${NC}"
        fi
        return $_exit_code
    fi

    # Mode 2: Non-interactive with prompt
    local meta_file=$(cage_get_session_file "$session" "meta.json")
    local orig_profile orig_tools orig_model
    eval "$(jq -r '
        "orig_profile=" + (.profile // "default" | @sh) + " " +
        "orig_tools=" + (.tools // "Bash,Write,Read,Edit,Glob,Grep" | @sh) + " " +
        "orig_model=" + (.model // "sonnet" | @sh)
    ' "$meta_file" 2>/dev/null)"

    # Create new session for tracking
    local day=$(date +%Y-%m-%d)
    local log_dir="${CAGE_STORAGE}/${day}"
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
        output_flags="$CAGE_JSON_OUTPUT_FLAGS"
    fi

    # Store metadata
    jq -n \
        --arg uuid "$new_uuid" \
        --arg name "$new_session" \
        --arg profile "$orig_profile" \
        --arg task "$prompt" \
        --arg start_time "$(date -Iseconds)" \
        --arg model "$orig_model" \
        --arg tools "$orig_tools" \
        --arg parent_session "$session" \
        --arg parent_uuid "$uuid" \
        '{uuid: $uuid, name: $name, profile: $profile, task: $task, start_time: $start_time, model: $model, tools: $tools, parent_session: $parent_session, parent_uuid: $parent_uuid}' \
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
    --name "$new_session" \\
    $fork_flag \\
    --model "$orig_model" \\
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
        source "$CAGE_ROOT/lib/tail.sh"
        cage_tail "$new_session_id"
    fi
}
