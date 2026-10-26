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
# Transcript copies of pinned ("Keep long") sessions, restored when Claude
# Code's retention sweep has deleted the original
CAGE_ARCHIVE="${CAGE_STORAGE}/archive"
# User settings (tracked copy: ~/MEGA/config/dotfiles/config/cage/config.json,
# linked by config-sync)
CAGE_CONFIG="${HOME}/.config/cage/config.json"
# Append-only record of what cage did to rows on its own (follows, hang-ups),
# readable after the terminal that printed it is gone
CAGE_EVENTS="${CAGE_STORAGE}/events.log"
# Claude Code's record of each live claude process: <pid>.json holding its
# pid and sessionId
CAGE_CLAUDE_SESSIONS="${HOME}/.claude/sessions"

# Append one line to the event log: time, session handle, event, detail.
# A failed write warns: the log is a diagnostic, and the change it records
# has already happened.
# Usage: cage_event "$handle" event "detail"
cage_event() {
    printf '%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$1" "$2" "${3//[$'\t\n']/ }" >> "$CAGE_EVENTS" 2>/dev/null \
        || echo -e "${YELLOW}Warning:${NC} cannot write the event log: $CAGE_EVENTS" >&2
}

# Load and validate the user settings. Every key is required and no other is
# allowed: a missing file, a missing or unknown key or an invalid value is an
# error naming the fix. Sets
# CFG_CLOSE_ASK (always|unless-named|never), CFG_CLOSE_DEFAULT
# (keep|delete|auto), CFG_PIN_DAYS, CFG_SHORT_MAX_PROMPTS and
# CFG_SHORT_PROMPT_MAX_CHARS (whole numbers >= 1).
# Usage: cage_load_config || return 1
cage_load_config() {
    if [ ! -f "$CAGE_CONFIG" ]; then
        echo -e "${RED}Error:${NC} cage settings missing: $CAGE_CONFIG (tracked copy in ~/MEGA/config/dotfiles/config/cage/; link it with 'config-sync install')" >&2
        return 1
    fi
    local out
    out=$(jq -r '
        # Wholeness is checked on the printed literal, which is what the
        # shell receives: digits only (jq 1.7 prints 30.0 as "30.0" and 1e2 as
        # "1E+2", which bash arithmetic and test -gt reject)
        def whole($k): if (.[$k]|type)=="number" and .[$k]>=1
                          and (.[$k]|tostring|test("^[0-9]+$")) then empty
                       else "\($k) must be a whole number >= 1 (got \(.[$k]|@json))" end;
        if type != "object" then "ERR\tthe settings must be a JSON object (got \(type))"
        else
          [ (keys_unsorted[] | select(IN("close_ask","close_default","pin_days","short_max_prompts","short_prompt_max_chars")|not) | "unknown key: \(.)"),
            (if (.close_ask|IN("always","unless-named","never")) then empty else "close_ask must be always, unless-named or never (got \(.close_ask|@json))" end),
            (if (.close_default|IN("keep","delete","auto")) then empty else "close_default must be keep, delete or auto (got \(.close_default|@json))" end),
            whole("pin_days"), whole("short_max_prompts"), whole("short_prompt_max_chars")
          ] as $errs
          | if ($errs|length)>0 then "ERR\t" + ($errs|join("\n"))
            else "CFG_CLOSE_ASK=\(.close_ask|@sh) CFG_CLOSE_DEFAULT=\(.close_default|@sh) CFG_PIN_DAYS=\(.pin_days) CFG_SHORT_MAX_PROMPTS=\(.short_max_prompts) CFG_SHORT_PROMPT_MAX_CHARS=\(.short_prompt_max_chars)" end
        end
    ' "$CAGE_CONFIG") || {
        echo -e "${RED}Error:${NC} cage settings are not valid JSON: $CAGE_CONFIG (see jq error above)" >&2
        return 1
    }
    if [[ $out == ERR$'\t'* ]]; then
        echo -e "${RED}Error:${NC} invalid cage settings in $CAGE_CONFIG:" >&2
        local line
        while IFS= read -r line; do echo "  - $line" >&2; done <<< "${out#ERR$'\t'}"
        return 1
    fi
    # jq prints nothing for an empty file and one line per value for several:
    # exactly one assignment line is the only valid outcome
    if [[ $out != CFG_CLOSE_ASK=* ]] || [[ $out == *$'\n'* ]]; then
        echo -e "${RED}Error:${NC} cage settings must hold exactly one JSON object: $CAGE_CONFIG" >&2
        return 1
    fi
    eval "$out"
}

# JSON output schema for background sessions
CAGE_JSON_OUTPUT_FLAGS='--output-format json --json-schema {"type":"object","properties":{"status":{"type":"string","enum":["success","error","partial"]},"summary":{"type":"string"},"files_created":{"type":"array","items":{"type":"string"}},"files_modified":{"type":"array","items":{"type":"string"}},"files_read":{"type":"array","items":{"type":"string"}},"errors":{"type":"array","items":{"type":"string"}},"data":{"type":"object"},"next_steps":{"type":"array","items":{"type":"string"}}},"required":["status","summary"]}'

# The session reference forms that win over a display name, in resolution
# order: relative code (days ago, number), absolute handle (date, number),
# UUID. The [sS] and [-_] classes exist because stored meta .name fields and
# transcripts contain underscore spellings — both must keep resolving. The
# day count may be negative (registry dir dated ahead of the local date after
# a westward timezone change). Must be expanded unquoted in [[ =~ ]]: a
# quoted pattern is matched literally, not as a regex; the groups fill
# BASH_REMATCH.
_CAGE_CODE_RE='^[sS](-?[0-9]+)[-_]([0-9]+)$'
_CAGE_HANDLE_RE='^cage[-_]([0-9]{4}-[0-9]{2}-[0-9]{2})[-_]([0-9]+)$'
_CAGE_UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# True when <s> parses as a code, handle or UUID, i.e. it can never be
# resolved as a display name
# Usage: cage_is_session_ref "$s"
cage_is_session_ref() {
    [[ $1 =~ $_CAGE_CODE_RE ]] || [[ $1 =~ $_CAGE_HANDLE_RE ]] || [[ $1 =~ $_CAGE_UUID_RE ]]
}

# Parse a session reference and return full path to a session file
# Accepts: s<days>-<num>, cage-YYYY-MM-DD-N, a UUID (the _CAGE_*_RE forms
# above), or a /rename'd display name.
# Usage: cage_get_session_file "s0-1" "result.json" -> ~/.local/state/cage/2026-01-05/cage_1.result.json
cage_get_session_file() {
    local session="$1"
    local file_type="$2"  # log, pid, status, meta.json, result.json

    local target_date=""
    local session_num=""

    # Parse s<days>-<num> relative format (e.g., s0-1, s1-3, s-1-2)
    if [[ $session =~ $_CAGE_CODE_RE ]]; then
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
        local today_epoch=$(cage_today_epoch)
        target_date=$(date -ud "@$(( today_epoch - days_ago * 86400 ))" +%Y-%m-%d)
    # Parse cage-YYYY-MM-DD-N absolute format (e.g., cage-2026-01-05-1)
    elif [[ $session =~ $_CAGE_HANDLE_RE ]]; then
        target_date=${BASH_REMATCH[1]}
        session_num=${BASH_REMATCH[2]}
    # UUID format: the row holding it now or before Claude Code moved the
    # conversation (cage_rows_holding_uuid)
    elif [[ $session =~ $_CAGE_UUID_RE ]]; then
        local meta_file
        meta_file=$(cage_rows_holding_uuid "$session") || return 1
        if [ -z "$meta_file" ]; then
            echo "No session found for UUID: $session" >&2
            return 1
        fi
        if [[ $meta_file == *$'\n'* ]]; then
            echo "UUID $session is held by several sessions:" >&2
            local m
            while IFS= read -r m; do echo "  $(cage_handle_from_meta "$m")" >&2; done <<< "$meta_file"
            return 1
        fi
        # Extract date and number from meta file path
        local base=$(basename "$meta_file" .meta.json)
        session_num=${base#cage_}
        target_date=$(basename "$(dirname "$meta_file")")
    else
        # /rename'd display name (runs only when no code/UUID form matched above)
        local found matches=()
        found=$(cage_sessions_named "$session") || return 1
        [ -n "$found" ] && mapfile -t matches <<< "$found"
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

# jq definition splitting a `grep -H` line into the file path (f) and the
# JSON record (j). Anchored on the record's opening brace, so a ':' inside
# the path cannot cut it short. Shared by the batch readers below.
_CAGE_GREP_H_SPLIT_JQ='def grep_h_split: capture("^(?<f>.*?):(?<j>\\{.*)$");'

# The last non-empty custom-title of each given transcript file, as
# "<file>\t<title>" lines (files without one print nothing), in one grep and
# one jq however many files: the batch form of cage_title_in_file, for
# lookups over the whole registry. A grep read error fails loudly.
# Usage: out=$(cage_titles_of "$file"...) || return 1
cage_titles_of() {
    [ $# -gt 0 ] || return 0
    # Unanchored grep prefilter (the "custom-title" type VALUE anywhere in the
    # line, so serialization/key-order changes don't break it); jq then
    # discards false positives from conversation text
    local -a g=(-a -H -- '"custom-title"' "$@")
    _cage_grep_jq g -nRr "$_CAGE_GREP_H_SPLIT_JQ"'
        reduce (inputs | grep_h_split
                | {f, t: (.j | fromjson? | select(.type=="custom-title") | .customTitle // "")}
                | select(.t != "")) as $x ({}; .[$x.f] = $x.t)
        | to_entries[] | "\(.key)\t\(.value | gsub("[\t\n]"; " "))"' || {
        echo -e "${RED}Error:${NC} cannot read the session titles (error above)" >&2
        return 1
    }
}

# Meta paths of every session whose current display name (the last
# custom-title of its transcript) equals <name>, one per line. A pinned
# session whose transcript the sweep deleted is named by its archive copy,
# so it still resolves and the resume can restore it. One batched title read
# over every transcript (cage_titles_of).
# Usage: found=$(cage_sessions_named "$name") || return 1
cage_sessions_named() {
    local rows
    rows=$(cage_meta_rows '.uuid // "", .cwd // "", .keep_until // ""') || return 1
    [ -n "$rows" ] || return 0
    local mf muuid mcwd mkeep file today titles title
    local -a files=()
    local -A meta_of
    today=$(date +%Y-%m-%d)
    while IFS="$_CAGE_ROW_SEP" read -r mf muuid mcwd mkeep; do
        [ -n "$muuid" ] && [ -n "$mcwd" ] || continue
        cage_transcript_path_var file "$mcwd" "$muuid"
        if [ ! -f "$file" ] && cage_pin_active "$mkeep" "$today"; then
            cage_archive_path_var file "$muuid"
        fi
        [ -f "$file" ] || continue
        files+=("$file")
        meta_of["$file"]+="$mf"$'\n'
    done <<< "$rows"
    titles=$(cage_titles_of "${files[@]}") || return 1
    [ -n "$titles" ] || return 0
    while IFS=$'\t' read -r file title; do
        [ "$title" = "$1" ] && printf '%s' "${meta_of[$file]}"
    done <<< "$titles"
    return 0
}

# Meta paths of every registry row holding session <uuid>, one per line: as
# its uuid, or among the ids it held before Claude Code moved the
# conversation (previous_uuids). A fork row's parent_uuid does not count.
# The one rule for which row an id belongs to (UUID references and the
# follow's ownership check). grep narrows the files and jq decides; a grep
# or jq failure is an error naming the unreadable files.
# Usage: holders=$(cage_rows_holding_uuid "$uuid") || return 1
cage_rows_holding_uuid() {
    local -a metas=() cands=()
    local f found
    while IFS= read -r -d '' f; do metas+=("$f"); done < <(cage_all_meta_files)
    [ ${#metas[@]} -gt 0 ] || return 0
    found=$(grep -l -F -- "\"$1\"" "${metas[@]}")
    case $? in
        0) ;;
        1) return 0 ;;
        *) echo -e "${RED}Error:${NC} cannot read the registry metas in ${CAGE_STORAGE} (grep error above)" >&2
           return 1 ;;
    esac
    mapfile -t cands <<< "$found"
    jq -r --arg u "$1" 'select(.uuid == $u or ((.previous_uuids // []) | index($u))) | input_filename' \
        -- "${cands[@]}" || {
        _cage_report_corrupt_metas "${cands[@]}"
        return 1
    }
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

# Resolve a /rename'd name to its absolute handle, into the named variable;
# the other reference forms (code, handle, UUID) pass through unchanged, so
# a relative code stays relative. A name is resolved ONCE here, since every
# later lookup by name would read the titles of the whole registry again.
# Usage: cage_handle_of_ref out_var "$ref" || return 1
cage_handle_of_ref() {
    local -n _chr_out="$1"
    if cage_is_session_ref "$2"; then
        _chr_out="$2"
        return 0
    fi
    local _chr_meta
    _chr_meta=$(cage_get_session_file "$2" "meta.json") || return 1
    _chr_out=$(cage_handle_from_meta "$_chr_meta")
}

# Absolute handle for a registry meta path
# Usage: cage_handle_from_meta ~/.local/state/cage/2026-01-05/cage_3.meta.json -> cage-2026-01-05-3
cage_handle_from_meta() {
    local day num
    cage_meta_parts_var day num "$1"
    echo "cage-${day}-${num}"
}

# All meta.json paths across dated dirs, newest first, NUL-separated.
# find gets the storage root itself (never a glob): an unmatched glob under
# nullglob would leave find with zero operands and it defaults to '.'
# Usage: while IFS= read -r -d '' f; do ...; done < <(cage_all_meta_files)
cage_all_meta_files() {
    find "${CAGE_STORAGE}" -mindepth 2 -maxdepth 2 -name "*.meta.json" -printf '%T@\t%p\0' 2>/dev/null | sort -rzn | cut -zf2
}

# Field separator of cage_meta_rows and of the resume picker's cache. Not a
# tab: tab is IFS whitespace, so `read` would merge the tabs around an empty
# field (a meta without keep_until or task) and shift every later field one
# to the left.
_CAGE_ROW_SEP=$'\x1f'

# Report the corrupt metas among <meta>... after a batch jq over them failed:
# jq's own parse error gives only a line and column, so each file is checked
# again (on that failure path only) and every one that is not a JSON object
# is named. The one corrupt-meta report (cage_meta_rows,
# cage_rows_holding_uuid).
# Usage: jq ... "${metas[@]}" || { _cage_report_corrupt_metas "${metas[@]}"; return 1; }
_cage_report_corrupt_metas() {
    echo -e "${RED}Error:${NC} corrupt meta.json in ${CAGE_STORAGE} (jq error above); unreadable:" >&2
    local f
    for f; do
        jq -e 'type == "object"' -- "$f" > /dev/null 2>&1 || echo "  $f" >&2
    done
}

# Project fields from every registry meta as rows separated by _CAGE_ROW_SEP
# (first field is always the meta path; newlines and separators inside values
# become spaces), newest first. Empty output when the registry is empty. jq
# aborts at the first corrupt file; the failure names the corrupt files
# (_cage_report_corrupt_metas) instead of silently dropping the sessions
# after it.
# Usage: rows=$(cage_meta_rows '.uuid // "", .cwd // ""') || return 1
#        while IFS="$_CAGE_ROW_SEP" read -r mf uuid cwd; do ...; done <<< "$rows"
cage_meta_rows() {
    local prog="[input_filename, ${1}] | map(tostring | gsub(\"[\\n\\u001f]\"; \" \")) | join(\"\\u001f\")"
    local metas=() f
    while IFS= read -r -d '' f; do metas+=("$f"); done < <(cage_all_meta_files)
    [ ${#metas[@]} -eq 0 ] && return 0
    jq -r "$prog" "${metas[@]}" || {
        _cage_report_corrupt_metas "${metas[@]}"
        return 1
    }
}

# Epoch of today's local date taken as a UTC midnight: the base of all day
# arithmetic (UTC midnights are exactly 86400 s apart, so it is DST-safe)
cage_today_epoch() {
    date -ud "$(date +%Y-%m-%d)" +%s
}

# Whole days between two such epochs, into the named variable (no subshell).
# Negative when the day is ahead of the local date (westward timezone change).
# Usage: cage_days_ago_var out_var today_epoch day_epoch
cage_days_ago_var() {
    local -n _cda_out="$1"
    _cda_out=$(( ($2 - $3) / 86400 ))
}

# Whole days from <date> to today
# Usage: cage_days_ago 2026-01-03 -> 2 (when today is 2026-01-05)
cage_days_ago() {
    local _cda_days
    cage_days_ago_var _cda_days "$(cage_today_epoch)" "$(date -ud "$1" +%s)"
    echo "$_cda_days"
}

# Relative display code from precomputed epochs, into the named variable (no
# subshell, for per-row loops). Display-only: it rots at midnight, so printed
# resume hints must use the absolute cage-YYYY-MM-DD-N handle instead.
# Usage: cage_relative_code_var out_var today_epoch day_epoch session_num
cage_relative_code_var() {
    local -n _crc_out="$1"
    local _crc_days
    cage_days_ago_var _crc_days "$2" "$3"
    _crc_out="s${_crc_days}-$4"
}

# The dated day and session number of a registry meta path, into the named
# variables, by parameter expansion (no fork, for per-row loops)
# Usage: cage_meta_parts_var day_var num_var "$meta_file"
cage_meta_parts_var() {
    local -n _cmp_day="$1" _cmp_num="$2"
    local _cmp_dir="${3%/*}"
    _cmp_day="${_cmp_dir##*/}"
    _cmp_num="${3##*/cage_}"
    _cmp_num="${_cmp_num%.meta.json}"
}

# Relative display code of a dated day and session number, into the named
# variable; the day's epoch is memoized in the named associative array, so a
# per-row loop forks date once per distinct day
# Usage: cage_day_code_var code_var epoch_map "$today_epoch" "$day" "$num"
cage_day_code_var() {
    local -n _cdc_epochs="$2"
    [ -n "${_cdc_epochs[$4]}" ] || _cdc_epochs["$4"]=$(date -ud "$4" +%s)
    cage_relative_code_var "$1" "$3" "${_cdc_epochs[$4]}" "$5"
}

# Relative display code for a dated dir entry
# Usage: cage_relative_code 2026-01-05 3 -> s0-3 (when today is 2026-01-05)
cage_relative_code() {
    local _crc_code
    cage_relative_code_var _crc_code "$(cage_today_epoch)" "$(date -ud "$1" +%s)" "$2"
    echo "$_crc_code"
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

# Path to Claude's transcript for a session. Claude Code's project slug turns
# every non-alphanumeric character into '-' (no ~/.claude/projects dir name
# holds anything but [A-Za-z0-9-]); mapping only '/', '.' and '_' would miss
# any cwd with a space, '+', '@' or a non-ASCII character.
# Usage: cage_transcript_path cwd uuid
cage_transcript_path() {
    local _ctp_path
    cage_transcript_path_var _ctp_path "$1" "$2"
    echo "$_ctp_path"
}

# Same, written into the named variable: no subshell, for per-row loops
# Usage: cage_transcript_path_var out_var cwd uuid
cage_transcript_path_var() {
    local -n _ctp_out="$1"
    _ctp_out="${HOME}/.claude/projects/${2//[^a-zA-Z0-9]/-}/${3}.jsonl"
}

# Check if Claude stored a conversation for a session
# Returns 0 if conversation file exists, 1 otherwise
# (no subshell, so per-row loops can call it)
# Usage: cage_has_conversation cwd uuid
cage_has_conversation() {
    [ -n "$1" ] && [ -n "$2" ] || return 1
    local _chc_path
    cage_transcript_path_var _chc_path "$1" "$2"
    [ -f "$_chc_path" ]
}

# Path of a session's archive copy (pinned sessions), into the named
# variable; its subagent dir is the same path minus .jsonl, as for the
# transcript
# Usage: cage_archive_path_var out_var uuid
cage_archive_path_var() {
    local -n _cap_out="$1"
    _cap_out="${CAGE_ARCHIVE}/${2}.jsonl"
}

# The LAST non-empty custom-title record in a transcript file (cage sets one
# at launch via --name; in-session /rename appends another), read by
# cage_titles_of, the one definition of a session's title, so what cage
# status shows and what cage resume <name> finds can never differ. Prints
# nothing and returns 1 when the file or a title is missing, and 2 when the
# scan failed (error printed).
# Usage: cage_title_in_file "$transcript_or_archive_copy"
cage_title_in_file() {
    [ -f "$1" ] || return 1
    local out
    out=$(cage_titles_of "$1") || return 2
    [ -n "$out" ] || return 1
    printf '%s\n' "${out#*$'\t'}"
}

# Current display name of a session, from its transcript (see
# cage_title_in_file). Returns 1 when transcript or title is missing —
# callers use the meta .name then — and 2 when the scan failed.
# Usage: cage_display_name cwd uuid
cage_display_name() {
    local transcript
    cage_transcript_path_var transcript "$1" "$2"
    cage_title_in_file "$transcript"
}

# True when a session was /rename'd: its current title is set and differs
# from the meta .name cage launched it with. The one place that rule lives
# (the picker applies it to its cached titles).
# Usage: cage_is_renamed "$title" "$meta_name"
cage_is_renamed() {
    [ -n "$1" ] && [ "$1" != "$2" ]
}

# A session's current display name (the meta .name when it has no title) and
# whether it was /rename'd (true, false, or unknown when the title scan
# failed, error printed: no caller may read that as "not renamed"), into the
# named variables
# Usage: cage_named_var dn_var named_var cwd uuid meta_name
cage_named_var() {
    local -n _cnv_dn="$1" _cnv_named="$2"
    local _cnv_rc
    _cnv_dn=$(cage_display_name "$3" "$4")
    _cnv_rc=$?
    _cnv_named=false
    if [ "$_cnv_rc" -eq 2 ]; then
        _cnv_dn="$5" _cnv_named=unknown
    elif [ "$_cnv_rc" -ne 0 ]; then
        _cnv_dn="$5"
    elif cage_is_renamed "$_cnv_dn" "$5"; then
        _cnv_named=true
    fi
    return 0
}

# Pipe grep into jq and fail when either side fails: grep exit 2 is a read
# error (1 = no match, and a SIGPIPE after jq stopped early, are not), and
# jq's own status otherwise. The first argument names an array holding the
# grep arguments; the rest are jq's. Output is jq's. The one place that rule
# lives, for every grep-prefiltered transcript scan (cage_titles_of,
# _cage_jq_records, cage_first_prompts_of).
# Usage: local -a g=(<grep args>); out=$(_cage_grep_jq g <jq args...>) || ...
_cage_grep_jq() {
    local -n _cgj_grep_args="$1"
    shift
    grep "${_cgj_grep_args[@]}" | jq "$@"
    local -a st=("${PIPESTATUS[@]}")
    [ "${st[0]}" -eq 2 ] && return 2
    return "${st[1]}"
}

# Run a jq program (read with -n, so it consumes `inputs` itself) over the
# lines of a transcript that mention a record type value (the grep
# prefilter, e.g. '"user"', keeps multi-hundred-MB transcripts cheap; jq
# still checks the type). Fails as _cage_grep_jq does.
# Usage: out=$(_cage_jq_records '"user"' "$transcript" [jq args...] "$program") || ...
_cage_jq_records() {
    local pattern="$1" file="$2"
    shift 2
    local -a g=(-a -- "$pattern" "$file")
    _cage_grep_jq g -nRr "$@"
}

# jq program emitting each real user prompt from a transcript, one per line
# (isMeta records, command noise, tool_result-only messages and
# [Request interrupted…] markers are skipped; newlines collapsed): the one
# definition of a real prompt. Run by cage_prompt_summary_of_file (one
# transcript; every per-session reader goes through it),
# cage_first_prompts_of (the picker's batch) and _CAGE_CONTINUED_JQ (a prompt
# after a continued-in record makes the stub live again, so editing this
# rule also changes which moved sessions are followed); the resume picker's
# cache key hashes it, so editing it invalidates that cache by itself.
_CAGE_PROMPT_JQ='fromjson?
    | select(.type=="user" and (.isMeta != true))
    | .message.content
    | if type=="array" then (map(select(.type=="text") | .text) | join(" ")) else . end
    | select(type=="string") | select(length>0) | select(startswith("<")|not)
    | select(startswith("[Request interrupted")|not)
    | gsub("[\\n\\t]+"; " ")'

# First prompt and prompt count (capped at <cap>) of one transcript file in
# one scan: the per-file prompt extractor, which every per-session reader
# goes through (cage_prompt_summary, cage_session_context, and the picker's
# exact scan of a file the batch could not settle). A grep prefilter on the
# "user" type value hands jq only candidate lines, which keeps
# multi-hundred-MB transcripts fast; jq still decides what a real prompt is.
# A missing file has no prompts. Prints "<count>\t<first prompt>"; returns 1
# when the scan failed (error printed), so a broken scan never reads as "no
# prompts".
# Usage: out=$(cage_prompt_summary_of_file "$transcript" 10) || ...
#        IFS=$'\t' read -r count first <<< "$out"
cage_prompt_summary_of_file() {
    local out prompts=()
    if [ -f "$1" ]; then
        out=$(_cage_jq_records '"user"' "$1" --argjson n "$2" "limit(\$n; inputs | $_CAGE_PROMPT_JQ)") || {
            echo -e "${RED}Error:${NC} cannot read the prompts of $1 (error above)" >&2
            return 1
        }
        [ -n "$out" ] && mapfile -t prompts <<< "$out"
    fi
    printf '%s\t%s\n' "${#prompts[@]}" "${prompts[0]-}"
}

# The same for a session given by cwd and uuid
# Usage: out=$(cage_prompt_summary "$cwd" "$uuid" 10) || ...
cage_prompt_summary() {
    local transcript
    cage_transcript_path_var transcript "$1" "$2"
    cage_prompt_summary_of_file "$transcript" "$3"
}

# The first real prompt of each given transcript file, as "<file>\t<prompt>"
# lines, in one grep and one jq however many files: the batch form of
# cage_prompt_summary_of_file, for the resume picker's cache misses. grep
# stops after the first 20 "user" lines of each file, where the first prompt
# nearly always is; a file without one there prints nothing, and the caller
# (_cage_picker_entries) runs cage_prompt_summary_of_file on it, so the
# result is exact. A grep read error fails loudly.
# Usage: out=$(cage_first_prompts_of "$file"...) || return 1
cage_first_prompts_of() {
    [ $# -gt 0 ] || return 0
    local -a g=(-a -H -m 20 -- '"user"' "$@")
    _cage_grep_jq g -nRr "$_CAGE_GREP_H_SPLIT_JQ"'
        reduce (inputs | grep_h_split
                | {f, p: (.j | '"$_CAGE_PROMPT_JQ"')}) as $x
               ({}; if has($x.f) then . else .[$x.f] = $x.p end)
        | to_entries[] | "\(.key)\t\(.value)"' || {
        echo -e "${RED}Error:${NC} cannot read the session prompts (error above)" >&2
        return 1
    }
}

# One-line "what was this session about" snippet: the first real user prompt.
# Prints nothing and returns 1 when the transcript or a prompt is missing —
# callers skip the line — and 2 when the scan failed (error printed). Reads
# cage_prompt_summary (which runs cage_prompt_summary_of_file, the per-file
# prompt extractor).
# Usage: cage_session_context cwd uuid
cage_session_context() {
    local _csc_out _csc_count _csc_first
    _csc_out=$(cage_prompt_summary "$1" "$2" 1) || return 2
    IFS=$'\t' read -r _csc_count _csc_first <<< "$_csc_out"
    [ -n "$_csc_first" ] || return 1
    printf '%s\n' "$_csc_first"
}

# jq definitions shared by _CAGE_INPUT_JQ and _CAGE_NONTEXT_JQ, so the two
# checks cannot drift apart: what a slash-command record looks like, and the
# walk over a user record's content (a plain string, or an array of items:
# a tool_result item never counts, any other non-text item always does, a
# text item when its text passes p). user_input(p) prints "1" per match.
_CAGE_USER_INPUT_DEFS='def slash_record: test("^<(command-|local-command-)");
    def user_input(p):
        fromjson?
        | select(.type=="user" and (.isMeta != true))
        | .message.content
        | if type=="array"
          then any(.[]; type=="object" and .type != "tool_result" and (.type != "text" or (.text|p)))
          else p end
        | select(.) | 1;'

# jq program printing "1" for any user record someone typed or pasted, text
# prompt or not: markup, an image, a bash-mode command. What does not count:
# isMeta records, the records slash commands write (<command-…>,
# <local-command-…>), [Request interrupted…] markers and tool_result-only
# messages. Both content forms get the same tests: a plain string, or an
# array of items (Claude Code writes interrupt markers and some slash-command
# records as text items). Broader than _CAGE_PROMPT_JQ on purpose: it decides
# whether a session may be deleted without asking.
_CAGE_INPUT_JQ="$_CAGE_USER_INPUT_DEFS"'
    def typed: type=="string" and length>0 and (slash_record|not)
        and (startswith("[Request interrupted")|not);
    user_input(typed)'

# Whether the session had any input: Claude answered at all (a session run
# only through a skill or custom slash command has no typed record, yet
# real work), or someone typed or pasted something (see _CAGE_INPUT_JQ). A
# session with neither was opened and closed: cage new deletes it without
# asking, so a failing check must never read as "no input". Returns 0
# input, 1 none, 2 when a scan failed (grep or jq; the error is shown). A
# missing transcript returns 1 on purpose: claude was never reached or wrote
# nothing, so there is nothing to keep.
# Usage: cage_has_user_input cwd uuid; case $? in ...
cage_has_user_input() {
    local transcript hit
    cage_transcript_path_var transcript "$1" "$2"
    [ -f "$transcript" ] || return 1
    local fail="cannot check the session for input: $transcript (error above)"
    hit=$(_cage_jq_records '"assistant"' "$transcript" 'first(inputs | fromjson? | select(.type=="assistant") | 1)') || {
        echo -e "${RED}Error:${NC} $fail" >&2
        return 2
    }
    if [ -z "$hit" ]; then
        hit=$(_cage_jq_records '"user"' "$transcript" "first(inputs | $_CAGE_INPUT_JQ)") || {
            echo -e "${RED}Error:${NC} $fail" >&2
            return 2
        }
    fi
    [ -n "$hit" ]
}

# jq program printing "1" for a user record holding non-text input: an
# image or other non-text item, or pasted markup (a string or text item
# starting with "<" that is not a slash-command record). _CAGE_PROMPT_JQ
# drops all of these, so a short caption under a screenshot or a pasted log
# would otherwise look like a near-empty session.
_CAGE_NONTEXT_JQ="$_CAGE_USER_INPUT_DEFS"'
    def markup: type=="string" and startswith("<") and (slash_record|not);
    user_input(markup)'

# Whether the session holds non-text input (see _CAGE_NONTEXT_JQ). Returns 0
# yes, 1 no (a missing transcript included), 2 when the scan failed (the
# error is shown).
# Usage: cage_has_nontext_input cwd uuid; case $? in ...
cage_has_nontext_input() {
    local transcript hit
    cage_transcript_path_var transcript "$1" "$2"
    [ -f "$transcript" ] || return 1
    hit=$(_cage_jq_records '"user"' "$transcript" "first(inputs | $_CAGE_NONTEXT_JQ)") || {
        echo -e "${RED}Error:${NC} cannot check the session for pasted input: $transcript (error above)" >&2
        return 2
    }
    [ -n "$hit" ]
}

# Near-empty: an interactive session that never went anywhere — no task, no
# result, not /rename'd, at most short_max_prompts prompts and a first prompt
# of at most short_prompt_max_chars characters (cage settings; needs
# cage_load_config); never with pasted markup or images
# (cage_has_nontext_input), and with no text prompt at all only when nothing
# else happened either (cage_has_user_input). A SUBSTANTIAL first question is
# normal quick-Q&A usage and never counts, and a failed scan never counts.
# Listings hide these by default, and the close menu defaults to Delete for
# them when close_default is auto. Called with 3 arguments it scans; a
# caller that already holds the facts passes all three so nothing is
# recomputed: the first prompt, whether the session is /rename'd (true,
# false or unknown as cage_named_var sets it, or empty to look it up only if
# needed) and the prompt count (exact up to
# at least short_max_prompts + 1).
# Usage: cage_is_near_empty cwd uuid meta_file [first named count]
cage_is_near_empty() {
    local cwd="$1" uuid="$2" meta_file="$3"
    [ -f "${meta_file%.meta.json}.result.json" ] && return 1
    [ -n "$(jq -r '.task // ""' "$meta_file" 2>/dev/null)" ] && return 1
    local first="$4" named="$5" count="$6"
    if [ $# -eq 3 ]; then
        # One scan for the count and the first prompt; a failed scan (error
        # printed) is never near-empty
        local summary
        summary=$(cage_prompt_summary "$cwd" "$uuid" $(( CFG_SHORT_MAX_PROMPTS + 1 ))) || return 1
        IFS=$'\t' read -r count first <<< "$summary"
    fi
    [ "${#first}" -gt "$CFG_SHORT_PROMPT_MAX_CHARS" ] && return 1
    [ "$count" -le "$CFG_SHORT_MAX_PROMPTS" ] || return 1
    # a /rename'd session was deliberately labeled — never debris, whatever
    # its prompts; nor is one whose title scan failed. Looked up only now,
    # for the few rows still in question.
    if [ -z "$named" ]; then
        local dn
        cage_named_var dn named "$cwd" "$uuid" "$(jq -r '.name // ""' "$meta_file" 2>/dev/null)"
    fi
    [ "$named" = false ] || return 1
    # Pasted markup or images make a session real whatever its text prompts
    # (a short caption under a screenshot); a failed check counts as input
    cage_has_nontext_input "$cwd" "$uuid"
    [ $? -eq 1 ] || return 1
    # No text prompt: near-empty only when nothing else happened either (no
    # Claude reply to a skill or custom command)
    if [ "$count" -eq 0 ]; then
        cage_has_user_input "$cwd" "$uuid"
        [ $? -eq 1 ]
        return
    fi
    return 0
}

# Remove every registry file of one session row; prunes the dated dir once it
# empties. The Claude-side transcript is never touched. Returns non-zero when
# a file could not be removed (rm prints the cause); the dated-dir prune is
# best-effort, since a non-empty dir is the normal case.
# Usage: cage_remove_session_files "$meta_file"
cage_remove_session_files() {
    local base="${1%.meta.json}"
    rm -f "$base".{meta.json,log,pid,status,result.json,result.md,settings.json,sysprompt} || return 1
    rmdir --ignore-fail-on-non-empty "$(dirname "$1")" 2>/dev/null
    return 0
}

# Refuse a malformed session uuid before any recursive removal built from it:
# the subagent dir is the transcript path minus .jsonl and the archive copy is
# ${CAGE_ARCHIVE}/<uuid>, so an empty uuid would name a whole project dir or
# the whole archive.
# Usage: cage_require_uuid "$uuid" || return 1
cage_require_uuid() {
    [[ $1 =~ $_CAGE_UUID_RE ]] && return 0
    echo -e "${RED}Error:${NC} invalid session uuid '$1'" >&2
    return 1
}

# Remove a registry row and its archive copy, if any (a pin that has expired
# leaves one behind, which nothing else would ever reach). Claude's
# transcript is not touched. A row without a uuid (an allocation placeholder)
# has no archive copy.
# Usage: cage_remove_session_row "$meta_file" "$uuid" || return 1
cage_remove_session_row() {
    if [ -n "$2" ]; then
        cage_require_uuid "$2" || return 1
        local copy
        cage_archive_path_var copy "$2"
        rm -rf -- "$copy" "${copy%.jsonl}" || return 1
    fi
    cage_remove_session_files "$1"
}

# Delete a session everywhere: Claude's transcript and its subagent dir, the
# transcripts of its previous ids (older copies Claude Code left when it
# moved the conversation, see cage_follow_session), the pinned archive copy,
# and the registry row. Irreversible.
# Usage: cage_delete_session "$meta_file" "$cwd" "$uuid" || return 1
cage_delete_session() {
    local meta_file="$1" cwd="$2" uuid="$3" transcript previous id
    cage_require_uuid "$uuid" || return 1
    previous=$(jq -r '.previous_uuids // [] | .[]' "$meta_file") || {
        echo -e "${RED}Error:${NC} cannot read previous ids from $meta_file" >&2
        return 1
    }
    # Every id is checked before anything is removed: a claude still open on
    # one of them (e.g. the worker a background hand-off started) would go on
    # writing a transcript that no longer exists
    for id in "$uuid" $previous; do
        cage_require_uuid "$id" || return 1
        cage_refuse_if_live "cannot delete $(cage_handle_from_meta "$meta_file")" "$id" || return 1
    done
    for id in "$uuid" $previous; do
        cage_transcript_path_var transcript "$cwd" "$id"
        rm -rf -- "$transcript" "${transcript%.jsonl}" || return 1
    done
    cage_remove_session_row "$meta_file" "$uuid"
}

# True while a keep_until date (YYYY-MM-DD, from meta) has not passed. A
# per-row loop passes today's date once computed, to spare a date fork per
# row.
# Usage: cage_pin_active "$keep_until" [today]
cage_pin_active() {
    [ -n "$1" ] && [[ ! $1 < ${2:-$(date +%Y-%m-%d)} ]]
}

# Copy a session's transcript (and its subagent dir) into the archive, so a
# pinned session survives Claude Code's retention sweep. Each copy replaces
# the previous one; the transcript must exist.
# Usage: cage_archive_transcript "$cwd" "$uuid" || return 1
cage_archive_transcript() {
    local transcript copy
    cage_require_uuid "$2" || return 1
    cage_transcript_path_var transcript "$1" "$2"
    cage_archive_path_var copy "$2"
    if [ ! -f "$transcript" ]; then
        echo -e "${RED}Error:${NC} cannot archive: no transcript at $transcript" >&2
        return 1
    fi
    mkdir -p "${copy%/*}" || return 1
    cp -- "$transcript" "$copy.tmp" && mv -- "$copy.tmp" "$copy" || {
        rm -f -- "$copy.tmp"
        return 1
    }
    rm -rf -- "${copy%.jsonl}" || return 1
    [ -d "${transcript%.jsonl}" ] && { cp -r -- "${transcript%.jsonl}" "${copy%.jsonl}" || return 1; }
    return 0
}

# Put an archived transcript back where Claude Code looks for it. The copy
# gets a fresh mtime, which starts a new retention period for the sweep.
# Usage: cage_restore_transcript "$cwd" "$uuid" || return 1
cage_restore_transcript() {
    local transcript copy
    cage_require_uuid "$2" || return 1
    cage_transcript_path_var transcript "$1" "$2"
    cage_archive_path_var copy "$2"
    if [ ! -f "$copy" ]; then
        echo -e "${RED}Error:${NC} pinned session $2 has neither a transcript nor an archive copy ($copy); it can never be resumed — remove its row with 'cage clean --expired'" >&2
        return 1
    fi
    mkdir -p "${transcript%/*}" || return 1
    cp -- "$copy" "$transcript" || return 1
    # -T: when the sweep left the subagent dir in place, merge into it instead
    # of nesting the copy inside it (<uuid>/<uuid>/), where Claude never looks
    if [ -d "${copy%.jsonl}" ]; then
        cp -rT -- "${copy%.jsonl}" "${transcript%.jsonl}" || return 1
    fi
    return 0
}

# Rewrite a session meta in place with a jq filter (and its jq arguments).
# The temp file lives in the meta's own dir, so the mv is an atomic
# same-filesystem rename (a reader never sees half a file).
# Usage: cage_meta_jq "$meta_file" [jq args...] "$filter" || return 1
cage_meta_jq() {
    local meta="$1" tmp
    shift
    tmp=$(mktemp "$meta.XXXXXX") || return 1
    if jq "$@" "$meta" > "$tmp" && mv -- "$tmp" "$meta"; then
        return 0
    fi
    rm -f "$tmp"
    echo -e "${RED}Error:${NC} cannot update $meta (error above)" >&2
    return 1
}

# Set one string field of a session meta in place
# Usage: cage_meta_set "$meta_file" key value || return 1
cage_meta_set() {
    cage_meta_jq "$1" --arg k "$2" --arg v "$3" '.[$k] = $v'
}

# How much of a transcript's end cage_continuation_of reads: the
# continued-in record is followed only by a few KB of bookkeeping
_CAGE_CONTINUED_WINDOW=1048576
# How much of each registered transcript's end cage_follow_moved_sessions
# scans for candidates (a miss leaves the row as it is, never misfollows it)
_CAGE_MOVED_SCAN_BYTES=65536

# jq program over a transcript's last lines, newest first (read with -n):
# the target id of the last continued-in record when no completed turn
# follows it, else nothing; MALFORMED when that record names no target (a
# missing, empty or non-string id), which cage_continuation_of rejects
# loudly. A completed turn is an assistant reply that finished (a string
# stop_reason, not an API error) or a real prompt (_CAGE_PROMPT_JQ). The
# same test Claude Code's /resume uses to hide a superseded session: a stub
# resumed and typed into after the move is a live conversation again.
_CAGE_CONTINUED_JQ='first(inputs | . as $line | fromjson? | objects
        | if .type == "continued-in"
          then (.continuedInSessionId | if type == "string" and . != "" then . else "MALFORMED" end)
          elif .type == "assistant" and (.message.stop_reason | type) == "string"
               and .isApiErrorMessage != true then ""
          elif ([$line | '"$_CAGE_PROMPT_JQ"'] | length) > 0 then ""
          else empty end)
    | select(. != "")'

# Claude Code moves a conversation to a new session id when it is handed to
# the background (`←` on an empty prompt, /background, Ctrl+B mid-turn): a
# worker continues it in a new transcript in the same project dir, and the
# old transcript, now a stub, gets a continued-in record naming the new id.
# /branch, /fork and --fork-session write no such record (the original stays
# a conversation of its own), so they are never followed. Prints the id
# <uuid> continues in, or nothing: no record in the last
# _CAGE_CONTINUED_WINDOW bytes, a completed turn after it
# (_CAGE_CONTINUED_JQ), or a target transcript that was never written or
# holds no record (a worker that did not start). Returns 1 on a read
# failure, and on a record whose target is missing, empty, not a UUID or
# the session's own id (error printed), which never reads as "not moved".
# Usage: next=$(cage_continuation_of cwd uuid) || return 1
cage_continuation_of() {
    local transcript last id="" next target
    cage_transcript_path_var transcript "$1" "$2"
    [ -f "$transcript" ] || return 0
    # Streamed, never held in a shell variable (bash is slow on a MB string).
    # grep settles the common cases cheaply: no record at all, or a last
    # record naming a worker that never wrote its transcript (such a stub
    # stays a candidate of every listing). The record's own match comes
    # before its id's, so a last line that is the record itself means it
    # names no id: jq then reports it as malformed.
    last=$(tail -c "$_CAGE_CONTINUED_WINDOW" -- "$transcript" \
        | grep -a -o -e '"continued-in"' -e '"continuedInSessionId":[^,}]*' | tail -n 1
        exit "${PIPESTATUS[0]}") || {
        echo -e "${RED}Error:${NC} cannot read $transcript" >&2
        return 1
    }
    [ -n "$last" ] || return 0
    [[ $last =~ ^\"continuedInSessionId\":\"([^\"]*)\"$ ]] && id="${BASH_REMATCH[1]}"
    if [[ $id =~ $_CAGE_UUID_RE ]] && [ ! -f "${transcript%/*}/${id}.jsonl" ]; then
        return 0
    fi
    next=$(tail -c "$_CAGE_CONTINUED_WINDOW" -- "$transcript" | tac | jq -nRr "$_CAGE_CONTINUED_JQ") || {
        echo -e "${RED}Error:${NC} cannot read the records of $transcript (jq error above)" >&2
        return 1
    }
    [ -n "$next" ] || return 0
    if ! [[ $next =~ $_CAGE_UUID_RE ]] || [ "$next" = "$2" ]; then
        echo -e "${RED}Error:${NC} $transcript has a malformed continued-in record (target '$next')" >&2
        return 1
    fi
    target="${transcript%/*}/${next}.jsonl"
    [ -f "$target" ] || return 0
    grep -q -m1 -F '"parentUuid":' -- "$target"
    case $? in
        0) printf '%s\n' "$next" ;;
        1) ;;
        *) echo -e "${RED}Error:${NC} cannot read $target" >&2; return 1 ;;
    esac
}

# Report a follow failure on the terminal and in the event log
# Usage: _cage_follow_failed "$handle" "message"; return 1
_cage_follow_failed() {
    echo -e "${RED}Error:${NC} cannot follow $1: $2" >&2
    cage_event "$1" follow-failed "$2"
}

# Follow a session to the transcript Claude Code continued it in (see
# cage_continuation_of), hop by hop. Each hop keeps the old id in
# previous_uuids and rewrites the meta only while its uuid is still the one
# followed from, so two follows at once cannot record a hop twice. A pinned
# row's archive copy is replaced by a copy of the new transcript (the old
# copy holds only the stub). Refused, with the error printed and logged: a
# pointer back into the row's own history or at another row's session
# (either would merge two conversations into one row), and a chain of more
# than 10 hops. Prints the final uuid (the same one when nothing moved); each
# hop is announced on stderr and recorded in the event log.
# Usage: uuid=$(cage_follow_session "$meta_file" "$cwd" "$uuid") || return 1
cage_follow_session() {
    local meta_file="$1" cwd="$2" uuid="$3" next hops=0 handle holders mf old_copy mtime
    handle=$(cage_handle_from_meta "$meta_file")
    while :; do
        next=$(cage_continuation_of "$cwd" "$uuid") || {
            _cage_follow_failed "$handle" "cannot read the transcript of $uuid (error above)"
            return 1
        }
        [ -n "$next" ] || break
        hops=$((hops + 1))
        if [ "$hops" -gt 10 ]; then
            _cage_follow_failed "$handle" "more than 10 hops from $3"
            return 1
        fi
        holders=$(cage_rows_holding_uuid "$next") || {
            _cage_follow_failed "$handle" "the registry is unreadable (error above)"
            return 1
        }
        while IFS= read -r mf; do
            [ -n "$mf" ] && [ "$mf" != "$meta_file" ] || continue
            _cage_follow_failed "$handle" "$uuid continues in $next, which belongs to $(cage_handle_from_meta "$mf")"
            return 1
        done <<< "$holders"
        # This row's own state is decided by the swap, in one read: already
        # at <next> (a follow that ran meanwhile; nothing changes), <next>
        # among its previous ids (the pointer leads back into its own
        # history), or moved elsewhere meanwhile. The meta's mtime orders the
        # listings by activity; a follow is bookkeeping, so the row keeps its
        # place.
        mtime=$(stat -c %Y -- "$meta_file") \
            && cage_meta_jq "$meta_file" --arg o "$uuid" --arg n "$next" '
            if .uuid == $n then .
            elif ((.previous_uuids // []) | index($n)) then error("\($o) points back to its earlier id \($n)")
            elif .uuid != $o then error("the row moved to \(.uuid) meanwhile")
            else .previous_uuids = ((.previous_uuids // []) + [.uuid]) | .uuid = $n end' \
            && touch -d "@$mtime" -- "$meta_file" || {
            _cage_follow_failed "$handle" "the meta was not updated for $uuid -> $next (reason above)"
            return 1
        }
        cage_archive_path_var old_copy "$uuid"
        if [ -f "$old_copy" ]; then
            cage_archive_transcript "$cwd" "$next" && rm -rf -- "$old_copy" "${old_copy%.jsonl}" || {
                _cage_follow_failed "$handle" "cannot move the pin's archive copy to $next (error above)"
                return 1
            }
        fi
        echo -e "${DIM}Claude Code continued ${handle} as session ${next}; cage follows it (previous id ${uuid} kept in the meta).${NC}" >&2
        cage_event "$handle" followed "$uuid -> $next"
        uuid="$next"
    done
    printf '%s\n' "$uuid"
}

# Follow every registry row Claude Code moved to a new session id (see
# cage_follow_session), so a command reads each row's current conversation:
# its /rename'd name, its prompts, the transcript a resume must open. One
# tail over the last _CAGE_MOVED_SCAN_BYTES of every registered transcript
# finds the candidates, and only those get the exact check; a candidate the
# window misses keeps its row as it is, it never makes a wrong follow.
# RUNNING rows are skipped: an interactive one is followed by its wrapper
# when claude exits, a -p job's row by the next call after the job ended.
# Returns 0, 1 when a follow failed (error printed and logged) or a
# transcript could not be read (printed, not logged: no row is named), with
# the registry still readable, and 2 when the registry is unreadable (the
# files are named).
# Usage: cage_follow_moved_sessions; case $? in ...
cage_follow_moved_sessions() {
    local rows
    rows=$(cage_meta_rows '.uuid // "", .cwd // ""') || return 2
    [ -n "$rows" ] || return 0
    local mf uuid cwd t hits hit tail_rc failed=0
    local -a files=()
    local -A row_of
    while IFS="$_CAGE_ROW_SEP" read -r mf uuid cwd; do
        [ -n "$uuid" ] && [ -n "$cwd" ] || continue
        cage_transcript_path_var t "$cwd" "$uuid"
        [ -f "$t" ] || continue
        files+=("$t")
        row_of["$t"]="${mf}${_CAGE_ROW_SEP}${cwd}${_CAGE_ROW_SEP}${uuid}"
    done <<< "$rows"
    [ ${#files[@]} -gt 0 ] || return 0
    # tail -v heads each file's chunk with "==> path <=="; a hit belongs to
    # the last header seen
    hits=$(tail -v -c "$_CAGE_MOVED_SCAN_BYTES" -- "${files[@]}" | awk '
        /^==> .* <==$/ { f = substr($0, 5, length($0) - 8); next }
        f != "" && index($0, "\"continued-in\"") { print f; f = "" }'
        exit "${PIPESTATUS[0]}")
    tail_rc=$?
    if [ "$tail_rc" -ne 0 ]; then
        echo -e "${RED}Error:${NC} cannot read every registered transcript (tail error above); moved sessions among them are not followed" >&2
        failed=1
    fi
    [ -n "$hits" ] || return $failed
    while IFS= read -r hit; do
        [ -n "${row_of[$hit]}" ] || continue
        IFS="$_CAGE_ROW_SEP" read -r mf cwd uuid <<< "${row_of[$hit]}"
        cage_meta_running "$mf" && continue
        cage_follow_session "$mf" "$cwd" "$uuid" > /dev/null || failed=1
    done <<< "$hits"
    return $failed
}

# Pin a session ("Keep long"): keep_until = today + pin_days (cage settings),
# and archive its transcript now.
# Usage: cage_pin_session "$meta_file" "$cwd" "$uuid" || return 1
cage_pin_session() {
    local meta_file="$1" keep_until
    keep_until=$(date -d "+${CFG_PIN_DAYS} days" +%Y-%m-%d)
    cage_archive_transcript "$2" "$3" || return 1
    cage_meta_set "$meta_file" keep_until "$keep_until" || return 1
    echo -e "${GREEN}✓${NC} Pinned until ${keep_until} (transcript archived in ${CAGE_ARCHIVE})"
}

# Name a session exactly the way /rename does: append Claude's title records
# to the transcript (claude has exited, so nothing else writes it). The name
# then shows in cage status and the picker and resolves with cage resume.
# Refuses a name that parses as a session code, handle or UUID: those forms
# win at resolution, so the name could never be resumed by. A name another
# session already carries is accepted, as with /rename; cage resume <name>
# then refuses and lists both handles.
# Usage: cage_name_session "$cwd" "$uuid" "$name" || return 1
cage_name_session() {
    local cwd="$1" uuid="$2" name="$3" transcript
    if [ -z "$name" ]; then
        echo -e "${RED}Error:${NC} empty name" >&2
        return 1
    fi
    if cage_is_session_ref "$name"; then
        echo -e "${RED}Error:${NC} '$name' looks like a session code, handle or UUID; pick a distinctive name" >&2
        return 1
    fi
    cage_transcript_path_var transcript "$cwd" "$uuid"
    # Appending to a missing transcript would create a stub of two title
    # records, which a pinned session's archive refresh would then copy over
    # the only full copy
    if [ ! -f "$transcript" ]; then
        echo -e "${RED}Error:${NC} cannot name: no transcript at $transcript" >&2
        return 1
    fi
    jq -nc --arg n "$name" --arg s "$uuid" \
        '{type: "custom-title", customTitle: $n, sessionId: $s}, {type: "agent-name", agentName: $n, sessionId: $s}' \
        >> "$transcript"
}

# Close-time decision for an interactive session (cage new calls it only when
# the session had user input; an interactive resume calls it when its
# transcript still exists), per the cage settings close_ask and
# close_default: Keep, Keep long (pin), Name and keep, Name and keep long, or
# Delete. Naming implies keeping, so it ends the menu. Without a terminal on
# stdin, or after a hang-up (<hup> true: the wrapper's HUP trap fired),
# nobody can answer, so the session is kept. A pinned session's archive is
# refreshed whenever it is kept. Returns 0 when kept, 10 when deleted, 1 on
# a failure (error printed).
# Usage: cage_close_session "$cwd" "$uuid" "$meta_file" "$session_name" "$hup"
cage_close_session() {
    local cwd="$1" uuid="$2" meta_file="$3" session_name="$4" hup="$5"
    local name keep_until dn named pinned=false fields
    # Checked: on an unreadable meta, empty name and keep_until would make
    # the session look named and unpinned
    fields=$(jq -r '"name=" + (.name // "" | @sh) + " keep_until=" + (.keep_until // "" | @sh)' "$meta_file") || {
        echo -e "${RED}Error:${NC} cannot read session metadata: $meta_file" >&2
        return 1
    }
    eval "$fields"
    cage_named_var dn named "$cwd" "$uuid" "$name"
    cage_pin_active "$keep_until" && pinned=true

    # Nobody can answer without a terminal on stdin, nor after a hang-up
    if [ "$CFG_CLOSE_ASK" = never ] || { [ "$CFG_CLOSE_ASK" = unless-named ] && [ "$named" = true ]; } \
        || [ ! -t 0 ] || [ "$hup" = true ]; then
        if [ "$pinned" = true ]; then cage_archive_transcript "$cwd" "$uuid" || return 1; fi
        return 0
    fi

    # Counted one past the larger of the header's cap and the near-empty
    # limit, so both the "10+" label and the near-empty test read an exact
    # answer from this one scan
    local cap=10 summary count first="" count_label="?" limit default="Keep"
    limit=$(( (cap > CFG_SHORT_MAX_PROMPTS ? cap : CFG_SHORT_MAX_PROMPTS) + 1 ))
    # A failed scan (error printed) leaves the count unknown and Keep the
    # default, whatever close_default says: nothing is pre-selected for
    # deletion on facts cage could not read
    if summary=$(cage_prompt_summary "$cwd" "$uuid" "$limit"); then
        IFS=$'\t' read -r count first <<< "$summary"
        count_label="$count"
        [ "$count" -gt "$cap" ] && count_label="${cap}+"
        if [ "$pinned" = false ]; then
            case "$CFG_CLOSE_DEFAULT" in
                delete) default="Delete" ;;
                # The first prompt, the name and the count are known here, so
                # the near-empty test does not redo the prompt scan (only a
                # session with no text prompt gets the input check)
                auto) cage_is_near_empty "$cwd" "$uuid" "$meta_file" "$first" "$named" "$count" && default="Delete" ;;
            esac
        fi
    fi
    local header choice new_name pin_label="Keep long (${CFG_PIN_DAYS} days)"
    local name_label="Name and keep" name_pin_label="Name and keep long (${CFG_PIN_DAYS} days)"
    header="Close ${session_name}"
    [ "$named" = true ] && header+="  \"${dn}\""
    header+=$'\n'"${count_label} prompt(s)"
    [ "$pinned" = true ] && header+=" · pinned until ${keep_until}"
    header+=" · ${first:0:60}"
    while :; do
        # Esc picks nothing: keep, the choice that loses nothing
        choice=$(gum choose --header "$header" --selected "$default" \
            "Keep" "$pin_label" "$name_label" "$name_pin_label" "Delete") || choice="Keep"
        case "$choice" in
            Keep)
                if [ "$pinned" = true ]; then cage_archive_transcript "$cwd" "$uuid" || return 1; fi
                return 0
                ;;
            "$pin_label")
                cage_pin_session "$meta_file" "$cwd" "$uuid" || return 1
                return 0
                ;;
            "$name_label"|"$name_pin_label")
                # Esc in the name prompt goes back to the menu
                new_name=$(gum input --placeholder "Session name (resume it with: cage resume <name>)" --value "$([ "$named" = true ] && printf '%s' "$dn")") || continue
                cage_name_session "$cwd" "$uuid" "$new_name" || continue
                echo -e "${GREEN}✓${NC} Named \"${new_name}\" — resume with: cage resume \"${new_name}\""
                if [ "$choice" = "$name_pin_label" ]; then
                    cage_pin_session "$meta_file" "$cwd" "$uuid" || return 1
                elif [ "$pinned" = true ]; then
                    cage_archive_transcript "$cwd" "$uuid" || return 1
                fi
                return 0
                ;;
            Delete)
                cage_delete_session "$meta_file" "$cwd" "$uuid" || {
                    echo -e "${RED}Error:${NC} cannot delete session $session_name (error above)" >&2
                    return 1
                }
                echo -e "${DIM}Session deleted (registry row, transcript and archive).${NC}"
                return 10
                ;;
        esac
    done
}

# True when a registry row's pid file points at a live process
# Usage: cage_meta_running "$meta_file"
cage_meta_running() {
    local pid_file="${1%.meta.json}.pid" pid=""
    [ -f "$pid_file" ] || return 1
    read -r pid < "$pid_file"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Keep the registry in step with Claude Code's transcripts. A pinned row
# (keep_until not passed) whose transcript the retention sweep deleted gets it
# restored from the archive. Every other row with no transcript (Claude Code
# purged it after cleanupPeriodDays, or claude was never reached) can never
# be resumed and is deleted, together with any archive copy an expired pin
# left. Rows with a background log or result are kept (cage
# result/tail/check still read them); RUNNING rows and today's rows (a launch
# may not have written its transcript yet) are never touched. These
# exemptions apply only to this automatic, unconfirmed prune: the confirmed
# `cage clean --expired` deliberately also removes today's and log/result
# rows. A row whose project dir does not exist
# at all is also spared: that points at a slug cage computed wrongly rather
# than a purged transcript, and an unconfirmed delete must not rest on it.
# Rows Claude Code moved to a new session id are followed first
# (cage_follow_moved_sessions), so the restore and prune below, and the
# listing after them, act on each row's current conversation.
# Prints one notice per kind of change. Returns 1 when a follow, restore or
# prune failed (the registry is still readable, so a listing can go on), and
# 2 when the registry itself could not be read (a corrupt meta.json, already
# reported with the files named): a listing after it would only fail again.
# Usage: cage_tidy_registry; case $? in ...
cage_tidy_registry() {
    local rows follow_rc=0
    cage_follow_moved_sessions
    case $? in
        0) ;;
        2) return 2 ;;
        *) follow_rc=1 ;;
    esac
    rows=$(cage_meta_rows '.uuid // "", .cwd // "", .keep_until // ""') || return 2
    [ -n "$rows" ] || return $follow_rc
    local today pruned=0 restored=0 unrestorable=0 mf uuid cwd keep_until day_dir base transcript
    today=$(date +%Y-%m-%d)
    while IFS="$_CAGE_ROW_SEP" read -r mf uuid cwd keep_until; do
        cage_transcript_path_var transcript "$cwd" "$uuid"
        [ -f "$transcript" ] && continue
        # A failed restore (error printed) is counted, not fatal: one broken
        # pin must not stop the other rows from being restored or pruned
        if cage_pin_active "$keep_until" "$today"; then
            if cage_restore_transcript "$cwd" "$uuid"; then
                restored=$((restored + 1))
            else
                unrestorable=$((unrestorable + 1))
            fi
            continue
        fi
        [ -d "${transcript%/*}" ] || continue
        day_dir="${mf%/*}"
        [ "${day_dir##*/}" = "$today" ] && continue
        cage_meta_running "$mf" && continue
        base="${mf%.meta.json}"
        { [ -f "$base.log" ] || [ -f "$base.result.json" ] || [ -f "$base.result.md" ]; } && continue
        cage_remove_session_row "$mf" "$uuid" || {
            echo -e "${RED}Error:${NC} cannot prune $(cage_handle_from_meta "$mf") (error above); ${pruned} record(s) were removed before it" >&2
            return 1
        }
        pruned=$((pruned + 1))
    done <<< "$rows"
    if [ "$restored" -gt 0 ]; then
        echo -e "${DIM}Restored ${restored} pinned transcript(s) from ${CAGE_ARCHIVE}${NC}" >&2
    fi
    if [ "$pruned" -gt 0 ]; then
        echo -e "${DIM}Pruned ${pruned} unresumable session record(s): no transcript left (background logs/results are kept)${NC}" >&2
    fi
    if [ "$unrestorable" -gt 0 ]; then
        echo -e "${RED}Error:${NC} ${unrestorable} pinned session(s) could not be restored (errors above)" >&2
        return 1
    fi
    return $follow_rc
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

# Wrap interactive claude session with PID tracking and terminal background
# color. The pid file stays until the close menu is done (cage_interactive_end
# after cage_close_session): while it shows, the session still counts as
# RUNNING, so no -p job or second resume can start on a transcript the menu
# may delete, rename or pin. The color goes back as soon as claude exits
# (cage_interactive_colors_off), so the menu is drawn in shell colors.
# Usage: cage_interactive_start "$pid_file"; ...; cage_interactive_end "$pid_file"
cage_interactive_start() {
    local pid_file="$1"
    echo $$ > "$pid_file"
    [ -t 1 ] && printf '\e]11;%s\a' "${COLOR_bg_claude:-#301000}"
}

cage_interactive_colors_off() {
    [ -t 1 ] && printf '\e]11;%s\a' "${COLOR_bg_shell:-#300020}"
    return 0
}

cage_interactive_end() {
    cage_interactive_colors_off
    rm -f "$1"
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
    cage_meta_running "$(cage_get_session_file "$1" "meta.json")"
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

# The pid of a live claude process holding session <uuid>, from Claude Code's
# own records of its processes: it sees a claude started outside cage
# (claude -r, a background worker), which cage's pid files cannot. A record
# counts only while its process lives and is still the one that wrote it
# (same start time), so a crashed claude's leftover record never blocks.
# Prints the pid and returns 0 when one is alive, returns 1 when none is, 2
# when a record cannot be read (the files are listed). Inside a sandbox with
# its own pid namespace no host process is visible, so nothing reads as
# alive there.
# Usage: pid=$(cage_live_claude_pid "$uuid"); case $? in ...
cage_live_claude_pid() {
    local -a recs=("$CAGE_CLAUDE_SESSIONS"/*.json)
    [ -e "${recs[0]}" ] || return 1
    local prog='select(.sessionId == $u and .pid != null) | "\(.pid) \(.procStart // "")"' pids pid
    if ! pids=$(jq -r --arg u "$1" "$prog" -- "${recs[@]}" 2> /dev/null); then
        # A record can vanish between the glob and the read (its claude
        # exited): read each one again, skip the vanished ones, and name
        # those still unreadable
        local f out bad=()
        pids=""
        for f in "${recs[@]}"; do
            [ -e "$f" ] || continue
            if out=$(jq -r --arg u "$1" "$prog" -- "$f" 2> /dev/null); then
                pids+="$out"$'\n'
            else
                bad+=("$f")
            fi
        done
        if [ ${#bad[@]} -gt 0 ]; then
            echo -e "${RED}Error:${NC} unreadable Claude Code session record(s):" >&2
            printf '  %s\n' "${bad[@]}" >&2
            return 2
        fi
    fi
    local start stat
    local -a fields
    while read -r pid start; do
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2> /dev/null || continue
        # A crashed claude leaves its record behind, and its pid can be
        # reused: procStart is the process start time (field 22 of
        # /proc/<pid>/stat, checked against every live record 2026-10-26),
        # so another start time means another process. A record without
        # it needs at least a process named claude.
        if [ -n "$start" ]; then
            stat=$(cat -- "/proc/$pid/stat" 2> /dev/null) || continue
            # Fields after the parenthesized name, which may hold spaces:
            # field 22 is the 20th of them
            read -ra fields <<< "${stat##*) }"
            [ "${fields[19]}" = "$start" ] || continue
        else
            [ "$(cat -- "/proc/$pid/comm" 2> /dev/null)" = claude ] || continue
        fi
        printf '%s\n' "$pid"
        return 0
    done <<< "$pids"
    return 1
}

# Refuse when a live claude holds session <uuid> (cage_live_claude_pid), and
# when that cannot be told
# Usage: cage_refuse_if_live "$what_is_refused" "$uuid" || return 1
cage_refuse_if_live() {
    local pid
    pid=$(cage_live_claude_pid "$2")
    case $? in
        1) return 0 ;;
        0) echo -e "${RED}Error:${NC} $1: session $2 is open in a running claude (PID $pid) — close that claude first" >&2 ;;
        *) echo -e "${RED}Error:${NC} $1: cannot tell whether a claude holds session $2 (unreadable records listed above)" >&2 ;;
    esac
    return 1
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
# past Claude Code's retention, or claude was never reached). Resuming one
# fails loudly and leaves the row alone: removing rows is the job of
# cage_tidy_registry (listing paths) and cage clean, not of a resume.
# The picker never offers a transcript-less row and RUNNING rows are refused
# earlier by cage_refuse_if_running, so this fires only when a resume names
# such a row directly (e.g. one the prune spared or has not reached yet).
# Usage: cage_require_transcript "$session" "$orig_cwd" "$uuid" || return 1
cage_require_transcript() {
    local session="$1" cwd="$2" uuid="$3"
    cage_has_conversation "$cwd" "$uuid" && return 0
    echo -e "${RED}Error:${NC} no transcript exists for session $session (expected $(cage_transcript_path "$cwd" "$uuid")) — likely expired past Claude Code's transcript retention" >&2
    return 1
}

# Load and validate a session's meta for resuming: parse the fields, verify
# name/cwd presence, and run the resume guards (running-session refusal, cwd
# recreation, restoring a pinned session's transcript from the archive when
# the sweep deleted it, following a move Claude Code made, refusal when a
# claude outside cage holds the conversation, transcript existence). Sets
# globals: _cage_meta_file, _cage_name (the canonical absolute handle —
# callers should replace their user-typed reference with it, since relative
# codes shift at midnight), _cage_resume_uuid (the session id to resume:
# <uuid>, or the one the conversation moved to), _cage_profile, _cage_cwd,
# _cage_model, _cage_effort, _cage_tools, _cage_sys_prompt, and the array
# _cage_plugin_dirs (each checked to still exist).
# Usage: cage_load_resume_meta "$session" "$uuid" || return 1
cage_load_resume_meta() {
    local session="$1" uuid="$2"
    _cage_meta_file=$(cage_get_session_file "$session" "meta.json")
    _cage_name="" _cage_profile="" _cage_cwd="" _cage_model=""
    _cage_effort="" _cage_tools="" _cage_sys_prompt="" _cage_resume_uuid=""
    local keep_until=""
    _cage_plugin_dirs=()
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
        "_cage_sys_prompt=" + (.system_prompt // "" | @sh) + " " +
        "keep_until=" + (.keep_until // "" | @sh) + " " +
        "_cage_plugin_dirs=(" + (.plugin_dirs // [] | @sh) + ")"
    ' "$_cage_meta_file" 2>/dev/null)"
    if [ -z "$_cage_name" ] || [ -z "$_cage_cwd" ]; then
        echo -e "${RED}Error:${NC} metadata for session $session lacks name or cwd: $_cage_meta_file" >&2
        return 1
    fi
    # --plugin-dir is per-invocation, so a resume re-passes the stored dirs;
    # resuming without a plugin the session was started with would silently
    # change its behavior
    local d
    for d in "${_cage_plugin_dirs[@]}"; do
        [ -e "$d" ] || {
            echo -e "${RED}Error:${NC} plugin dir of session $session no longer exists: $d" >&2
            return 1
        }
    done
    cage_refuse_if_running "$_cage_name" || return 1
    cage_ensure_cwd "$_cage_cwd" || return 1
    # A pinned session outlives Claude Code's retention: bring back its
    # transcript if the sweep deleted it
    if cage_pin_active "$keep_until" && ! cage_has_conversation "$_cage_cwd" "$uuid"; then
        cage_restore_transcript "$_cage_cwd" "$uuid" || return 1
        echo -e "${DIM}Restored the pinned transcript of $_cage_name from ${CAGE_ARCHIVE}${NC}" >&2
    fi
    # Never resume a stub: a resume would reopen the conversation as it was
    # before the move, and anything typed there splits it in two. A failed
    # follow (error printed) refuses rather than guessing.
    _cage_resume_uuid=$(cage_follow_session "$_cage_meta_file" "$_cage_cwd" "$uuid") || {
        echo -e "${RED}Error:${NC} cannot tell whether Claude Code moved $_cage_name to a new session id — not resuming" >&2
        return 1
    }
    cage_refuse_if_live "cannot resume $_cage_name" "$_cage_resume_uuid" || return 1
    cage_require_transcript "$_cage_name" "$_cage_cwd" "$_cage_resume_uuid" || return 1
}

# Validate a profile's sandbox block (compact JSON string).
# Allowed shape: {"filesystem":{"allowWrite":[],"denyWrite":[],"allowRead":[]},
#                 "network":{"allowedDomains":[]},
#                 "allowUnsandboxedCommands":true}
# Filesystem entries must be absolute paths; domains must be non-empty/whitespace-free;
# allowUnsandboxedCommands must be a boolean.
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
          (if type=="object" and length==0 then "sandbox block is empty; define filesystem, network, and/or allowUnsandboxedCommands" else empty end),
          (if type=="object" then (keys_unsorted[] | select(.!="filesystem" and .!="network" and .!="allowUnsandboxedCommands") | "unknown sandbox key: \(.)") else empty end),
          (if type=="object" and has("allowUnsandboxedCommands") and (.allowUnsandboxedCommands|type)!="boolean" then "sandbox.allowUnsandboxedCommands must be a boolean" else empty end),
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
