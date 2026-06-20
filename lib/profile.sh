#!/usr/bin/env bash

# profile.sh - Manage cage profiles
# Usage: cage profile [list|show|edit|create|delete] [name]

CAGE_PROFILES_DIR="$CAGE_ROOT/profiles"

# Tool bundle definitions: display key → comma-separated expanded tools
# Bash (unrestricted) is intentionally excluded — edit profile JSON directly if needed
declare -A _CAGE_TOOL_BUNDLES=(
    ["Glob+Grep"]="Glob,Grep"
    ["Write+Edit"]="Write,Edit"
    ["Web(Search+Fetch)"]="WebSearch,WebFetch"
    ["Bash(ls+find+tree+du+df+which+type)"]="Bash(ls:*),Bash(find:*),Bash(tree:*),Bash(du:*),Bash(df:*),Bash(which:*),Bash(type:*)"
    ["Bash(cat+head+tail+file+jq+xxd+od+strings+md5+sha1+sha256)"]="Bash(cat:*),Bash(head:*),Bash(tail:*),Bash(file:*),Bash(jq:*),Bash(xxd:*),Bash(od:*),Bash(strings:*),Bash(md5sum:*),Bash(sha1sum:*),Bash(sha256sum:*)"
    ["Bash(git: status+log+diff+show)"]="Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git show:*)"
    ["Bash(grep+diff+stat+wc)"]="Bash(grep:*),Bash(diff:*),Bash(stat:*),Bash(wc:*)"
    ["Bash(sort+uniq+cut+tr+echo+awk+tac+nl+rev)"]="Bash(sort:*),Bash(uniq:*),Bash(cut:*),Bash(tr:*),Bash(echo:*),Bash(awk:*),Bash(tac:*),Bash(nl:*),Bash(rev:*)"
    ["Bash(paste+join+comm+column)"]="Bash(paste:*),Bash(join:*),Bash(comm:*),Bash(column:*)"
    ["Bash(ps+lsof+ss+free+uptime+lscpu+lsblk)"]="Bash(ps:*),Bash(lsof:*),Bash(ss:*),Bash(free:*),Bash(uptime:*),Bash(lscpu:*),Bash(lsblk:*)"
    ["Bash(pdftotext+pdfinfo)"]="Bash(pdftotext:*),Bash(pdfinfo:*)"
    ["Bash(pdflatex+latexmk+bibtex+makeindex)"]="Bash(pdflatex:*),Bash(latexmk:*),Bash(bibtex:*),Bash(makeindex:*)"
    ["Bash(luac+lua)"]="Bash(luac:*),Bash(lua:*)"
    ["GoogleDocs(read)"]="mcp__google-docs-mcp__readSpreadsheet,mcp__google-docs-mcp__getPresentation,mcp__google-docs-mcp__readGoogleDoc"
)

# Ordered display list for the tool selector (bundles + standalones)
_CAGE_TOOL_DISPLAY=(
    "Read"
    "Glob+Grep"
    "Write+Edit"
    "Web(Search+Fetch)"
    "TodoWrite"
    "Bash(ls+find+tree+du+df+which+type)"
    "Bash(cat+head+tail+file+jq+xxd+od+strings+md5+sha1+sha256)"
    "Bash(git: status+log+diff+show)"
    "Bash(git add:*)"
    "Bash(git branch:*)"
    "Bash(grep+diff+stat+wc)"
    "Bash(sort+uniq+cut+tr+echo+awk+tac+nl+rev)"
    "Bash(curl:*)"
    "Bash(paste+join+comm+column)"
    "Bash(ps+lsof+ss+free+uptime+lscpu+lsblk)"
    "Bash(pdftotext+pdfinfo)"
    "Bash(pdflatex+latexmk+bibtex+makeindex)"
    "Bash(gdxdump:*)"
    "Bash(nvim:*)"
    "Bash(luac+lua)"
    "GoogleDocs(read)"
)

# Interactive tool selector using gum choose with bundles
# Reads PROF_TOOLS, writes updated PROF_TOOLS
_cage_tool_selector() {
    # Build lookup set of current profile tools
    declare -A profile_tools_set
    local parts=()
    IFS=',' read -ra parts <<< "$PROF_TOOLS"
    for t in "${parts[@]}"; do profile_tools_set["$t"]=1; done

    # Determine pre-selected display items
    local selected=()

    for item in "${_CAGE_TOOL_DISPLAY[@]}"; do
        if [[ -n "${_CAGE_TOOL_BUNDLES[$item]}" ]]; then
            # Bundle: select if all component tools are present
            local all_present=true
            local bundle_parts=()
            IFS=',' read -ra bundle_parts <<< "${_CAGE_TOOL_BUNDLES[$item]}"
            for bt in "${bundle_parts[@]}"; do
                [[ -z "${profile_tools_set[$bt]}" ]] && { all_present=false; break; }
            done
            $all_present && selected+=("$item")
        else
            # Standalone: select if present in profile
            [[ -n "${profile_tools_set[$item]}" ]] && selected+=("$item")
        fi
    done

    # Warn on partial bundles
    local header="Select tools  (space=toggle, enter=confirm)"
    for bk in "${!_CAGE_TOOL_BUNDLES[@]}"; do
        local any=false all=true
        local bparts=()
        IFS=',' read -ra bparts <<< "${_CAGE_TOOL_BUNDLES[$bk]}"
        for bt in "${bparts[@]}"; do
            [[ -n "${profile_tools_set[$bt]}" ]] && any=true || all=false
        done
        if $any && ! $all; then
            header="Select tools  [partial bundle: select '${bk}' to keep all]"
            break
        fi
    done

    # ANSI color codes
    local GRY=$'\e[90m' BLU=$'\e[94m' RST=$'\e[0m'

    # Decorated labels — sync with _CAGE_TOOL_DISPLAY, _CAGE_TOOL_BUNDLES, and dmap when adding tools
    declare -A lmap
    lmap["Read"]="${RST}Read"
    lmap["Glob+Grep"]="${BLU}Glob${RST}+${BLU}Grep${RST}"
    lmap["Write+Edit"]="${BLU}Write${RST}+${BLU}Edit${RST}"
    lmap["Web(Search+Fetch)"]="${RST}Web(${BLU}Search${RST}+${BLU}Fetch${RST})"
    lmap["TodoWrite"]="${RST}TodoWrite"
    lmap["Bash(ls+find+tree+du+df+which+type)"]="${RST}Bash(${BLU}ls${RST}+${BLU}find${RST}+${BLU}tree${RST}+${BLU}du${RST}+${BLU}df${RST}+${BLU}which${RST}+${BLU}type${RST})"
    lmap["Bash(cat+head+tail+file+jq+xxd+od+strings+md5+sha1+sha256)"]="${RST}Bash(${BLU}cat${RST}+${BLU}head${RST}+${BLU}tail${RST}+${BLU}file${RST}+${BLU}jq${RST}+${BLU}xxd${RST}+${BLU}od${RST}+${BLU}strings${RST}+${BLU}md5${RST}+${BLU}sha1${RST}+${BLU}sha256${RST})"
    lmap["Bash(git: status+log+diff+show)"]="${RST}Bash(git: ${BLU}status${RST}+${BLU}log${RST}+${BLU}diff${RST}+${BLU}show${RST})"
    lmap["Bash(git add:*)"]="${RST}Bash(${BLU}git add${RST}:*)"
    lmap["Bash(git branch:*)"]="${RST}Bash(${BLU}git branch${RST}:*)"
    lmap["Bash(grep+diff+stat+wc)"]="${RST}Bash(${BLU}grep${RST}+${BLU}diff${RST}+${BLU}stat${RST}+${BLU}wc${RST})"
    lmap["Bash(sort+uniq+cut+tr+echo+awk+tac+nl+rev)"]="${RST}Bash(${BLU}sort${RST}+${BLU}uniq${RST}+${BLU}cut${RST}+${BLU}tr${RST}+${BLU}echo${RST}+${BLU}awk${RST}+${BLU}tac${RST}+${BLU}nl${RST}+${BLU}rev${RST})"
    lmap["Bash(curl:*)"]="${RST}Bash(${BLU}curl${RST}:*)"
    lmap["Bash(paste+join+comm+column)"]="${RST}Bash(${BLU}paste${RST}+${BLU}join${RST}+${BLU}comm${RST}+${BLU}column${RST})"
    lmap["Bash(ps+lsof+ss+free+uptime+lscpu+lsblk)"]="${RST}Bash(${BLU}ps${RST}+${BLU}lsof${RST}+${BLU}ss${RST}+${BLU}free${RST}+${BLU}uptime${RST}+${BLU}lscpu${RST}+${BLU}lsblk${RST})"
    lmap["Bash(pdftotext+pdfinfo)"]="${RST}Bash(${BLU}pdftotext${RST}+${BLU}pdfinfo${RST})"
    lmap["Bash(pdflatex+latexmk+bibtex+makeindex)"]="${RST}Bash(${BLU}pdflatex${RST}+${BLU}latexmk${RST}+${BLU}bibtex${RST}+${BLU}makeindex${RST})"
    lmap["Bash(gdxdump:*)"]="${RST}Bash(${BLU}gdxdump${RST}:*)"
    lmap["Bash(nvim:*)"]="${RST}Bash(${BLU}nvim${RST}:*)"
    lmap["Bash(luac+lua)"]="${RST}Bash(${BLU}luac${RST}+${BLU}lua${RST})"
    lmap["GoogleDocs(read)"]="${RST}GoogleDocs(${BLU}read${RST})"

    # Descriptions
    declare -A dmap
    dmap["Read"]="read files"
    dmap["Glob+Grep"]="find files · search content"
    dmap["Write+Edit"]="create & modify files"
    dmap["Web(Search+Fetch)"]="web search · fetch URLs"
    dmap["TodoWrite"]="manage task list"
    dmap["Bash(ls+find+tree+du+df+which+type)"]="browse filesystem · locate commands · disk usage"
    dmap["Bash(cat+head+tail+file+jq+xxd+od+strings+md5+sha1+sha256)"]="view · inspect · checksum files (text · JSON · binary)"
    dmap["Bash(git: status+log+diff+show)"]="inspect git history, read-only"
    dmap["Bash(git add:*)"]="stage files for commit"
    dmap["Bash(git branch:*)"]="list & create branches"
    dmap["Bash(grep+diff+stat+wc)"]="search · compare · count"
    dmap["Bash(sort+uniq+cut+tr+echo+awk+tac+nl+rev)"]="sort · dedupe · transform · reorder text"
    dmap["Bash(curl:*)"]="HTTP requests"
    dmap["Bash(paste+join+comm+column)"]="merge · compare · format columns"
    dmap["Bash(ps+lsof+ss+free+uptime+lscpu+lsblk)"]="system state & hardware"
    dmap["Bash(pdftotext+pdfinfo)"]="extract PDF text & metadata"
    dmap["Bash(pdflatex+latexmk+bibtex+makeindex)"]="LaTeX build toolchain"
    dmap["Bash(gdxdump:*)"]="dump GAMS .gdx files"
    dmap["Bash(nvim:*)"]="run Neovim · headless config validation"
    dmap["Bash(luac+lua)"]="validate · run Lua"
    dmap["GoogleDocs(read)"]="read docs · sheets · presentations"

    # Build gum items and selected-labels in a single pass
    local gum_items=() sel_labels=()
    declare -A is_selected
    for s in "${selected[@]}"; do is_selected["$s"]=1; done

    for item in "${_CAGE_TOOL_DISPLAY[@]}"; do
        local lbl="${lmap[$item]:-$item}"
        local desc="${dmap[$item]:-}"
        local display_str
        if [[ -n "$desc" ]]; then
            display_str="${lbl}  ${GRY}${desc}${RST}"
        else
            display_str="${lbl}"
        fi
        gum_items+=("${display_str}|${item}")
        [[ -n "${is_selected[$item]}" ]] && sel_labels+=("$display_str")
    done

    local sel_str
    sel_str=$(IFS=,; echo "${sel_labels[*]}")

    local sel_pfx=$'\e[32m✓\e[0m '
    local raw_sel
    raw_sel=$(gum choose --no-limit --no-strip-ansi \
        --label-delimiter="|" \
        --header "$header" \
        --selected "$sel_str" \
        --selected-prefix "$sel_pfx" \
        --unselected-prefix "  " \
        --cursor-prefix "  " \
        "${gum_items[@]}")
    local gum_rc=$?

    if [ $gum_rc -eq 0 ]; then
        # Expand bundles to flat tool list
        local flat=()
        if [ -n "$raw_sel" ]; then
            while IFS= read -r item; do
                if [[ -n "${_CAGE_TOOL_BUNDLES[$item]}" ]]; then
                    local exp=()
                    IFS=',' read -ra exp <<< "${_CAGE_TOOL_BUNDLES[$item]}"
                    flat+=("${exp[@]}")
                else
                    flat+=("$item")
                fi
            done <<< "$raw_sel"
        fi
        PROF_TOOLS=$(IFS=,; echo "${flat[*]}")
    fi
}

_cage_profile_help() {
    cat <<'EOF'
cage profile - Manage session profiles

Usage: cage profile [command] [name]

Commands:
  list              List all profiles (default)
  show <name>       Show profile details
  edit <name>       Interactive profile editor
  create <name>     Create a new profile interactively
  delete <name>     Delete a profile

Examples:
  cage profile
  cage profile show web
  cage profile edit default
  cage profile create custom
  cage profile delete custom
EOF
}

# Load a profile by name, sets: PROF_DESCRIPTION, PROF_MODEL, PROF_EFFORT, PROF_TOOLS, PROF_OUTPUT, PROF_CWD, PROF_SYSTEM_PROMPT, PROF_SANDBOX, PROF_HAS_SANDBOX
cage_load_profile() {
    local name="$1"
    local profile_file="$CAGE_PROFILES_DIR/${name}.json"

    if [ ! -f "$profile_file" ]; then
        echo "Unknown profile: $name" >&2
        echo "Available: $(ls "$CAGE_PROFILES_DIR"/*.json 2>/dev/null | xargs -I{} basename {} .json | tr '\n' ' ')" >&2
        return 1
    fi

    eval "$(jq -r '
        "PROF_DESCRIPTION=" + (.description // "" | @sh) + " " +
        "PROF_MODEL=" + (.model // "sonnet" | @sh) + " " +
        "PROF_EFFORT=" + (.effort // "xhigh" | @sh) + " " +
        "PROF_TOOLS=" + (.tools // "Bash,Write,Read,Edit,Glob,Grep" | @sh) + " " +
        "PROF_OUTPUT=" + (.output // "json" | @sh) + " " +
        "PROF_CWD=" + (.cwd // "." | @sh) + " " +
        "PROF_SYSTEM_PROMPT=" + (.system_prompt // "" | @sh)
    ' "$profile_file")"

    # Optional sandbox block (compact JSON). "// empty" yields "" for a missing key
    # or an explicit null. When present, validate at load time and fail loud.
    PROF_SANDBOX=$(jq -c '.sandbox // empty' "$profile_file")
    if [ -n "$PROF_SANDBOX" ]; then
        PROF_HAS_SANDBOX=true
        cage_validate_sandbox "$PROF_SANDBOX" "$name" || return 1
    else
        PROF_SANDBOX=""
        PROF_HAS_SANDBOX=false
    fi
}

# Read profile summary fields (for the 'cage new --help' and 'cage profile list'
# listings) in one jq call. Sets: PSUM_DESC, PSUM_MODEL, PSUM_OUTPUT, PSUM_EFFORT, PSUM_TOOLS
# Usage: _cage_profile_summary_fields "$profile_file"
_cage_profile_summary_fields() {
    # Reset first: if the profile JSON fails to parse, jq emits nothing and eval is
    # a no-op, so without this the previous profile's values would leak into the row.
    PSUM_DESC="" PSUM_MODEL="" PSUM_OUTPUT="" PSUM_EFFORT="" PSUM_TOOLS=""
    eval "$(jq -r '
        "PSUM_DESC=" + (.description // "" | @sh) + " " +
        "PSUM_MODEL=" + (.model // "" | @sh) + " " +
        "PSUM_OUTPUT=" + (.output // "" | @sh) + " " +
        "PSUM_EFFORT=" + (.effort // "xhigh" | @sh) + " " +
        "PSUM_TOOLS=" + (.tools // "" | @sh)
    ' "$1")"
}

# Save current PROF_* vars to a profile file
# The sandbox block is round-tripped via --argjson; the key is omitted when absent.
_cage_profile_save() {
    local profile_file="$1"
    jq -n \
        --arg description "$PROF_DESCRIPTION" \
        --arg model "$PROF_MODEL" \
        --arg effort "$PROF_EFFORT" \
        --arg tools "$PROF_TOOLS" \
        --arg output "$PROF_OUTPUT" \
        --arg cwd "$PROF_CWD" \
        --arg system_prompt "$PROF_SYSTEM_PROMPT" \
        --argjson sandbox "${PROF_SANDBOX:-null}" \
        '{description: $description, model: $model, effort: $effort, tools: $tools, output: $output, cwd: $cwd, system_prompt: $system_prompt}
         + (if $sandbox != null then {sandbox: $sandbox} else {} end)' \
        > "$profile_file"
}

# Interactive profile editor using gum
_cage_profile_edit_interactive() {
    local name="$1"
    local profile_file="$CAGE_PROFILES_DIR/${name}.json"

    # Load current values
    cage_load_profile "$name" || return 1

    while true; do
        echo ""
        echo -e "${BOLD}Editing profile: ${GREEN}${name}${NC}"
        echo ""

        # Build menu with current values
        local sandbox_summary="(none)"
        [ "$PROF_HAS_SANDBOX" = true ] && sandbox_summary="$PROF_SANDBOX"
        local choice
        choice=$(gum choose \
            "Description:    $PROF_DESCRIPTION" \
            "Model:          $PROF_MODEL" \
            "Effort:         $PROF_EFFORT" \
            "Output:         $PROF_OUTPUT" \
            "Tools:          $PROF_TOOLS" \
            "CWD:            $PROF_CWD" \
            "System prompt:  ${PROF_SYSTEM_PROMPT:-(none)}" \
            "Sandbox:        ${sandbox_summary}" \
            "Save and exit" \
            "Cancel")

        case "$choice" in
            Description:*)
                local new_desc
                new_desc=$(gum input --placeholder "Profile description" --value "$PROF_DESCRIPTION")
                [ $? -eq 0 ] && [ -n "$new_desc" ] && PROF_DESCRIPTION="$new_desc"
                ;;
            Model:*)
                local new_model
                new_model=$(gum choose --header "Select model" "opus[1m]" "sonnet" "haiku")
                [ $? -eq 0 ] && PROF_MODEL="$new_model"
                ;;
            Effort:*)
                local new_effort
                new_effort=$(gum choose --header "Select effort level" "low" "medium" "high" "xhigh" "max")
                [ $? -eq 0 ] && PROF_EFFORT="$new_effort"
                ;;
            Output:*)
                local new_output
                new_output=$(gum choose --header "Select output format" "json" "markdown")
                [ $? -eq 0 ] && PROF_OUTPUT="$new_output"
                ;;
            Tools:*)
                _cage_tool_selector
                ;;
            CWD:*)
                local new_cwd
                new_cwd=$(gum input --placeholder "Working directory (. for caller's cwd)" --value "$PROF_CWD")
                [ $? -eq 0 ] && [ -n "$new_cwd" ] && PROF_CWD="$new_cwd"
                ;;
            "System prompt:"*)
                local new_sp
                new_sp=$(gum write --placeholder "System prompt (empty to clear)" --value "$PROF_SYSTEM_PROMPT")
                [ $? -eq 0 ] && PROF_SYSTEM_PROMPT="$new_sp"
                ;;
            "Sandbox:"*)
                local new_sb compact_sb
                new_sb=$(gum write \
                    --placeholder 'Sandbox JSON, e.g. {"filesystem":{"allowWrite":["/abs/path"]}} (empty to clear)' \
                    --value "$PROF_SANDBOX")
                if [ $? -eq 0 ]; then
                    if [ -z "$(echo "$new_sb" | tr -d '[:space:]')" ]; then
                        PROF_SANDBOX=""
                        PROF_HAS_SANDBOX=false
                    elif compact_sb=$(echo "$new_sb" | jq -c . 2>/dev/null) && \
                         cage_validate_sandbox "$compact_sb" "$name"; then
                        PROF_SANDBOX="$compact_sb"
                        PROF_HAS_SANDBOX=true
                    else
                        [ -z "$compact_sb" ] && echo -e "${RED}Error:${NC} not valid JSON" >&2
                        echo -e "${YELLOW}Sandbox unchanged.${NC}" >&2
                        gum input --placeholder "Press Enter to continue" >/dev/null 2>&1
                    fi
                fi
                ;;
            "Save and exit")
                _cage_profile_save "$profile_file"
                echo -e "${GREEN}✓${NC} Profile saved: $name"
                return 0
                ;;
            "Cancel"|"")
                echo -e "${DIM}Cancelled${NC}"
                return 0
                ;;
        esac
    done
}

cage_profile() {
    local cmd="${1:-list}"
    shift 2>/dev/null

    case "$cmd" in
        list)
            echo -e "${BOLD}Available profiles:${NC}"
            echo ""
            for f in "$CAGE_PROFILES_DIR"/*.json; do
                [ -f "$f" ] || continue
                local name=$(basename "$f" .json)
                _cage_profile_summary_fields "$f"
                echo -e "  ${GREEN}${name}${NC}  ${DIM}[${PSUM_MODEL}, ${PSUM_EFFORT}, ${PSUM_OUTPUT}]${NC}"
                echo -e "    ${PSUM_DESC}"
            done
            ;;
        show)
            local name="$1"
            if [ -z "$name" ]; then
                echo "Usage: cage profile show <name>"
                return 1
            fi
            local profile_file="$CAGE_PROFILES_DIR/${name}.json"
            if [ ! -f "$profile_file" ]; then
                echo -e "${RED}Error:${NC} Profile not found: $name"
                return 1
            fi
            cage_load_profile "$name" || return 1
            echo -e "${BOLD}Profile: ${GREEN}${name}${NC}"
            echo -e "  ${DIM}Description:${NC}   $PROF_DESCRIPTION"
            echo -e "  ${DIM}Model:${NC}         $PROF_MODEL"
            echo -e "  ${DIM}Effort:${NC}        $PROF_EFFORT"
            echo -e "  ${DIM}Output:${NC}        $PROF_OUTPUT"
            echo -e "  ${DIM}CWD:${NC}           $PROF_CWD"
            echo -e "  ${DIM}Tools:${NC}         $PROF_TOOLS"
            [ "$PROF_HAS_SANDBOX" = true ] && echo -e "  ${DIM}Sandbox:${NC}       ${PROF_SANDBOX}"
            [ -n "$PROF_SYSTEM_PROMPT" ] && echo -e "  ${DIM}System prompt:${NC} ${PROF_SYSTEM_PROMPT}"
            ;;
        edit)
            local name="$1"
            if [ -z "$name" ]; then
                echo "Usage: cage profile edit <name>"
                return 1
            fi
            local profile_file="$CAGE_PROFILES_DIR/${name}.json"
            if [ ! -f "$profile_file" ]; then
                echo -e "${RED}Error:${NC} Profile not found: $name"
                return 1
            fi
            _cage_profile_edit_interactive "$name"
            ;;
        create)
            local name="$1"
            if [ -z "$name" ]; then
                echo "Usage: cage profile create <name>"
                return 1
            fi
            local profile_file="$CAGE_PROFILES_DIR/${name}.json"
            if [ -f "$profile_file" ]; then
                echo -e "${YELLOW}Profile already exists:${NC} $name"
                echo "Use 'cage profile edit $name' to modify it."
                return 1
            fi
            # Initialize from default profile
            cage_load_profile "default" || return 1
            PROF_DESCRIPTION=""
            PROF_SYSTEM_PROMPT=""
            _cage_profile_save "$profile_file"
            _cage_profile_edit_interactive "$name"
            ;;
        delete)
            local name="$1"
            if [ -z "$name" ]; then
                echo "Usage: cage profile delete <name>"
                return 1
            fi
            local profile_file="$CAGE_PROFILES_DIR/${name}.json"
            if [ ! -f "$profile_file" ]; then
                echo -e "${RED}Error:${NC} Profile not found: $name"
                return 1
            fi
            if gum confirm "Delete profile '$name'?"; then
                rm "$profile_file"
                echo -e "${GREEN}✓${NC} Profile deleted: $name"
            else
                echo -e "${DIM}Cancelled${NC}"
            fi
            ;;
        -h|--help|help)
            _cage_profile_help
            ;;
        *)
            # If arg looks like a profile name, treat as 'show'
            local profile_file="$CAGE_PROFILES_DIR/${cmd}.json"
            if [ -f "$profile_file" ]; then
                cage_profile show "$cmd"
            else
                echo "Unknown command: $cmd"
                _cage_profile_help
                return 1
            fi
            ;;
    esac
}
