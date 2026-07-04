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
cage resume                                   # Interactive picker across all days (gum)
cage resume s0-3                              # Relative code (as shown by cage status today)
cage resume cage-2026-01-05-1                 # Absolute handle (works any day)
cage resume "my-renamed-session"              # /rename'd display name (quote spaces)
cage resume s0-3 -p "Now add tests"           # Background job on the SAME session (no new row)
cage resume s0-3 -p "task" --fork             # Branch into a NEW session row
cage resume s0-3 -p "task" --md               # Markdown output
```

A non-fork `-p` resume is a background job on the existing conversation: it
reuses the session's own registry row (log appends, `result.json` is
overwritten by the next job). `--fork` branches into a genuinely new session
with its own handle and UUID. A RUNNING session refuses to resume in either
mode.

### Session management

```bash
cage status                                   # List sessions
cage status --profile settings                # List only one profile's sessions
cage status s0-3                              # Show session details
cage result s0-3                              # Read result JSON
cage result s0-3 .summary                     # Read specific field
cage tail s0-3                                # Tail log
cage meta s0-3                                # Read metadata
cage kill s0-3                                # Kill session
cage clean                                    # gum menu: expired / near-empty / pick / by-age
cage clean --expired --dry-run                # Preview rows whose transcript Claude already purged
cage clean --empty                            # Remove near-empty sessions (not today's)
```

`cage status` rows and the resume picker show identifying context per session:
the `/rename`'d name when set, else the task or the first prompt typed into it.
Near-empty sessions (no task, no result, not renamed, at most one
greeting-sized prompt) are hidden by default — a dim footer counts them and
`--all` reveals them. Closing such a session interactively offers on-the-spot
cleanup (Enter = clean). A single substantial question never counts as
near-empty, and a `/rename`'d session is always kept.

### Profile management

```bash
cage profile                                  # List profiles
cage profile show web                         # Show profile details
cage profile edit default                     # Interactive editor
cage profile create custom                    # Create new profile
cage profile delete custom                    # Delete profile
```

## Profiles

Profiles are JSON files in `profiles/` defining model, effort, tools, output format, working directory, system prompt, and an optional `sandbox` block.

| Profile | Model | Tools | Output | CWD | Purpose |
|---------|-------|-------|--------|-----|---------|
| default | opus | All standard tools | markdown | /tmp/cage | General purpose |
| fast | sonnet | Basic tools | json | /tmp/cage | Lightweight, speed-optimized |
| web | opus | Read, Glob, Grep, WebSearch, WebFetch | markdown | /tmp/cage | Online research |
| full | opus | All tools + TodoWrite | json | /tmp | All tools, complex multi-step tasks |
| self | opus | Standard tools + git branch | markdown | cage repo | Modify cage itself |
| settings | opus | Standard tools + Write, Edit, nvim, lua | markdown | ~/MEGA/config | Update host configs (Claude Code, WezTerm, Neovim, dotfiles) |
| latex | opus | LaTeX toolchain + Write, Edit, git | markdown | ~/MEGA/repo/latex | bp-latex/bp-library LaTeX infrastructure |
| ai | opus | Read/Write/Edit/Grep + git + jq | markdown | ~/MEGA/config/dotfiles/ai | Claude Code / AI infrastructure (skills, agents, hooks, pre-commit) |

CWD `.` means the caller's working directory. `/tmp/cage` is an isolated directory.

A profile's `system_prompt` applies in both interactive and background sessions: it is passed to `claude` via `--append-system-prompt` (additive — Claude's defaults and CLAUDE.md still load). Because the flag is per-invocation, `cage resume` re-applies the stored prompt automatically.

### Per-profile sandbox

A profile may declare an optional `sandbox` block to widen its own bubblewrap sandbox, scoped to that profile's sessions only (it never edits global settings or affects other profiles):

```json
"sandbox": {
  "filesystem": { "allowWrite": [...], "denyWrite": [...], "allowRead": [...] },
  "network":    { "allowedDomains": [...] }
}
```

Filesystem entries must be absolute paths; domains must be non-empty. When present, cage writes a per-session `cage_N.settings.json` containing exactly that block and launches with `claude --settings <file>` (sandbox arrays merge across scopes). Profiles without a `sandbox` block launch unchanged. The `settings` profile uses this to grant nvim its write paths so it can run `nvim --headless` config validation.

## Session references

Every subcommand accepts four reference forms, tried in this order (codes can
never be shadowed by a display name):

1. `s<days_ago>-<number>` — relative code, e.g. `s0-1` (today's first session),
   `s1-1` (yesterday's first). **Display-only semantics: the same session's
   code shifts at midnight** (`s0-1` becomes `s1-1` tomorrow), so use whatever
   `cage status` shows *right now*. Printed resume hints therefore always use
   the absolute handle instead.
2. `cage-YYYY-MM-DD-N` — absolute handle, valid forever.
3. The session UUID.
4. A `/rename`'d display name, e.g. `cage resume "my-renamed-session"` (quote
   names containing spaces). If several sessions share a name, cage errors and
   lists their absolute handles. Renaming to something that parses as one of
   the forms above makes the code interpretation win — pick distinctive names.

Uppercase `S` and underscore separators (`S0_1`, `cage_2026-01-05_1`) parse
too — stored metadata and old transcripts use that spelling.

Sessions launched directly with `claude` (not via cage) have no registry entry
and are invisible to cage; resume those with `claude --resume` from their
working directory.

## Shell integration

After an **interactive** session (`cage new` / `cage resume` without `-p`)
ends, your shell cd's into the session's working directory (e.g. `/tmp/cage`).
This deliberately breaks the usual rule that a child process cannot change
your shell's cwd: a `cage()` shell function (dotfiles
`shell/functions/shortcuts.sh`) exports `CAGE_CWD_FILE`, the binary records
the session cwd there on the interactive paths only, and the wrapper cd's to
it after exit. Background `-p` runs and all other subcommands never write the
file, and `command cage` bypasses the wrapper entirely.

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

The session registry lives in `~/.local/state/cage/YYYY-MM-DD/` (persistent
across reboots; the profiles' *working* directories such as `/tmp/cage` are a
separate concern and unchanged):
- `cage_N.log` - Full output
- `cage_N.pid` - PID while running
- `cage_N.status` - Exit code
- `cage_N.meta.json` - Session metadata
- `cage_N.result.json` - Structured result
- `cage_N.sysprompt` - Transient system-prompt hand-off for `-p` resume jobs
  (deleted by the job wrapper when the run finishes)

Conversation transcripts are Claude Code's own, under
`~/.claude/projects/<cwd-slug>/<uuid>.jsonl`, retained per your
`cleanupPeriodDays` setting. `cage clean` prunes registry rows after an
itemized warning + confirmation; its default mode removes exactly the rows
whose transcript Claude already purged (unresumable), so it stays in sync
with your retention setting instead of assuming a number of days.

## Dependencies

- bash (4.0+)
- GNU getopt (for argument parsing)
- jq
- uuidgen
- gum (interactive resume picker, profile editor, clean confirmation)
- bat (`batcat` — log rendering for cage tail)
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
