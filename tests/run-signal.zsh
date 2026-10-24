#!/bin/zsh
# 신호 시험: tests/run-signal.zsh <vmq 경로> <시험용 차례표 폴더>. 실제 차례표 · 대상 목록을 쓰지 않게 폴더를 따로 주고, 그 안에 가짜 대상
# S1 · S2(역할 smbbuild)를 만든다. `vmq run` 이 신호로 끝날 때 그 명령이 만든 차례가 어떻게 되는지 본다(poieve bug_1792813277239_fyx5wg).
#   1 그룹에 TERM(Claude Code 의 TaskStop 과 같다): 바로 놓는다
#   2 vmq run 에만 TERM(pkill -f 와 같다): 명령이 도는 동안은 쥐고, 명령이 끝나면 놓는다
#   3 그룹에 KILL: 받을 수 없어 차례가 남는다(LEASE 로 만료)
#   4 기다리는 중 그룹에 TERM: 기다리던 요청을 지운다
set -u
zmodload zsh/datetime
V=${1:?vmq 경로}; D=${2:?시험용 차례표 폴더}
rm -rf $D; mkdir -p $D
print -l "S1	127.0.0.1	smbbuild" "S2	127.0.0.1	smbbuild" > $D/resources.tsv
export VMQ_REGISTRY=$D/resources.tsv
ok=0 bad=0
check() { if eval "$2"; then print "맞음: $1"; (( ++ok )); else print "틀림: $1"; (( ++bad )); fi }
held() { $V status 2>/dev/null | grep -c '잡음 F' }
waiting() { $V status 2>/dev/null | grep -c '대기 [0-9]*: F' }
start() { perl -e 'setpgrp(0,0); exec @ARGV' env VM_QUEUE_OWNER=F VM_QUEUE_DIR=$VM_QUEUE_DIR $V run @smbbuild -- "$@" >/dev/null 2>&1 & print $! }
waitheld() { local i; for i in {1..20}; do (( $(held) )) && return 0; sleep 0.5; done; return 1 }

export VM_QUEUE_DIR=$D/q1
p=$(start sleep 60); waitheld; kill -TERM -$p; sleep 2
check "1. 그룹 TERM 2초 뒤 F 의 차례가 없다" '(( $(held) == 0 ))'
pkill -g $p 2>/dev/null

export VM_QUEUE_DIR=$D/q2
p=$(start sleep 5); waitheld; t=$EPOCHREALTIME; kill -TERM $p; sleep 1
check "2. run 에만 TERM 1초 뒤에는 명령이 돌아 차례를 쥐고 있다" '(( $(held) == 1 ))'
for i in {1..24}; do (( $(held) )) || break; sleep 0.5; done
e=$(( EPOCHREALTIME - t ))
check "2. 명령이 끝난 뒤(TERM 뒤 4초 넘어, 12초 안) 놓는다($(printf %.1f $e)초)" '(( $(held) == 0 && e > 4 && e < 12 ))'
pkill -g $p 2>/dev/null

export VM_QUEUE_DIR=$D/q3
p=$(start sleep 60); waitheld; kill -KILL -$p; sleep 2
check "3. 그룹 KILL 뒤에는 차례가 남는다(LEASE 로 만료)" '(( $(held) == 1 ))'

export VM_QUEUE_DIR=$D/q4
VM_QUEUE_OWNER=X $V acquire -w 5 S1 S2 >/dev/null
p=$(start true); sleep 3
check "4. X 가 잡은 동안 F 는 기다린다" '(( $(waiting) >= 1 ))'
kill -TERM -$p; sleep 2
VM_QUEUE_OWNER=X $V release >/dev/null; sleep 1
check "4. 기다리던 중 TERM 으로 끝난 F 의 요청이 지워졌다(배정 · 대기 없음)" '(( $(held) == 0 && $(waiting) == 0 )) && ! $V status 2>/dev/null | grep -q "F 에게 배정"'
pkill -g $p 2>/dev/null

print "맞음 $ok · 틀림 $bad"
rm -rf $D
(( bad == 0 ))
