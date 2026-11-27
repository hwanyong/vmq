#!/bin/zsh
# Signal test: tests/run-signal.zsh <vmq path> <test folder>. The queue and the target list are made in the test folder, with two
# fake targets S1 and S2 (role build). Sees what happens to the turn `vmq run` made when it ends by a signal.
#   1 TERM to the process group (as a tool stop does): released at once
#   2 TERM to vmq run alone (as pkill -f does): held while the command runs, released when it ends
#   3 KILL to the group: cannot be caught, the turn stays (it expires by LEASE)
#   4 TERM to the group while waiting: the waiting request is removed
set -u
zmodload zsh/datetime
V=${1:?vmq path}; D=${2:?test folder}
rm -rf $D; mkdir -p $D
print -l "S1	127.0.0.1	build" "S2	127.0.0.1	build" > $D/resources.tsv
export VMQ_REGISTRY=$D/resources.tsv
ok=0 bad=0
check() { if eval "$2"; then print "right: $1"; (( ++ok )); else print "wrong: $1"; (( ++bad )); fi }
held() { $V status 2>/dev/null | grep -c 'held by F' }
waiting() { $V status 2>/dev/null | grep -c 'waiting [0-9]*: F' }
start() { perl -e 'setpgrp(0,0); exec @ARGV' env VM_QUEUE_OWNER=F VM_QUEUE_DIR=$VM_QUEUE_DIR $V run @build -- "$@" >/dev/null 2>&1 & print $! }
waitheld() { local i; for i in {1..20}; do (( $(held) )) && return 0; sleep 0.5; done; return 1 }

export VM_QUEUE_DIR=$D/q1
p=$(start sleep 60); waitheld; kill -TERM -$p; sleep 2
check "1. 2 s after TERM to the group, F has no turn" '(( $(held) == 0 ))'
pkill -g $p 2>/dev/null

export VM_QUEUE_DIR=$D/q2
p=$(start sleep 5); waitheld; t=$EPOCHREALTIME; kill -TERM $p; sleep 1
check "2. 1 s after TERM to run alone, the command still runs and the turn is held" '(( $(held) == 1 ))'
for i in {1..24}; do (( $(held) )) || break; sleep 0.5; done
e=$(( EPOCHREALTIME - t ))
check "2. released after the command ends (over 4 s and within 12 s after TERM: $(printf %.1f $e) s)" '(( $(held) == 0 && e > 4 && e < 12 ))'
pkill -g $p 2>/dev/null

export VM_QUEUE_DIR=$D/q3
p=$(start sleep 60); waitheld; kill -KILL -$p; sleep 2
check "3. after KILL to the group the turn stays (it expires by LEASE)" '(( $(held) == 1 ))'

export VM_QUEUE_DIR=$D/q4
VM_QUEUE_OWNER=X $V acquire -w 5 S1 S2 >/dev/null
p=$(start true); sleep 3
check "4. F waits while X holds" '(( $(waiting) >= 1 ))'
kill -TERM -$p; sleep 2
VM_QUEUE_OWNER=X $V release >/dev/null; sleep 1
check "4. F's request, ended by TERM while waiting, is removed (not assigned, not waiting)" '(( $(held) == 0 && $(waiting) == 0 )) && ! $V status 2>/dev/null | grep -q "assigned to F"'
pkill -g $p 2>/dev/null

print "right $ok, wrong $bad"
rm -rf $D
(( bad == 0 ))
