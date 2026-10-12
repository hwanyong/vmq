#!/bin/zsh
# 동시 실행 시험: tests/stress.zsh <vmq 경로> <시험용 차례표 폴더> <출력 파일>. 소유자 10개가 동시에 run 하고 대상마다 동시에 잡은 수의 최대를 찍는다(1 이어야 한다). 실제 차례표를 쓰지 않게 차례표 폴더를 따로 준다
zmodload zsh/datetime
V=$1; export VM_QUEUE_DIR=$2; out=$3; rm -rf $2 $out; touch $out
for i in {1..10}; do
  if (( i % 3 == 0 )); then spec=(@server @client); else spec=(@server); fi
  VM_QUEUE_OWNER=S$i $V run $spec -- zsh -c 'zmodload zsh/datetime; for v in ${=VM_QUEUE_GRANTED}; do print "$v B $EPOCHREALTIME $0" >> '$out'; done; sleep 0.4; for v in ${=VM_QUEUE_GRANTED}; do print "$v E $EPOCHREALTIME $0" >> '$out'; done' S$i 2>/dev/null &
done
wait
for v in $($V list | cut -f1); do
  m=$(grep "^$v " $out | sort -k3 -n | awk 'BEGIN{d=0;m=0} $2=="B"{d++; if(d>m)m=d} $2=="E"{d--} END{print m}')
  print "$v 구간 $(grep -c "^$v B" $out)개, 최대 동시 $m"
done
