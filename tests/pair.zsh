#!/bin/zsh
# Pair candidate test: tests/pair.zsh <vmq path> <test folder>. The queue and the target list are made in the test folder, so the
# real ones are not used. Targets: S1, C1 on Mac A and S2, C2 on Mac B. Nine owners `vmq run` at once: six ask for a pair
# (`@server+@client`), three for `@server` alone. Checks: (1) at most 1 turn at once per target (2) every pair taken is a server and
# a client on the same Mac (0 mixed pairs) (3) while one pair is held, another owner's pair request gets the other Mac's pair at
# once (4) while both pairs are held a third pair request exits 75, and gets one once a pair is released
# (5) a pair with only one side held is not given
zmodload zsh/datetime
V=${1:A}; T=$2
rm -rf $T; mkdir -p $T
export VM_QUEUE_DIR=$T/q VMQ_REGISTRY=$T/resources.tsv
print -l "S1	hostA	server" "C1	hostA	client" "S2	hostB	server" "C2	hostB	client" > $VMQ_REGISTRY
out=$T/run.out; touch $out
pass=0 fail=0
check() { if [[ $3 == $2 ]]; then print "right: $1"; (( pass++ )); else print "wrong: $1 (expected $2, got $3)"; (( fail++ )); fi }

# (1) (2) concurrent runs
for i in {1..9}; do
  if (( i % 3 == 0 )); then spec=(@server); else spec=(@server+@client); fi
  VM_QUEUE_OWNER=P$i $V run $spec -- zsh -c 'zmodload zsh/datetime; print "GRANT $0 $VM_QUEUE_GRANTED" >> '$out'; for v in ${=VM_QUEUE_GRANTED}; do print "$v B $EPOCHREALTIME $0" >> '$out'; done; sleep 0.4; for v in ${=VM_QUEUE_GRANTED}; do print "$v E $EPOCHREALTIME $0" >> '$out'; done' P$i 2>$T/err.P$i &
done
wait

for v in S1 C1 S2 C2; do
  m=$(grep "^$v " $out | sort -k3 -n | awk 'BEGIN{d=0;m=0} $2=="B"{d++; if(d>m)m=d} $2=="E"{d--} END{print m}')
  check "(1) $v at most 1 at once ($(grep -c "^$v B" $out) intervals, most at once $m)" 1 $(( m <= 1 ))
done
pairs=$(grep '^GRANT' $out | awk '{print $2, $3, $4}' | grep -v -E '^P(3|6|9) ')
mixed=$(print -r -- $pairs | awk '{ if (substr($2,2) != substr($3,2) || substr($2,1,1) != "S" || substr($3,1,1) != "C") print }' | grep -c .)
check "(2) all six pair requests were granted" 6 $(print -r -- $pairs | grep -c .)
# A run that did not run its command: print its stderr, so a failure shows why
for i in {1..9}; do grep -q "^GRANT P$i " $out || { print "  P$i ran no command; its stderr:"; sed 's/^/    /' $T/err.P$i }; done
check "(2) mixed pairs (different Macs, first not a server, second not a client)" 0 $mixed

# Every run has ended, so the queue must be empty here. When it is not, print it: the checks below would fail on it
left=$($V status 2>&1 | grep -E 'held by|waiting [0-9]|assigned to')
check "(2) the queue is empty after all runs ended (no turn left behind)" "" "$left"
[[ -z $left ]] || { print "queue after all runs ended (expected empty):"; $V status 2>&1 | sed 's/^/  /'; tail -20 $VM_QUEUE_DIR/log | sed 's/^/  log: /' }

# (3) (4) taking pairs in turn
VM_QUEUE_OWNER=A $V acquire -w 5 S1+C1 >/dev/null; check "(3) A takes S1+C1" 0 $?
r=$(VM_QUEUE_OWNER=B $V acquire -w 5 @server+@client 2>/dev/null); rc=$?
check "(3) B's pair request gets the other Mac's pair (exit code)" 0 $rc
check "(3) the pair B got" "S2 C2" "$(VM_QUEUE_OWNER=B $V mine)"
VM_QUEUE_OWNER=C $V acquire -w 3 @server+@client >/dev/null 2>&1; check "(4) C exits 75 while both pairs are held" 75 $?
VM_QUEUE_OWNER=A $V release >/dev/null
VM_QUEUE_OWNER=C $V acquire -w 5 @server+@client >/dev/null 2>&1; check "(4) C gets one after A releases" 0 $?
check "(4) the pair C got" "S1 C1" "$(VM_QUEUE_OWNER=C $V mine)"
VM_QUEUE_OWNER=B $V release >/dev/null; VM_QUEUE_OWNER=C $V release >/dev/null

# (5) a pair is not given while one side is held: while D holds only C1, E's pair request gets S2+C2; once F holds C2 too, G's exits 75
VM_QUEUE_OWNER=D $V acquire -w 5 C1 >/dev/null
VM_QUEUE_OWNER=E $V acquire -w 5 @server+@client >/dev/null 2>&1; check "(5) E's pair request while only C1 is held (exit code)" 0 $?
check "(5) the pair E got (not the one with C1)" "S2 C2" "$(VM_QUEUE_OWNER=E $V mine)"
VM_QUEUE_OWNER=E $V release >/dev/null
VM_QUEUE_OWNER=F $V acquire -w 5 C2 >/dev/null
VM_QUEUE_OWNER=G $V acquire -w 3 @server+@client >/dev/null 2>&1; check "(5) G's pair request exits 75 while C1 and C2 are each held (S1 and S2 free)" 75 $?
VM_QUEUE_OWNER=G $V release >/dev/null; VM_QUEUE_OWNER=D $V release >/dev/null; VM_QUEUE_OWNER=F $V release >/dev/null

print "right $pass, wrong $fail"
(( fail == 0 ))
