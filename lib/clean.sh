#!/usr/bin/env bash

# clean.sh - Prune registry entries
# Usage: cage clean [--expired | --empty | --interactive | --older-than DAYS] [--dry-run]

_cage_clean_help() {
    cat <<'EOF'
cage clean - Prune registry entries

Usage: cage clean [MODE] [--dry-run]

Modes (bare `cage clean` opens a gum menu):
  --expired           Rows whose Claude transcript no longer exists — past
                      Claude Code's cleanupPeriodDays retention, so they can
                      never be resumed again
  --empty             Near-empty sessions: no task, no result, not renamed,
                      at most one greeting-sized prompt (today's sessions and
                      RUNNING ones are kept)
  --interactive       Pick the sessions to delete from a gum multi-select
  --older-than DAYS   Everything older than DAYS

Options:
  --dry-run           Show what would be removed without touching anything
  -h, --help          Show this help

Only cage's registry (~/.local/state/cage) is touched — Claude-side
transcripts under ~/.claude/projects are never deleted here. Every choice is
echoed back for the record, every mode ends with an itemized warning and a
gum confirmation, and stale pid files in the remaining rows are swept
afterwards.
EOF
}

# Print one itemized line per doomed session: handle, context snippet
_cage_clean_describe() {
    local mf="$1"
    local uuid cwd ctx
    uuid=$(jq -r '.uuid // ""' "$mf" 2>/dev/null)
    cwd=$(jq -r '.cwd // ""' "$mf" 2>/dev/null)
    ctx=$(jq -r '.task // ""' "$mf" 2>/dev/null)
    [ -z "$ctx" ] && { ctx=$(cage_session_context "$cwd" "$uuid") || ctx=""; }
    echo -e "  ${GREEN}$(cage_handle_from_meta "$mf")${NC}  ${DIM}${ctx:0:60}${NC}"
}

# True when the session row's pid file points at a live process
_cage_clean_is_running() {
    local pid_file="${1%.meta.json}.pid"
    [ -f "$pid_file" ] || return 1
    local pid
    read -r pid < "$pid_file"
    kill -0 "$pid" 2>/dev/null
}

cage_clean() {
    local mode="" days="" dry_run=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --expired)     mode="expired"; shift ;;
            --empty)       mode="empty"; shift ;;
            --interactive) mode="pick"; shift ;;
            --older-than)
                if [ -z "$2" ] || ! [[ $2 =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}Error:${NC} --older-than requires a number of days" >&2
                    return 1
                fi
                mode="age"
                days="$2"
                shift 2
                ;;
            --dry-run) dry_run=true; shift ;;
            -h|--help) _cage_clean_help; return 0 ;;
            *)
                echo -e "${RED}Error:${NC} unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    if [ -z "$mode" ]; then
        command -v gum >/dev/null 2>&1 || {
            echo -e "${RED}Error:${NC} gum is required for the mode menu (or pass --expired/--empty/--interactive/--older-than)" >&2
            return 1
        }
        local choice
        choice=$(gum choose --header "cage clean — what to remove?" \
            "expired      rows whose Claude transcript is gone (unresumable)" \
            "near-empty   no task/result/rename, one greeting-sized prompt at most" \
            "pick         select sessions to delete" \
            "by-age       everything older than N days") || {
            echo "Aborted — nothing removed."
            return 1
        }
        case "$choice" in
            expired*)    mode="expired" ;;
            near-empty*) mode="empty" ;;
            pick*)       mode="pick" ;;
            by-age*)
                mode="age"
                # Pre-filled with the user's actual Claude Code retention —
                # rows older than that have lost their transcripts anyway
                days=$(gum input --value "$(cage_cleanup_period_days)" --prompt "Older than (days): ") || {
                    echo "Aborted — nothing removed."
                    return 1
                }
                if ! [[ $days =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}Error:${NC} not a number of days: $days" >&2
                    return 1
                fi
                ;;
        esac
    fi

    # gum widgets erase themselves — echo every choice for the record
    echo -e "${DIM}Mode:${NC} ${mode}${days:+ (older than ${days} days)}"
    echo -e "${DIM}Scanning registry…${NC}"

    # One batched jq for all rows (a per-row jq trio makes large registries
    # feel hung, especially before the pick selector appears)
    local meta_rows
    meta_rows=$(cage_meta_rows '.uuid // "", .cwd // "", .task // ""') || return 1
    if [ -z "$meta_rows" ]; then
        echo "Registry is empty."
        return 0
    fi

    # Collect target rows per mode; RUNNING rows are never touched
    local targets=() pick_rows=() kept_running=0 today
    today=$(date +%Y-%m-%d)
    local mf uuid cwd task
    while IFS=$'\t' read -r mf uuid cwd task; do
        [ -n "$mf" ] || continue
        if _cage_clean_is_running "$mf"; then
            kept_running=$((kept_running + 1))
            continue
        fi
        case "$mode" in
            expired)
                cage_has_conversation "$cwd" "$uuid" || targets+=("$mf")
                ;;
            empty)
                # Today's sessions are spared: one just closed might be
                # reopened in a moment
                [ "$(basename "$(dirname "$mf")")" = "$today" ] && continue
                cage_is_near_empty "$cwd" "$uuid" "$mf" && targets+=("$mf")
                ;;
            age)
                [ "$(cage_days_ago "$(basename "$(dirname "$mf")")")" -gt "$days" ] && targets+=("$mf")
                ;;
            pick)
                local ctx="$task"
                [ -z "$ctx" ] && { ctx=$(cage_session_context "$cwd" "$uuid") || ctx=""; }
                pick_rows+=("$(printf '%-21s %s' "$(cage_handle_from_meta "$mf")" "${ctx:0:60}")")
                targets+=("$mf")
                ;;
        esac
    done <<< "$meta_rows"

    if [ "$mode" = "pick" ]; then
        command -v gum >/dev/null 2>&1 || {
            echo -e "${RED}Error:${NC} gum is required for interactive selection" >&2
            return 1
        }
        if [ ${#targets[@]} -eq 0 ]; then
            echo "Nothing to pick: registry is empty."
            return 0
        fi
        local picked
        picked=$(printf '%s\n' "${pick_rows[@]}" | gum choose --no-limit --height 20 \
            --header "Select sessions to DELETE (space toggles, enter confirms)") || {
            echo "Aborted — nothing removed."
            return 1
        }
        targets=()
        local line handle
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            handle="${line%% *}"
            targets+=("$(cage_get_session_file "$handle" "meta.json")")
        done <<< "$picked"
        echo -e "${DIM}Selected:${NC} ${#targets[@]} session(s)"
    fi

    [ "$kept_running" -gt 0 ] && echo -e "${YELLOW}Note:${NC} ${kept_running} RUNNING session(s) excluded" >&2
    if [ ${#targets[@]} -eq 0 ]; then
        echo "Nothing to clean for this mode."
        return 0
    fi

    # Informative warning: exactly what goes, and what is deliberately spared
    echo -e "${BOLD}cage clean${NC} — ${#targets[@]} session record(s) to remove:"
    for mf in "${targets[@]}"; do
        _cage_clean_describe "$mf"
    done
    echo -e "${YELLOW}Warning:${NC} this permanently deletes these registry records (meta, log, result, exit code)."
    echo -e "${DIM}Claude-side transcripts under ~/.claude/projects are NOT touched.${NC}"

    if [ "$dry_run" = true ]; then
        echo "(dry run — nothing removed)"
        return 0
    fi

    command -v gum >/dev/null 2>&1 || {
        echo -e "${RED}Error:${NC} gum is required to confirm deletion (or use --dry-run to inspect)" >&2
        return 1
    }
    gum confirm "Delete ${#targets[@]} session record(s)?" || {
        echo "Aborted — nothing removed."
        return 1
    }

    for mf in "${targets[@]}"; do
        cage_remove_session_files "$mf"
    done
    echo -e "${GREEN}✓${NC} Removed ${#targets[@]} session record(s)."

    # Sweep stale pid files left in the remaining rows (their processes died
    # without cleanup; a recycled PID could otherwise show a false RUNNING)
    local swept=0 pid_file pid
    for pid_file in "${CAGE_STORAGE}"/????-??-??/*.pid; do
        [ -f "$pid_file" ] || continue
        read -r pid < "$pid_file"
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$pid_file"
            swept=$((swept + 1))
        fi
    done
    [ "$swept" -gt 0 ] && echo -e "${GREEN}✓${NC} Swept ${swept} stale pid file(s)."
    return 0
}
