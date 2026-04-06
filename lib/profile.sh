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
    ["Bash(ls+find+tree+du+df)"]="Bash(ls:*),Bash(find:*),Bash(tree:*),Bash(du:*),Bash(df:*)"
    ["Bash(cat+head+tail+file)"]="Bash(cat:*),Bash(head:*),Bash(tail:*),Bash(file:*)"
    ["Bash(git: status+log+diff+show)"]="Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git show:*)"
    ["Bash(grep+diff+stat+wc)"]="Bash(grep:*),Bash(diff:*),Bash(stat:*),Bash(wc:*)"
    ["Bash(sort+uniq+cut+tr+echo)"]="Bash(sort:*),Bash(uniq:*),Bash(cut:*),Bash(tr:*),Bash(echo:*)"
    ["Bash(which+type)"]="Bash(which:*),Bash(type:*)"
)

# Ordered display list for the tool selector (bundles + standalones)
_CAGE_TOOL_DISPLAY=(
    "Read"
    "Glob+Grep"
    "Write+Edit"
    "Web(Search+Fetch)"
    "TodoWrite"
    "Bash(ls+find+tree+du+df)"
    "Bash(cat+head+tail+file)"
    "Bash(git: status+log+diff+show)"
    "Bash(git add:*)"
    "Bash(git branch:*)"
    "Bash(grep+diff+stat+wc)"
    "Bash(sort+uniq+cut+tr+echo)"
    "Bash(curl:*)"
    "Bash(which+type)"
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
    lmap["Bash(ls+find+tree+du+df)"]="${RST}Bash(${BLU}ls${RST}+${BLU}find${RST}+${BLU}tree${RST}+${BLU}du${RST}+${BLU}df${RST})"
    lmap["Bash(cat+head+tail+file)"]="${RST}Bash(${BLU}cat${RST}+${BLU}head${RST}+${BLU}tail${RST}+${BLU}file${RST})"
    lmap["Bash(git: status+log+diff+show)"]="${RST}Bash(git: ${BLU}status${RST}+${BLU}log${RST}+${BLU}diff${RST}+${BLU}show${RST})"
    lmap["Bash(git add:*)"]="${RST}Bash(${BLU}git add${RST}:*)"
    lmap["Bash(git branch:*)"]="${RST}Bash(${BLU}git branch${RST}:*)"
    lmap["Bash(grep+diff+stat+wc)"]="${RST}Bash(${BLU}grep${RST}+${BLU}diff${RST}+${BLU}stat${RST}+${BLU}wc${RST})"
    lmap["Bash(sort+uniq+cut+tr+echo)"]="${RST}Bash(${BLU}sort${RST}+${BLU}uniq${RST}+${BLU}cut${RST}+${BLU}tr${RST}+${BLU}echo${RST})"
    lmap["Bash(curl:*)"]="${RST}Bash(${BLU}curl${RST}:*)"
    lmap["Bash(which+type)"]="${RST}Bash(${BLU}which${RST}+${BLU}type${RST})"

    # Descriptions
    declare -A dmap
    dmap["Read"]="read files"
    dmap["Glob+Grep"]="find files · search content"
    dmap["Write+Edit"]="create & modify files"
    dmap["Web(Search+Fetch)"]="web search · fetch URLs"
    dmap["TodoWrite"]="manage task list"
    dmap["Bash(ls+find+tree+du+df)"]="browse dirs & disk usage"
    dmap["Bash(cat+head+tail+file)"]="file content & type detection"
    dmap["Bash(git: status+log+diff+show)"]="inspect git history, read-only"
    dmap["Bash(git add:*)"]="stage files for commit"
    dmap["Bash(git branch:*)"]="list & create branches"
    dmap["Bash(grep+diff+stat+wc)"]="search · compare · count"
    dmap["Bash(sort+uniq+cut+tr+echo)"]="sort · dedupe · transform text"
    dmap["Bash(curl:*)"]="HTTP requests"
    dmap["Bash(which+type)"]="locate commands"

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

# Load a profile by name, sets: PROF_DESCRIPTION, PROF_MODEL, PROF_TOOLS, PROF_OUTPUT, PROF_CWD, PROF_SYSTEM_PROMPT
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
        "PROF_TOOLS=" + (.tools // "Bash,Write,Read,Edit,Glob,Grep" | @sh) + " " +
        "PROF_OUTPUT=" + (.output // "json" | @sh) + " " +
        "PROF_CWD=" + (.cwd // "." | @sh) + " " +
        "PROF_SYSTEM_PROMPT=" + (.system_prompt // "" | @sh)
    ' "$profile_file")"
}

# Save current PROF_* vars to a profile file
_cage_profile_save() {
    local profile_file="$1"
    jq -n \
        --arg description "$PROF_DESCRIPTION" \
        --arg model "$PROF_MODEL" \
        --arg tools "$PROF_TOOLS" \
        --arg output "$PROF_OUTPUT" \
        --arg cwd "$PROF_CWD" \
        --arg system_prompt "$PROF_SYSTEM_PROMPT" \
        '{description: $description, model: $model, tools: $tools, output: $output, cwd: $cwd, system_prompt: $system_prompt}' \
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
        local choice
        choice=$(gum choose \
            "Description:    $PROF_DESCRIPTION" \
            "Model:          $PROF_MODEL" \
            "Output:         $PROF_OUTPUT" \
            "Tools:          $PROF_TOOLS" \
            "CWD:            $PROF_CWD" \
            "System prompt:  ${PROF_SYSTEM_PROMPT:-(none)}" \
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
                new_model=$(gum choose --header "Select model" "opus" "sonnet" "haiku")
                [ $? -eq 0 ] && PROF_MODEL="$new_model"
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
                local desc="" model="" output=""
                eval "$(jq -r '"desc=" + (.description // "" | @sh) + " model=" + (.model // "" | @sh) + " output=" + (.output // "" | @sh)' "$f")"
                echo -e "  ${GREEN}${name}${NC}  ${DIM}[${model}, ${output}]${NC}"
                echo -e "    ${desc}"
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
            echo -e "  ${DIM}Output:${NC}        $PROF_OUTPUT"
            echo -e "  ${DIM}CWD:${NC}           $PROF_CWD"
            echo -e "  ${DIM}Tools:${NC}         $PROF_TOOLS"
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
