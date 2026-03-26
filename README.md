# cage - Claude Agent CLI

Claude session management for interactive and background workflows.

## Installation

```bash
cd ~/MEGA/repo/claude/cage
./install.sh
```

## Usage

### Start a new session

```bash
cage new "Fix the bug in auth.py"                # Interactive (default)
cage new fast "Quick question"                    # With profile
cage new -m opus "Complex task"                   # Override model
cage new -p "Background task"                     # Background mode
cage new -p web "What are best practices for X?"  # Background with profile
cage new -pt "Fix something"                      # Background with tail
```

### Resume a session

```bash
cage resume S0_3                              # Interactive
cage resume S0_3 -p "Now add tests"           # Non-interactive background
cage resume S0_3 -p "task" --fork             # Fork session
cage resume S0_3 -p "task" --md               # Markdown output
```

### Session management

```bash
cage status                                   # List sessions
cage status S0_3                              # Show session details
cage result S0_3                              # Read result JSON
cage result S0_3 .summary                     # Read specific field
cage tail S0_3                                # Tail log
cage meta S0_3                                # Read metadata
cage kill S0_3                                # Kill session
```

### Profile management

```bash
cage profile                                  # List profiles
cage profile show web                         # Show profile details
cage profile edit default                     # Interactive editor
cage profile create custom                    # Create new profile
cage profile delete custom                    # Delete profile
```

## Profiles

Profiles are JSON files in `profiles/` defining model, tools, output format, working directory, and system prompt.

| Profile | Model | Tools | Output | CWD | Purpose |
|---------|-------|-------|--------|-----|---------|
| default | sonnet | All standard tools | markdown | /tmp/cage | General purpose |
| fast | haiku | Basic tools | json | /tmp/cage | Lightweight, speed-optimized |
| explore | opus | Glob, Grep, Read, limited Bash | markdown | . | Read-only codebase exploration |
| write | opus | Read, Write, Edit, Glob, Grep, Bash | json | . | Code modification |
| web | opus | Read, Glob, Grep, WebSearch, WebFetch | markdown | /tmp/cage | Online research |
| full | opus | All tools + TodoWrite | json | . | All tools with project context |

CWD `.` means the caller's working directory. `/tmp/cage` is an isolated directory.

## Session IDs

Sessions use the format `S<days_ago>_<number>`:
- `S0_1` - Today's first session
- `S0_2` - Today's second session
- `S1_1` - Yesterday's first session

Full format: `cage_YYYY-MM-DD_N`

Sessions can also be referenced by UUID.

## Output Formats

Output format is set by the profile (default: see table above):
- `--md` flag: Force markdown output (background mode only)
- `--json` flag: Force JSON output (background mode only)

## Result JSON Schema

```json
{
  "status": "success|error|partial",
  "summary": "Brief description",
  "files_created": ["path/to/file.py"],
  "files_modified": ["path/to/existing.py"],
  "files_read": ["path/to/reference.py"],
  "errors": ["Error message if any"],
  "data": {"custom": "data"},
  "next_steps": ["Suggested follow-up"]
}
```

## Storage

Sessions are stored in `/tmp/cage/YYYY-MM-DD/`:
- `cage_N.log` - Full output
- `cage_N.pid` - PID while running
- `cage_N.status` - Exit code
- `cage_N.meta.json` - Session metadata
- `cage_N.result.json` - Structured result

## Dependencies

- bash (4.0+)
- GNU getopt (for argument parsing)
- jq
- uuidgen
- gum (for interactive profile editor)
- Claude CLI (`claude` in PATH)

### macOS Setup

macOS ships with BSD getopt which doesn't support long options. Install GNU getopt:

```bash
brew install gnu-getopt
export PATH="/usr/local/opt/gnu-getopt/bin:$PATH"
```

Add the export line to your `~/.bashrc` or `~/.zshrc`.

## License

AGPL-3.0
