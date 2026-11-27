#!/bin/zsh
# Concurrency test: tests/stress.zsh <vmq path> <test folder> <output file>. Ten owners `vmq run` at once, and the most turns held
# at once on each target is printed (it must be 1). The queue and the target list are made in the test folder, so the real ones
# are not used. Targets: S1, C1 on hostA and S2, C2 on hostB.
zmodload zsh/datetime
V=${1:A}; T=$2; out=$3; rm -rf $T $out; mkdir -p $T; touch $out
export VM_QUEUE_DIR=$T/q VMQ_REGISTRY=$T/resources.tsv
print -l "S1	hostA	server" "C1	hostA	client" "S2	hostB	server" "C2	hostB	client" > $VMQ_REGISTRY
for i in {1..10}; do
  if (( i % 3 == 0 )); then spec=(@server @client); else spec=(@server); fi
  VM_QUEUE_OWNER=S$i $V run $spec -- zsh -c 'zmodload zsh/datetime; for v in ${=VM_QUEUE_GRANTED}; do print "$v B $EPOCHREALTIME $0" >> '$out'; done; sleep 0.4; for v in ${=VM_QUEUE_GRANTED}; do print "$v E $EPOCHREALTIME $0" >> '$out'; done' S$i 2>/dev/null &
done
wait
worst=0
for v in $($V list | cut -f1); do
  m=$(grep "^$v " $out | sort -k3 -n | awk 'BEGIN{d=0;m=0} $2=="B"{d++; if(d>m)m=d} $2=="E"{d--} END{print m}')
  print "$v: $(grep -c "^$v B" $out) intervals, at most $m at once"
  (( m > worst )) && worst=$m
done
(( worst == 1 ))
