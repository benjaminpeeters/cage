#!/usr/bin/env bash

# helpers.sh - Shared utilities for cage CLI
# Provides session resolution, file path helpers, and color definitions

# Color definitions
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'

# Session registry location (persistent across reboots; the sessions' working
# dirs — e.g. the default profile's /tmp/cage — are a separate concern)
CAGE_STORAGE="${HOME}/.local/state/cage"

# JSON output schema for background sessions
CAGE_JSON_OUTPUT_FLAGS='--output-format json --json-schema {"type":"object","properties":{"status":{"type":"string","enum":["success","error","partial"]},"summary":{"type":"string"},"files_created":{"type":"array","items":{"type":"string"}},"files_modified":{"type":"array","items":{"type":"string"}},"files_read":{"type":"array","items":{"type":"string"}},"errors":{"type":"array","items":{"type":"string"}},"data":{"type":"object"},"next_steps":{"type":"array","items":{"type":"string"}}},"required":["status","summary"]}'

# Parse a session reference and return full path to a session file
# Accepts: s<days>-<num>, cage-YYYY-MM-DD-N, a UUID, or a /rename'd display
# name. The [sS] and [-_] classes exist because stored meta .name fields and
# transcripts contain underscore spellings — both must keep resolving. The
# day count may be negative (registry dir dated ahead of the local date after
# a westward timezone change).
# Usage: cage_get_session_file "s0-1" "result.json" -> ~/.local/state/cage/2026-01-05/cage_1.result.json
cage_get_session_file() {
    local session="$1"
    local file_type="$2"  # log, pid, status, meta.json, result.json

    local target_date=""
    local session_num=""

    # Parse s<days>-<num> relative format (e.g., s0-1, s1-3, s-1-2)
    if [[ $session =~ ^[sS](-?[0-9]+)[-_]([0-9]+)$ ]]; then
        local days_ago=${BASH_REMATCH[1]}
        session_num=${BASH_REMATCH[2]}
        # Force base-10 with the sign split off — a hand-typed leading zero
        # (s08-1) would otherwise abort $((...)) as invalid octal, and a bare
        # 10# prefix rejects the supported negative offsets
        local sign=1
        [[ $days_ago == -* ]] && sign=-1
        days_ago=$(( sign * 10#${days_ago#-} ))
        # Epoch subtraction at UTC midnight, not `date -d "X - N days"`:
        # calendar phrasing misreads negative offsets ("- -1 days" still goes
        # backwards) and local midnights drift across DST changes
        local today_epoch=$(date -ud "$(date +%Y-%m-%d)" +%s)
        target_date=$(date -ud "@$(( today_epoch - days_ago * 86400 ))" +%Y-%m-%d)
    # Parse cage-YYYY-MM-DD-N absolute format (e.g., cage-2026-01-05-1)
    elif [[ $session =~ ^cage[-_]([0-9]{4}-[0-9]{2}-[0-9]{2})[-_]([0-9]+)$ ]]; then
        target_date=${BASH_REMATCH[1]}
        session_num=${BASH_REMATCH[2]}
    # UUID format: search meta.json files for matching uuid
    elif [[ $session =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        local meta_file
        meta_file=$(grep -l "\"uuid\": \"$session\"" "${CAGE_STORAGE}"/*/*.meta.json < /dev/null 2>/dev/null | head -1)
        if [ -z "$meta_file" ]; then
            echo "No session found for UUID: $session" >&2
            return 1
        fi
        # Extract date and number from meta file path
        local base=$(basename "$meta_file" .meta.json)
        session_num=${base#cage_}
        target_date=$(basename "$(dirname "$meta_file")")
    else
        # /rename'd display name: compare against the last custom-title of every
        # session's transcript (runs only when no code/UUID form matched above)
        local rows
        rows=$(cage_meta_rows '.uuid // "", .cwd // ""') || return 1
        local matches=() mf muuid mcwd dn
        if [ -n "$rows" ]; then
            while IFS=$'\t' read -r mf muuid mcwd; do
                [ -n "$muuid" ] && [ -n "$mcwd" ] || continue
                dn=$(cage_display_name "$mcwd" "$muuid") || continue
                [ "$dn" = "$session" ] && matches+=("$mf")
            done <<< "$rows"
        fi
        if [ ${#matches[@]} -eq 0 ]; then
            echo "No session found: $session (accepts s<days>-<n>, cage-YYYY-MM-DD-N, UUID, or a /rename'd name)" >&2
            return 1
        fi
        if [ ${#matches[@]} -gt 1 ]; then
            echo "Name '$session' matches multiple sessions:" >&2
            local m
            for m in "${matches[@]}"; do
                echo "  $(cage_handle_from_meta "$m")" >&2
            done
            echo "Resume one explicitly by its cage-YYYY-MM-DD-N handle." >&2
            return 1
        fi
        local mbase=$(basename "${matches[0]}" .meta.json)
        session_num=${mbase#cage_}
        target_date=$(basename "$(dirname "${matches[0]}")")
    fi

    # Build file path
    local log_dir="${CAGE_STORAGE}/${target_date}"
    local base_path="${log_dir}/cage_${session_num}"

    case "$file_type" in
        log)         echo "${base_path}.log" ;;
        pid)         echo "${base_path}.pid" ;;
        status)      echo "${base_path}.status" ;;
        meta.json)   echo "${base_path}.meta.json" ;;
        result.json) echo "${base_path}.result.json" ;;
        *)           echo "${base_path}.${file_type}" ;;
    esac
}

# Resolve a session reference to its UUID
# Usage: cage_resolve_uuid "s0-1" -> 351f41fe-ac51-4cfd-8e4f-a8105e0adf8a
cage_resolve_uuid() {
    local session="$1"
    local meta_file=$(cage_get_session_file "$session" "meta.json")

    if [ -f "$meta_file" ]; then
        jq -r '.uuid' "$meta_file" 2>/dev/null
    else
        echo ""
        return 1
    fi
}

# Absolute handle for a registry meta path
# Usage: cage_handle_from_meta ~/.local/state/cage/2026-01-05/cage_3.meta.json -> cage-2026-01-05-3
cage_handle_from_meta() {
    local base=$(basename "$1" .meta.json)
    echo "cage-$(basename "$(dirname "$1")")-${base#cage_}"
}

# All meta.json paths across dated dirs, newest first, NUL-separated.
# find gets the storage root itself (never a glob): an unmatched glob under
# nullglob would leave find with zero operands and it defaults to '.'
# Usage: while IFS= read -r -d '' f; do ...; done < <(cage_all_meta_files)
cage_all_meta_files() {
    find "${CAGE_STORAGE}" -mindepth 2 -maxdepth 2 -name "*.meta.json" -printf '%T@\t%p\0' 2>/dev/null | sort -rzn | cut -zf2
}

# Project fields from every registry meta as TSV rows (first column is always
# the meta path), newest first. Empty output when the registry is empty. jq
# aborts at the first corrupt file — that failure is surfaced loudly (jq's own
# error names the file) instead of silently dropping the sessions after it.
# Usage: rows=$(cage_meta_rows '.uuid // "", .cwd // ""') || return 1
cage_meta_rows() {
    local projection="$1"
    local metas=() f
    while IFS= read -r -d '' f; do metas+=("$f"); done < <(cage_all_meta_files)
    [ ${#metas[@]} -eq 0 ] && return 0
    jq -r "[input_filename, ${projection}] | @tsv" "${metas[@]}" || {
        echo -e "${RED}Error:${NC} corrupt meta.json in ${CAGE_STORAGE} (see jq error above)" >&2
        return 1
    }
}

# Whole days from <date> to today (UTC midnights, so DST-safe; negative when
# <date> is ahead of the local date, e.g. after a westward timezone change)
# Usage: cage_days_ago 2026-01-03 -> 2 (when today is 2026-01-05)
cage_days_ago() {
    echo $(( ($(date -ud "$(date +%Y-%m-%d)" +%s) - $(date -ud "$1" +%s)) / 86400 ))
}

# Relative display code for a dated dir entry. Display-only: it rots at
# midnight, so printed resume hints must use the absolute cage-YYYY-MM-DD-N
# handle instead.
# Usage: cage_relative_code 2026-01-05 3 -> s0-3 (when today is 2026-01-05)
cage_relative_code() {
    local day_raw="$1" session_num="$2"
    echo "s$(cage_days_ago "$day_raw")-${session_num}"
}

# Get next available session number in a dated dir. The dir is an argument so
# a caller's captured day and the numbering can never disagree across a
# midnight boundary.
# Usage: cage_next_session_num "$log_dir" -> 1 (or next available)
cage_next_session_num() {
    local log_dir="${1:?cage_next_session_num requires a log_dir}"
    mkdir -p "$log_dir"

    local session_num=1
    while [ -f "${log_dir}/cage_${session_num}.log" ] || [ -f "${log_dir}/cage_${session_num}.pid" ] || [ -f "${log_dir}/cage_${session_num}.meta.json" ]; do
        ((session_num++))
    done
    echo "$session_num"
}

# Allocate today's next session slot (dated dir, number, handle, uuid) in one
# consistent step. Sets globals: _cage_day, _cage_log_dir, _cage_session_num,
# _cage_session_name, _cage_uuid (same globals pattern as cage_resolve_status).
# Usage: cage_alloc_session
cage_alloc_session() {
    _cage_day=$(date +%Y-%m-%d)
    _cage_log_dir="${CAGE_STORAGE}/${_cage_day}"
    mkdir -p "$_cage_log_dir"
    # Atomic slot claim: noclobber-create the meta file inside the search
    # loop, so two concurrent allocations can never compute the same number
    # (the real meta content overwrites this placeholder moments later)
    while :; do
        _cage_session_num=$(cage_next_session_num "$_cage_log_dir")
        if (set -o noclobber; echo '{}' > "${_cage_log_dir}/cage_${_cage_session_num}.meta.json") 2>/dev/null; then
            break
        fi
    done
    _cage_session_name="cage-${_cage_day}-${_cage_session_num}"
    _cage_uuid=$(uuidgen)
}

# Print session info header before launching claude
# Usage: cage_print_session_header "cage-2026-04-04-2 (s0-2)" profile model cwd
cage_print_session_header() {
    local session_display="$1"
    local profile="$2"
    local model="$3"
    local cwd="$4"
    echo -e "${GREEN}✓${NC} Session: ${BOLD}${session_display}${NC}"
    echo -e "${GREEN}✓${NC} Profile: ${PURPLE}${profile}${NC}  Model: ${CYAN}${model}${NC}  CWD: ${CYAN}${cwd}${NC}"
    echo ""
}

# Print resume hint after claude exits
# Usage: cage_print_resume_hint session_id
cage_print_resume_hint() {
    local session_id="$1"
    echo -e "${CYAN}Resume with:${NC} cage resume ${session_id}"
}

# Path to Claude's transcript for a session. Claude Code's project slug maps
# '/', '.' AND '_' to '-' (verified against real ~/.claude/projects dirs) —
# converting only '/' silently misses any cwd containing a dot or underscore.
# Usage: cage_transcript_path cwd uuid
cage_transcript_path() {
    local cwd="$1" uuid="$2"
    local slug="${cwd//\//-}"
    slug="${slug//./-}"
    slug="${slug//_/-}"
    echo "${HOME}/.claude/projects/${slug}/${uuid}.jsonl"
}

# Check if Claude stored a conversation for a session
# Returns 0 if conversation file exists, 1 otherwise
# Usage: cage_has_conversation cwd uuid
cage_has_conversation() {
    local cwd="$1" uuid="$2"
    [ -n "$cwd" ] && [ -n "$uuid" ] || return 1
    [ -f "$(cage_transcript_path "$cwd" "$uuid")" ]
}

# Current display name of a session: the LAST custom-title record in the
# transcript (cage sets one at launch via --name; in-session /rename appends
# another). Prints nothing and returns 1 when transcript or title is missing —
# callers fall back to the meta .name explicitly.
# Usage: cage_display_name cwd uuid
cage_display_name() {
    local transcript
    transcript=$(cage_transcript_path "$1" "$2")
    [ -f "$transcript" ] || return 1
    # Unanchored grep prefilter (matches the "custom-title" type VALUE anywhere
    # in the line, so serialization/key-order changes don't break it) keeps the
    # scan cheap on multi-MB transcripts; jq then parses only candidate lines,
    # discarding false positives from conversation text.
    local title
    title=$(tac "$transcript" | grep -a '"custom-title"' \
        | jq -Rr 'fromjson? | select(.type=="custom-title") | .customTitle // empty' 2>/dev/null \
        | grep -m1 . )
    [ -n "$title" ] || return 1
    printf '%s\n' "$title"
}

# jq program emitting each real user prompt from a transcript, one per line
# (isMeta records, command noise, and tool_result-only messages are skipped;
# newlines collapsed). Shared by cage_session_context / cage_real_prompt_count.
_CAGE_PROMPT_JQ='fromjson?
    | select(.type=="user" and (.isMeta != true))
    | .message.content
    | if type=="array" then (map(select(.type=="text") | .text) | join(" ")) else . end
    | select(type=="string") | select(length>0) | select(startswith("<")|not)
    | gsub("[\\n\\t]+"; " ")'

# One-line "what was this session about" snippet: the first real user prompt.
# Prints nothing and returns 1 when the transcript or a prompt is missing —
# callers skip the line.
# Usage: cage_session_context cwd uuid
cage_session_context() {
    local transcript
    transcript=$(cage_transcript_path "$1" "$2")
    [ -f "$transcript" ] || return 1
    local ctx
    ctx=$(jq -Rr "$_CAGE_PROMPT_JQ" "$transcript" 2>/dev/null | head -n 1)
    [ -n "$ctx" ] || return 1
    printf '%s\n' "$ctx"
}

# Number of real user prompts in the transcript, capped at 2: callers only
# distinguish 0/1 from "2 or more", and the cap keeps the scan cheap.
# Usage: cage_real_prompt_count cwd uuid -> 0|1|2
cage_real_prompt_count() {
    local transcript
    transcript=$(cage_transcript_path "$1" "$2")
    [ -f "$transcript" ] || { echo 0; return; }
    jq -Rr "$_CAGE_PROMPT_JQ" "$transcript" 2>/dev/null | head -n 2 | wc -l
}

# Near-empty: an interactive session that never went anywhere — no task, no
# result, not /rename'd, and at most one greeting-sized prompt (<25 chars).
# A single SUBSTANTIAL question is normal quick-Q&A usage and never counts.
# Session listings hide these by default and the interactive exit paths offer
# to delete them on the spot.
# Usage: cage_is_near_empty cwd uuid meta_file
cage_is_near_empty() {
    local cwd="$1" uuid="$2" meta_file="$3"
    [ -f "${meta_file%.meta.json}.result.json" ] && return 1
    [ -n "$(jq -r '.task // ""' "$meta_file" 2>/dev/null)" ] && return 1
    local first
    if [ $# -ge 4 ]; then
        # caller already extracted the first prompt — reuse, don't rescan
        first="$4"
        [ -z "$first" ] && return 0
    else
        first=$(cage_session_context "$cwd" "$uuid") || return 0
    fi
    # A substantial first prompt settles it here: the expensive whole-file
    # scans below then only ever run on short-first-prompt sessions, whose
    # transcripts are tiny
    [ "${#first}" -ge 25 ] && return 1
    # a /rename'd session was deliberately labeled — never debris
    local name dn
    name=$(jq -r '.name // ""' "$meta_file" 2>/dev/null)
    dn=$(cage_display_name "$cwd" "$uuid") || dn="$name"
    [ "$dn" != "$name" ] && return 1
    [ "$(cage_real_prompt_count "$cwd" "$uuid")" -lt 2 ]
}

# Remove every registry file of one session row; prunes the dated dir once it
# empties. The Claude-side transcript is never touched.
# Usage: cage_remove_session_files "$meta_file"
cage_remove_session_files() {
    local base="${1%.meta.json}"
    rm -f "$base".{meta.json,log,pid,status,result.json,result.md,settings.json,sysprompt}
    rmdir --ignore-fail-on-non-empty "$(dirname "$1")" 2>/dev/null
}

# Claude Code's transcript retention in days (cleanupPeriodDays; 30 is the
# platform's documented default when the key is absent from settings)
cage_cleanup_period_days() {
    jq -r '.cleanupPeriodDays // 30' "${HOME}/.claude/settings.json" 2>/dev/null || echo 30
}

# Resolve session status label from pid/status/log files
# Sets globals: _cage_status (colored label), _cage_running (true/false), _cage_pid (PID if running)
# Usage: cage_resolve_status pid_file status_file log_file
cage_resolve_status() {
    local pid_file="$1" status_file="$2" log_file="$3"
    _cage_running=false
    _cage_status="${DIM}FINISHED${NC}"
    _cage_pid=""

    local pid=""
    [ -f "$pid_file" ] && read -r pid < "$pid_file"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        _cage_status="${BOLD}${GREEN}RUNNING${NC}"
        _cage_running=true
        _cage_pid="$pid"
    elif [ -f "$status_file" ]; then
        local exit_code=""
        read -r exit_code < "$status_file"
        if [ "$exit_code" = "0" ]; then
            if [ -f "$log_file" ]; then
                local size; size=$(du -h "$log_file" 2>/dev/null | cut -f1)
                _cage_status="${GREEN}SUCCESS${NC} (${size})"
            else
                _cage_status="${GREEN}FINISHED${NC}"
            fi
        elif [ -n "$exit_code" ]; then
            _cage_status="${RED}FAILED${NC} (exit $exit_code)"
        fi
    elif [ -f "$log_file" ]; then
        local size; size=$(du -h "$log_file" 2>/dev/null | cut -f1)
        _cage_status="${DIM}UNKNOWN${NC} (${size})"
    fi
}

# Wrap interactive claude session with PID tracking and terminal background color
# Usage: cage_interactive_start "$pid_file"; ...; cage_interactive_end "$pid_file"
cage_interactive_start() {
    local pid_file="$1"
    echo $$ > "$pid_file"
    [ -t 1 ] && printf '\e]11;%s\a' "${COLOR_bg_claude:-#301000}"
}

cage_interactive_end() {
    local pid_file="$1"
    [ -t 1 ] && printf '\e]11;%s\a' "${COLOR_bg_shell:-#300020}"
    rm -f "$pid_file"
}

# Follow-the-session cd: when the cage() shell wrapper (dotfiles
# shortcuts.sh) exports CAGE_CWD_FILE, record the session cwd there so the
# wrapper can cd the calling shell after the session ends. Interactive
# sessions only. A failed write warns instead of aborting: the handoff is
# cosmetic, and a nested cage (inside a sandboxed claude) may not be allowed
# to write /tmp.
# Usage: cage_write_cwd_handoff "$work_dir"
cage_write_cwd_handoff() {
    [ -n "$CAGE_CWD_FILE" ] || return 0
    printf '%s\n' "$1" > "$CAGE_CWD_FILE" 2>/dev/null \
        || echo -e "${YELLOW}Warning:${NC} cannot write cwd handoff: $CAGE_CWD_FILE" >&2
}

# Check if a session is currently running
# Usage: cage_is_running "s0-1" -> 0 (running) or 1 (not running)
cage_is_running() {
    local session="$1"
    local pid_file=$(cage_get_session_file "$session" "pid")

    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Get session PID if running
# Usage: cage_get_pid "s0-1" -> 12345 or empty
cage_get_pid() {
    local session="$1"
    local pid_file=$(cage_get_session_file "$session" "pid")

    if [ -f "$pid_file" ]; then
        cat "$pid_file"
    fi
}

# Refuse to act on a RUNNING session: a second claude on the same transcript
# corrupts turn ordering, and the resume paths would clobber its pid file.
# (kill -0 based, so a crashed session with a leftover pid file still passes.)
# Usage: cage_refuse_if_running "$session" || return 1
cage_refuse_if_running() {
    cage_is_running "$1" || return 0
    echo -e "${RED}Error:${NC} session $1 is already running (PID $(cage_get_pid "$1")) — cannot resume while active (use 'cage kill $1' if it is stuck)" >&2
    return 1
}

# Recreate a session's working directory if missing. claude --resume only
# finds the transcript from the cwd it was recorded under, so the caller's
# cwd is never substituted.
# Usage: cage_ensure_cwd "$orig_cwd" || return 1
cage_ensure_cwd() {
    [ -d "$1" ] && return 0
    mkdir -p "$1" || {
        echo -e "${RED}Error:${NC} cannot recreate session cwd: $1" >&2
        return 1
    }
}

# A registry row without a transcript cannot be resumed (the transcript aged
# past Claude Code's retention, or claude was never reached). Fail loudly and
# KEEP the row — deleting it would destroy the only remaining record.
# Usage: cage_require_transcript "$session" "$orig_cwd" "$uuid" || return 1
cage_require_transcript() {
    local session="$1" cwd="$2" uuid="$3"
    cage_has_conversation "$cwd" "$uuid" && return 0
    echo -e "${RED}Error:${NC} no transcript exists for session $session (expected $(cage_transcript_path "$cwd" "$uuid")) — likely expired past Claude Code's transcript retention" >&2
    return 1
}

# Load and validate a session's meta for resuming: parse the fields, verify
# name/cwd presence, and run the resume guards (running-session refusal, cwd
# recreation, transcript existence). Sets globals: _cage_meta_file, _cage_name
# (the canonical absolute handle — callers should replace their user-typed
# reference with it, since relative codes shift at midnight), _cage_profile,
# _cage_cwd, _cage_model, _cage_effort, _cage_tools, _cage_sys_prompt.
# Usage: cage_load_resume_meta "$session" "$uuid" || return 1
cage_load_resume_meta() {
    local session="$1" uuid="$2"
    _cage_meta_file=$(cage_get_session_file "$session" "meta.json")
    _cage_name="" _cage_profile="" _cage_cwd="" _cage_model=""
    _cage_effort="" _cage_tools="" _cage_sys_prompt=""
    if [ ! -f "$_cage_meta_file" ]; then
        echo -e "${RED}Error:${NC} metadata file missing for session $session — cannot resume" >&2
        return 1
    fi
    eval "$(jq -r '
        "_cage_name=" + (.name // "" | @sh) + " " +
        "_cage_profile=" + (.profile // "" | @sh) + " " +
        "_cage_cwd=" + (.cwd // "" | @sh) + " " +
        "_cage_model=" + (.model // "sonnet" | @sh) + " " +
        "_cage_effort=" + (.effort // "xhigh" | @sh) + " " +
        "_cage_tools=" + (.tools // "" | @sh) + " " +
        "_cage_sys_prompt=" + (.system_prompt // "" | @sh)
    ' "$_cage_meta_file" 2>/dev/null)"
    if [ -z "$_cage_name" ] || [ -z "$_cage_cwd" ]; then
        echo -e "${RED}Error:${NC} metadata for session $session lacks name or cwd: $_cage_meta_file" >&2
        return 1
    fi
    cage_refuse_if_running "$_cage_name" || return 1
    cage_ensure_cwd "$_cage_cwd" || return 1
    cage_require_transcript "$_cage_name" "$_cage_cwd" "$uuid" || return 1
}

# Validate a profile's sandbox block (compact JSON string).
# Allowed shape: {"filesystem":{"allowWrite":[],"denyWrite":[],"allowRead":[]},
#                 "network":{"allowedDomains":[]}}
# Filesystem entries must be absolute paths; domains must be non-empty/whitespace-free.
# Prints one clear error per problem to stderr; returns 1 on any problem, 0 if valid.
# Usage: cage_validate_sandbox "$compact_json" "$profile_name"
cage_validate_sandbox() {
    local sandbox_json="$1" profile_name="$2"
    local errs
    errs=$(jq -r '
        def fs_check($k):
          if has($k) then
            if (.[$k]|type) != "array" then "sandbox.filesystem.\($k) must be an array of strings"
            else (.[$k][] | select((type!="string") or (startswith("/")|not))
                  | "sandbox.filesystem.\($k) must contain absolute paths (got \(@json))")
            end
          else empty end;
        [ (if type!="object" then "sandbox must be a JSON object" else empty end),
          (if type=="object" and length==0 then "sandbox block is empty; define filesystem and/or network" else empty end),
          (if type=="object" then (keys_unsorted[] | select(.!="filesystem" and .!="network") | "unknown sandbox key: \(.)") else empty end),
          (if type=="object" and has("filesystem") then
             (if (.filesystem|type)!="object" then "sandbox.filesystem must be an object"
              else (.filesystem | keys_unsorted[] | select(.!="allowWrite" and .!="denyWrite" and .!="allowRead") | "unknown sandbox.filesystem key: \(.)"),
                   (.filesystem | fs_check("allowWrite")), (.filesystem | fs_check("denyWrite")), (.filesystem | fs_check("allowRead"))
              end) else empty end),
          (if type=="object" and has("network") then
             (if (.network|type)!="object" then "sandbox.network must be an object"
              else (.network | keys_unsorted[] | select(.!="allowedDomains") | "unknown sandbox.network key: \(.)"),
                   (if (.network|has("allowedDomains")) then
                      (if (.network.allowedDomains|type)!="array" then "sandbox.network.allowedDomains must be an array of strings"
                       else (.network.allowedDomains[] | select((type!="string") or (.=="") or test("\\s")) | "sandbox.network.allowedDomains has invalid domain (got \(@json))") end)
                    else empty end)
              end) else empty end)
        ] | .[]
    ' <<< "$sandbox_json" 2>&1)
    local rc=$?

    if [ $rc -ne 0 ]; then
        echo -e "${RED}Error:${NC} profile '${profile_name}' has malformed sandbox JSON: ${errs}" >&2
        return 1
    fi
    if [ -n "$errs" ]; then
        echo -e "${RED}Error:${NC} invalid sandbox block in profile '${profile_name}':" >&2
        while IFS= read -r line; do
            [ -n "$line" ] && echo "  - $line" >&2
        done <<< "$errs"
        return 1
    fi
    return 0
}

# Write a per-session settings file containing ONLY the sandbox block.
# Produces exactly {"sandbox": <block>} so `claude --settings <file>` merges it.
# Usage: cage_write_sandbox_settings "$settings_file" "$compact_sandbox_json"
cage_write_sandbox_settings() {
    local settings_file="$1" sandbox_json="$2"
    jq -n --argjson sandbox "$sandbox_json" '{sandbox: $sandbox}' > "$settings_file"
}
