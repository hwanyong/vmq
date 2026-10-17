#!/bin/zsh
# 짝 단위 후보 시험: tests/pair.zsh <vmq 경로> <시험용 폴더>. 실제 차례표 · 대상 목록을 쓰지 않게 둘 다 시험용 폴더에 만든다.
# 대상 목록: Mac A 에 S1 · C1, Mac B 에 S2 · C2. 소유자 아홉 개가 동시에 `vmq run` 한다. 여섯 개는 `@server+@client`(짝), 세 개는
# `@server`(옛 형식처럼 대상 하나). 확인: ① 대상마다 동시에 잡은 수의 최대가 1 ② 짝으로 받은 차례가 모두 같은 Mac 의 서버 · 클라이언트(섞인 짝 0)
# ③ 짝 하나를 잡은 동안 다른 소유자의 짝 요청은 다른 Mac 의 짝을 바로 받는다 ④ 짝 둘이 모두 잡힌 동안 세 번째 짝 요청은 75, 하나가 놓이면 받는다
zmodload zsh/datetime
V=${1:A}; T=$2
rm -rf $T; mkdir -p $T
export VM_QUEUE_DIR=$T/q VMQ_REGISTRY=$T/resources.tsv
print -l "S1	hostA	server" "C1	hostA	client" "S2	hostB	server" "C2	hostB	client" > $VMQ_REGISTRY
out=$T/run.out; touch $out
pass=0 fail=0
check() { if [[ $3 == $2 ]]; then print "맞음: $1"; (( pass++ )); else print "틀림: $1 (기대 $2, 실제 $3)"; (( fail++ )); fi }

# ① ② 동시 실행
for i in {1..9}; do
  if (( i % 3 == 0 )); then spec=(@server); else spec=(@server+@client); fi
  VM_QUEUE_OWNER=P$i $V run $spec -- zsh -c 'zmodload zsh/datetime; print "GRANT $0 $VM_QUEUE_GRANTED" >> '$out'; for v in ${=VM_QUEUE_GRANTED}; do print "$v B $EPOCHREALTIME $0" >> '$out'; done; sleep 0.4; for v in ${=VM_QUEUE_GRANTED}; do print "$v E $EPOCHREALTIME $0" >> '$out'; done' P$i 2>/dev/null &
done
wait
for v in S1 C1 S2 C2; do
  m=$(grep "^$v " $out | sort -k3 -n | awk 'BEGIN{d=0;m=0} $2=="B"{d++; if(d>m)m=d} $2=="E"{d--} END{print m}')
  check "① $v 최대 동시 1(구간 $(grep -c "^$v B" $out)개)" 1 $m
done
pairs=$(grep '^GRANT' $out | awk '{print $2, $3, $4}' | grep -v -E '^P(3|6|9) ')
mixed=$(print -r -- $pairs | awk '{ if (substr($2,2) != substr($3,2) || substr($2,1,1) != "S" || substr($3,1,1) != "C") print }' | grep -c .)
check "② 짝 요청 여섯 개가 모두 받았다" 6 $(print -r -- $pairs | grep -c .)
check "② 섞인 짝(다른 Mac · 서버가 아닌 첫째 · 클라이언트가 아닌 둘째)" 0 $mixed

# ③ ④ 짝 바꿔 받기
VM_QUEUE_OWNER=A $V acquire -w 5 S1+C1 >/dev/null; check "③ A 가 S1+C1 을 받음" 0 $?
r=$(VM_QUEUE_OWNER=B $V acquire -w 5 @server+@client 2>/dev/null); rc=$?
check "③ B 의 짝 요청이 다른 Mac 의 짝을 받음(종료 코드)" 0 $rc
check "③ B 가 받은 짝" "S2 C2" "$(VM_QUEUE_OWNER=B $V mine)"
VM_QUEUE_OWNER=C $V acquire -w 3 @server+@client >/dev/null 2>&1; check "④ 짝이 모두 잡힌 동안 C 는 75" 75 $?
VM_QUEUE_OWNER=A $V release >/dev/null
VM_QUEUE_OWNER=C $V acquire -w 5 @server+@client >/dev/null 2>&1; check "④ A 가 놓은 뒤 C 가 받음" 0 $?
check "④ C 가 받은 짝" "S1 C1" "$(VM_QUEUE_OWNER=C $V mine)"
VM_QUEUE_OWNER=B $V release >/dev/null; VM_QUEUE_OWNER=C $V release >/dev/null

# ⑤ 짝의 한쪽만 잡혀 있어도 그 짝은 받지 않는다: D 가 C1 만 잡은 동안 E 의 짝 요청은 S2+C2 를 받고, F 가 C2 도 잡으면 G 의 짝 요청은 75
VM_QUEUE_OWNER=D $V acquire -w 5 C1 >/dev/null
VM_QUEUE_OWNER=E $V acquire -w 5 @server+@client >/dev/null 2>&1; check "⑤ C1 만 잡힌 동안 E 의 짝 요청(종료 코드)" 0 $?
check "⑤ E 가 받은 짝(C1 이 든 짝이 아님)" "S2 C2" "$(VM_QUEUE_OWNER=E $V mine)"
VM_QUEUE_OWNER=E $V release >/dev/null
VM_QUEUE_OWNER=F $V acquire -w 5 C2 >/dev/null
VM_QUEUE_OWNER=G $V acquire -w 3 @server+@client >/dev/null 2>&1; check "⑤ C1 · C2 가 각각 잡힌 동안 G 의 짝 요청은 75(S1 · S2 는 비어 있음)" 75 $?
VM_QUEUE_OWNER=G $V release >/dev/null; VM_QUEUE_OWNER=D $V release >/dev/null; VM_QUEUE_OWNER=F $V release >/dev/null

print "맞음 $pass · 틀림 $fail"
(( fail == 0 ))
