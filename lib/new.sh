#!/usr/bin/env bash

# new.sh - Start a new Claude session
# Usage: cage new [options] [profile] "task"

_cage_new_help() {
    # Dynamic help: list profiles from files
    cat <<'EOF'
cage new - Start a new Claude session

Usage: cage new [options] [profile] "task"

By default, starts an interactive foreground session.
With -p, runs non-interactively in the background.

Options:
  -p, --print          Non-interactive background mode (like claude -p)
  -m, --model MODEL    Model override (opus, sonnet, haiku)
  -t, --tail           Tail the log after starting (only with -p)
  --md                 Force markdown output (only with -p)
  --json               Force JSON output (only with -p)
  --result-file PATH   Custom path for result JSON (only with -p)
  -h, --help           Show this help

EOF
    echo "Profiles (positional, before the task):"
    source "$CAGE_ROOT/lib/profile.sh"
    for f in "$CAGE_PROFILES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local name=$(basename "$f" .json)
        local desc="" model="" output="" tools=""
        eval "$(jq -r '"desc=" + (.description // "" | @sh) + " model=" + (.model // "" | @sh) + " output=" + (.output // "" | @sh) + " tools=" + (.tools // "" | @sh)' "$f")"
        printf "  %-10s %s [%s, %s]\n" "$name" "$desc" "$model" "$output"
        printf "             %s\n" "$tools"
    done
    cat <<'EOF'

Model can be overridden with -m: cage new -m opus fast "task"
See 'cage profile' for full profile management.

Examples:
  cage new "Fix the bug in auth.py"
  cage new fast "Quick question about this code"
  cage new explore "Map out the auth module"
  cage new -p web "What are best practices for X?"
  cage new -m opus "Complex refactoring task"
  cage new -pt "Explain this codebase"
EOF
}

cage_new() {
    local print_mode=false
    local tail_mode=false
    local output_override=""
    local model_override=""
    local result_file=""

    # Parse options with GNU getopt
    local opts
    opts=$(getopt -o ptm:h \
                  --long print,tail,model:,md,json,result-file:,help \
                  -n 'cage new' -- "$@") || return 1
    eval set -- "$opts"

    while true; do
        case "$1" in
            -p|--print) print_mode=true; shift ;;
            -t|--tail) tail_mode=true; shift ;;
            -m|--model) model_override="$2"; shift 2 ;;
            --md) output_override="markdown"; shift ;;
            --json) output_override="json"; shift ;;
            --result-file) result_file="$2"; shift 2 ;;
            -h|--help) _cage_new_help; return 0 ;;
            --) shift; break ;;
            *) echo "Internal error"; return 1 ;;
        esac
    done

    # Load profile module
    source "$CAGE_ROOT/lib/profile.sh"

    # Check if first positional arg is a profile name
    local profile="default"
    if [ $# -ge 1 ]; then
        if [ -f "$CAGE_PROFILES_DIR/${1}.json" ]; then
            profile="$1"
            shift
        fi
    fi

    local task="$*"
    cage_load_profile "$profile" || return 1

    local tools="$PROF_TOOLS"
    local model="$PROF_MODEL"
    local sys_prompt="$PROF_SYSTEM_PROMPT"
    local output_format="$PROF_OUTPUT"
    local work_dir="$PROF_CWD"

    # Resolve working directory ("." means caller's cwd)
    if [ "$work_dir" = "." ]; then
        work_dir="$(pwd)"
    fi
    mkdir -p "$work_dir"

    # Overrides take precedence
    [ -n "$model_override" ] && model="$model_override"
    [ -n "$output_override" ] && output_format="$output_override"

    # Generate UUID for session tracking
    local uuid=$(uuidgen)

    # Create organized log directory structure
    local day=$(date +%Y-%m-%d)
    local log_dir="${CAGE_STORAGE}/${day}"
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

    # Store metadata as JSON before running
    jq -n \
        --arg uuid "$uuid" \
        --arg name "$session_name" \
        --arg profile "$profile" \
        --arg task "$task" \
        --arg start_time "$(date -Iseconds)" \
        --arg model "$model" \
        --arg tools "$tools" \
        --arg output "$output_format" \
        --arg cwd "$work_dir" \
        '{uuid: $uuid, name: $name, profile: $profile, task: $task, start_time: $start_time, model: $model, tools: $tools, output: $output, cwd: $cwd}' \
        > "$meta_file"

    # Mode 1: Interactive (default)
    if [ "$print_mode" = false ]; then
        echo -e "${GREEN}✓${NC} Session: ${BOLD}$session_name${NC} (${session_id})"
        echo -e "${GREEN}✓${NC} Profile: ${PURPLE}$profile${NC}  Model: ${CYAN}$model${NC}  CWD: ${CYAN}$work_dir${NC}"
        echo ""
        (cd "$work_dir" && claude --session-id "$uuid" --name "$session_name" --model "$model" --allowedTools "$tools" ${task:+"$task"})
        echo -e "${CYAN}Resume with:${NC} cage resume ${session_id}"
        return
    fi

    # Mode 2: Non-interactive background (with -p)
    local md_mode=false
    [ "$output_format" = "markdown" ] && md_mode=true

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
        output_flags="$CAGE_JSON_OUTPUT_FLAGS"
    fi

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
SESSION_NAME="${11}"
WORK_DIR="${12}"

cd "$WORK_DIR" || exit 1

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
    claude -p "$TASK" \
        --session-id "$UUID" \
        --name "$SESSION_NAME" \
        --model "$MODEL" \
        --allowedTools "$TOOLS" \
        --output-format text >> "$LOG_FILE" 2>&1
    EXIT_CODE=$?
    # For markdown mode, copy log content to result (minus header)
    tail -n +8 "$LOG_FILE" | head -n -3 > "${RESULT_FILE%.json}.md" 2>/dev/null
else
    OUTPUT=$(claude -p "$TASK" \
        --session-id "$UUID" \
        --name "$SESSION_NAME" \
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
        "$session_name" \
        "$work_dir" \
        < /dev/null > /dev/null 2>&1 &

    local pid=$!
    echo $pid > "$pid_file"
    disown

    # Output session info
    echo -e "${GREEN}✓${NC} Started session: ${BOLD}$session_name${NC}"
    echo -e "${GREEN}✓${NC} PID: ${YELLOW}$pid${NC}"
    echo -e "${GREEN}✓${NC} UUID: ${CYAN}${uuid}${NC}"
    echo -e "${GREEN}✓${NC} Profile: ${PURPLE}$profile${NC}  Model: ${CYAN}$model${NC}  Output: ${CYAN}$output_format${NC}"
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
        source "$CAGE_ROOT/lib/tail.sh"
        cage_tail "$session_id"
    fi
}
