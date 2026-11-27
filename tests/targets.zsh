#!/bin/zsh
# Target list test: tests/targets.zsh <vmq path> <test folder>. The data folder is made in the test folder (VMQ_DATA).
#   1 vmq paths: the data folder and target list follow VMQ_DATA; without VMQ_DATA, the host's default (lib/paths.zsh)
#   2 vmq target add before vmq init creates the list; vmq init leaves an existing list as it is
#   3 refusals: a name that exists, a bad name, address, roles or operating system, too few values
#   4 vmq target remove refuses a target a turn holds, removes it once released, and refuses a name not in the list
set -u
V=${1:?vmq path}; D=${2:?test folder}
rm -rf $D; mkdir -p $D
export VMQ_DATA=$D/data
unset VMQ_REGISTRY VM_QUEUE_DIR VMQ_HOSTS_FILE
ok=0 bad=0
check() { if eval "$2"; then print "right: $1"; (( ++ok )); else print "wrong: $1"; (( ++bad )); fi }
rc() { "$@" >/dev/null 2>&1; print $? }

check "1. paths follow VMQ_DATA" '[[ $($V paths --json | jq -r .registry) == $VMQ_DATA/resources.tsv ]]'
if [[ $OSTYPE == darwin* ]]; then expected=$HOME/Library/Application\ Support/vmq; else expected=$D/xdg/vmq; fi
check "1. without VMQ_DATA the default is $expected" '[[ $(env -u VMQ_DATA XDG_DATA_HOME=$D/xdg $V paths --json | jq -r .data) == $expected ]]'

check "2. add before init creates the list" '(( $(rc $V target add TestServer mac-a.local server,myproject macOS) == 0 )) && [[ -r $VMQ_DATA/resources.tsv ]]'
check "2. init keeps an existing list" '$V init | grep -q "1 targets"'
check "2. add a build slot" '(( $(rc $V target add Build1 localhost build -) == 0 ))'
check "2. list holds both" '[[ $($V list | cut -f1 | tr "\n" " ") == "Build1 TestServer " ]]'

check "3. a name that exists is refused" '(( $(rc $V target add TestServer x - macOS) == 1 ))'
check "3. a name with a space is refused" '(( $(rc $V target add "bad name" x - macOS) == 1 ))'
check "3. an address with ; is refused" '(( $(rc $V target add X "a;b" - macOS) == 1 ))'
check "3. roles with a space are refused" '(( $(rc $V target add X h "a b" macOS) == 1 ))'
check "3. an unknown operating system is refused" '(( $(rc $V target add X h - Solaris) == 1 ))'
check "3. too few values is a usage error" '(( $(rc $V target add X h) == 2 ))'
check "3. the list did not change" '(( $(grep -vc "^#" $VMQ_DATA/resources.tsv) == 2 ))'

VM_QUEUE_OWNER=A $V acquire -w 5 Build1 >/dev/null 2>&1
check "4. removing a held target is refused" '(( $(rc $V target remove Build1) == 1 ))'
VM_QUEUE_OWNER=A $V release >/dev/null 2>&1
check "4. removed once released" '(( $(rc $V target remove Build1) == 0 )) && ! $V list | grep -q Build1'
check "4. a name not in the list is refused" '(( $(rc $V target remove Nope) == 1 ))'
check "4. the queue log has the changes" '(( $(grep -c " target-" $VMQ_DATA/queue/log) == 3 ))'

print "right $ok, wrong $bad"
rm -rf $D
(( bad == 0 ))
