#!/usr/bin/env bash

# new.sh - Start a new Claude session
# Usage: cage new [options] [profile] ["task"]

_cage_new_help() {
    cat <<'EOF'
cage new - Start a new Claude session

Usage: cage new [options] [profile] ["task"]

  profile  a name from the list below (default: default)
  task     sent as the session's first prompt; omit it to open an empty
           interactive session (required with -p). Quote it: unquoted,
           a first word naming a profile or a word starting with - is
           taken by cage, and zsh expands ? and *

Options:
  -p, --print          Run in the background (like claude -p)
  -m, --model MODEL    Model override, e.g. claude-sonnet-5-5
  -t, --tail           Tail the log after starting (with -p)
  --md | --json        Force the output format (with -p)
  --result-file PATH   Custom result path (with -p)
  --plugin-dir PATH    Load a plugin dir or .zip (repeatable; re-applied by
                       cage resume)
  -h, --help           Show this help

An interactive session ends with your shell cd'd into its working directory
(cage() shell wrapper; 'command cage' opts out).

Profiles:
EOF
    # Dynamic: one row per profile file; the tool list is only counted here
    source "$CAGE_ROOT/lib/profile.sh"
    local fmt="  %-10s %-21s %-6s %-5s %5s  %s\n"
    printf "$fmt" NAME MODEL EFFORT OUT TOOLS CWD
    local f name tools_arr out
    for f in "$CAGE_PROFILES_DIR"/*.json; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .json)
        _cage_profile_summary_fields "$f"
        IFS=',' read -ra tools_arr <<< "$PSUM_TOOLS"
        out="$PSUM_OUTPUT"
        [ "$out" = "markdown" ] && out="md"
        printf "$fmt" "$name" "$PSUM_MODEL" "$PSUM_EFFORT" "$out" "${#tools_arr[@]}" "${PSUM_CWD/#$HOME/\~}"
    done
    cat <<'EOF'
  'cage profile list' describes them; 'cage profile show NAME' lists the tools.

Examples:
  cage new "Fix the bug in auth.py"
  cage new fast "Quick question"
  cage new -p web "Best practices for X?"
  cage new --plugin-dir ./my-plugin "Try it"
EOF
}

cage_new() {
    local print_mode=false
    local tail_mode=false
    local output_override=""
    local model_override=""
    local result_file=""
    local plugin_dirs=()

    # Parse options with GNU getopt
    local opts
    opts=$(getopt -o ptm:h \
                  --long print,tail,model:,md,json,result-file:,plugin-dir:,help \
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
            --plugin-dir)
                # Absolute now: claude runs from the profile cwd, where a
                # caller-relative path would not resolve
                local abs_plugin
                abs_plugin=$(realpath -e -- "$2") || {
                    echo -e "${RED}Error:${NC} --plugin-dir path cannot be resolved: $2" >&2
                    return 1
                }
                plugin_dirs+=("$abs_plugin")
                shift 2
                ;;
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
    # claude -p with an empty prompt dies in the background wrapper, unseen
    if [ "$print_mode" = true ] && [ -z "$task" ]; then
        echo -e "${RED}Error:${NC} -p requires a task" >&2
        return 1
    fi
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

    # Store metadata as JSON before running (sandbox and plugin_dirs keys
    # omitted when absent)
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
         + (if $sandbox != null then {sandbox: $sandbox} else {} end)
         + (if ($ARGS.positional | length) > 0 then {plugin_dirs: $ARGS.positional} else {} end)' \
        --args "${plugin_dirs[@]}" \
        > "$meta_file"

    # Empty array → zero args, so a plugin-less session launches byte-identically
    local plugin_args=() d
    for d in "${plugin_dirs[@]}"; do plugin_args+=(--plugin-dir "$d"); done

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
        # --allowedTools is variadic (<tools...>): without the `--` it swallows
        # the task as one more tool name and the session opens with no prompt
        local task_args=()
        [ -n "$task" ] && task_args=(-- "$task")
        cage_write_cwd_handoff "$work_dir"
        cage_interactive_start "$pid_file"
        trap 'cage_interactive_end "$pid_file"' EXIT
        trap 'cage_interactive_end "$pid_file"; trap - INT; kill -INT $$' INT TERM
        (cd "$work_dir" && claude --session-id "$uuid" --name "$session_name" --model "$model" --effort "$effort" --allowedTools "$tools" "${settings_args[@]}" "${sysprompt_args[@]}" "${plugin_args[@]}" "${task_args[@]}")
        local _exit_code=$?
        trap - EXIT INT TERM
        cage_interactive_end "$pid_file"
        # Empty = no real user prompt ever sent. Transcript existence stopped
        # being the signal: claude writes the file at launch for the --name
        # title record even when the session is closed immediately.
        if cage_session_context "$work_dir" "$uuid" >/dev/null; then
            echo "$_exit_code" > "$status_file"
            cage_offer_near_empty_cleanup "$work_dir" "$uuid" "$meta_file" "$session_name"
            case $? in
                0) return $_exit_code ;;
                2) return 1 ;;
            esac
            cage_print_resume_hint "$session_name"
        else
            cage_remove_session_files "$meta_file" || {
                echo -e "${RED}Error:${NC} cannot remove empty session $session_name (rm error above)" >&2
                return 1
            }
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
# Remaining args: ready-built --plugin-dir flag pairs (none for a plugin-less session)
shift 15
PLUGIN_ARGS=("$@")

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
        "${PLUGIN_ARGS[@]}" \
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
        "${PLUGIN_ARGS[@]}" \
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
        "${plugin_args[@]}" \
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
