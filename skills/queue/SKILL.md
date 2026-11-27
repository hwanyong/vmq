---
name: queue
description: Take a vmq turn before driving a VM, device, simulator, desktop app window or browser profile that other Claude Code sessions may also drive, and release it when done. Use before any control command on such a target (clicks, key presses, snapshot restore, install, reboot, screen capture), when handing such work to a subagent or another session, when a vmq command or vmq_require refuses or exits 75, when the user asks to add, register, list or remove a target (VM, device, desktop, build slot) for vmq, and when vmq cannot run on this host (`vmq: command not found`, `zsh: command not found` or `bad interpreter` for vmq, jq missing, the status line says `vmq: setup needed`, or the user asks to install or set up vmq).
---

# vmq: take a turn before you drive a shared target

When several sessions drive the same VM or device, one session's clicks, key presses or snapshot restores break another session's test. vmq is a queue: a session takes a turn on a target, drives it, and releases it. A target is listed in the target list (`vmq list`; `vmq paths` prints where vmq keeps its files).

The commands are `vmq` (on the Bash tool's PATH while this plugin is enabled; also `${CLAUDE_PLUGIN_ROOT}/bin/vmq`) and the shell library `${CLAUDE_PLUGIN_ROOT}/lib/vmq.zsh`. The owner of a turn is this session (`CLAUDE_CODE_SESSION_ID`).

## Setup

vmq needs zsh (with the modules zsh/datetime, zsh/stat, zsh/net/tcp), jq and ps. `vmq-setup` (`${CLAUDE_PLUGIN_ROOT}/bin/vmq-setup`, a bash script on the Bash tool's PATH) checks them and installs what is missing. Do this yourself when vmq cannot run, when the status line says `vmq: setup needed`, or when the user asks to set up vmq; do not hand the steps to the user unless a step below says so.

1. Run `vmq-setup --check`. Exit code 0 means nothing is missing: stop. Otherwise it prints one `missing: …` line each.
2. Tell the user in one line what is missing and what you will install, then run `vmq-setup`. It prints each step.
   - macOS: `brew install jq` (zsh ships with macOS). Without Homebrew it prints where to get it; tell the user.
   - Linux and WSL2: the distribution's package manager installs zsh, jq and procps. As root or with sudo that needs no password it installs; otherwise it prints the `sudo …` command, and the user runs it by typing it after `!` in Claude Code (it asks for their password).
   - Windows with Git Bash: it downloads the MSYS2 zsh package and the DLLs zsh needs, checks each against the SHA-256 in the MSYS2 package index, also takes jq from MSYS2 (a native Windows jq.exe writes CRLF line ends, which breaks vmq), and copies them into Git's `usr` folder without replacing any of Git's files. When Git is installed for all users, Windows asks once for administrator rights (UAC): tell the user to expect that prompt and accept it.
3. Run `vmq-setup --check` again and report the result. When it is 0, `vmq list` (or `vmq init`) works; when no target is listed yet, offer to add targets ("Adding and removing targets").
4. The first time `vmq-main` opens, Claude Code must trust the data folder, its working folder. Only the user can accept that trust prompt; do not edit `~/.claude.json` to give it. When `vmq-main` reports `does not trust`, give the user the command it printed, and tell them to run it once in a terminal, accept the prompt, quit, and then run `/vmq-main`. The data folder is the `data` line of `vmq paths`.

On Windows without Git for Windows, Claude Code has only its PowerShell tool and no Bash tool. Then run, with the PowerShell tool, `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}\bin\vmq-setup.ps1" -Check` and then without `-Check`. It installs Git for Windows with winget (for this user first) and runs `vmq-setup` in its Git Bash. Then tell the user to restart Claude Code, so the Bash tool uses Git Bash.

## Rules

1. **Take a turn before you drive a target.** Targets are anything two sessions could drive whose state changes: test VMs, desktops and app windows driven by computer use or cua-driver, real devices, simulators, a shared browser profile. Commands that only ask for state (list, is it on, its address) are not driving. A screen capture is a read, but it shows a screen another session may be driving, so take it inside a turn.
2. **Wait when another owner holds it.** `vmq acquire` exits 75 when the wait runs out; run the same command again to keep your place.
3. **Release when done.** A turn left behind expires 1200 s after its last activity (`VM_QUEUE_LEASE`), and the next owner gets it.
4. **Take several targets together, in one acquire.** Do not take more while holding: two owners each holding one and waiting for the other deadlock. vmq refuses it.
5. **The tool enforces, not the instruction.** A project script that drives a target calls `vmq_require <target>` before each control command and exits when refused. Do not order sessions with words such as "wait for my message": nothing enforces them.
6. **Take by role when any of several targets will do.** `vmq acquire @server` gives whichever server is free first. Take by name only when the work depends on that target's earlier state (a snapshot, a pairing, a setting).
7. **Record the build on each target.** Targets can run different builds. Write the commit, a hash of uncommitted changes and the executable's hash into the target when installing, and put that line next to test results. Do not judge behavior between two targets that run different builds.

## Commands

| Need | Command |
|---|---|
| Take a turn (Bash timeout 330000 or more) | `vmq acquire -w 300 -l "<what you do>" <group>…` |
| Keep waiting after exit code 75 | the same command again |
| What I hold | `vmq mine` |
| Release | `vmq release` (or `vmq release <target>`) |
| Queue state | `vmq status` (`--json` for a program) |
| Run one command inside a turn | `vmq run -l "<label>" <group>… -- <command…>` (releases when it ends, also on TERM, INT, HUP) |
| Is a read allowed without a turn | `vmq peek-check '<command line>'` |

A group is a target name, comma-separated candidates (`Server1,Server2`), a role (`@server`), or targets joined with `+` that are taken together (`Server2+Client2`). `@server+@client` takes a server and a client on the same Mac. Exit codes: 0 done, 1 refused or error, 2 usage, 75 still waiting.

## Adding and removing targets

Use this when the user asks to add, register, list or remove a VM, device, simulator, desktop or build slot ("add my two test VMs", "register the Mac mini desktop"). Change the target list only with these commands, never by editing the file: they check the values, refuse a name that exists, refuse to remove a target a turn holds, and log the change.

| Need | Command |
|---|---|
| First use (creates the data folder and `resources.tsv`) | `vmq init` |
| Add a target | `vmq target add <name> <mac> <roles> <os>` |
| Remove a target (no turn may hold or wait for it) | `vmq target remove <name>` |
| Change a target | `vmq target remove <name>`, then `vmq target add` with the new values |
| See the list | `vmq list` |

The four values, one target each:

| Value | Rule | Example |
|---|---|---|
| name | Letters, digits, `. _ -`. Turns use it, so keep it stable | `TestServer`, `Pixel8`, `MiniDesktop` |
| mac | The SSH address of the Mac the target is on (any name for this Mac, such as `localhost`). Targets with the same value count as on the same Mac for `@server+@client` | `localhost`, `mac-mini.local` |
| roles | Words joined with `,`, or `-`. A role names targets that can do the same job (`vmq acquire @server`); a project name as a role lets that project pick its own | `server,myproject` |
| os | The operating system running inside the target: `macOS`, `Windows`, `Linux`, or `-` for none (a build slot) | `macOS` |

Steps when the user asks in words:

1. Collect the four values for each target. Ask the user for what you cannot read from the request. Do not guess the Mac address or the roles.
2. Show the `vmq target add` lines you will run and run them. Each prints `added: …` or the reason it refused.
3. Run `vmq list` and show the result.
4. A Mac reachable on several addresses (a direct link and the LAN) can get a line in `hosts.tsv` in the data folder (`vmq paths`) (format in `${CLAUDE_PLUGIN_ROOT}/examples/hosts.tsv`). It is optional.

To limit how many builds run at once, add that many build slots with the same role and run builds with `vmq run @build -- <command>`: `vmq target add Build1 localhost build -`, `vmq target add Build2 localhost build -`.

## Long scripts

- Call `vmq_require <target>…` at the start of a script that drives targets. While that script's process lives, its turn does not expire for up to 3600 s (`VM_QUEUE_HOLD_MAX`) after its last control command or refresh.
- A step that waits close to that limit without control commands calls `vmq_keepalive` every 600 s.
- A script that calls `vmq_require` once at the start and not before each command calls `vmq_keepalive_or_exit` between long steps, from its top-level shell, so it stops driving targets when it has lost its turn.
- Without a script, do not leave a turn idle for more than 20 minutes between commands.

## Handing work to a subagent or another session

Put this in its instructions:

- Before driving a target: `vmq acquire -w 300 -l "<label>" <group>…` (Bash timeout 330000 or more); on 75 run it again. When done: `vmq release`. State: `vmq status`.
- Whether to take by role or by name (rule 6), and that a server and a client that work together are taken as a pair: `vmq acquire @server+@client` (`@server @client` can mix Macs). A pair is printed server first.
- Which read commands may run without a turn (the project's own peek command, checked with `vmq peek-check`).
- To put the build line next to results (rule 7).
- A subagent inherits this session's id. If it drives a target on its own while this session also does, give it its own `VM_QUEUE_OWNER=<name>`.

## When vmq refuses

- `vmq: no turn for <target>`: acquire first.
- `vmq: no target list`, or the status line says `vmq: no targets yet`: add targets ("Adding and removing targets" above; ask the user what they are).
- `vmq: this owner already holds …`: release, then acquire everything together.
- Reservations and priorities between projects are kept by the session `vmq-main` in `reservations.tsv` in the data folder (`vmq paths`). Read it before choosing a target, and send requests about the queue (reservations, asking another session to release, a turn whose process is gone) to `vmq-main` with SendMessage, by that name. Do not run `vmq force-release` yourself unless the user says so.
