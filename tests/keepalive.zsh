#!/bin/zsh
# 만료 시험: tests/keepalive.zsh <vmq 경로> <시험용 차례표 폴더>. 실제 차례표를 쓰지 않게 차례표 폴더를 따로 준다. VM_QUEUE_LEASE 를 5초로
# 줄여, 차례를 쥔 프로세스가 살아 있으면 만료되지 않고 · 끝나면 만료되고 · 상한(VM_QUEUE_HOLD_MAX)이 지나면 살아 있어도 만료되는지 본다.
zmodload zsh/datetime
V=${1:A}; export VM_QUEUE_DIR=$2 VM_QUEUE_LEASE=5 VM_QUEUE_HOLD_MAX=3600; rm -rf $2
LIB=${V:h:h}/lib/vmq.zsh
X=$($V list | head -1 | cut -f1)
pass=0 fail=0
check() { if [[ $3 == $2 ]]; then print "맞음: $1"; (( pass++ )); else print "틀림: $1 (기대 $2, 실제 $3)"; (( fail++ )); fi }
# 그 소유자가 acquire 한다: got_after <소유자> <기다릴 초> → REPLY 에 종료 코드, took 에 걸린 초
got_after() { local t=$EPOCHSECONDS; VM_QUEUE_OWNER=$1 $V acquire -w $2 $X >/dev/null 2>&1; REPLY=$?; took=$(( EPOCHSECONDS - t )) }
# 소유자 A 가 받고, vmq_require 를 부른 프로세스를 그 초만큼 살려 둔다: hold_proc <초> → 그 프로세스의 PID
hold_proc() { VM_QUEUE_OWNER=A zsh -c "source ${(q)LIB}; vmq_require $X || exit 1; sleep $1" >/dev/null 2>&1 & sleep 1; print $! }
# 그 PID 의 프로세스가 끝날 때까지 기다린다(이 셸의 자식이 아니라 wait 를 쓰지 못한다)
wait_gone() { while kill -0 $1 2>/dev/null; do sleep 0.2; done }

print "대상 $X, 차례표 $VM_QUEUE_DIR"

# 1. 쥔 프로세스가 없으면 지금처럼 마지막 활동에서 VM_QUEUE_LEASE 뒤 만료된다
VM_QUEUE_OWNER=A $V acquire -w 5 $X >/dev/null
got_after B 14; check "1. 쥔 프로세스가 없으면 만료되어 B 가 받는다" 0 $REPLY; print "   걸린 시간 ${took}초"
VM_QUEUE_OWNER=B $V release >/dev/null

# 2 · 3. vmq_require 를 부른 프로세스가 살아 있는 동안은 만료되지 않고, 끝나면 만료된다
VM_QUEUE_OWNER=A $V acquire -w 5 $X >/dev/null
p=$(hold_proc 14)
got_after B 9; check "2. 쥔 프로세스(PID $p)가 살아 있는 동안 B 는 9초 기다려도 받지 못한다(LEASE 5초)" 75 $REPLY
wait_gone $p
got_after B 14; check "3. 그 프로세스가 끝나면 만료되어 B 가 받는다" 0 $REPLY; print "   끝난 뒤 걸린 시간 ${took}초"
VM_QUEUE_OWNER=B $V release >/dev/null

# 4. 마지막 제어 명령에서 상한이 지나면 프로세스가 살아 있어도 만료된다
export VM_QUEUE_HOLD_MAX=4
VM_QUEUE_OWNER=A $V acquire -w 5 $X >/dev/null
p=$(hold_proc 40)
got_after B 25; check "4. 상한 4초가 지나면 살아 있는 프로세스(PID $p)의 차례도 만료되어 B 가 받는다" 0 $REPLY; print "   걸린 시간 ${took}초"
kill -0 $p 2>/dev/null; check "4. 그때 그 프로세스는 살아 있었다" 0 $?
grep -q "만료 $X A (.*상한 4초" "$VM_QUEUE_DIR/log"; check "4. log 의 만료 줄에 상한이 적힌다" 0 $?
kill $p 2>/dev/null; wait_gone $p
VM_QUEUE_OWNER=B $V release >/dev/null
export VM_QUEUE_HOLD_MAX=3600

# 5. PID 가 같아도 시작 시각이 다르면(끝난 프로세스의 PID 를 다른 프로세스가 받은 것) 살아 있는 것으로 보지 않는다
VM_QUEUE_OWNER=A $V acquire -w 5 $X >/dev/null
f=("$VM_QUEUE_DIR/$X"/<->-A(N))
print -l "active=$EPOCHSECONDS" "procs=$$@Thu_Jan__1_00:00:00_1970" >> $f[1]
got_after B 14; check "5. 시작 시각이 다른 PID($$)는 차례를 붙들지 않는다" 0 $REPLY; print "   걸린 시간 ${took}초"
VM_QUEUE_OWNER=B $V release >/dev/null

# 6. run 은 명령이 도는 동안 차례를 쥔다(명령이 vmq_require 를 부르지 않아도)
VM_QUEUE_OWNER=A $V run $X -- sleep 13 & r=$!
sleep 1
got_after B 9; check "6. run 의 명령이 도는 동안 B 는 9초 기다려도 받지 못한다" 75 $REPLY
wait $r
got_after B 5; check "6. run 이 끝나면 놓아 B 가 받는다" 0 $REPLY; print "   끝난 뒤 걸린 시간 ${took}초"
VM_QUEUE_OWNER=B $V release >/dev/null

# 7. 쥔 프로세스를 적은 쪽과 읽는 쪽의 로캘 · 시간대가 달라도 살아 있는 것으로 본다(bug_1792168576710_qdniti).
#    A 는 TZ=Asia/Seoul · LC_ALL=ko_KR.UTF-8 로 적고, B 는 TZ=America/Los_Angeles · LC_ALL=C 로 기다린다
VM_QUEUE_OWNER=A $V acquire -w 5 $X >/dev/null
TZ=Asia/Seoul LC_ALL=ko_KR.UTF-8 VM_QUEUE_OWNER=A zsh -c "source ${(q)LIB}; vmq_require $X || exit 1; sleep 14" >/dev/null 2>&1 & sleep 1; p=$!
t=$EPOCHSECONDS; TZ=America/Los_Angeles LC_ALL=C VM_QUEUE_OWNER=B $V acquire -w 9 $X >/dev/null 2>&1; rc=$?
check "7. 다른 TZ · 로캘로 적은 쥔 프로세스(PID $p)가 살아 있는 동안 B 는 9초 기다려도 받지 못한다" 75 $rc; print "   걸린 시간 $(( EPOCHSECONDS - t ))초"
wait_gone $p
TZ=America/Los_Angeles LC_ALL=C VM_QUEUE_OWNER=B $V acquire -w 14 $X >/dev/null 2>&1; check "7. 그 프로세스가 끝나면 만료되어 B 가 받는다" 0 $?
VM_QUEUE_OWNER=B $V release >/dev/null

print "맞음 $pass · 틀림 $fail"
(( fail == 0 ))
