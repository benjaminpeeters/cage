#!/usr/bin/env bash

# profile.sh - Manage cage profiles
# Usage: cage profile [list|show|edit|create|delete] [name]

CAGE_PROFILES_DIR="$CAGE_ROOT/profiles"

# All known Claude tools for the tool selector
_CAGE_ALL_TOOLS="Bash Read Write Edit Glob Grep WebSearch WebFetch TodoWrite"

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
                # Build selected list from current tools
                local current_tools=",$PROF_TOOLS,"
                local selected_args=()
                for tool in $_CAGE_ALL_TOOLS; do
                    if [[ "$current_tools" == *",$tool,"* ]] || [[ "$current_tools" == *",$tool("* ]]; then
                        selected_args+=("$tool")
                    fi
                done

                # Multi-select with current tools pre-selected
                local new_tools
                new_tools=$(gum choose --no-limit \
                    --header "Select tools (space to toggle)" \
                    --selected "$(IFS=,; echo "${selected_args[*]}")" \
                    $_CAGE_ALL_TOOLS)
                if [ $? -eq 0 ] && [ -n "$new_tools" ]; then
                    # Convert newline-separated to comma-separated
                    PROF_TOOLS=$(echo "$new_tools" | tr '\n' ',' | sed 's/,$//')
                fi
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
            # Initialize with defaults
            PROF_DESCRIPTION=""
            PROF_MODEL="sonnet"
            PROF_TOOLS="Bash,Write,Read,Edit,Glob,Grep"
            PROF_OUTPUT="json"
            PROF_CWD="."
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
