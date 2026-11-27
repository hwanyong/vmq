# vmq: a control queue for VMs and devices shared by Claude Code sessions

[한국어](README.ko.md)

When several Claude Code sessions drive the same test VM, device or app window, one session's clicks, key presses or snapshot restores break another session's test. vmq is a queue for those targets: a session takes a turn on a target, drives it, and releases it. The scripts that drive a target call `vmq_require` before each control command, so a session without a turn is refused before anything happens.

The plugin has four parts:

| Part | Path | What it does |
|---|---|---|
| CLI | `bin/vmq` | `acquire`, `release`, `run`, `status`, ... On the Bash tool's PATH while the plugin is enabled |
| Shell library | `lib/vmq.zsh`, `lib/peek.zsh` | `vmq_require`, `vmq_keepalive`, `vmq_ssh`, `peek_allowed` for project scripts |
| Mod | `hooks/register.tsx` | The queue in the status line, a pane (`/vmq`) and toasts; starts and prompts the `vmq-main` session |
| Skill | `skills/queue/SKILL.md` | Tells every session the rules: take a turn before driving a shared target |

## Requirements

- macOS, Linux, Windows inside WSL2 (a Linux host), or native Windows with Git Bash (Git for Windows). WSL 1 is refused: its file locks do not keep other processes out (convert with `wsl --set-version <distribution> 2`)
- zsh, `jq`, and on Linux `procps` (`ps`, `pkill`). `nc` is used for `hosts.tsv` when present. You do not install these
  yourself: `vmq-setup` does it, and Claude runs it ("Setup")
- Claude Code with plugin hooks modules (mods) and plugin `bin/` on the Bash tool's PATH. Tested with 2.1.332

## Install

In Claude Code:

```
/plugin marketplace add hwanyong/vmq
/plugin install vmq@vmq
```

or from a shell:

```sh
claude plugin marketplace add hwanyong/vmq
claude plugin install vmq@vmq --scope user
```

## Setup

After installing, start a new Claude Code session. When something vmq needs is missing, the status line says `vmq: setup needed (…). Run /vmq-setup`. Run `/vmq-setup`, or ask Claude to set up vmq: the skill `vmq:queue` has Claude run `vmq-setup --check` and then `vmq-setup`, which installs only what is missing and prints each step.

| Host | What `vmq-setup` installs | What you may have to do |
|---|---|---|
| macOS | `jq` with Homebrew (zsh ships with macOS) | Install Homebrew if it is missing |
| Linux, WSL2 | `zsh`, `jq`, `procps` with the distribution's package manager | When sudo asks for a password, run the `sudo …` line it prints, typed after `!` in Claude Code |
| Windows with Git Bash | The MSYS2 `zsh` package and the DLLs it needs, checked against the SHA-256 in the MSYS2 package index, and the MSYS2 `jq` package (a native Windows `jq.exe` writes CRLF line ends), copied into Git's `usr` folder without replacing Git's files | When Git is installed for all users, accept the one administrator prompt (UAC) |
| Windows without Git Bash | Git for Windows with winget, for this user first (`bin/vmq-setup.ps1`, which Claude runs with its PowerShell tool), then the row above | Restart Claude Code so its Bash tool uses Git Bash |

Claude Code on Windows uses Git Bash for its Bash tool when Git for Windows is installed, and only a PowerShell tool when it is not ([setup docs](https://code.claude.com/docs/en/setup.md)). vmq runs in Git Bash.

The first time `vmq-main` opens, Claude Code must trust its working folder, the data folder. Trust is given by you at Claude Code's trust prompt, so Claude cannot give it. Run once in a terminal, accept the prompt, and quit:

```sh
cd "$(vmq paths | awk -F'\t' '$1 == "data" { print $2 }')" && claude
```

`vmq paths` prints the data folder (on macOS `~/Library/Application Support/vmq`). Until then, `vmq-main` does not open, and the mod shows that failure once, not in every session.

Then list the targets your sessions share ("Targets" below). Either ask Claude in words ("add my test VMs TestServer and TestClient on this Mac, roles server and client"), and the skill `vmq:queue` runs the commands for you, or run them yourself:

```sh
vmq init
vmq target add TestServer localhost server,myproject macOS
vmq target add TestClient localhost client,myproject macOS
vmq list
```

Until a target is listed, the status line says `vmq: no targets yet` and `vmq-main` is not started.

## Targets

The target list is `resources.tsv` in the data folder (`VMQ_REGISTRY`; `vmq paths` prints where it is). Change it with these commands, not by hand: they check the values, refuse a name that exists, refuse to remove a target a turn holds or waits for, and log the change in the queue log.

| Command | What it does |
|---|---|
| `vmq init` | Creates the data folder and an empty target list when absent |
| `vmq target add <name> <mac> <roles> <os>` | Adds a target (creates the list when absent) |
| `vmq target remove <name>` | Removes a target no turn holds or waits for |
| `vmq list` | Lists the targets |

To change a target, remove it and add it again.

| Value | Rule | Example |
|---|---|---|
| name | Letters, digits, `. _ -`. Turns are kept under it, so keep it stable | `TestServer`, `Pixel8`, `MiniDesktop` |
| mac | SSH address of the Mac the target is on, or any name for this Mac (`localhost`). Targets with the same value are on the same Mac for `@server+@client` | `localhost`, `mac-mini.local` |
| roles | Words joined with `,`, or `-` for none. A role names targets that can do the same job: `vmq acquire @server` takes whichever is free first. A project name as a role lets a project's scripts pick theirs (`vmq_with_role myproject`) | `server,myproject` |
| os | Operating system inside the target: `macOS`, `Windows`, `Linux`, or `-` for none | `macOS` |

Asking in words works through the skill (`skills/queue/SKILL.md`, "Adding and removing targets"): Claude collects the four values, asks for what it cannot tell, runs `vmq target add` and shows `vmq list`.

A build slot is a target with no operating system. To let at most two builds run at once, add two slots with one role and run builds through the queue:

```sh
vmq target add Build1 localhost build -
vmq target add Build2 localhost build -
vmq run @build -- make
```

`hosts.tsv` (optional, same folder) lists more addresses for a Mac, tried in order, for a Mac reachable on a direct link and on the LAN. See `examples/hosts.tsv`.

## Settings

### Plugin option

Set at install (`claude plugin install vmq@vmq --config autoStartMain=false`), or later with `/plugin configure vmq@vmq`. Until it is set, the default applies.

| Option | Default | What it does |
|---|---|---|
| `autoStartMain` | on | When a session starts, the target list holds a target, and no live session named `vmq-main` exists, the mod opens one in the background with `bin/vmq-main --if-absent`. It runs in permission mode `bypassPermissions` and may run `vmq force-release` on turns whose holding process is gone (see "The vmq-main session"). Turn it off to open it yourself with `/vmq-main` |

While `autoStartMain` is on, stopping `vmq-main` lasts until the next session starts. To keep it closed, turn the option off.

### Environment variables

The CLI and library read these. For the mod, which runs `bin/vmq` from inside Claude Code, set them in the `env` of `~/.claude/settings.json`; for a project script, in its environment.

| Variable | Default | Meaning |
|---|---|---|
| `VMQ_DATA` | macOS `~/Library/Application Support/vmq`, Linux `$XDG_DATA_HOME/vmq` (`~/.local/share/vmq`) | Data folder: target list, queue, reservations |
| `VMQ_CACHE` | macOS `~/Library/Caches/vmq`, Linux `$XDG_CACHE_HOME/vmq` (`~/.cache/vmq`) | The mod's shared read cache |
| `VMQ_REGISTRY` | `$VMQ_DATA/resources.tsv` | Target list |
| `VMQ_HOSTS_FILE` | `$VMQ_DATA/hosts.tsv` | More SSH addresses per Mac |
| `VM_QUEUE_DIR` | `$VMQ_DATA/queue` | The queue. Keep it on a local disk: `mkdir` is the lock and is not trusted to be atomic on SMB |
| `VM_QUEUE_LEASE` | 1200 | Seconds a turn lives after its last activity |
| `VM_QUEUE_HOLD_MAX` | 3600 | Seconds a turn lives after its last control command while its holding process is alive |
| `VM_QUEUE_STARVE` | 1800 | Seconds after which a waiting turn reserves free targets among its candidates |
| `VM_QUEUE_OWNER` | `CLAUDE_CODE_SESSION_ID` | Owner name (letters, digits, `. _ -`). Give a subagent that drives a target on its own its own owner |
| `VM_QUEUE_LABEL` | none | Label of a turn, same as `-l` |
| `VM_QUEUE_TICKET` | none | Pins `vmq_require`, `vmq release` and the others to one turn key (`vmq ticket`) |
| `VM_QUEUE_INTERNAL` | none | `1` skips the check, for a tool that runs itself again on another Mac |
| `VMQ_LOCK_WAIT` | 120 | Seconds a command waits for the queue lock before it gives up (exit code 1) |
| `VMQ_SSH_RETRY_S` | 30 | Seconds `vmq_ssh` keeps retrying connections that end in the banner exchange |
| `VMQ_REQUIRED_REF` | `main` | Branch `.vmq-required` is read from ("Rules") |

## Commands

| Command | What it does |
|---|---|
| `vmq acquire [-w s] [-l label] <group>…` | Takes a turn, one candidate per group. Waits 90 s by default; exit 75 means still waiting (run it again) |
| `vmq release [<target>…]` | Releases my turn, or only those targets |
| `vmq run [-l label] <group>… -- <command…>` | Takes a turn, runs the command with `VM_QUEUE_GRANTED`, releases (also on TERM, INT, HUP) |
| `vmq status [--json] [<target>…]` | Holder and waiting owners per target |
| `vmq mine` · `vmq ticket` | The targets I hold · my turn key |
| `vmq ended <target>` | How my last turn on it ended: `released`, `expired` or `force-released`, the time, and who took it next |
| `vmq force-release <target>` | Removes the turn that holds it. Only when the user says so, or `vmq-main` for a turn whose process is gone |
| `vmq list` · `vmq init` · `vmq target add` · `vmq target remove` | The target list ("Targets") |
| `vmq paths [--json]` | Where this host keeps the data folder, target list, queue and cache |
| `vmq peek-check '<command line>'` | Whether a read may run without a turn |
| `/vmq` · `/vmq-main` | Opens the pane · opens the `vmq-main` session |
| `vmq-setup [--check]` · `/vmq-setup` | Checks and installs what vmq needs ("Setup") · asks Claude to run it |

A group is a target name, comma-separated candidates (`Server1,Server2`), a role (`@server`), or targets joined with `+` that are taken together (`Server2+Client2`). `@server+@client` takes a server and a client on the same Mac. Exit codes: 0 done, 1 refused or error, 2 usage, 75 waiting.

## Using it in a project script

Scripts that drive a target source the library and call `vmq_require` before each control command:

```zsh
source "${VMQ_HOME:-$(dirname "$(command -v vmq)")/..}/lib/vmq.zsh"
vmq_require TestServer || exit 1
# ... drive TestServer ...
```

`command -v vmq` works in a shell a Claude Code session started (the plugin's `bin/` is on its PATH). Elsewhere set `VMQ_HOME` to the plugin folder.

1. Call `vmq_require <target>…` for every target at the start, so a script is not refused halfway and does not leave a target half changed. While the script's process lives, its turn does not expire for `VM_QUEUE_HOLD_MAX` seconds after its last control command.
2. A step that waits long without control commands calls `vmq_keepalive` every 600 s. A script that calls `vmq_require` only at the start calls `vmq_keepalive_or_exit` between long steps, so it stops when its turn is lost.
3. Read commands that may run without a turn go through `source .../lib/peek.zsh` and `peek_allowed "<command line>"` before connecting.
4. A script that runs itself again on another Mac sets `VM_QUEUE_INTERNAL=1` there: the check already happened on this Mac, and the queue is on this Mac only.
5. `vmq_ssh <address> …` runs ssh with `VMQ_SSH_BASE` (BatchMode, ConnectTimeout 5, ServerAlive 15 × 4), the addresses in `hosts.tsv`, and retries on a banner exchange timeout.

## Rules

| Item | Rule |
|---|---|
| Turn | Commands that change a target (start, stop, snapshot, restore, install, drive the screen, capture the screen, run tests) run only for the owner that holds its turn. The project tool calls `vmq_require <target>…` before each and exits 1 when refused |
| Request | One request per owner. Each group gets one target; the candidate free first is given; a `+` candidate is given when all its targets are free. All targets are taken at once, so nobody holds one and waits for another (no deadlock). To get more after taking, release and acquire together. While waiting, `acquire` with other groups changes the request under the same sequence number |
| Assignment | Waiting turns are read in sequence order and each group gets a free candidate. A turn that cannot be filled is skipped, so later turns can use free targets. A turn waiting longer than `VM_QUEUE_STARVE` reserves the free targets among its candidates |
| Expiry | A turn idle for `VM_QUEUE_LEASE` seconds is removed. On Windows (Git Bash) a process is told apart by its process group and session in place of its start time, because Cygwin sets the start time again on exec. `vmq_require` writes the calling shell's PID and start time into the turn; while that process lives the turn is kept, up to `VM_QUEUE_HOLD_MAX` seconds after its last control command or `vmq_keepalive`. Start times are read with `LC_ALL=C TZ=UTC`, so a reused PID is not taken as alive |
| Ended chains | A chain is a shell that takes a turn once, drives targets and ends; `vmq_chain_mark <pid> <target>…` writes it into the turn. A turn whose chain ended is not handed even to the same owner's next `acquire` until its cleanup releases it or it expires, so the cleanup never acts on the next chain's targets |
| Pinning | With `VM_QUEUE_TICKET=<key>`, `vmq_require`, `vmq_keepalive`, `vmq_chain_of`, `vmq_chain_mark`, `vmq release` and `vmq mine` act only on that turn, so a cleanup cannot act on a newer turn of the same owner |
| Tool version | When the calling script is in a git work tree whose `main` has `.vmq-required` (lines `<commit>\t<paths>\t<note>`), `vmq_require` refuses unless HEAD contains each commit or those paths equal `main`. An old work tree's tool then cannot drive targets without a fix that landed on `main` |
| Reads without a turn | `lib/peek.zsh` lists read commands and their argument rules. Chaining or writing syntax (`;`, `&`, `>`, `<`, backquotes, `$(`, newlines) and commands not listed are refused before connecting. Values read on a target another owner holds are that owner's state mid-work, not test evidence |
| Log | `$VM_QUEUE_DIR/log` gets a line for `registered`, `changed`, `held`, `released`, `expired`, `force-released`, `chain`, `target-added` and `target-removed`. Tools read it through `vmq ended`, not directly |

## status --json

`vmq status --json [<target>…]` prints one JSON object after the same lock, expiry and assignment as `vmq status`. Programs read this, not the text output.

| Field | Value |
|---|---|
| `version` | Format version, now 1 |
| `now` · `lease` · `holdMax` · `starve` | Time of the judgement (epoch seconds) and the limits in seconds |
| `owner` | The caller's owner, or `null` |
| `targets[]` | Per target: `name`, `host`, `roles[]`, `os` (`null` for `-`), `holder` (key or `null`), `assigned`, `reserved`, `waiting[]` |
| `requests[]` | Per turn with a file on the given targets: `key` (`<sequence>-<owner>`), `seq`, `owner`, `isMine`, `label`, `need[]`, `targets[]`, `held[]`, `assigned[]`, `created`, `active`, `procs[]`, `alive[]`, `expiry` |
| `expiry` | `basis` `holdMax` (a holding process is alive; expires `holdMax` seconds after `active`) or `lease` (expires `lease` seconds after the last activity); `seconds` left; `since` seconds since that start |

## Reservations

`reservations.tsv` in the data folder holds reservations and priorities. The `vmq` command does not read it; sessions read it before choosing a target, the mod judges turns against it, and `vmq-main` writes it. One line per reservation, seven tab-separated columns; lines starting with `#` and blank lines are skipped.

| Column | Value |
|---|---|
| 1 kind | `only`: only sessions under the project path hold or wait for these targets. `max`: sessions under the project path hold at most column 4 of these targets at once |
| 2 targets | Target names joined with `,` |
| 3 project path | Absolute. A session whose working folder is this path or below it belongs to the project |
| 4 number | The limit for `max`; `-` for `only` |
| 5 start · 6 end | UTC ISO 8601 (`2026-11-11T15:00Z`). `vmq-main` removes a line past its end |
| 7 reason | Who set it and when |

An owner without a session id (`VM_QUEUE_OWNER=build-1`) has no project, so its turns are not judged.

## The mod

Every 30 s the mod reads `vmq status --json`, `claude agents --json --all` and `reservations.tsv`, and adds the session name, project and verdicts to each turn. It does not change the queue. The two commands' stdout is cached in `$VMQ_CACHE/status.json` for 25 s and shared by sessions, because `vmq status` holds the queue lock for about 2 s.

| Where | What |
|---|---|
| Status line | `vmq held <n> · waiting <n> · violations <n>`, plus `no process`, `expiring` and `ended reservations` counts when there are any |
| Pane (`/vmq`) | One row per turn: state, session, project, targets, operating system, expiry, verdicts; the label below. Violations red, no process yellow, expiring cyan |
| pane-grid cell | With [pane-grid](https://github.com/hwanyong/pane-grid) installed, `vmq` can be placed in a grid cell |
| Toast | New verdicts, for 8 s |

| Verdict | When |
|---|---|
| `violation` | An `only` line's targets held or waited for by a session outside its project, or a `max` line's limit passed (later turns in sequence order) |
| `dead` | Holds targets, no live holding process, basis `lease`, idle over 120 s, and the owning session is not busy |
| `expiring` | Holds targets, basis `lease`, 300 s or less left, not `dead` |

The first read after the mod loads only fills the list. After that, new verdicts show a toast, and in the session named `vmq-main` they are also sent to the model as a `[vmq]` prompt. That prompt holds only values the mod makes (verdict kind, sequence number): labels, session names and reservation reasons are written by other sessions and would otherwise reach `vmq-main`, which may run `vmq force-release`, as instructions.

## The vmq-main session

`vmq-main` is one background session that watches the queue. The queue works without it. It writes reservations, tells a project's main session about turns that break them, warns about turns about to expire, and force-releases turns whose holding process is gone. Its role is `VMQ-MAIN.md`, which the mod adds to the system prompt of the session named `vmq-main` on every request, so it survives `/clear` and compaction.

It opens automatically (`autoStartMain`), with `/vmq-main`, or with `vmq-main` in a shell. `bin/vmq-main` checks for a live `vmq-main` under a lock, so sessions starting together open one. It opens with name `vmq-main` (other sessions send to it by name), permission mode `bypassPermissions` (messages from sessions in another mode would wait for approval) and working folder `$VMQ_DATA`. If a second session gets the same name, the later one gets a warning in place of the role.

When the data folder is not trusted yet, `claude --bg` refuses it and `bin/vmq-main` writes one stderr line with the folder and the command to run ("Setup"). The mod keeps the last such line in `$VMQ_CACHE/vmq-main-failed.txt` and shows a toast only when the line is new, so the same failure is not shown in every session.

## Tests

The tests make their own queue and target list under the folder you give.

```sh
zsh tests/peek.zsh                                        # read check: 18 reads pass, 33 commands refused
zsh tests/stress.zsh bin/vmq "$TMPDIR/vmq-s" "$TMPDIR/vmq-s.out"   # 10 owners at once: at most 1 per target
zsh tests/pair.zsh bin/vmq "$TMPDIR/vmq-p"                 # server+client pairs on one Mac (15 checks)
zsh tests/keepalive.zsh bin/vmq "$TMPDIR/vmq-k"            # expiry with a live holding process (11 checks, about 2 min)
zsh tests/run-signal.zsh bin/vmq "$TMPDIR/vmq-r"           # vmq run ended by TERM, KILL (6 checks)
```

Each exits 0 when every check is right. When you change the queue, also break the changed line in a copy and see the test fail before trusting it.

## License

MIT
