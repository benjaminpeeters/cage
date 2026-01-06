#!/usr/bin/env bash

# new.sh - Start a new background Claude session
# Usage: cage new [options] "task"

_cage_new_help() {
    cat <<'EOF'
cage new - Start a new background Claude session

Usage: cage new [options] "task"

Options:
  -t, --tail           Automatically tail the log after starting
  -m, --md             Output in markdown (default: JSON for inter-agent use)
  -p, --profile NAME   Tool preset: explore|write|research|full|default
  --result-file PATH   Custom path for result JSON
  -h, --help           Show this help

Profiles:
  explore   Codebase exploration (Glob, Grep, Read, limited Bash)
  write     Code writing (Read, Write, Edit, Glob, Grep, Bash)
  research  Online research (Read, Glob, Grep, WebSearch, WebFetch)
  full      All tools including TodoWrite
  default   General purpose tools

Examples:
  cage new "Fix the bug in auth.py"
  cage new -p research "What are best practices for X?"
  cage new -mt "Explain this codebase"
EOF
}

cage_new() {
    local tail_mode=false
    local md_mode=false
    local profile="default"
    local result_file=""

    # Parse options with GNU getopt
    local opts
    opts=$(getopt -o tmp:h \
                  --long tail,md,profile:,result-file:,help \
                  -n 'cage new' -- "$@") || return 1
    eval set -- "$opts"

    while true; do
        case "$1" in
            -t|--tail) tail_mode=true; shift ;;
            -m|--md) md_mode=true; shift ;;
            -p|--profile) profile="$2"; shift 2 ;;
            --result-file) result_file="$2"; shift 2 ;;
            -h|--help) _cage_new_help; return 0 ;;
            --) shift; break ;;
            *) echo "Internal error"; return 1 ;;
        esac
    done

    local task="$*"

    if [ -z "$task" ]; then
        echo "Error: No task provided"
        echo "Usage: cage new [options] \"task\""
        return 1
    fi

    # Generate UUID for session tracking
    local uuid=$(uuidgen)

    # Profile definitions: tools, model, system prompt
    local tools model sys_prompt
    case $profile in
        explore)
            tools="Glob,Grep,Read,Bash(ls:*),Bash(find:*),Bash(tree:*)"
            model="opus"
            sys_prompt="Focus on finding and listing relevant files and code patterns."
            ;;
        write)
            tools="Read,Write,Edit,Glob,Grep,Bash"
            model="opus"
            sys_prompt="Write clean, minimal code. Follow existing patterns."
            ;;
        research)
            tools="Read,Glob,Grep,WebSearch,WebFetch"
            model="opus"
            sys_prompt="Search online for current information. Cite sources."
            ;;
        full)
            tools="Bash,Write,Read,Edit,Glob,Grep,WebSearch,WebFetch,TodoWrite"
            model="opus"
            sys_prompt="Complete complex multi-step tasks thoroughly."
            ;;
        *)  # default
            tools="Bash,Write,Read,Edit,Glob,Grep"
            model="opus"
            sys_prompt=""
            ;;
    esac

    # Create organized log directory structure
    local day=$(date +%Y-%m-%d)
    local log_dir="${CAGE_STORAGE}/cage_${day}"
    mkdir -p "$log_dir"

    # Find next session number for today
    local session_num=$(cage_next_session_num)

    local session_name="cage_${day}_${session_num}"
    local session_id="S0_${session_num}"
    local log_file="${log_dir}/cage_${session_num}.log"
    local pid_file="${log_dir}/cage_${session_num}.pid"
    local meta_file="${log_dir}/cage_${session_num}.meta.json"
    local status_file="${log_dir}/cage_${session_num}.status"

    # Set default result file if not specified
    [ -z "$result_file" ] && result_file="${log_dir}/cage_${session_num}.result.json"

    # Build final task with system prompt
    local final_task="$task"
    [ -n "$sys_prompt" ] && final_task="$sys_prompt

$task"

    # Build output flags based on mode
    local output_flags
    if [ "$md_mode" = true ]; then
        final_task="$final_task

Write your response in clean markdown format without bold formatting.
Use headers, lists, and code blocks as appropriate.
By default, use the International System of Units."
        output_flags="--output-format text"
    else
        output_flags='--output-format json --json-schema {"type":"object","properties":{"status":{"type":"string","enum":["success","error","partial"]},"summary":{"type":"string"},"files_created":{"type":"array","items":{"type":"string"}},"files_modified":{"type":"array","items":{"type":"string"}},"files_read":{"type":"array","items":{"type":"string"}},"errors":{"type":"array","items":{"type":"string"}},"data":{"type":"object"},"next_steps":{"type":"array","items":{"type":"string"}}},"required":["status","summary"]}'
    fi

    # Store metadata as JSON before running
    jq -n \
        --arg uuid "$uuid" \
        --arg profile "$profile" \
        --arg task "$task" \
        --arg start_time "$(date -Iseconds)" \
        --arg model "$model" \
        --arg tools "$tools" \
        '{uuid: $uuid, profile: $profile, task: $task, start_time: $start_time, model: $model, tools: $tools}' \
        > "$meta_file"

    # Create wrapper script
    local wrapper_script="/tmp/cage_wrapper_${session_name}.sh"
    cat > "$wrapper_script" << 'WRAPPER_EOF'
#!/bin/bash
LOG_FILE="$1"
PID_FILE="$2"
RESULT_FILE="$3"
TASK="$4"
TOOLS="$5"
MODEL="$6"
OUTPUT_FLAGS="$7"
UUID="$8"
STATUS_FILE="$9"
MD_MODE="${10}"

# Add session info to log
{
    echo "---"
    echo "Start: $(date)"
    echo "PID: $$"
    echo "UUID: $UUID"
    echo "Model: $MODEL"
    echo "Task: $TASK"
    echo "---"
} > "$LOG_FILE"

# Run Claude and capture output
if [ "$MD_MODE" = "true" ]; then
    ~/.claude/local/claude -p "$TASK" \
        --session-id "$UUID" \
        --model "$MODEL" \
        --allowedTools "$TOOLS" \
        --output-format text >> "$LOG_FILE" 2>&1
    EXIT_CODE=$?
    # For markdown mode, copy log content to result (minus header)
    tail -n +8 "$LOG_FILE" | head -n -3 > "${RESULT_FILE%.json}.md" 2>/dev/null
else
    OUTPUT=$(~/.claude/local/claude -p "$TASK" \
        --session-id "$UUID" \
        --model "$MODEL" \
        --allowedTools "$TOOLS" \
        $OUTPUT_FLAGS 2>&1)
    EXIT_CODE=$?
    echo "$OUTPUT" >> "$LOG_FILE"
    echo "$OUTPUT" > "$RESULT_FILE"
fi

echo "$EXIT_CODE" > "$STATUS_FILE"

{
    echo "~~~"
    echo "Exit code: $EXIT_CODE"
    echo "Session ended at $(date)"
} >> "$LOG_FILE"

rm -f "$PID_FILE"
rm -f "$0"
WRAPPER_EOF

    chmod +x "$wrapper_script"

    # Run in background
    nohup "$wrapper_script" \
        "$log_file" \
        "$pid_file" \
        "$result_file" \
        "$final_task" \
        "$tools" \
        "$model" \
        "$output_flags" \
        "$uuid" \
        "$status_file" \
        "$md_mode" \
        < /dev/null > /dev/null 2>&1 &

    local pid=$!
    echo $pid > "$pid_file"
    disown

    # Output session info
    echo -e "${GREEN}✓${NC} Started session: ${BOLD}$session_name${NC}"
    echo -e "${GREEN}✓${NC} PID: ${YELLOW}$pid${NC}"
    echo -e "${GREEN}✓${NC} UUID: ${CYAN}${uuid}${NC}"
    echo -e "${GREEN}✓${NC} Profile: ${PURPLE}$profile${NC}"
    echo -e "${GREEN}✓${NC} Log: ${CYAN}$log_file${NC}"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${BLUE}Check logs:${NC}    tail -f $log_file"
    echo -e "  ${BLUE}Check status:${NC}  cage status"
    echo -e "  ${BLUE}Read result:${NC}   cage result $session_id"
    echo -e "  ${BLUE}Resume later:${NC}  cage resume $session_id"
    echo -e "  ${BLUE}Kill process:${NC}  cage kill $session_id"

    # If tail mode is enabled, launch cage tail after a brief pause
    if [ "$tail_mode" = true ]; then
        echo ""
        echo -e "${DIM}Launching tail mode in 2s...${NC}"
        sleep 2
        source "$CAGE_ROOT/lib/tail.sh"
        cage_tail "$session_id"
    fi
}
