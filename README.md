# cage - Claude Agent CLI

Background Claude session management for inter-agent workflows.

## Installation

```bash
cd ~/MEGA/repo/claude/cage
./install.sh
```

## Usage

### Start a new session

```bash
cage new "Fix the bug in auth.py"
cage new -p research "What are best practices for X?"
cage new -m "Explain this codebase"          # Markdown output
cage new -t "Fix something"                   # With tail
cage new -mt "Quick question"                 # Combined flags
```

### Resume a session

```bash
cage resume S0_3                              # Interactive
cage resume S0_3 -p "Now add tests"           # Non-interactive
cage resume S0_3 -p "task" --fork             # Fork session
cage resume S0_3 -p "task" -m                 # Markdown output
cage resume S0_3 -p "task" -mt                # Combined flags
```

### Session management

```bash
cage status                                   # List sessions
cage result S0_3                              # Read result JSON
cage result S0_3 .summary                     # Read specific field
cage tail S0_3                                # Tail log
cage meta S0_3                                # Read metadata
cage kill S0_3                                # Kill session
```

## Profiles

| Profile | Tools | Purpose |
|---------|-------|---------|
| explore | Glob, Grep, Read, limited Bash | Codebase exploration |
| write | Read, Write, Edit, Glob, Grep, Bash | Code writing |
| research | Read, Glob, Grep, WebSearch, WebFetch | Online research |
| full | All tools + TodoWrite | Complex multi-step tasks |
| default | Bash, Write, Read, Edit, Glob, Grep | General purpose |

## Session IDs

Sessions use the format `S<days_ago>_<number>`:
- `S0_1` - Today's first session
- `S0_2` - Today's second session
- `S1_1` - Yesterday's first session

Full format: `cage_YYYY-MM-DD_N`

## Output Formats

- Default: JSON with schema (for inter-agent communication)
- `-m` flag: Markdown (human-readable)

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

Sessions are stored in `/tmp/cage_YYYY-MM-DD/`:
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
