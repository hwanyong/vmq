# vmq: the control queue for targets several sessions share (README.md). A project's tools source this file:
#   source "<vmq>/lib/vmq.zsh"
# When several sessions drive the same VM or device, one session's clicks, key presses or snapshot restores break another
# session's test. Only the owner that holds a turn drives the target. The project's tool calls vmq_require before each control
# command, so a session without a turn is refused before anything happens.
#
# Target list: VMQ_REGISTRY (default $VMQ_DATA/resources.tsv). One line per target: <name> <Mac> <roles> <os> (tab-separated).
# One list per Mac.
# Queue: VMQ_DIR (default $VMQ_DATA/queue). Keep it on this Mac's local disk: mkdir is not trusted to be atomic on SMB or
# other network disks. A target on another Mac uses the queue of the Mac that runs the command driving it. A tool that runs
# itself again on another Mac sets VM_QUEUE_INTERNAL=1 there to skip the check.
#
# One turn = one request. A request is a list of groups, and each group gets one candidate. A group is comma-separated
# candidates (`Server1,Server2`, or a role `@server`). One candidate can be several targets joined with `+`
# (`Server2+Client2`): that candidate is taken only when all its targets are free. When a joined part is a role
# (`@server+@client`), only targets on the same Mac (second column of resources.tsv) are joined, for a server and a client
# that must pair on one Mac. Of the candidates, the one free first is given.
# Turn file: $VMQ_DIR/<candidate>/<10-digit sequence>-<owner>, the same content under each candidate. Lines: owner, label,
# created, need (groups space-separated, candidates comma-separated, targets in a candidate joined with +), held (the targets
# taken, once taken), active (time of the last control command or vmq_keepalive), procs (the processes that called that
# control command, `<PID>@<start time>` space-separated). On taking, the files of the candidates not taken are removed.
# The file's modification time is the last activity.
#
# Assignment (vmq_plan): targets of held turns are set aside first, then waiting turns are read in sequence order, and for
# each group a candidate whose targets are all free is picked. When every group is filled, the turn is assigned. A turn that
# cannot be filled is skipped, so a later turn can use a free target while an earlier one waits for another.
# A turn older than VM_QUEUE_STARVE seconds (default 1800) since it registered reserves the free targets among its candidates
# even when it cannot be filled yet, so later turns cannot keep taking them. An assigned turn is taken by its owner's next
# acquire or control command (vmq_commit).
# An owner has one turn. To get more targets after taking, release and acquire them together. While waiting, the request can
# be changed under the same sequence number.
# Owner: VM_QUEUE_OWNER, else CLAUDE_CODE_SESSION_ID, which Claude Code gives each session. Subagents (Agent tool) inherit the
# session id, so a subagent that drives a target on its own sets its own VM_QUEUE_OWNER.
# A turn is valid for VM_QUEUE_LEASE seconds (default 1200) from its last activity. vmq_require and acquire write the time.
# A turn idle longer is removed by the next reader of the queue. A turn across several targets is removed when all its files
# are past VM_QUEUE_LEASE (vmq_purge). A turn held by an ended chain does not get its time written by the same owner's reads
# (vmq mine, vmq_chain_of) or by the waits of acquire and run (see vmq_chain_ended and vmq_sync).
# Pinning a turn: with VM_QUEUE_TICKET set to a turn key (<10-digit sequence>-<owner>, from vmq ticket), vmq_require,
# vmq_keepalive, vmq_chain_of, vmq_chain_mark, vmq release and vmq mine act only when that key is this owner's current turn,
# and otherwise do nothing and return 1 (vmq_ticket_ok).
# A turn whose holding process is alive is not removed for inactivity. vmq_require writes the shell process that called it
# ($$, the script when called from one) into procs, and the queue reader (vmq_purge) writes a new modification time while that
# process lives. When it ends, the turn is removed VM_QUEUE_LEASE seconds after the next read of the queue (waiters read every
# 2 seconds). After VM_QUEUE_HOLD_MAX seconds (default 3600) from the last control command or refresh (active), the time is no
# longer written even if the process lives, so a stuck script's turn is also removed VM_QUEUE_LEASE seconds later.
# The limit is meant for a long step that drives no target (an app build) inside a script that holds a turn.

zmodload zsh/datetime
zmodload -F zsh/stat b:zstat
zmodload zsh/system

VMQ_ROOT=${${(%):-%x}:A:h:h}
source "$VMQ_ROOT/lib/paths.zsh"
VMQ_REGISTRY=${VMQ_REGISTRY:-$VMQ_DATA/resources.tsv}
VMQ_DIR=${VM_QUEUE_DIR:-$VMQ_DATA/queue}
VMQ_LEASE=${VM_QUEUE_LEASE:-1200}
VMQ_STARVE=${VM_QUEUE_STARVE:-1800}
VMQ_HOLD_MAX=${VM_QUEUE_HOLD_MAX:-3600}
# What reading the queue found (vmq_scan). Keys are turn file names (<sequence>-<owner>).
typeset -gA Q_vms Q_file Q_need Q_held Q_alloc Q_busy
# Expiry of a turn file (vmq_expiry) or a turn (vmq_key_expiry)
typeset -ga Q_exp

# Reads the target list. VMQ_HOST[name] = Mac, VMQ_ROLES[name] = roles (space-separated), VMQ_OS[name] = the target's
# operating system (`-` for none). read's last name takes all remaining columns, so os must be named or the fourth column
# would be appended to roles.
typeset -gA VMQ_HOST VMQ_ROLES VMQ_OS
vmq_load_registry() {
  local name host roles os
  VMQ_HOST=() VMQ_ROLES=() VMQ_OS=()
  # VMQ_REGISTRY_OPTIONAL=1 (bin/vmq init and target) reads a missing list as empty without the message
  [[ -r $VMQ_REGISTRY ]] || { [[ -n ${VMQ_REGISTRY_OPTIONAL:-} ]] || print -u2 "vmq: no target list: $VMQ_REGISTRY (vmq init, then vmq target add)"; return 1 }
  while IFS=$'\t' read -r name host roles os; do
    [[ -z $name || $name == \#* ]] && continue
    VMQ_HOST[$name]=$host VMQ_ROLES[$name]=${roles//,/ } VMQ_OS[$name]=${os:--}
  done < "$VMQ_REGISTRY"
}
vmq_load_registry
# ssh options for a Mac: vmq_ssh_opts <identity address> → reply. The identity address (second column of resources.tsv) stays
# the ssh destination, and the options this function returns go before it: `vmq_ssh_opts $h; ssh "${reply[@]}" $h …`.
# reply always starts with VMQ_SSH_BASE (below). Then the addresses in hosts.tsv are tried in order, 2 seconds each
# (vmq_port_open <address>). When the address that answers is the identity address, nothing is added; when it is another one,
# -o HostName=<that address> -o HostKeyAlias=<identity address> is added so the same host key is checked. When none answers,
# the exit code is 1 (ssh then reports that failure itself). An identity address not in hosts.tsv gets VMQ_SSH_BASE alone.
# This is for a Mac reachable on several networks (a direct link and the LAN): when the first link is down, the next one is used.
# VMQ_SSH_BASE: the shared ssh options for Macs and VMs. No password prompts (BatchMode), a connection that does not open in
# 5 seconds is dropped (ConnectTimeout), and a peer that stops answering is asked every 15 seconds and dropped after 4 missed
# answers (about 75 seconds with the first 15, exit code 255). sshd answers keepalives apart from the remote command, so a long
# healthy command is not cut. A hung ssh would otherwise hold a turn until its lease runs out. A caller that also uses ssh to a
# guest VM uses this array as it is.
typeset -ga VMQ_SSH_BASE=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
VMQ_HOSTS_FILE=${VMQ_HOSTS_FILE:-$VMQ_DATA/hosts.tsv}
# Whether TCP port 22 of an address accepts a connection within 2 seconds: vmq_port_open <address> → 0 or 1.
# macOS nc takes the connect timeout as -G (its -w is the idle timeout); the OpenBSD nc of Linux distributions (netcat-openbsd)
# takes it as -w. Without nc, zsh's own TCP module under coreutils timeout is used.
vmq_port_open() {
  if [[ $OSTYPE == darwin* ]]; then nc -z -G 2 $1 22 >/dev/null 2>&1
  elif (( $+commands[nc] )); then nc -z -w 2 $1 22 >/dev/null 2>&1
  else timeout 2 zsh -c 'zmodload zsh/net/tcp && ztcp $1 22 && ztcp -c' zsh $1 >/dev/null 2>&1
  fi
}
vmq_ssh_opts() {
  local id=$1 key addrs a
  reply=($VMQ_SSH_BASE)
  [[ -r $VMQ_HOSTS_FILE ]] || return 0
  while IFS=$'\t' read -r key addrs; do
    [[ $key == $id ]] && break
    addrs=
  done < "$VMQ_HOSTS_FILE"
  [[ -n $addrs ]] || return 0
  for a in ${=addrs}; do
    vmq_port_open $a || continue
    [[ $a == $id ]] || reply+=(-o "HostName=$a" -o "HostKeyAlias=$id")
    return 0
  done
  return 1
}
# Runs ssh to a Mac: vmq_ssh <identity address> [ssh options…] [remote command…] → ssh's exit code. vmq_ssh_opts picks the
# options on every attempt. ssh also takes options after the destination (`vmq_ssh $h -n uptime`). The remote command's stdout
# and stderr pass through, and ssh's own diagnostics (taken with -E) are copied to stderr on every attempt. The retry loop is
# vmq_ssh_retry below; scp and ssh to a guest VM call it directly.
# Only a connection that ended in the banner exchange (exit code 255 and "during banner exchange") is retried with a new
# connection: before the banner the remote command has not started and standard input has not been read. No attempt starts
# after VMQ_SSH_RETRY_S seconds from the first. Every retry writes its count and elapsed seconds to stderr and the queue log.
# Why: on macOS, packets of a new ssh flow are sometimes dropped right after it connects (kernel log "reason: NECP"), and such
# a connection times out in the banner exchange while a new connection a few seconds later works. Waiting longer on the same
# connection did not help, so a new connection is opened instead.
# VMQ_SSH_RETRY_S (default 30) is an estimate: the second attempt starts about 5.1 seconds after the first (ConnectTimeout 5),
# so 30 allows about six attempts. To measure again, collect attempt counts, elapsed seconds and exit codes from the queue log:
# `grep -E '(ssh|scp) [^ ]+: [0-9]+ attempts' "$VMQ_DIR/log"`, and look for runs that hit the limit and ended with 255.
VMQ_SSH_RETRY_S=${VMQ_SSH_RETRY_S:-30}
# The retry loop: vmq_ssh_retry <log name> <prepare function> [its arguments…] → the command's exit code. vmq_ssh to a Mac and a
# project's ssh or scp to a guest VM share these rules from here.
# <prepare function> is called on every attempt and puts the whole command to run into reply. That command's ssh diagnostics
# must go to the $VMQ_SSH_ERR file: `-E "$VMQ_SSH_ERR"` for ssh, `-S "$VMQ_ROOT/bin/vmq-ssh-e"` for scp (it runs ssh with -E
# set to that file). The file is copied to stderr on every attempt.
# The log name is a target without spaces, such as "ssh <identity address>" or "scp <VM>" (the measuring grep looks for that form).
vmq_ssh_retry() {
  local name=$1 prep=$2 rc n=0 t0=$EPOCHREALTIME msg
  shift 2
  local -x VMQ_SSH_ERR
  VMQ_SSH_ERR=$(mktemp "${TMPDIR:-/tmp}/vmq-ssh.XXXXXX") || return 255
  while :; do
    (( ++n ))
    $prep "$@"
    # Take the exit code as a list so a caller under set -e does not end at the failing command
    "${reply[@]}" && rc=0 || rc=$?
    [[ -s $VMQ_SSH_ERR ]] && cat -- $VMQ_SSH_ERR >&2
    (( rc == 255 )) && grep -q 'during banner exchange' $VMQ_SSH_ERR && (( EPOCHREALTIME - t0 < VMQ_SSH_RETRY_S )) || break
    : >| $VMQ_SSH_ERR
    msg=$(printf '%s: ended in the banner exchange, retrying with a new connection (attempt %d, %.1f s after the first)' $name $(( n + 1 )) $(( EPOCHREALTIME - t0 )))
    print -u2 -r -- "vmq_ssh: $msg"
    vmq_log "$msg" 2>/dev/null || true
  done
  if (( n > 1 )); then
    msg=$(printf '%s: %d attempts, %.1f s, exit code %d' $name $n $(( EPOCHREALTIME - t0 )) $rc)
    print -u2 -r -- "vmq_ssh: $msg"
    vmq_log "$msg" 2>/dev/null || true
  fi
  rm -f -- $VMQ_SSH_ERR
  return $rc
}
# vmq_ssh's prepare function: picks the address again on every attempt (the first link may have gone down in between)
vmq_ssh_cmd() { local id=$1; shift; vmq_ssh_opts $id || true; reply=(ssh -E "$VMQ_SSH_ERR" "${reply[@]}" $id "$@") }
vmq_ssh() { vmq_ssh_retry "ssh $1" vmq_ssh_cmd "$@" }

# Targets with a role, by name: vmq_with_role <role>
vmq_with_role() { local v; for v in ${(ok)VMQ_HOST}; do vmq_has "${VMQ_ROLES[$v]}" $1 && print -r -- $v; done; true }

# Optional: in a Doghoodie terminal tab, the id of the Claude Code session that opened the tab: vmq_owner_doghoodie
# Doghoodie (a terminal app) can run a session's Bash commands in its own tabs (`doghoodie run --session cc-<first 8 characters
# of the session id>[/<name>]`). That tab's shell is a login shell the app opened, so it does not inherit CLAUDE_CODE_SESSION_ID
# and has no claude among its parent processes; it has DOGHOODIE_TERMINAL and DOGHOODIE_SOCKET. So the tab's session name is read
# from `doghoodie ls --json`, and the id is printed only when exactly one live session in `claude agents --json` has a sessionId
# starting with those 8 characters. Without DOGHOODIE_TERMINAL this function is never called.
vmq_owner_doghoodie() {
  local t=${DOGHOODIE_TERMINAL:-} h helper inst name prefix ids
  [[ $t =~ '^[0-9]+$' ]] || return 1
  for h in ${commands[doghoodie]:-} $HOME/Applications/Doghoodie.app/Contents/Helpers/doghoodie /Applications/Doghoodie.app/Contents/Helpers/doghoodie; do
    [[ -x $h ]] && { helper=$h; break }
  done
  [[ -n $helper ]] || { print -u2 "vmq: Doghoodie terminal $t, but no doghoodie executable on PATH, in ~/Applications or in /Applications"; return 1 }
  (( $+commands[jq] && $+commands[claude] )) || { print -u2 "vmq: jq and claude must be on PATH to find the owner of Doghoodie terminal $t"; return 1 }
  # With several app instances, read only this tab's instance (the pid in its control socket control-<pid>.sock).
  local -a iopt
  inst=${${DOGHOODIE_SOCKET:t}#control-}; inst=${inst%.sock}
  [[ $inst =~ '^[0-9]+$' ]] && iopt=(-i $inst)
  name=$("$helper" ls $iopt --json | jq -r --argjson t $t 'map(select(.terminal == $t)) | if length == 1 then (.[0].session // "") else "" end') \
    || { print -u2 "vmq: could not read doghoodie ls --json (Doghoodie terminal $t)"; return 1 }
  prefix=${${name#cc-}%%/*}
  [[ $name == cc-* && $prefix =~ '^[0-9a-f]{8}$' ]] \
    || { print -u2 "vmq: the session name of Doghoodie terminal $t is not cc-<first 8 characters of a session id>: ${name:-none}"; return 1 }
  ids=$(claude agents --json | jq -r --arg p $prefix '[.[] | .sessionId // empty | select(startswith($p))] | unique | .[]') \
    || { print -u2 "vmq: could not read claude agents --json"; return 1 }
  local -a found=(${(f)ids})
  (( $#found == 1 )) \
    || { print -u2 "vmq: ${#found} live Claude Code sessions start with $prefix, from Doghoodie session name $name (there must be 1)"; return 1 }
  print -r -- $found[1]
}

# The owner name. It goes into file names, so only letters, digits and . _ - are accepted.
# VM_QUEUE_OWNER, else CLAUDE_CODE_SESSION_ID, else in a Doghoodie tab the value of vmq_owner_doghoodie.
vmq_owner() {
  local o=${VM_QUEUE_OWNER:-${CLAUDE_CODE_SESSION_ID:-}}
  [[ -z $o && -n ${DOGHOODIE_TERMINAL:-} ]] && { o=$(vmq_owner_doghoodie) || return 1 }
  [[ -n $o ]] || { print -u2 "vmq: no owner. Set VM_QUEUE_OWNER=<name> (a Claude Code session uses CLAUDE_CODE_SESSION_ID)"; return 1 }
  [[ $o =~ '^[A-Za-z0-9._-]+$' ]] || { print -u2 "vmq: an owner name takes only letters, digits and . _ -: $o"; return 1 }
  print -r -- $o
}

# Version check of the calling tool: vmq_tool_current. When the script that sourced this file ($ZSH_ARGZERO resolved against the
# working folder at source time, or that folder when it is not a file) is inside a git work tree and that repository's main
# branch has .vmq-required, this work tree must pass every line: HEAD contains that commit, or the work tree content of the
# paths on that line equals main. When any line fails, the reason and the fix go to stderr and the return is 1. Without that
# repository or file, 0. Line format: <commit>\t<paths, space-separated>\t<note>. Lines starting with # and blank lines are skipped.
# The branch the list is read from is VMQ_REQUIRED_REF (default main), for trying a list on a test branch first.
# Why: an old work tree branched long before a fix on main can run an old tool that lacks the fix (an ssh without keepalive
# that holds a turn for half an hour). The old tool does not have the new check itself, but it always sources this file, so
# vmq_require checks here. The list is read from main, not the work tree, so a new line applies to running scripts at once.
# Before adding a line, check that the work trees of running scripts have that commit (a refused script's cleanup is refused too).
VMQ_CALLER=${ZSH_ARGZERO:A}
[[ -f $VMQ_CALLER ]] && VMQ_CALLER_DIR=${VMQ_CALLER:h} || VMQ_CALLER_DIR=$PWD
vmq_tool_current() {
  local top c paths note line ref=refs/heads/${VMQ_REQUIRED_REF:-main}
  local -a missing
  top=$(git -C "$VMQ_CALLER_DIR" rev-parse --show-toplevel 2>/dev/null) || return 0
  git -C "$top" cat-file -e $ref:.vmq-required 2>/dev/null || return 0
  while IFS=$'\t' read -r c paths note; do
    [[ -z $c || $c == \#* ]] && continue
    git -C "$top" merge-base --is-ancestor "$c" HEAD 2>/dev/null && continue
    [[ -n $paths ]] && git -C "$top" diff --quiet $ref -- ${=paths} 2>/dev/null && continue
    missing+=("$c"$'\t'"$paths"$'\t'"$note")
  done < <(git -C "$top" show $ref:.vmq-required)
  (( ${#missing} )) || return 0
  print -u2 "vmq: refused because this tool's version lacks main commits needed to drive targets (nothing was done)."
  print -u2 "  tool: $VMQ_CALLER"
  print -u2 "  work tree: $top (HEAD $(git -C "$top" rev-parse --short HEAD 2>/dev/null))"
  for line in $missing; do
    IFS=$'\t' read -r c paths note <<< "$line"
    print -u2 "  missing commit: $c $note"
    print -u2 "    fix: merge main into the branch (git -C ${(q)top} merge ${ref#refs/heads/}) or check out those paths from it (git -C ${(q)top} checkout ${ref#refs/heads/} -- $paths)"
  done
  print -u2 "  list: .vmq-required on branch ${ref#refs/heads/}"
  return 1
}

vmq_log() { print -r -- "$(strftime '%Y-%m-%d %H:%M:%S' $EPOCHSECONDS) $*" >> "$VMQ_DIR/log" }

# The lock held while the queue is changed: an fcntl lock (zsystem flock) on $VMQ_DIR/.lock. The kernel ties it to the process
# that holds it, so only that process releases it (vmq_unlock), and the kernel releases it when that process ends, also by exit
# or KILL. A caller waits up to VMQ_LOCK_WAIT seconds (default 120), then gives up with exit code 1.
# Before, the lock was a directory (mkdir .mutex) with a rule that a lock older than 30 seconds was left by an ended process. On
# a GitHub ubuntu runner two processes held it at once (CI runs 46036892280 and 46037313663, traced with the holder's pid written into the lock):
# one process's rmdir removed a lock another process had just taken, and from then on each release removed the next holder's
# lock. A turn file was then written again after its turn was released, which left an empty request that kept two targets
# assigned to an owner that had ended (tests/pair.zsh, CI run 46032992617). The 30-second rule would also take a lock from a
# holder slower than that (a slow disk or host).
# Inside the holding process the lock file must not be opened and closed again: closing any descriptor of the file releases
# the process's fcntl locks. Subshells and child processes do not hold the lock, so their opening and closing does not release it.
# WSL 1 runs Linux programs on the Windows kernel, and there fcntl locks do not keep other processes out (CI run 46039179664:
# 8 processes adding 25 each under the lock ended at 2, not 200). WSL 2 runs a Linux kernel. So on WSL 1 vmq refuses to change
# the queue instead of changing it without a lock. WSL 1's kernel release names Microsoft (4.4.0-<build>-Microsoft); WSL 2's
# ends in microsoft-standard-WSL2.
VMQ_LOCK_WAIT=${VMQ_LOCK_WAIT:-120}
typeset -g VMQ_LOCK_FD=
typeset -g VMQ_WSL1=0
[[ -r /proc/sys/kernel/osrelease && $(</proc/sys/kernel/osrelease) == *Microsoft* ]] && VMQ_WSL1=1
vmq_lock() {
  local f="$VMQ_DIR/.lock" fd
  (( ! VMQ_WSL1 )) || { print -u2 "vmq: WSL 1 is not supported: its file locks do not keep other processes out. Convert the distribution to WSL 2 (in Windows: wsl --set-version <distribution> 2)"; return 1 }
  mkdir -p "$VMQ_DIR"
  [[ -e $f ]] || : >> "$f" || return 1
  zsystem flock -t $VMQ_LOCK_WAIT -f fd "$f" || { print -u2 "vmq: could not get the lock in $VMQ_LOCK_WAIT s ($f)"; return 1 }
  VMQ_LOCK_FD=$fd
}
vmq_unlock() {
  [[ -n $VMQ_LOCK_FD ]] || return 0
  zsystem flock -u $VMQ_LOCK_FD
  VMQ_LOCK_FD=
}

# Turn files of a target, oldest first: vmq_tickets <vm> → reply
vmq_tickets() { reply=("$VMQ_DIR/$1"/<->-*(N.on)) }
vmq_key_owner() { print -r -- ${1#*-} }
vmq_idle() { print $(( EPOCHSECONDS - $(zstat +mtime -- "$1") )) }
vmq_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1 }
# Is the word in the space-separated list: vmq_has <list> <word>
vmq_has() { [[ " $1 " == *" $2 "* ]] }

# Writes a turn file again: vmq_write <file> <owner> <label> <created> <need> [held] [active] [procs] [chain]
# chain is the `<PID>@<start time>` of the chain shell that holds this turn (vmq_chain_mark). A turn whose chain ended
# (vmq_chain_ended) is not handed even to the same owner's acquire or run (register in bin/vmq), and the same owner's reads do
# not write its time (vmq_sync).
vmq_write() {
  print -l "owner=$2" "label=$3" "created=$4" "need=$5" ${6:+"held=$6"} ${7:+"active=$7"} ${8:+"procs=$8"} ${9:+"chain=$9"} > "$1"
}

# A value naming one process, `<PID>@<start time>`: vmq_proc_id <PID>. 1 when there is no such process. The start time is kept
# so a PID reused by another process after the first ended is not taken as alive. It is read with LC_ALL=C and TZ=UTC:
# `ps -o lstart=` prints in the caller's locale and time zone, so a writer and a reader with different LANG or TZ would take a
# live process as ended. A value written before this rule is written again by the holder's next vmq_require (vmq_attach);
# until then expiry is judged by VM_QUEUE_LEASE from the last activity.
# Git Bash (OSTYPE cygwin or msys) has a ps without -o, and its start time (field 22 of /proc/<PID>/stat) is set again when
# the process execs another program (CI run 46030706984: 304964 before `exec sleep`, 305037 after), which would take a script
# whose shell execs as ended. There the value is the process group and session (fields 5 and 6), which exec keeps:
# `<PID>@g<group>s<session>`. A reused PID is taken as alive only when it also has that group and session, which is less
# certain than a start time. Fields 3 on follow the `(<command>) ` part, which can hold spaces.
vmq_proc_id() {
  local s f
  if [[ $OSTYPE == (cygwin|msys)* ]]; then
    s=$(<"/proc/$1/stat") 2>/dev/null || return 1
    f=(${=${s##*\) }})
    [[ -n ${f[4]:-} ]] || return 1
    s="g${f[3]}s${f[4]}"
  else
    s=$(LC_ALL=C TZ=UTC ps -o lstart= -p $1 2>/dev/null)
    [[ -n ${s// } ]] || return 1
    s=${(j:_:)${=s}}
  fi
  print -r -- "$1@$s"
}
# The live processes among procs: vmq_procs_alive <procs> → prints the live ones space-separated. 1 when none.
vmq_procs_alive() {
  local p out=()
  for p in ${=1}; do [[ $(vmq_proc_id ${p%%@*}) == $p ]] && out+=($p); done
  (( ${#out} )) || return 1
  print -r -- ${out}
}

# The targets in a candidate: vmq_members <candidate> → reply. Names joined with `+`.
vmq_members() { reply=(${(s:+:)1}) }
# All targets of several groups, without repeats: vmq_all_members <group>… → reply
vmq_all_members() {
  local g c out=()
  for g in "$@"; do for c in ${(s:,:)g}; do out+=(${(s:+:)c}); done; done
  reply=(${(u)out})
}

# Expands one group (comma-separated candidates) to a comma list: vmq_expand <group>. 1 for an unknown name or role.
# @<role> is every target with that role (by name). A `+` candidate with a role expands, per Mac (by name), into the
# combinations filled with that Mac's targets. A candidate of names alone is taken as written.
vmq_expand() {
  local out=() x c r
  for x in ${(s:,:)1}; do
    if [[ $x == *+* ]]; then
      c=$(vmq_expand_joined $x) || return 1
      out+=(${=c})
    elif [[ $x == @* ]]; then
      r=(${(f)"$(vmq_with_role ${x#@})"})
      (( ${#r} )) || { print -u2 "vmq: no target has that role: $x (target list $VMQ_REGISTRY)"; return 1 }
      out+=($r)
    else
      [[ -n ${VMQ_HOST[$x]:-} ]] || { print -u2 "vmq: unknown target: $x (target list $VMQ_REGISTRY: ${(ok)VMQ_HOST})"; return 1 }
      out+=($x)
    fi
  done
  out=(${(u)out})
  (( ${#out} )) || { print -u2 "vmq: a group with no candidate: $1"; return 1 }
  print -r -- ${(j:,:)out}
}
# Expands one `+` candidate: vmq_expand_joined <part+part…> → candidates, space-separated. No target appears twice in one candidate.
vmq_expand_joined() {
  local parts=(${(s:+:)1}) p host combos next c m here v roles=0 hosts
  for p in $parts; do
    if [[ $p == @* ]]; then
      roles=1
      [[ -n $(vmq_with_role ${p#@}) ]] || { print -u2 "vmq: no target has that role: $p (target list $VMQ_REGISTRY)"; return 1 }
    else
      [[ -n ${VMQ_HOST[$p]:-} ]] || { print -u2 "vmq: unknown target: $p (target list $VMQ_REGISTRY: ${(ok)VMQ_HOST})"; return 1 }
    fi
  done
  (( roles )) || { print -r -- $1; return 0 }
  hosts=(${(ou)${(v)VMQ_HOST}})
  local out=()
  for host in $hosts; do
    combos=("")
    for p in $parts; do
      if [[ $p == @* ]]; then m=(${(f)"$(vmq_with_role ${p#@})"}); else m=($p); fi
      here=()
      for v in $m; do [[ ${VMQ_HOST[$v]} == $host ]] && here+=($v); done
      next=()
      for c in "${combos[@]}"; do for v in $here; do vmq_has "${c//+/ }" $v || next+=(${c:+$c+}$v); done; done
      combos=($next)
    done
    out+=($combos)
  done
  (( ${#out} )) || { print -u2 "vmq: no candidate can be filled on one Mac: $1"; return 1 }
  print -r -- $out
}

# Removes turns past VMQ_LEASE from their last activity (called under the lock). The judgement is per turn (key), by
# vmq_key_expiry. When the basis is holdMax (a holding process in one of the key's files is alive and VMQ_HOLD_MAX has not
# passed since the last control command or refresh), all the key's files are touched and kept. When the basis is lease and the
# elapsed seconds exceed VMQ_LEASE (every file of the key is past VMQ_LEASE), all the key's files are removed, and the log gets
# one line per target: `expired <target> <owner> (last activity N s ago[, …])` (bin/vmq ended reads this form).
# N is the seconds since the turn's last activity (the newest modification time of its files), the same on every line of a turn.
# Judging per file would leave some files of a multi-target turn behind, and Q_held would then name a target whose file is gone.
vmq_purge() {
  local vm f k why
  local -A kvms
  for vm in ${(ok)VMQ_HOST}; do
    vmq_tickets $vm
    for f in $reply; do kvms[${f:t}]+="${kvms[${f:t}]:+ }$vm"; done
  done
  for k in ${(ok)kvms}; do
    vmq_key_expiry $k ${=kvms[$k]}
    if [[ ${Q_exp[1]} == holdMax ]]; then
      for vm in ${=kvms[$k]}; do touch -- "$VMQ_DIR/$vm/$k"; done
      continue
    fi
    (( Q_exp[4] > VMQ_LEASE )) || continue
    why=; [[ -n ${Q_exp[3]} ]] && why=", process ${Q_exp[3]} is alive but the ${VMQ_HOLD_MAX} s limit since the last control command or refresh has passed"
    for vm in ${=kvms[$k]}; do rm -f -- "$VMQ_DIR/$vm/$k" && vmq_log "expired $vm $(vmq_key_owner $k) (last activity ${Q_exp[4]} s ago$why)"; done
  done
}

# When and on what basis one turn file expires: vmq_expiry <file> → Q_exp=(<basis> <seconds to expiry> <live processes>
# <seconds since the basis started>). The basis is holdMax (a holding process is alive and VMQ_HOLD_MAX has not passed since the
# last control command or refresh; seconds counted from active) or lease (otherwise; seconds counted from the last activity, the
# modification time). Live processes are reported even under lease (when the limit has passed).
# The per-turn judgement (vmq_key_expiry) calls this for each file.
vmq_expiry() {
  local f=$1 active alive idle
  active=$(vmq_field $f active)
  alive=$(vmq_procs_alive "$(vmq_field $f procs)") || alive=
  if [[ -n $alive ]] && (( EPOCHSECONDS - ${active:-0} <= VMQ_HOLD_MAX )); then
    Q_exp=(holdMax $(( VMQ_HOLD_MAX - EPOCHSECONDS + active )) "$alive" $(( EPOCHSECONDS - active )))
    return
  fi
  idle=$(vmq_idle $f)
  Q_exp=(lease $(( VMQ_LEASE - idle )) "$alive" $idle)
}

# When and on what basis one turn expires: vmq_key_expiry <key> <target>… → Q_exp (same form as vmq_expiry). The targets are
# those with a file of that key (Q_vms[key] after vmq_scan). When any file's basis is holdMax that file's judgement is used,
# otherwise the judgement of the file with the newest last activity: the turn is removed only when all its files are past
# VMQ_LEASE (vmq_purge), so the newest file decides the seconds left. 1 when there is no target.
# vmq_purge and vmq status (text and --json) share this one judgement, so every target line of a turn shows the same expiry.
vmq_key_expiry() {
  local k=$1 vm
  local -a best
  shift
  for vm in "$@"; do
    vmq_expiry "$VMQ_DIR/$vm/$k"
    [[ ${Q_exp[1]} == holdMax ]] && return 0
    if (( ! ${#best} )) || (( Q_exp[4] < best[4] )); then best=("${Q_exp[@]}"); fi
  done
  (( ${#best} )) || return 1
  Q_exp=("${best[@]}")
}

# Reads the queue (under the lock). A turn of the oldest format (no need line) is a request for one each of the targets with a
# file, and is held when it is first on all of them (the old rule). Reading writes it again in the current format.
vmq_scan() {
  Q_vms=() Q_file=() Q_need=() Q_held=()
  local vm f k head m
  for vm in ${(ok)VMQ_HOST}; do
    vmq_tickets $vm
    for f in $reply; do
      k=${f:t}
      Q_vms[$k]+="${Q_vms[$k]:+ }$vm"
      [[ -n ${Q_file[$k]:-} ]] || Q_file[$k]=$f
    done
  done
  for k in ${(k)Q_vms}; do
    Q_need[$k]=$(vmq_field ${Q_file[$k]} need)
    Q_held[$k]=$(vmq_field ${Q_file[$k]} held)
    [[ -n ${Q_need[$k]} ]] && continue
    Q_need[$k]=${Q_vms[$k]}
    head=1
    for vm in ${=Q_vms[$k]}; do vmq_tickets $vm; [[ ${reply[1]:t} == $k ]] || head=0; done
    (( head )) && Q_held[$k]=${Q_vms[$k]}
    # Rewriting is not activity, so the last activity time (modification time) is kept
    for vm in ${=Q_vms[$k]}; do
      f="$VMQ_DIR/$vm/$k"
      m=$(zstat +mtime -- $f)
      vmq_write $f "$(vmq_field $f owner)" "$(vmq_field $f label)" "$(vmq_field $f created)" "${Q_need[$k]}" "${Q_held[$k]}"
      touch -t $(strftime '%Y%m%d%H%M.%S' $m) -- $f
    done
  done
}

# Assigns turns to targets (under the lock, after vmq_scan). Result: Q_alloc[key] = the targets assigned, in group order;
# Q_busy[target] = the turn that holds it, is assigned it, or reserves it (`~<key>`)
vmq_plan() {
  Q_alloc=() Q_busy=()
  local k vm g c pick picks ok free
  for k in ${(k)Q_held}; do
    [[ -n ${Q_held[$k]} ]] || continue
    Q_alloc[$k]=${Q_held[$k]}
    for vm in ${=Q_held[$k]}; do Q_busy[$vm]=$k; done
  done
  for k in ${(ok)Q_vms}; do
    [[ -n ${Q_held[$k]} ]] && continue
    picks=() ok=1
    for g in ${=Q_need[$k]}; do
      pick=
      for c in ${(s:,:)g}; do
        # Every target of the candidate must be free. A candidate with a target that has no turn file (removed by expiry) is not picked
        vmq_members $c; free=1
        for vm in $reply; do
          vmq_has "${Q_vms[$k]}" $vm && [[ -z ${Q_busy[$vm]:-} ]] && (( ! ${picks[(Ie)$vm]} )) || { free=0; break }
        done
        (( free )) && { pick=$c; break }
      done
      [[ -n $pick ]] || { ok=0; break }
      picks+=(${(s:+:)pick})
    done
    if (( ok )); then
      Q_alloc[$k]=${(j: :)picks}
      for vm in $picks; do Q_busy[$vm]=$k; done
    elif (( EPOCHSECONDS - $(vmq_field ${Q_file[$k]} created) > VMQ_STARVE )); then
      for vm in ${=Q_vms[$k]}; do [[ -n ${Q_busy[$vm]:-} ]] || Q_busy[$vm]="~$k"; done
    fi
  done
}

# The owner's turn key, or an empty line (after vmq_scan).
vmq_key() { local k; for k in ${(k)Q_vms}; do [[ ${k#*-} == $1 ]] && { print -r -- $k; return }; done }

# Takes an assigned turn (under the lock): writes held into the turn files of the assigned targets and removes the files of the
# candidates not assigned.
vmq_commit() {
  local k=$1 vm f
  [[ -n $k && -z ${Q_held[$k]:-} && -n ${Q_alloc[$k]:-} ]] || return 1
  f=${Q_file[$k]}
  local o=$(vmq_field $f owner) l=$(vmq_field $f label) c=$(vmq_field $f created)
  for vm in ${=Q_vms[$k]}; do
    if vmq_has "${Q_alloc[$k]}" $vm; then
      vmq_write "$VMQ_DIR/$vm/$k" $o "$l" $c "${Q_need[$k]}" "${Q_alloc[$k]}"
    else
      rm -f -- "$VMQ_DIR/$vm/$k"
    fi
  done
  Q_held[$k]=${Q_alloc[$k]} Q_vms[$k]=${Q_alloc[$k]}
  Q_file[$k]="$VMQ_DIR/${Q_alloc[$k]%% *}/$k"
  vmq_log "held $o ${Q_alloc[$k]}${l:+ ($l)}"
}

# Settles the queue (under the lock): vmq_settle <owner>. Expiry, read, assignment, then taking the owner's turn when assigned.
# Leaves the owner's key (or an empty value) in REPLY. This function does not write a turn's time because it is the caller's
# turn (vmq_touch does). The vmq_purge inside writes the modification time of any owner's turn whose holding process is alive
# within VMQ_HOLD_MAX, and vmq_commit rewrites the file of an assigned turn it takes (its modification time changes too).
vmq_settle() {
  vmq_purge
  vmq_scan
  vmq_plan
  REPLY=$(vmq_key $1)
  [[ -n $REPLY ]] || return 0
  vmq_commit $REPLY
  return 0
}

# Writes the time (last activity) of the key's turn files as now (under the lock, after vmq_settle): vmq_touch <key>.
# Does nothing for an empty key.
vmq_touch() {
  local k=${1:-} vm
  [[ -n $k ]] || return 0
  for vm in ${=Q_vms[$k]}; do touch -- "$VMQ_DIR/$vm/$k"; done
}

# Is this a turn held by an ended chain (after vmq_scan): vmq_chain_ended <key>. 0 when the key exists, the turn is held, it
# has a chain line (vmq_chain_mark) and that chain process is not alive (vmq_procs_alive); otherwise 1. The chain's cleanup may
# still be stopping and restoring targets with that turn, so it is not handed even to the same owner's acquire or run (register
# in bin/vmq returns 4), and the same owner's reads do not write its time (vmq_sync).
vmq_chain_ended() {
  local k=${1:-} chain
  [[ -n $k && -n ${Q_held[$k]:-} ]] || return 1
  chain=$(vmq_field ${Q_file[$k]} chain)
  [[ -n $chain ]] || return 1
  ! vmq_procs_alive $chain >/dev/null
}

# Checks a pinned turn (under the lock, after vmq_settle): vmq_ticket_ok <owner> <current key>. 0 when VM_QUEUE_TICKET is empty
# or unset, or equals the current key. Otherwise (or with no current turn) the pinned and current keys go to stderr and the
# return is 1, and the caller does nothing to that turn.
# VM_QUEUE_TICKET is a turn key (<10-digit sequence>-<owner>, as vmq ticket prints). vmq_require and vmq release judge per
# owner, so after a turn is removed by expiry or force-release and the same owner takes a new one, they would apply to the new
# turn. The earlier turn's cleanup passes its key in VM_QUEUE_TICKET so it never applies to the new turn.
# vmq_require, vmq_keepalive, vmq_chain_of, vmq_chain_mark, vmq release and vmq mine read it. bin/vmq unsets it for other commands.
vmq_ticket_ok() {
  [[ -z ${VM_QUEUE_TICKET:-} || $VM_QUEUE_TICKET == ${2:-} ]] && return 0
  print -u2 -r -- "vmq: refused because the turn in VM_QUEUE_TICKET is not this owner's current turn (nothing was done). owner $1, pinned key $VM_QUEUE_TICKET, current key ${2:-none}"
  return 1
}

# Settles the queue and refreshes the owner's turn (under the lock): vmq_sync <owner>. After vmq_settle, checks the pinned turn
# with vmq_ticket_ok and, when it matches, writes the time of the owner's turn files with vmq_touch. Leaves the owner's key
# (or an empty value) in REPLY. 1 without writing when the check refuses, 0 otherwise.
# A turn held by an ended chain (vmq_chain_ended) does not get its time written. Only what actually acts with the turn writes
# it: vmq_attach in vmq_require, vmq_chain_mark and a successful vmq_keepalive rewrite the turn file. So the same owner reading
# again and again with vmq mine, vmq_chain_of, acquire or run does not keep that turn from expiring VMQ_LEASE after its last
# activity, and a different owner waiting behind it gets it.
vmq_sync() {
  vmq_settle $1
  vmq_ticket_ok $1 "$REPLY" || return 1
  vmq_chain_ended "$REPLY" || vmq_touch "$REPLY"
  return 0
}

# Does the owner hold all these targets (after vmq_settle or vmq_sync)
vmq_holds() {
  local owner=$1 k vm; shift
  k=$(vmq_key $owner)
  [[ -n $k && -n ${Q_held[$k]} ]] || return 1
  for vm in "$@"; do vmq_has "${Q_held[$k]}" $vm || return 1; done
}

# The key of the turn that holds the target, or an empty line (after vmq_scan).
vmq_holder() { local k; for k in ${(k)Q_held}; do vmq_has "${Q_held[$k]}" $1 && { print -r -- $k; return }; done }

# One line about the holder: vmq_holder_line <vm> (after vmq_scan)
vmq_holder_line() {
  local k=$(vmq_holder $1) n=0 x
  for x in ${(k)Q_vms}; do [[ -z ${Q_held[$x]} ]] && vmq_has "${Q_vms[$x]}" $1 && (( n++ )); done
  [[ -n $k ]] || { print "none, waiting $n"; return }
  local f="$VMQ_DIR/$1/$k" l
  # When the file of a target in held is gone (a turn left by an older per-file vmq_purge), read the turn's remaining file
  [[ -f $f ]] || f=${Q_file[$k]}
  l=$(vmq_field $f label)
  print "$(vmq_key_owner $k)${l:+ ($l)}, last activity $(vmq_idle $f) s ago, waiting $n"
}

# Writes the time of a control command and the process that called it into a held turn (under the lock, after vmq_sync):
# vmq_attach <key> <PID>. Ended processes are dropped from procs.
vmq_attach() {
  local k=$1 me vm f procs
  me=$(vmq_proc_id $2) || return 0
  f=${Q_file[$k]}
  procs=$(vmq_procs_alive "$(vmq_field $f procs)")
  vmq_has "$procs" $me || procs="${procs:+$procs }$me"
  for vm in ${=Q_vms[$k]}; do
    f="$VMQ_DIR/$vm/$k"
    vmq_write $f "$(vmq_field $f owner)" "$(vmq_field $f label)" "$(vmq_field $f created)" "$(vmq_field $f need)" "$(vmq_field $f held)" $EPOCHSECONDS "$procs" "$(vmq_field $f chain)"
  done
}

# Writes the chain that holds a held turn: vmq_chain_mark <PID of the chain shell> <target>… 0 when the owner holds the turn,
# otherwise 1 (also 1 when VM_QUEUE_TICKET differs from the current turn, vmq_ticket_ok).
# A chain is a shell that takes a turn once, drives targets and ends; its cleanup releases the turn afterwards. Without this
# mark, the same owner's next chain could acquire before that cleanup released, get the same turn back ("already registered"),
# and the earlier chain's cleanup would stop and restore the next chain's targets. The mark is written while the chain is alive,
# so it applies from the moment the chain shell ends.
vmq_chain_mark() {
  [[ ${VM_QUEUE_INTERNAL:-} == 1 ]] && return 0
  local pid=$1 owner vm f chain ok=0
  shift
  chain=$(vmq_proc_id $pid) || { print -u2 "vmq: no chain process $pid"; return 1 }
  owner=$(vmq_owner) || return 1
  vmq_lock || return 1
  {
    if vmq_sync $owner && vmq_holds $owner "$@"; then
      ok=1
      for vm in ${=Q_vms[$REPLY]}; do
        f="$VMQ_DIR/$vm/$REPLY"
        vmq_write $f "$(vmq_field $f owner)" "$(vmq_field $f label)" "$(vmq_field $f created)" "$(vmq_field $f need)" "$(vmq_field $f held)" $EPOCHSECONDS "$(vmq_field $f procs)" $chain
      done
      vmq_log "chain $owner ${Q_vms[$REPLY]} $chain"
    fi
  } always { vmq_unlock }
  (( ok ))
}
# The chain written in my held turn: vmq_chain_of <target>… → prints the `<PID>@<start time>` written (an empty line when none).
# 1 when there is no turn (also when VM_QUEUE_TICKET differs from the current turn, vmq_ticket_ok). It is a read, so the time of
# a turn held by an ended chain is not written (vmq_sync).
vmq_chain_of() {
  local owner ok=0 out=
  owner=$(vmq_owner) || return 1
  vmq_lock || return 1
  {
    vmq_sync $owner && vmq_holds $owner "$@" && { ok=1; out=$(vmq_field ${Q_file[$REPLY]} chain) }
  } always { vmq_unlock }
  (( ok )) && print -r -- $out
}

# Called by a process that holds a turn while it waits long without control commands: vmq_keepalive. Only when this shell ($$)
# is written alive in procs of the turn this owner holds, active (last activity) is written as now and the return is 0;
# otherwise nothing changes. procs and chain are kept. The only write to the turn files is vmq_write on success. The vmq_settle
# before it runs even when refusing, and two functions in it change turn files: vmq_purge writes the time of every file of a
# turn judged holdMax, and vmq_commit takes an assigned waiting turn (held line, log "held"). So a refusal changes nothing by
# this function, but that turn's content or modification time changes in those two cases.
# A different owner (another session), or a process of the same owner not written in the turn by vmq_require, cannot extend
# someone else's turn.
# Call it every VMQ_KEEPALIVE seconds (1/6 of VM_QUEUE_HOLD_MAX, default 600), so five refreshes in a row must fail (the queue
# lock not obtained, say) before the limit is reached. When the calling process ends, the refreshes stop and the expiry rules
# above apply as they are.
# Exit codes: 0 refreshed. 1 this process holds no turn (expired, force-released, not taken, $$ not in procs, VM_QUEUE_TICKET
# differs, no owner); the reason goes to stderr. 75 the queue lock was not obtained, a passing failure: the turn is unchanged and
# the next call refreshes again (75 is the same value as acquire's "waiting").
VMQ_KEEPALIVE=$(( VMQ_HOLD_MAX / 6 ))
vmq_keepalive() {
  [[ ${VM_QUEUE_INTERNAL:-} == 1 ]] && return 0
  local owner me vm f why=
  me=$(vmq_proc_id $$) || { print -u2 -r -- "vmq: could not read the start time of this shell (pid $$), so the activity was not refreshed"; return 1 }
  owner=$(vmq_owner) || return 1
  vmq_lock || return 75
  {
    vmq_settle $owner
    if ! vmq_ticket_ok $owner "$REPLY"; then
      why=ticket
    elif [[ -z $REPLY ]]; then
      why="owner $owner has no turn (it expired, was force-released or was never taken)"
    elif [[ -z ${Q_held[$REPLY]:-} ]]; then
      why="turn ${REPLY%%-*} of owner $owner is still waiting and holds no target"
    elif ! vmq_has "$(vmq_procs_alive "$(vmq_field ${Q_file[$REPLY]} procs)")" $me; then
      why="this shell (pid $$) is not in procs of turn ${REPLY%%-*} (vmq_require was not called from this shell)"
    else
      for vm in ${=Q_vms[$REPLY]}; do
        f="$VMQ_DIR/$vm/$REPLY"
        vmq_write $f "$(vmq_field $f owner)" "$(vmq_field $f label)" "$(vmq_field $f created)" "$(vmq_field $f need)" "$(vmq_field $f held)" $EPOCHSECONDS "$(vmq_field $f procs)" "$(vmq_field $f chain)"
      done
    fi
  } always { vmq_unlock }
  [[ -z $why ]] && return 0
  # For ticket, vmq_ticket_ok already wrote the reason to stderr
  [[ $why == ticket ]] || print -u2 -r -- "vmq: activity not refreshed. $why"
  return 1
}

# Refreshes, and ends the script when the turn is lost: vmq_keepalive_or_exit. When vmq_keepalive returns 1 it writes to stderr
# and exits 1; for 75 (a passing lock failure) it writes a warning and returns 0. This keeps a script from driving targets after
# losing its turn. A script that does not pass vmq_require on every control command (one that calls it once at the start, like
# a GUI script) calls this between long steps, more often than every VMQ_KEEPALIVE seconds. A script that passes vmq_require on
# every control command does not need it: its next command is refused.
# Call it from the script's top-level shell. Inside $(...), a pipe or ( ), exit ends only that subshell and the script goes on.
# In zsh $$ is the outer shell's PID in a subshell too, so the refresh itself still works.
vmq_keepalive_or_exit() {
  local code=0
  vmq_keepalive || code=$?
  (( code == 0 )) && return 0
  (( code == 75 )) && { print -u2 -r -- "vmq: lock not obtained, this refresh is skipped. The turn is unchanged and the next call refreshes again"; return 0 }
  print -u2 -r -- "vmq: the turn was lost, so the script stops driving targets and exits with code 1 (pid $$)"
  exit 1
}

# A project's tool calls this before each control command: vmq_require <target>… When the owner holds the turn, the time and
# this shell process ($$) are written and the return is 0; otherwise the reason goes to stderr and the return is 1. While the
# written process lives the turn does not expire (see expiry above, limit VM_QUEUE_HOLD_MAX).
# When VM_QUEUE_TICKET differs from the current turn nothing is written and the return is 1 (vmq_ticket_ok). When it matches,
# vmq_attach writes even into a turn held by an ended chain, because the control commands of the cleanup that stops and
# restores targets with that turn must pass here.
# The calling tool's version is checked before the turn (vmq_tool_current above).
vmq_require() {
  [[ ${VM_QUEUE_INTERNAL:-} == 1 ]] && return 0
  local owner vm ok=0
  vmq_tool_current || return 1
  owner=$(vmq_owner) || return 1
  vmq_lock || return 1
  {
    if ! vmq_sync $owner; then
      : # VM_QUEUE_TICKET refused. vmq_ticket_ok wrote the reason to stderr
    elif vmq_holds $owner "$@"; then
      ok=1
      vmq_attach $REPLY $$
    else
      for vm in "$@"; do
        vmq_holds $owner $vm && continue
        print -u2 "vmq: no turn for $vm (owner $owner). Holder now: $(vmq_holder_line $vm)"
      done
      print -u2 "  take a turn first: $VMQ_ROOT/bin/vmq acquire [-l label] $* (state: vmq status)"
    fi
  } always { vmq_unlock }
  (( ok ))
}
