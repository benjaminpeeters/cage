#!/usr/bin/env bash

# status.sh - List Claude sessions
# Usage: cage status [session|max_logs]

# Display details for a single session
_cage_status_single() {
    local session="$1"

    local meta_file=$(cage_get_session_file "$session" "meta.json")
    if [ ! -f "$meta_file" ]; then
        echo -e "${RED}Error:${NC} Session not found: $session" >&2
        return 1
    fi

    local log_file=$(cage_get_session_file "$session" "log")
    local pid_file=$(cage_get_session_file "$session" "pid")
    local status_file=$(cage_get_session_file "$session" "status")
    local result_file=$(cage_get_session_file "$session" "result.json")

    local uuid name cwd profile task start_time model tools
    eval "$(jq -r '
        "uuid=" + (.uuid // "" | @sh) + " " +
        "name=" + (.name // "" | @sh) + " " +
        "cwd=" + (.cwd // "" | @sh) + " " +
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

    # Resolve relative display code
    local day_dir=$(dirname "$log_file")
    local day_raw=$(basename "$day_dir")
    local session_num=$(basename "$log_file" .log | sed 's/cage_//')
    local session_id=$(cage_relative_code "$day_raw" "$session_num")

    # Current display name (reflects in-session /rename)
    local display_name
    display_name=$(cage_display_name "$cwd" "$uuid") || display_name="$name"

    echo -e "${BOLD}Session: ${GREEN}${session_id}${NC} ${DIM}(${name})${NC}"
    [ "$display_name" != "$name" ] && echo -e "  ${DIM}Name:${NC}     ${BOLD}${display_name}${NC}"
    echo -e "  ${DIM}Status:${NC}   $status"
    [ -n "$duration" ] && echo -e "  ${DIM}Duration:${NC} ${YELLOW}$duration${NC}"
    [ -n "$pid" ] && [ "$running" = true ] && echo -e "  ${DIM}PID:${NC}      ${YELLOW}$pid${NC}"
    [ -n "$uuid" ] && echo -e "  ${DIM}UUID:${NC}     ${CYAN}$uuid${NC}"
    [ -n "$profile" ] && echo -e "  ${DIM}Profile:${NC}  ${PURPLE}$profile${NC}"
    [ -n "$model" ] && echo -e "  ${DIM}Model:${NC}    $model"
    [ -n "$tools" ] && echo -e "  ${DIM}Tools:${NC}    $tools"
    [ -n "$start_time" ] && echo -e "  ${DIM}Started:${NC}  $start_time"
    if [ -n "$task" ]; then
        echo -e "  ${DIM}Task:${NC}     ${task:0:120}"
    else
        local ctx
        ctx=$(cage_session_context "$cwd" "$uuid") || ctx=""
        [ -n "$ctx" ] && echo -e "  ${DIM}Prompt:${NC}   ${ctx:0:120}"
    fi
    echo -e "  ${DIM}Log:${NC}      ${CYAN}$log_file${NC}"
    [ -f "$result_file" ] && echo -e "  ${DIM}Result:${NC}  ${CYAN}$result_file${NC}"
    return 0
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
            cage_relative_code "$day_raw" "$session_num"
            return 0
        fi
    done
    return 1
}

cage_status() {
    local profile_filter="" show_all=false
    while :; do
        case "$1" in
            -h|--help)
                cat <<'EOF'
cage status - List sessions or show one session

Usage: cage status [--profile NAME] [--all] [session | max_logs]

Arguments:
  session          Session reference (s0-1, cage-2026-01-05-1, a UUID, or a /rename'd name)
  max_logs         Number of finished sessions to list (default: 10)

Options:
  --profile NAME   List only sessions launched with this profile
  -a, --all        Also list near-empty sessions (no task, no result, not
                   renamed, at most one greeting-sized prompt) — hidden by
                   default as test debris

Rows show identifying context: the /rename'd name when set, else the
session's task or the first prompt typed into it.
EOF
                return 0
                ;;
            --profile)
                if [ -z "$2" ]; then
                    echo -e "${RED}Error:${NC} --profile requires a profile name" >&2
                    return 1
                fi
                profile_filter="$2"
                shift 2
                ;;
            -a|--all)
                show_all=true
                shift
                ;;
            -*)
                echo -e "${RED}Error:${NC} unknown option: $1" >&2
                return 1
                ;;
            *)
                break
                ;;
        esac
    done

    local arg="$1"

    # Enable nullglob for this function (restore on return)
    local old_nullglob=$(shopt -p nullglob 2>/dev/null)
    shopt -s nullglob
    trap 'eval "$old_nullglob"' RETURN

    # If argument looks like a session identifier, show single session
    if [ -n "$arg" ]; then
        local resolved=""
        # s<n>-<n> or cage-YYYY-MM-DD-N or UUID ([sS]/[-_] also match the
        # underscore spellings stored in older meta .name fields)
        if [[ $arg =~ ^[sS]-?[0-9]+[-_][0-9]+$ ]] || \
           [[ $arg =~ ^cage[-_][0-9]{4}-[0-9]{2}-[0-9]{2}[-_][0-9]+$ ]] || \
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
        # Anything else non-numeric: a /rename'd display name — resolution
        # (and the loud not-found error) happens in cage_get_session_file.
        # Resolve ONCE to the absolute handle: passing the raw name down would
        # re-run the full transcript scan for every per-file lookup in
        # _cage_status_single.
        elif [[ ! $arg =~ ^[0-9]+$ ]]; then
            local meta
            meta=$(cage_get_session_file "$arg" "meta.json") || return 1
            resolved=$(cage_handle_from_meta "$meta")
        fi

        if [ -n "$resolved" ]; then
            _cage_status_single "$resolved"
            return
        fi
    fi

    _cage_status_list "${arg:-10}" "$profile_filter" "$show_all"
}

_cage_status_list() {
    local max_logs="$1"
    local profile_filter="$2"
    local show_all="${3:-false}"
    local hidden=0

    # Scan all meta.json files sorted by modification time (newest first)
    local meta_files=()
    while IFS= read -r -d '' file; do
        meta_files+=("$file")
    done < <(cage_all_meta_files)

    # Split into running and finished
    local running_entries=() finished_entries=()
    local count=0

    for meta_file in "${meta_files[@]}"; do
        [ -f "$meta_file" ] || continue
        local session_num=$(basename "$meta_file" .meta.json | sed 's/cage_//')
        local day_dir=$(dirname "$meta_file")
        local day_raw=$(basename "$day_dir")
        local pid_file="${day_dir}/cage_${session_num}.pid"

        # Quick check: if no pid file and we already have enough finished, skip
        if [ ! -f "$pid_file" ] && [ $count -ge $max_logs ]; then
            continue
        fi

        local session_id=$(cage_relative_code "$day_raw" "$session_num")

        local uuid="" name="" cwd="" profile="" start_time="" task=""
        eval "$(jq -r '
            "uuid=" + (.uuid // "" | @sh) + " " +
            "name=" + (.name // "" | @sh) + " " +
            "cwd=" + (.cwd // "" | @sh) + " " +
            "profile=" + (.profile // "default" | @sh) + " " +
            "start_time=" + (.start_time // "" | @sh) + " " +
            "task=" + (.task // "" | @sh)
        ' "$meta_file" 2>/dev/null)"

        [ -n "$profile_filter" ] && [ "$profile" != "$profile_filter" ] && continue

        local time="${start_time:0:19}"; time="${time/T/ }"
        [ -z "$time" ] && time=$(stat -c '%y' "$meta_file" 2>/dev/null | cut -d'.' -f1)

        local log_file="${day_dir}/cage_${session_num}.log"
        local status_file="${day_dir}/cage_${session_num}.status"

        cage_resolve_status "$pid_file" "$status_file" "$log_file"
        # Identifying context: the task, else the first prompt typed. Scanned
        # ONCE here and reused by the near-empty decision below.
        local ctx="$task" first_prompt=""
        if [ -z "$ctx" ]; then
            first_prompt=$(cage_session_context "$cwd" "$uuid") || first_prompt=""
            ctx="$first_prompt"
        fi
        # Near-empty rows (test debris) are hidden by default; RUNNING ones
        # stay visible — a freshly opened session has no prompts yet
        if [ "$show_all" = false ] && [ "$_cage_running" = false ] \
            && cage_is_near_empty "$cwd" "$uuid" "$meta_file" "$first_prompt"; then
            hidden=$((hidden + 1))
            continue
        fi
        if [ "$_cage_running" = true ] || [ $count -lt $max_logs ]; then
            # Display name computed only for rows actually shown (one
            # transcript scan per row); appended when it differs from the
            # meta name, i.e. the session was /rename'd
            local display_name named=""
            display_name=$(cage_display_name "$cwd" "$uuid") || display_name="$name"
            [ "$display_name" != "$name" ] && named="  ${BOLD}${display_name}${NC}"
            local line1="• ${GREEN}${session_id}${NC} (${BLUE}${time}${NC}) - ${_cage_status}${named}"
            local line2="  ${DIM}UUID:${NC} ${CYAN}${uuid}${NC}  ${DIM}Profile:${NC} ${PURPLE}${profile}${NC}"
            local entry="$line1"$'\n'"$line2"
            [ -n "$ctx" ] && entry+=$'\n'"  ${DIM}${ctx:0:80}${NC}"
            if [ "$_cage_running" = true ]; then
                running_entries+=("$entry")
            else
                finished_entries+=("$entry")
                ((count++))
            fi
        fi
    done

    echo -e "${BOLD}${PURPLE}=== Active Sessions ===${NC}"
    if [ ${#running_entries[@]} -eq 0 ]; then
        echo -e "${DIM}No active sessions${NC}"
    else
        for entry in "${running_entries[@]}"; do
            echo -e "$entry"
        done
    fi

    echo ""
    echo -e "${BOLD}${PURPLE}=== Recent Sessions ===${NC}"
    if [ ${#finished_entries[@]} -eq 0 ]; then
        echo -e "${DIM}No recent sessions${NC}"
    else
        for entry in "${finished_entries[@]}"; do
            echo -e "$entry"
        done
    fi
    if [ "$hidden" -gt 0 ]; then
        echo -e "${DIM}(${hidden} near-empty session(s) hidden — cage status --all)${NC}"
    fi
}
