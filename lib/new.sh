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

When an interactive session ends, your shell cd's into the session's working
directory (via the cage() shell wrapper; deliberately not standard Unix
child-process behavior — 'command cage' bypasses it).

Options:
  -p, --print          Non-interactive background mode (like claude -p)
  -m, --model MODEL    Model override (opus[1m], sonnet, haiku)
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
        _cage_profile_summary_fields "$f"
        printf "  %-10s %s [%s, %s, %s]\n" "$name" "$PSUM_DESC" "$PSUM_MODEL" "$PSUM_EFFORT" "$PSUM_OUTPUT"
        printf "             %s\n" "$PSUM_TOOLS"
    done
    cat <<'EOF'

Model can be overridden with -m: cage new -m 'opus[1m]' fast "task"
See 'cage profile' for full profile management.

Examples:
  cage new "Fix the bug in auth.py"
  cage new fast "Quick question about this code"
  cage new -p web "What are best practices for X?"
  cage new -m 'opus[1m]' "Complex refactoring task"
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

    # Background-only flags are meaningless without -p — refuse loudly
    if [ "$print_mode" = false ]; then
        if [ "$tail_mode" = true ] || [ -n "$output_override" ] || [ -n "$result_file" ]; then
            echo -e "${RED}Error:${NC} --tail/--md/--json/--result-file require -p" >&2
            return 1
        fi
    fi

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
    local effort="$PROF_EFFORT"
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

    # Allocate today's session slot (dated dir, number, handle, uuid) in one
    # consistent step — a midnight boundary cannot split the day and numbering
    cage_alloc_session
    local uuid="$_cage_uuid"
    local log_dir="$_cage_log_dir"
    local session_num="$_cage_session_num"
    local session_name="$_cage_session_name"
    # Display-only relative code: it rots at midnight, so every printed resume
    # hint uses $session_name instead.
    local session_id="s0-${session_num}"
    local log_file="${log_dir}/cage_${session_num}.log"
    local pid_file="${log_dir}/cage_${session_num}.pid"
    local meta_file="${log_dir}/cage_${session_num}.meta.json"
    local status_file="${log_dir}/cage_${session_num}.status"
    local settings_file=""

    # Set default result file if not specified
    [ -z "$result_file" ] && result_file="${log_dir}/cage_${session_num}.result.json"

    # Generate a per-session sandbox settings file when the profile declares one.
    # Only this session sees it (passed via --settings); global settings stay untouched.
    if [ "$PROF_HAS_SANDBOX" = true ]; then
        settings_file="${log_dir}/cage_${session_num}.settings.json"
        cage_write_sandbox_settings "$settings_file" "$PROF_SANDBOX"
    fi

    # Store metadata as JSON before running (sandbox key omitted when absent)
    jq -n \
        --arg uuid "$uuid" \
        --arg name "$session_name" \
        --arg profile "$profile" \
        --arg task "$task" \
        --arg start_time "$(date -Iseconds)" \
        --arg model "$model" \
        --arg effort "$effort" \
        --arg tools "$tools" \
        --arg output "$output_format" \
        --arg cwd "$work_dir" \
        --arg system_prompt "$sys_prompt" \
        --argjson sandbox "${PROF_SANDBOX:-null}" \
        '{uuid: $uuid, name: $name, profile: $profile, task: $task, start_time: $start_time, model: $model, effort: $effort, tools: $tools, output: $output, cwd: $cwd, system_prompt: $system_prompt}
         + (if $sandbox != null then {sandbox: $sandbox} else {} end)' \
        > "$meta_file"

    # Mode 1: Interactive (default)
    if [ "$print_mode" = false ]; then
        cage_print_session_header "$session_name ($session_id)" "$profile" "$model" "$work_dir"
        # Empty arrays → zero args, so a sandbox-less / prompt-less profile launches byte-identically.
        local settings_args=()
        [ "$PROF_HAS_SANDBOX" = true ] && settings_args=(--settings "$settings_file")
        # Apply the profile's system prompt to the interactive session too. --append-system-prompt
        # is additive (keeps Claude's defaults + CLAUDE.md) and applies for the whole session.
        local sysprompt_args=()
        [ -n "$sys_prompt" ] && sysprompt_args=(--append-system-prompt "$sys_prompt")
        cage_write_cwd_handoff "$work_dir"
        cage_interactive_start "$pid_file"
        trap 'cage_interactive_end "$pid_file"' EXIT
        trap 'cage_interactive_end "$pid_file"; trap - INT; kill -INT $$' INT TERM
        (cd "$work_dir" && claude --session-id "$uuid" --name "$session_name" --model "$model" --effort "$effort" --allowedTools "$tools" "${settings_args[@]}" "${sysprompt_args[@]}" ${task:+"$task"})
        local _exit_code=$?
        trap - EXIT INT TERM
        cage_interactive_end "$pid_file"
        # Empty = no real user prompt ever sent. Transcript existence stopped
        # being the signal: claude writes the file at launch for the --name
        # title record even when the session is closed immediately.
        if cage_session_context "$work_dir" "$uuid" >/dev/null; then
            echo "$_exit_code" > "$status_file"
            # Near-empty sessions get offered for immediate cleanup (Enter =
            # clean) so test debris never accumulates in the registry
            if [ -t 0 ] && cage_is_near_empty "$work_dir" "$uuid" "$meta_file"; then
                if gum confirm --affirmative "Clean" --negative "Keep" "Near-empty session (single short prompt) — clean it now?"; then
                    cage_remove_session_files "$meta_file"
                    echo -e "${DIM}Near-empty session removed.${NC}"
                    return $_exit_code
                fi
            fi
            cage_print_resume_hint "$session_name"
        else
            cage_remove_session_files "$meta_file"
            echo -e "${DIM}Empty session removed.${NC}"
        fi
        return $_exit_code
    fi

    # Mode 2: Non-interactive background (with -p)
    local md_mode=false
    [ "$output_format" = "markdown" ] && md_mode=true

    # The profile's system prompt is applied via --append-system-prompt (passed to the
    # wrapper), the same mechanism as the interactive path — not prepended to the task.
    local final_task="$task"

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
EFFORT="${13}"
SETTINGS_FILE="${14}"
SYS_PROMPT="${15}"

# Per-session sandbox settings. Empty when the profile declares no sandbox block,
# so the claude command below is byte-identical to a non-sandbox launch.
SETTINGS_ARGS=()
[ -n "$SETTINGS_FILE" ] && SETTINGS_ARGS=(--settings "$SETTINGS_FILE")
# Profile system prompt, applied additively (same as the interactive path).
APPEND_ARGS=()
[ -n "$SYS_PROMPT" ] && APPEND_ARGS=(--append-system-prompt "$SYS_PROMPT")

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

# Headless: no one can answer a permission prompt, and an unanswerable ask aborts
# the run. The mode-policy.sh hook reads CAGE_HEADLESS and converts every would-be
# ask into a deny-with-reason (recoverable by the model) instead of a hang.
export CAGE_HEADLESS=1

# Run Claude and capture output
if [ "$MD_MODE" = "true" ]; then
    claude -p "$TASK" \
        --session-id "$UUID" \
        --name "$SESSION_NAME" \
        --model "$MODEL" \
        --effort "$EFFORT" \
        --allowedTools "$TOOLS" \
        "${SETTINGS_ARGS[@]}" \
        "${APPEND_ARGS[@]}" \
        --output-format text >> "$LOG_FILE" 2>&1
    EXIT_CODE=$?
    # For markdown mode, copy log content to result (minus header)
    tail -n +8 "$LOG_FILE" | head -n -3 > "${RESULT_FILE%.json}.md" 2>/dev/null
else
    OUTPUT=$(claude -p "$TASK" \
        --session-id "$UUID" \
        --name "$SESSION_NAME" \
        --model "$MODEL" \
        --effort "$EFFORT" \
        --allowedTools "$TOOLS" \
        "${SETTINGS_ARGS[@]}" \
        "${APPEND_ARGS[@]}" \
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
        "$effort" \
        "$settings_file" \
        "$sys_prompt" \
        < /dev/null > /dev/null 2>&1 &

    local pid=$!
    echo $pid > "$pid_file"
    disown

    # Output session info
    echo -e "${GREEN}✓${NC} Started session: ${BOLD}$session_name${NC}"
    echo -e "${GREEN}✓${NC} PID: ${YELLOW}$pid${NC}"
    echo -e "${GREEN}✓${NC} UUID: ${CYAN}${uuid}${NC}"
    echo -e "${GREEN}✓${NC} Profile: ${PURPLE}$profile${NC}  Model: ${CYAN}$model${NC}  Effort: ${CYAN}$effort${NC}  Output: ${CYAN}$output_format${NC}"
    echo -e "${GREEN}✓${NC} Log: ${CYAN}$log_file${NC}"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${BLUE}Check logs:${NC}    tail -f $log_file"
    echo -e "  ${BLUE}Check status:${NC}  cage status"
    echo -e "  ${BLUE}Read result:${NC}   cage result $session_name"
    echo -e "  ${BLUE}Resume later:${NC}  cage resume $session_name"
    echo -e "  ${BLUE}Kill process:${NC}  cage kill $session_name"

    # If tail mode is enabled, launch cage tail after a brief pause
    if [ "$tail_mode" = true ]; then
        echo ""
        source "$CAGE_ROOT/lib/tail.sh"
        cage_tail "$session_name"
    fi
}
