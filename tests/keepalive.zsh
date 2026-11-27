#!/bin/zsh
# Expiry test: tests/keepalive.zsh <vmq path> <test folder>. The queue and the target list are made in the test folder, so the real
# ones are not used. VM_QUEUE_LEASE is cut to 5 seconds to see that a turn does not expire while its holding process lives, expires
# once it ends, and expires past the limit (VM_QUEUE_HOLD_MAX) even while it lives.
zmodload zsh/datetime
V=${1:A}; T=$2; rm -rf $T; mkdir -p $T
export VM_QUEUE_DIR=$T/q VMQ_REGISTRY=$T/resources.tsv VM_QUEUE_LEASE=5 VM_QUEUE_HOLD_MAX=3600
print -l "T1	hostA	test" > $VMQ_REGISTRY
LIB=${V:h:h}/lib/vmq.zsh
X=T1
pass=0 fail=0
check() { if [[ $3 == $2 ]]; then print "right: $1"; (( pass++ )); else print "wrong: $1 (expected $2, got $3)"; (( fail++ )); fi }
# The owner acquires: got_after <owner> <seconds to wait> → exit code in REPLY, seconds taken in took
got_after() { local t=$EPOCHSECONDS; VM_QUEUE_OWNER=$1 $V acquire -w $2 $X >/dev/null 2>&1; REPLY=$?; took=$(( EPOCHSECONDS - t )) }
# Owner A keeps a process that called vmq_require alive for that many seconds: hold_proc <seconds> → that process's PID
hold_proc() { VM_QUEUE_OWNER=A zsh -c "source ${(q)LIB}; vmq_require $X || exit 1; sleep $1" >/dev/null 2>&1 & sleep 1; print $! }
# Waits until the process with that PID ends (it is not this shell's child, so wait cannot be used)
wait_gone() { while kill -0 $1 2>/dev/null; do sleep 0.2; done }

print "target $X, queue $VM_QUEUE_DIR"

# 1. With no holding process, the turn expires VM_QUEUE_LEASE after its last activity
VM_QUEUE_OWNER=A $V acquire -w 5 $X >/dev/null
got_after B 14; check "1. with no holding process the turn expires and B gets it" 0 $REPLY; print "   took ${took} s"
VM_QUEUE_OWNER=B $V release >/dev/null

# 2, 3. While the process that called vmq_require lives the turn does not expire; once it ends it does
VM_QUEUE_OWNER=A $V acquire -w 5 $X >/dev/null
p=$(hold_proc 14)
got_after B 9; check "2. while the holding process (PID $p) lives, B does not get it in 9 s (LEASE 5 s)" 75 $REPLY
wait_gone $p
got_after B 14; check "3. once that process ends the turn expires and B gets it" 0 $REPLY; print "   took ${took} s after it ended"
VM_QUEUE_OWNER=B $V release >/dev/null

# 4. Past the limit from the last control command, the turn expires even while the process lives
export VM_QUEUE_HOLD_MAX=4
VM_QUEUE_OWNER=A $V acquire -w 5 $X >/dev/null
p=$(hold_proc 40)
got_after B 25; check "4. past the 4 s limit the turn of a live process (PID $p) expires too and B gets it" 0 $REPLY; print "   took ${took} s"
kill -0 $p 2>/dev/null; check "4. that process was alive then" 0 $?
grep -q "expired $X A (.*the 4 s limit" "$VM_QUEUE_DIR/log"; check "4. the expired line in the log names the limit" 0 $?
kill $p 2>/dev/null; wait_gone $p
VM_QUEUE_OWNER=B $V release >/dev/null
export VM_QUEUE_HOLD_MAX=3600

# 5. The same PID with a different start time (an ended process's PID reused) is not taken as alive
VM_QUEUE_OWNER=A $V acquire -w 5 $X >/dev/null
f=("$VM_QUEUE_DIR/$X"/<->-A(N))
print -l "active=$EPOCHSECONDS" "procs=$$@Thu_Jan__1_00:00:00_1970" >> $f[1]
got_after B 14; check "5. a PID ($$) with a different start time does not hold the turn" 0 $REPLY; print "   took ${took} s"
VM_QUEUE_OWNER=B $V release >/dev/null

# 6. run holds the turn while its command runs (even when the command never calls vmq_require)
VM_QUEUE_OWNER=A $V run $X -- sleep 13 & r=$!
sleep 1
got_after B 9; check "6. while run's command runs, B does not get it in 9 s" 75 $REPLY
wait $r
got_after B 5; check "6. when run ends it releases and B gets it" 0 $REPLY; print "   took ${took} s after it ended"
VM_QUEUE_OWNER=B $V release >/dev/null

# 7. A holding process is taken as alive even when the writer and the reader differ in locale and time zone.
#    A writes with TZ=Asia/Seoul and LC_ALL=ko_KR.UTF-8, B waits with TZ=America/Los_Angeles and LC_ALL=C
VM_QUEUE_OWNER=A $V acquire -w 5 $X >/dev/null
TZ=Asia/Seoul LC_ALL=ko_KR.UTF-8 VM_QUEUE_OWNER=A zsh -c "source ${(q)LIB}; vmq_require $X || exit 1; sleep 14" >/dev/null 2>&1 & sleep 1; p=$!
t=$EPOCHSECONDS; TZ=America/Los_Angeles LC_ALL=C VM_QUEUE_OWNER=B $V acquire -w 9 $X >/dev/null 2>&1; rc=$?
check "7. while a holding process (PID $p) written in another TZ and locale lives, B does not get it in 9 s" 75 $rc; print "   took $(( EPOCHSECONDS - t )) s"
wait_gone $p
TZ=America/Los_Angeles LC_ALL=C VM_QUEUE_OWNER=B $V acquire -w 14 $X >/dev/null 2>&1; check "7. once that process ends the turn expires and B gets it" 0 $?
VM_QUEUE_OWNER=B $V release >/dev/null

print "right $pass, wrong $fail"
(( fail == 0 ))
