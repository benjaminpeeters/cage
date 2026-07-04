#!/usr/bin/env bash

# resume.sh - Resume an existing Claude session
# Usage: cage resume <session> [options]

_cage_resume_help() {
    cat <<'EOF'
cage resume - Resume an existing Claude session

Usage: cage resume [session] [options]

Arguments:
  session    Session reference: s0-3, cage-2026-01-05-1, a UUID, or a
             /rename'd display name (quote names containing spaces).
             With no argument, opens an interactive picker across all days.

When an interactive resume ends, your shell cd's into the session's working
directory (via the cage() shell wrapper; deliberately not standard Unix
child-process behavior — 'command cage' bypasses it).

Options:
  -p, --prompt TEXT    Background job on the SAME conversation (requires an
                       explicit session): no new session row; the log appends
                       and result.json is overwritten by the next job
  -f, --fork           Branch into a NEW session row instead (new
                       conversation with its own handle and UUID; requires -p)
  -m, --md             Markdown output (default: JSON)
  -t, --tail           Tail log after starting (non-interactive only)
  -h, --help           Show this help

A RUNNING session refuses to resume (interactive or -p) — one claude per
conversation at a time.

Examples:
  cage resume                              # Pick from all sessions
  cage resume s0-3                         # Interactive
  cage resume cage-2026-01-05-1            # Absolute handle (works any day)
  cage resume "my-renamed-session"         # /rename'd display name
  cage resume s0-3 -p "add tests"          # Non-interactive
  cage resume s0-3 -p "task" --fork        # Fork session
  cage resume s0-3 -p "task" -mt           # Markdown + tail
EOF
}

# Interactive session picker across all dated dirs. Prints the selected
# session's absolute handle (cage-YYYY-MM-DD-N) to stdout; the handle is
# rebuilt from the meta path, so it resolves regardless of the stored name.
_cage_resume_picker() {
    command -v gum >/dev/null 2>&1 || {
        echo -e "${RED}Error:${NC} gum is required for the session picker (https://github.com/charmbracelet/gum)" >&2
        return 1
    }
    local meta_rows
    meta_rows=$(cage_meta_rows '.uuid // "", .cwd // "", .name // "", .profile // "default", .start_time // ""') || return 1
    if [ -z "$meta_rows" ]; then
        echo -e "${RED}Error:${NC} no sessions found in ${CAGE_STORAGE}" >&2
        return 1
    fi
    local rows=() mf uuid cwd name profile start_time
    while IFS=$'\t' read -r mf uuid cwd name profile start_time; do
        local day_dir day_raw session_num state dn when
        day_dir=$(dirname "$mf")
        day_raw=$(basename "$day_dir")
        session_num=$(basename "$mf" .meta.json)
        session_num=${session_num#cage_}
        cage_resolve_status "${day_dir}/cage_${session_num}.pid" \
                            "${day_dir}/cage_${session_num}.status" \
                            "${day_dir}/cage_${session_num}.log"
        state="FINISHED"
        [ "$_cage_running" = true ] && state="RUNNING"
        dn=$(cage_display_name "$cwd" "$uuid") || dn="$name"
        # Last column: the /rename'd name when set, else a content snippet
        # (the handle already occupies column 1, so repeating it says nothing)
        if [ "$dn" = "$name" ]; then
            local ctx
            ctx=$(cage_session_context "$cwd" "$uuid") || ctx=""
            dn="${ctx:0:50}"
        fi
        when="${start_time:0:16}"
        when="${when/T/ }"
        rows+=("$(printf '%-21s %-8s %-16s %-8s %-9s %s' \
            "cage-${day_raw}-${session_num}" \
            "$(cage_relative_code "$day_raw" "$session_num")" \
            "$when" "$state" "$profile" "$dn")")
    done <<< "$meta_rows"
    local selected
    selected=$(printf '%s\n' "${rows[@]}" | gum filter --height 20 \
        --header "Resume a session" --placeholder "Type to filter (name, date, profile)...") || {
        echo -e "${DIM}No session selected.${NC}" >&2
        return 1
    }
    echo "${selected%% *}"
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

    # Background-only flags are meaningless on an interactive resume — refuse
    # loudly instead of silently resuming the parent conversation
    if [ -z "$prompt" ] && { [ "$fork_mode" = true ] || [ "$md_mode" = true ] || [ "$tail_mode" = true ]; }; then
        echo -e "${RED}Error:${NC} --fork/--md/--tail require -p" >&2
        return 1
    fi

    if [ -z "$session" ]; then
        if [ -n "$prompt" ]; then
            echo -e "${RED}Error:${NC} -p requires an explicit session" >&2
            return 1
        fi
        session=$(_cage_resume_picker) || return 1
    fi

    local uuid=$(cage_resolve_uuid "$session")
    if [ -z "$uuid" ]; then
        echo -e "${RED}Error:${NC} Session not found: $session" >&2
        echo "Use 'cage status' to see available sessions." >&2
        return 1
    fi

    # Mode 1: Interactive (no prompt)
    if [ -z "$prompt" ]; then
        cage_load_resume_meta "$session" "$uuid" || return 1
        local meta_file="$_cage_meta_file"
        local session_name="$_cage_name" profile="$_cage_profile" orig_cwd="$_cage_cwd"
        local orig_model="$_cage_model" orig_effort="$_cage_effort" orig_tools="$_cage_tools" orig_sys_prompt="$_cage_sys_prompt"
        # Canonicalize to the absolute handle: relative codes shift at midnight,
        # and the pid/status paths below are re-derived from $session after
        # claude exits — possibly on a later day.
        session="$session_name"

        local display="$session_name"
        local current_name
        current_name=$(cage_display_name "$orig_cwd" "$uuid") || current_name=""
        [ -n "$current_name" ] && [ "$current_name" != "$session_name" ] && display="$current_name ($session_name)"
        cage_print_session_header "$display" "$profile" "$orig_model" "$orig_cwd"

        # Re-apply the original session's sandbox (stored in meta) for this resume.
        # Empty array → zero args, so a sandbox-less session resumes byte-identically.
        local orig_sandbox="" settings_file="" settings_args=()
        [ -f "$meta_file" ] && orig_sandbox=$(jq -c '.sandbox // empty' "$meta_file")
        if [ -n "$orig_sandbox" ]; then
            cage_validate_sandbox "$orig_sandbox" "$session" || return 1
            settings_file=$(cage_get_session_file "$session" "settings.json")
            cage_write_sandbox_settings "$settings_file" "$orig_sandbox"
            settings_args=(--settings "$settings_file")
        fi

        # Re-apply the profile's system prompt (read from meta above). --append-system-prompt
        # is per-invocation, so a resume must re-pass it to keep the standing instructions.
        local sysprompt_args=()
        [ -n "$orig_sys_prompt" ] && sysprompt_args=(--append-system-prompt "$orig_sys_prompt")

        local resume_pid_file=$(cage_get_session_file "$session" "pid")
        cage_write_cwd_handoff "$orig_cwd"
        cage_interactive_start "$resume_pid_file"
        trap 'cage_interactive_end "$resume_pid_file"' EXIT
        trap 'cage_interactive_end "$resume_pid_file"; trap - INT; kill -INT $$' INT TERM
        (cd "$orig_cwd" && claude --resume "$uuid" ${orig_model:+--model "$orig_model"} ${orig_effort:+--effort "$orig_effort"} ${orig_tools:+--allowedTools "$orig_tools"} "${settings_args[@]}" "${sysprompt_args[@]}")
        local _exit_code=$?
        trap - EXIT INT TERM
        cage_interactive_end "$resume_pid_file"
        local status_file=$(cage_get_session_file "$session" "status")
        echo "$_exit_code" > "$status_file"
        # Transcript existence was verified before launch; disappearing during
        # the session is exceptional — warn, never delete registry files
        if ! cage_has_conversation "$orig_cwd" "$uuid"; then
            echo -e "${YELLOW}Warning:${NC} transcript for $session disappeared during the session — registry files kept" >&2
        fi
        # A session still near-empty after a resume gets the same immediate
        # cleanup offer as a fresh one (Enter = clean)
        if [ -t 0 ] && cage_is_near_empty "$orig_cwd" "$uuid" "$meta_file"; then
            if gum confirm --affirmative "Clean" --negative "Keep" "Near-empty session (single short prompt) — clean it now?"; then
                cage_remove_session_files "$meta_file"
                echo -e "${DIM}Near-empty session removed.${NC}"
                return $_exit_code
            fi
        fi
        cage_print_resume_hint "$session_name"
        return $_exit_code
    fi

    # Mode 2: Non-interactive with prompt
    cage_load_resume_meta "$session" "$uuid" || return 1
    local meta_file="$_cage_meta_file"
    local orig_name="$_cage_name" orig_cwd="$_cage_cwd" orig_profile="$_cage_profile"
    local orig_tools="$_cage_tools" orig_model="$_cage_model" orig_effort="$_cage_effort" orig_sys_prompt="$_cage_sys_prompt"
    # Canonical absolute handle (date-stable for all path lookups below); the
    # wrapper later cd's into the ensured cwd before claude --resume
    session="$orig_name"

    # Carry the parent session's sandbox (stored in meta) into the new sub-session.
    # Read shape matches the interactive path above (guarded, no error suppression).
    local orig_sandbox=""
    [ -f "$meta_file" ] && orig_sandbox=$(jq -c '.sandbox // empty' "$meta_file")
    [ -n "$orig_sandbox" ] && { cage_validate_sandbox "$orig_sandbox" "$session" || return 1; }

    # Non-fork: a background job on the EXISTING conversation — it reuses the
    # session's own registry row (no new sX-N handle; the log appends, the
    # result is overwritten by the next job). Fork: a genuinely NEW
    # conversation — it gets its own row, name, and a real uuid via
    # --session-id (claude honors it alongside --resume --fork-session).
    local job_session run_uuid claude_session_flags
    local new_session="" new_uuid=""
    if [ "$fork_mode" = true ]; then
        cage_alloc_session
        new_session="$_cage_session_name"
        new_uuid="$_cage_uuid"
        job_session="$new_session"
        run_uuid="$new_uuid"
        claude_session_flags="--resume $uuid --fork-session --session-id $new_uuid --name $new_session"
    else
        job_session="$session"
        run_uuid="$uuid"
        # No --name here: without a fork it would rename the parent conversation
        claude_session_flags="--resume $uuid"
    fi

    local log_file=$(cage_get_session_file "$job_session" "log")
    local pid_file=$(cage_get_session_file "$job_session" "pid")
    local result_file=$(cage_get_session_file "$job_session" "result.json")
    local status_file=$(cage_get_session_file "$job_session" "status")

    # Generate the per-session sandbox settings file for the run.
    local settings_file="" settings_flag=""
    if [ -n "$orig_sandbox" ]; then
        settings_file=$(cage_get_session_file "$job_session" "settings.json")
        cage_write_sandbox_settings "$settings_file" "$orig_sandbox"
        # The wrapper heredoc below is unquoted and interpolates this verbatim; the
        # settings path is under CAGE_STORAGE (no spaces) — the same invariant that
        # $claude_session_flags and $output_flags already rely on for word-splitting.
        settings_flag="--settings $settings_file"
    fi

    # Re-apply the profile's system prompt to the -p run. --append-system-prompt is
    # per-invocation and is NOT stored in the resumed transcript, so it must be re-passed
    # (same as interactive resume). The prompt may be multi-line, so it is written to a file
    # and read at wrapper runtime — only the space-free file path is interpolated.
    local sysprompt_file="" append_flag=""
    if [ -n "$orig_sys_prompt" ]; then
        sysprompt_file=$(cage_get_session_file "$job_session" "sysprompt")
        printf '%s' "$orig_sys_prompt" > "$sysprompt_file"
        append_flag="--append-system-prompt \"\$(cat '$sysprompt_file')\""
    fi

    # Build output flags
    local output_flags
    if [ "$md_mode" = true ]; then
        output_flags="--output-format text"
    else
        output_flags="$CAGE_JSON_OUTPUT_FLAGS"
    fi

    # Store metadata — forks only: a non-fork job belongs to the parent's meta
    if [ "$fork_mode" = true ]; then
        local new_meta_file=$(cage_get_session_file "$job_session" "meta.json")
        jq -n \
            --arg uuid "$new_uuid" \
            --arg name "$new_session" \
            --arg profile "$orig_profile" \
            --arg task "$prompt" \
            --arg start_time "$(date -Iseconds)" \
            --arg model "$orig_model" \
            --arg effort "$orig_effort" \
            --arg tools "$orig_tools" \
            --arg cwd "$orig_cwd" \
            --arg parent_session "$session" \
            --arg parent_uuid "$uuid" \
            --arg system_prompt "$orig_sys_prompt" \
            --argjson sandbox "${orig_sandbox:-null}" \
            '{uuid: $uuid, name: $name, profile: $profile, task: $task, start_time: $start_time, model: $model, effort: $effort, tools: $tools, cwd: $cwd, parent_session: $parent_session, parent_uuid: $parent_uuid, system_prompt: $system_prompt}
             + (if $sandbox != null then {sandbox: $sandbox} else {} end)' \
            > "$new_meta_file"
    fi

    # Atomic single-job claim: a noclobber create of the pid file closes the
    # window between cage_refuse_if_running's check and the launch below —
    # two concurrent resumes would otherwise both pass the guard and run two
    # claudes on one transcript (and truncate each other's wrapper script).
    if ! (set -o noclobber; echo $$ > "$pid_file") 2>/dev/null; then
        cage_refuse_if_running "$session" || return 1
        # pid file exists but its process is dead — take over the stale claim
        echo $$ > "$pid_file"
    fi

    # Record the job on the parent row AFTER the claim succeeds (a losing
    # concurrent invocation must not relabel the winner's job): cage status
    # shows the latest task, and the meta mtime bump keeps the row at the top
    # of the mtime-sorted list. The temp file lives in the meta's own dir so
    # the mv is an atomic same-filesystem rename.
    if [ "$fork_mode" = false ]; then
        local tmp_meta
        tmp_meta=$(mktemp "${meta_file}.XXXXXX") || { rm -f "$pid_file"; return 1; }
        jq --arg task "$prompt" '.task = $task' "$meta_file" > "$tmp_meta" || {
            rm -f "$tmp_meta" "$pid_file"
            echo -e "${RED}Error:${NC} cannot update metadata: $meta_file" >&2
            return 1
        }
        mv "$tmp_meta" "$meta_file" || {
            rm -f "$tmp_meta" "$pid_file"
            echo -e "${RED}Error:${NC} cannot replace metadata: $meta_file" >&2
            return 1
        }
    fi

    # Create wrapper script (job_session is unique here: the pid-file claim
    # above allows at most one active run per session)
    local wrapper_script="/tmp/cage_wrapper_${job_session}.sh"
    cat > "$wrapper_script" << WRAPPER_EOF
#!/bin/bash
# The task arrives as \$1: interpolating it into this unquoted heredoc would
# re-parse quotes and \\\$(...) from the prompt text as shell syntax.
TASK="\$1"
LOG_FILE="$log_file"
RESULT_FILE="$result_file"
STATUS_FILE="$status_file"
PID_FILE="$pid_file"
MD_MODE="$md_mode"
SYSPROMPT_FILE="$sysprompt_file"
# Single-quoted so the JSON schema's double quotes survive the wrapper's own
# parse; expanded unquoted below to word-split into flags (same as new.sh's
# OUTPUT_FLAGS argument). Inlining \$output_flags in the claude call instead
# makes bash strip the JSON's quotes and claude rejects the schema.
OUTPUT_FLAGS='$output_flags'

{
    echo "---"
    echo "Start: \$(date)"
    echo "PID: \$\$"
    echo "Session: $job_session"
    echo "UUID: $run_uuid"
    echo "Task: \$TASK"
    echo "---"
} >> "\$LOG_FILE"

# claude --resume resolves the transcript relative to the cwd it was recorded
# under — without this cd the background resume inherits the caller's cwd and
# finds nothing. Failure is recorded (log + status) rather than dying silently
# with a stale pid file.
cd "$orig_cwd" || {
    echo "Error: cannot cd to session cwd: $orig_cwd" >> "\$LOG_FILE"
    echo 1 > "\$STATUS_FILE"
    rm -f "\$PID_FILE"
    exit 1
}

# Headless: convert would-be permission asks to denies (see new.sh) so an
# unanswerable prompt can't hang the background resume.
export CAGE_HEADLESS=1

OUTPUT=\$(claude -p "\$TASK" \\
    $claude_session_flags \\
    --model "$orig_model" \\
    --effort "$orig_effort" \\
    --allowedTools "$orig_tools" \\
    $settings_flag \\
    $append_flag \\
    \$OUTPUT_FLAGS 2>&1)
EXIT_CODE=\$?

echo "\$OUTPUT" >> "\$LOG_FILE"
if [ "\$MD_MODE" = "true" ]; then
    # Markdown goes to a sidecar .md — result.json keeps the last STRUCTURED
    # result (for a non-fork job it is the parent session's file)
    echo "\$OUTPUT" > "\${RESULT_FILE%.json}.md"
else
    echo "\$OUTPUT" > "\$RESULT_FILE"
fi
echo "\$EXIT_CODE" > "\$STATUS_FILE"

{
    echo "~~~"
    echo "Exit code: \$EXIT_CODE"
    echo "Session ended at \$(date)"
} >> "\$LOG_FILE"

rm -f "\$PID_FILE"
[ -n "\$SYSPROMPT_FILE" ] && rm -f "\$SYSPROMPT_FILE"
rm -f "\$0"
WRAPPER_EOF

    chmod +x "$wrapper_script"

    # Run in background — the prompt travels as an argument, never as
    # interpolated script text
    nohup "$wrapper_script" "$prompt" < /dev/null > /dev/null 2>&1 &

    local pid=$!
    echo $pid > "$pid_file"
    disown

    if [ "$fork_mode" = true ]; then
        echo -e "${GREEN}✓${NC} Forked from: ${BOLD}$session${NC}"
        echo -e "${GREEN}✓${NC} New session: ${BOLD}$new_session${NC}"
        echo -e "${GREEN}✓${NC} UUID: ${CYAN}${new_uuid}${NC}"
    else
        echo -e "${GREEN}✓${NC} Resumed in background: ${BOLD}$session${NC}"
    fi
    echo -e "${GREEN}✓${NC} PID: ${YELLOW}$pid${NC}"
    echo -e "${GREEN}✓${NC} Log: ${CYAN}$log_file${NC}"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${BLUE}Check logs:${NC}    tail -f $log_file"
    echo -e "  ${BLUE}Read result:${NC}   cage result $job_session"
    echo -e "  ${BLUE}Kill job:${NC}      cage kill $job_session"

    if [ "$tail_mode" = true ]; then
        echo ""
        source "$CAGE_ROOT/lib/tail.sh"
        cage_tail "$job_session"
    fi
}
