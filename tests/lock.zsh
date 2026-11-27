#!/bin/zsh
# Lock test: tests/lock.zsh <vmq path> <test folder>. The queue and the target list are made in the test folder.
#   1 mutual exclusion: 8 processes each add 1 to a counter file 25 times under vmq_lock (read, wait, write). A total under 200
#     means two processes held the lock at once
#   2 release on exit: after a holder ends without vmq_unlock (exit, then KILL), the next process gets the lock
#   3 waiting: while another process holds the lock, vmq_lock gives up after VMQ_LOCK_WAIT seconds with exit code 1, also when
#     the holder opened and closed the lock file in a subshell meanwhile
set -u
zmodload zsh/datetime
V=${1:?vmq path}; D=${2:?test folder}
L=${V:A:h:h}/lib/vmq.zsh
rm -rf $D; mkdir -p $D
print "T1	127.0.0.1	-" > $D/resources.tsv
export VMQ_REGISTRY=$D/resources.tsv VM_QUEUE_DIR=$D/q
ok=0 bad=0
check() { if eval "$2"; then print "right: $1"; (( ++ok )); else print "wrong: $1"; (( ++bad )); fi }

print 0 > $D/count
for p in {1..8}; do
  zsh -c 'source $1 || exit 1; for i in {1..25}; do vmq_lock || exit 1; n=$(<$2); sleep 0.01; print $(( n + 1 )) > $2; vmq_unlock; done' zsh $L $D/count &
done
wait
n=$(<$D/count)
check "1. 8 processes x 25 increments under the lock: 200 (got $n)" '(( n == 200 ))'

zsh -c 'source $1; vmq_lock; exit 0' zsh $L
check "2. free after its holder exited without vmq_unlock" 'VMQ_LOCK_WAIT=2 zsh -c "source $L && vmq_lock"'
zsh -c 'source $1; vmq_lock; kill -KILL $$' zsh $L 2>/dev/null
check "2. free after its holder was killed (KILL)" 'VMQ_LOCK_WAIT=2 zsh -c "source $L && vmq_lock"'

zsh -c 'source $1; vmq_lock; x=$(cat $VMQ_DIR/.lock); sleep 4' zsh $L &
holder=$!
sleep 1.5
t=$EPOCHREALTIME
VMQ_LOCK_WAIT=1 zsh -c "source $L && vmq_lock" 2>/dev/null; rc=$?
e=$(( EPOCHREALTIME - t ))
check "3. refused while held (exit code 1, got $rc) after about 1 s (took $(printf %.1f $e) s)" '(( rc == 1 && e >= 0.9 && e < 3 ))'
wait $holder

print "right $ok, wrong $bad"
rm -rf $D
(( bad == 0 ))
