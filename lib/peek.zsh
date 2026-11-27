# Reads without a turn (README.md). A project's tool sources this file and checks a command with peek_allowed before running it on
# a target. To check only: `vmq peek-check '<one command line>'`.
# Commands that do not change a target's state may run without a turn, but whether a command is such a read is decided by the lists
# below, not by the caller's judgement: the rule does not rest on the caller knowing it. A command not on the lists is refused, and
# the caller takes a turn to run it.
#
# One command line is stages joined with `|`. Each stage's first word must be in PEEK_COMMANDS and follow that command's argument
# rules (peek_args). The first word is a name or an absolute path in a system folder (PEEK_SYSTEM_DIRS). Other absolute paths are
# refused even when the name is on the list.
# `log` is accepted only as `/usr/bin/log`, not by name (PEEK_SHELL_BUILTINS): the target's shell is zsh, and the name runs zsh's
# builtin log (login watch), which ends with `zsh:log:1: too many arguments`.
# `;`, `&`, `>`, `<`, backquotes, `$(` and newlines are refused (syntax that chains commands, writes files or inserts other
# commands). sudo is not on the list. Screen captures and cua-driver are reads too, but they show a screen another owner may be
# driving, so they run inside a turn.

typeset -ga PEEK_COMMANDS=(
  cat head tail ls stat readlink realpath file wc grep egrep fgrep cut sort uniq tr awk
  pgrep ps lsof netstat df du sw_vers scutil uname id whoami date uptime hostname
  defaults launchctl log sqlite3 plutil mdls xattr shasum md5 find sysctl codesign pluginkit system_profiler ioreg sw_vers
)

# Folders accepted when the first word is an absolute path: where the listed commands live on macOS.
typeset -ga PEEK_SYSTEM_DIRS=(/usr/bin /bin /usr/sbin /sbin)

# Names that run a zsh builtin of the same name on the target. Accepted only as an absolute path in a system folder.
typeset -ga PEEK_SHELL_BUILTINS=(log)

# Argument rules: peek_args <command> <arguments…>. On a violation the reason goes to stderr and the return is 1.
peek_args() {
  local c=$1 a; shift
  case $c in
  defaults) [[ ${1:-} == (read|read-type|domains|find) ]] || { print -u2 "defaults: only read, read-type, domains, find"; return 1 } ;;
  launchctl) [[ ${1:-} == (print|list|print-disabled|blame|managername|manageruid) ]] || { print -u2 "launchctl: only print, list, print-disabled, blame, managername, manageruid"; return 1 } ;;
  log) [[ ${1:-} == show ]] || { print -u2 "log: only show"; return 1 } ;;
  scutil) [[ ${1:-} == --get ]] || { print -u2 "scutil: only --get"; return 1 } ;;
  plutil) [[ ${1:-} == (-p|-lint) ]] || { print -u2 "plutil: only -p, -lint"; return 1 } ;;
  pluginkit) [[ ${1:-} == -m* ]] || { print -u2 "pluginkit: only -m"; return 1 } ;;
  awk) for a in "$@"; do [[ $a == *(system|getline|'print >'|'printf >'|'| '|fflush)* ]] && { print -u2 "awk: system, getline and output redirection are refused"; return 1 }; done ;;
  sqlite3)
    (( ${@[(Ie)-readonly]} )) || { print -u2 "sqlite3: -readonly is required"; return 1 }
    for a in "$@"; do [[ ${a:l} == *(.shell|.system|.output|.once|.import|.save|.backup|.restore|.load|.open|.cd|load_extension|attach|vacuum|pragma)* ]] && { print -u2 "sqlite3: that command is refused: $a"; return 1 }; done ;;
  find) for a in "$@"; do [[ $a == (-delete|-exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls) ]] && { print -u2 "find: $a is refused"; return 1 }; done ;;
  xattr) for a in "$@"; do [[ $a == -*[wdcs]* ]] && { print -u2 "xattr: only reads (-l, -p, -x)"; return 1 }; done ;;
  sysctl) for a in "$@"; do [[ $a == -w || $a == *=* ]] && { print -u2 "sysctl: only reads"; return 1 }; done ;;
  codesign) for a in "$@"; do [[ $a == (-s|--sign|-f|--force|--remove-signature) ]] && { print -u2 "codesign: only -d, -v"; return 1 }; done ;;
  sort) for a in "$@"; do [[ $a == (-o*|--output*) ]] && { print -u2 "sort: -o is refused"; return 1 }; done ;;
  esac
  return 0
}

# Is one command line a read that may run without a turn: peek_allowed <one command line>
peek_allowed() {
  local line=$1 seg w name
  [[ -n ${line//[[:space:]]/} ]] || { print -u2 "no command"; return 1 }
  if [[ $line == *[\;\&\<\>\`$'\n']* || $line == *'$('* ]]; then
    print -u2 "syntax that chains commands or writes files (; & > < backquote \$( newline) is refused"; return 1
  fi
  for seg in "${(@s:|:)line}"; do
    w=(${(Q)${(z)seg}})
    (( ${#w} )) || { print -u2 "an empty stage (|| and the like)"; return 1 }
    name=${w[1]}
    if [[ $name == /* ]]; then
      (( ${PEEK_SYSTEM_DIRS[(Ie)${name:h}]} )) || { print -u2 "an absolute path is accepted only for commands in ${PEEK_SYSTEM_DIRS}: $name"; return 1 }
      name=${name:t}
    elif (( ${PEEK_SHELL_BUILTINS[(Ie)$name]} )); then
      print -u2 "this name runs a zsh builtin on the target: $name. Write the absolute path (for example /usr/bin/$name)"; return 1
    fi
    (( ${PEEK_COMMANDS[(Ie)$name]} )) || { print -u2 "a command that cannot run without a turn: ${w[1]} (read list: ${PEEK_COMMANDS})"; return 1 }
    peek_args $name "${(@)w[2,-1]}" || return 1
  done
}
