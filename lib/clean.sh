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
                      at most short_max_prompts prompts, the first at most
                      short_prompt_max_chars characters (see
                      ~/.config/cage/config.json; today's sessions are kept)
  --interactive       Pick the sessions to delete from a gum multi-select
  --older-than DAYS   Everything older than DAYS

Options:
  --dry-run           Show what would be removed without touching anything
  -h, --help          Show this help

RUNNING sessions and pinned ones (Keep long, pin not expired) are never
removed; delete a pinned session from its close menu. A pinned session that
lost both its transcript and its archive copy counts as unpinned. Only
cage's own storage (~/.local/state/cage: registry rows and the archive copy
an expired pin left) is touched — Claude-side transcripts under
~/.claude/projects are never deleted here. Every choice is echoed back for
the record, every mode ends with an itemized warning and a gum
confirmation, and stale pid files in the remaining rows are swept
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

    # --empty needs the near-empty thresholds from the user settings. Loaded
    # after the options, so --help still works when the file is invalid.
    cage_load_config || return 1

    if [ -z "$mode" ]; then
        command -v gum >/dev/null 2>&1 || {
            echo -e "${RED}Error:${NC} gum is required for the mode menu (or pass --expired/--empty/--interactive/--older-than)" >&2
            return 1
        }
        local choice
        choice=$(gum choose --header "cage clean — what to remove?" \
            "expired      rows whose Claude transcript is gone (unresumable)" \
            "near-empty   no task/result/rename, few prompts, short first one (cage settings)" \
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
    meta_rows=$(cage_meta_rows '.uuid // "", .cwd // "", .keep_until // "", .task // ""') || return 1
    if [ -z "$meta_rows" ]; then
        echo "Registry is empty."
        return 0
    fi

    # Collect target rows per mode; RUNNING and pinned rows are never touched
    # (a pinned row without transcript is restored by cage status or the
    # picker, never expired here). A pinned row with neither a transcript nor
    # an archive copy can never be restored, so it is treated as unpinned.
    local targets=() pick_rows=() kept_running=0 kept_pinned=0 today
    local -A uuid_of mf_of_handle
    today=$(date +%Y-%m-%d)
    local mf uuid cwd keep_until task handle copy
    while IFS="$_CAGE_ROW_SEP" read -r mf uuid cwd keep_until task; do
        [ -n "$mf" ] || continue
        if cage_meta_running "$mf"; then
            kept_running=$((kept_running + 1))
            continue
        fi
        cage_archive_path_var copy "$uuid"
        if cage_pin_active "$keep_until" \
            && { cage_has_conversation "$cwd" "$uuid" || [ -f "$copy" ]; }; then
            kept_pinned=$((kept_pinned + 1))
            continue
        fi
        uuid_of["$mf"]="$uuid"
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
                handle=$(cage_handle_from_meta "$mf")
                mf_of_handle["$handle"]="$mf"
                pick_rows+=("$(printf '%-21s %s' "$handle" "${ctx:0:60}")")
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
        local line
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            handle="${line%% *}"
            mf="${mf_of_handle[$handle]}"
            [ -n "$mf" ] || {
                echo -e "${RED}Error:${NC} gum returned a row that was not offered: $line" >&2
                return 1
            }
            targets+=("$mf")
        done <<< "$picked"
        echo -e "${DIM}Selected:${NC} ${#targets[@]} session(s)"
    fi

    [ "$kept_running" -gt 0 ] && echo -e "${YELLOW}Note:${NC} ${kept_running} RUNNING session(s) excluded" >&2
    [ "$kept_pinned" -gt 0 ] && echo -e "${YELLOW}Note:${NC} ${kept_pinned} pinned session(s) excluded (delete one from its close menu)" >&2
    if [ ${#targets[@]} -eq 0 ]; then
        echo "Nothing to clean for this mode."
        return 0
    fi

    # Informative warning: exactly what goes, and what is deliberately spared
    echo -e "${BOLD}cage clean${NC} — ${#targets[@]} session record(s) to remove:"
    for mf in "${targets[@]}"; do
        _cage_clean_describe "$mf"
    done
    echo -e "${YELLOW}Warning:${NC} this permanently deletes these registry records (meta, log, result, exit code) and any archive copy an expired pin left."
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

    local failed=0
    for mf in "${targets[@]}"; do
        cage_remove_session_row "$mf" "${uuid_of[$mf]}" || failed=$((failed + 1))
    done
    echo -e "${GREEN}✓${NC} Removed $(( ${#targets[@]} - failed )) session record(s)."

    # Sweep stale pid files left in the remaining rows (their processes died
    # without cleanup; a recycled PID could otherwise show a false RUNNING).
    # Runs before a removal failure is reported, so the help's promise holds.
    local swept=0 pid_file
    for pid_file in "${CAGE_STORAGE}"/????-??-??/*.pid; do
        [ -f "$pid_file" ] || continue
        if ! cage_meta_running "${pid_file%.pid}.meta.json"; then
            rm -f "$pid_file" && swept=$((swept + 1))
        fi
    done
    [ "$swept" -gt 0 ] && echo -e "${GREEN}✓${NC} Swept ${swept} stale pid file(s)."

    if [ "$failed" -gt 0 ]; then
        echo -e "${RED}Error:${NC} ${failed} session record(s) could not be removed (rm errors above)" >&2
        return 1
    fi
    return 0
}
