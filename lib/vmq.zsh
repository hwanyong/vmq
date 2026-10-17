# 제어 대상 큐(전역 규약 §18, ~/.claude/tools/vmq/README.md). 프로젝트의 도구가 source 해서 쓴다:
#   source ~/.claude/tools/vmq/lib/vmq.zsh
# 같은 VM · 장치를 세션 여럿이 함께 다루면 한쪽의 클릭 · 키 입력 · 스냅숏 되돌리기가 다른 쪽의 시험을 깨뜨렸다(2026-10-12 사용자 지시
# 「동일 VM을 제어하기 전에 제어 Queue 시스템을 만들어서 충돌나지 않도록 해」). 차례를 잡은(held) 소유자만 그 대상을 다룬다. 그 대상을 다루는
# 프로젝트의 도구가 제어 명령 앞에서 vmq_require 를 불러, 차례가 없으면 아무것도 하기 전에 거절한다. 2026-10-12 사용자 지시 「Vm 운영
# 방법은글로벌 규칙과 툴로 적용해줘」로 poieve 의 CloudLLM-Claude-code/tools 에서 이곳으로 옮겼다.
#
# 대상 목록: VMQ_REGISTRY(기본 ~/.claude/tools/vmq/resources.tsv). 줄마다 <이름> <Mac> <역할들>(탭). 이 Mac 하나에 하나뿐이다.
# 차례표: VMQ_DIR(기본 ~/Library/Application Support/vmq/queue). 이 Mac 의 로컬 디스크에 둔다. SMB · 네트워크 디스크에서는 원자적인
# mkdir 을 믿지 않는다. 다른 Mac 에 있는 대상도 그 대상을 다루는 명령을 실행하는 Mac 의 차례표를 쓴다. 도구가 다른 Mac 에서 자기를 다시
# 실행할 때는 VM_QUEUE_INTERNAL=1 로 검사를 건너뛴다.
#
# 차례 하나 = 요청 하나. 요청은 묶음의 목록이고, 묶음마다 후보 하나를 받는다. 묶음은 쉼표로 적은 후보다(`PoieveServer,PoieveServer2`,
# 또는 역할 `@server`). 후보 하나가 대상 여럿일 수 있다: `+` 로 잇는다(`PoieveServer2+PoieveClient2`). 그 후보는 그 대상들이 모두 빌 때만
# 받는다. `+` 로 이은 부분에 역할이 있으면(`@server+@client`) 같은 Mac(resources.tsv 의 둘째 열)의 대상끼리만 잇는다. 서버 · 클라이언트를
# 같은 Mac 의 짝으로 받을 때 쓴다(두 Mac 의 VM 은 서로 다른 NAT 망이라 섞인 짝은 페어링되지 않는다, poieve task_1792215878907_oe4o0d). 2026-10-12 사용자 지시 「VM 사용에 병목이 생긴다면, MacMini에 있는 VM으로도 사용해도 돼. 이러한 VM 할당을
# 유동적으로 제어해서 큐의 항목을 이전하여 처리 속도를 원활하게 할 수 있도록 해」에 따라 후보 중 먼저 비는 대상을 준다.
# 차례 파일: $VMQ_DIR/<후보>/<일련번호 10자리>-<소유자>. 후보마다 같은 내용의 파일을 둔다. 줄: owner · label · created ·
# need(묶음을 공백으로, 후보를 쉼표로, 후보 안의 대상을 +로. `+` 가 없는 옛 요청은 대상 하나짜리 후보로 그대로 읽는다) · held(잡은 대상, 잡은 뒤에만) · active(마지막 제어 명령의 시각) · procs(그 제어 명령을 부른
# 프로세스, `<PID>@<시작 시각>` 을 공백으로). 잡으면 받지 않은 후보의 파일을 지운다. 파일의 수정 시각이 마지막 활동이다.
#
# 배정(vmq_plan): 잡은 차례의 대상을 먼저 빼고, 기다리는 차례를 일련번호 순으로 보며 묶음마다 대상이 모두 비어 있는 후보를 하나씩 고른다. 모든 묶음이
# 채워지면 그 차례에 배정한다. 채워지지 않은 차례는 건너뛰므로, 앞 차례가 다른 대상을 기다리는 동안 뒤 차례가 빈 대상을 쓸 수 있다.
# 등록에서 VM_QUEUE_STARVE 초(기본 1800)가 지난 차례는 채워지지 않아도 자기 후보 중 빈 대상을 맡아 두어 뒤 차례가 가져가지 못하게 한다
# (뒤 차례가 빈 대상을 계속 가져가 앞 차례가 끝없이 기다리는 일을 막는다). 배정된 차례는 그 소유자의 acquire · 제어 명령이 잡는다(vmq_commit).
# 한 소유자의 차례는 하나다. 잡은 뒤 대상을 더 받으려면 놓고 함께 다시 받는다. 기다리는 동안에는 같은 일련번호로 요청을 바꿀 수 있다.
# 소유자: VM_QUEUE_OWNER, 없으면 Claude Code 가 세션마다 주는 CLAUDE_CODE_SESSION_ID. 한 세션 안의 하위 에이전트(Agent 도구)는 같은
# 세션 ID 를 물려받으므로, 하위 에이전트가 따로 대상을 다루면 VM_QUEUE_OWNER 를 따로 정한다.
# 차례는 마지막 활동에서 VM_QUEUE_LEASE 초(기본 1200) 동안 유효하다. 제어 명령의 vmq_require 와 acquire 가 시각을 새로 적는다. 그보다
# 오래 활동이 없는 차례는 다음에 차례표를 읽는 쪽이 지운다.
# 차례를 쥔 프로세스가 살아 있으면 활동이 없어도 지우지 않는다. vmq_require 가 자기를 부른 셸 프로세스($$, 스크립트면 그 스크립트)를
# procs 에 적고, 차례표를 읽는 쪽(vmq_purge)은 그 프로세스가 살아 있으면 수정 시각을 새로 적는다. 그래서 그 프로세스가 끝나면 끝난 뒤
# 차례표를 처음 읽은 때부터 VM_QUEUE_LEASE 초 뒤 지워진다(기다리는 쪽이 2초마다 읽는다). 마지막 제어 명령(active)에서 VM_QUEUE_HOLD_MAX 초
# (기본 3600)가 지나면 프로세스가 살아 있어도 새로 적지 않아, 멈춘 스크립트의 차례도 그 뒤 VM_QUEUE_LEASE 초 안에 지워진다.
# 2026-10-16 에 한 단계가 1200초 넘게 제어 명령을 부르지 않은 실행 중인 묶음의 차례가 지워지고, 다음 차례가 VM 을 되돌려 그 묶음이 깨졌다
# (poieve tracker bug_1792137322422_fwsach). 상한 3600초는 VM 을 다루지 않는 긴 한 단계인 poieve 앱 빌드(최근 빌드 기록 15개 중 14개가
# 1188초 이하)의 세 배쯤으로 잡았다.

zmodload zsh/datetime
zmodload -F zsh/stat b:zstat

VMQ_ROOT=${${(%):-%x}:A:h:h}
VMQ_REGISTRY=${VMQ_REGISTRY:-$VMQ_ROOT/resources.tsv}
VMQ_DIR=${VM_QUEUE_DIR:-$HOME/Library/Application Support/vmq/queue}
VMQ_LEASE=${VM_QUEUE_LEASE:-1200}
VMQ_STARVE=${VM_QUEUE_STARVE:-1800}
VMQ_HOLD_MAX=${VM_QUEUE_HOLD_MAX:-3600}
# 차례표를 읽은 결과(vmq_scan). 키는 차례 파일 이름(<일련번호>-<소유자>).
typeset -gA Q_vms Q_file Q_need Q_held Q_alloc Q_busy

# 대상 목록을 읽는다. VMQ_HOST[이름] = Mac, VMQ_ROLES[이름] = 역할(공백으로 나눔)
typeset -gA VMQ_HOST VMQ_ROLES
vmq_load_registry() {
  local name host roles
  VMQ_HOST=() VMQ_ROLES=()
  [[ -r $VMQ_REGISTRY ]] || { print -u2 "제어 대상 큐: 대상 목록이 없다: $VMQ_REGISTRY"; return 1 }
  while IFS=$'\t' read -r name host roles; do
    [[ -z $name || $name == \#* ]] && continue
    VMQ_HOST[$name]=$host VMQ_ROLES[$name]=${roles//,/ }
  done < "$VMQ_REGISTRY"
}
vmq_load_registry
# 역할을 가진 대상, 이름 순서: vmq_with_role <역할>
vmq_with_role() { local v; for v in ${(ok)VMQ_HOST}; do vmq_has "${VMQ_ROLES[$v]}" $1 && print -r -- $v; done; true }

# 소유자 이름. 파일 이름에 들어가므로 영문 · 숫자 · . _ - 만 받는다.
vmq_owner() {
  local o=${VM_QUEUE_OWNER:-${CLAUDE_CODE_SESSION_ID:-}}
  [[ -n $o ]] || { print -u2 "제어 대상 큐: 소유자가 없다. VM_QUEUE_OWNER=<이름> 을 정한다(Claude Code 세션이면 CLAUDE_CODE_SESSION_ID 를 쓴다)"; return 1 }
  [[ $o =~ '^[A-Za-z0-9._-]+$' ]] || { print -u2 "제어 대상 큐: 소유자 이름에는 영문 · 숫자 · . _ - 만 쓴다: $o"; return 1 }
  print -r -- $o
}

vmq_log() { print -r -- "$(strftime '%Y-%m-%d %H:%M:%S' $EPOCHSECONDS) $*" >> "$VMQ_DIR/log" }

# 차례표 전체를 바꾸는 동안 잡는 잠금. mkdir 은 로컬 APFS 에서 원자적이다. 30초 넘게 남은 잠금은 끝난 프로세스가 남긴 것으로 본다.
vmq_lock() {
  local m="$VMQ_DIR/.mutex" i=0
  mkdir -p "$VMQ_DIR"
  until mkdir "$m" 2>/dev/null; do
    if (( EPOCHSECONDS - $(zstat +mtime -- "$m" 2>/dev/null || print $EPOCHSECONDS) > 30 )); then
      rmdir "$m" 2>/dev/null && vmq_log "잠금 해제(30초 넘게 남음)"
      continue
    fi
    sleep 0.05
    (( ++i < 600 )) || { print -u2 "제어 대상 큐: 잠금을 얻지 못했다($m)"; return 1 }
  done
}
vmq_unlock() { rmdir "$VMQ_DIR/.mutex" 2>/dev/null }

# 그 VM 의 차례 파일, 오래된 차례부터: vmq_tickets <vm> → reply
vmq_tickets() { reply=("$VMQ_DIR/$1"/<->-*(N.on)) }
vmq_key_owner() { print -r -- ${1#*-} }
vmq_idle() { print $(( EPOCHSECONDS - $(zstat +mtime -- "$1") )) }
vmq_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1 }
# 공백으로 나눈 목록에 그 낱말이 있는가: vmq_has <목록> <낱말>
vmq_has() { [[ " $1 " == *" $2 "* ]] }

# 차례 파일을 다시 쓴다: vmq_write <파일> <owner> <label> <created> <need> [held] [active] [procs]
vmq_write() {
  print -l "owner=$2" "label=$3" "created=$4" "need=$5" ${6:+"held=$6"} ${7:+"active=$7"} ${8:+"procs=$8"} > "$1"
}

# 프로세스 하나를 가리키는 값 `<PID>@<시작 시각>`: vmq_proc_id <PID>. 없는 프로세스면 1. 시작 시각을 함께 적어, 끝난 프로세스의 PID 를
# 다른 프로세스가 다시 받아도 살아 있는 것으로 보지 않는다. 시작 시각은 LC_ALL=C · TZ=UTC 로 고정해 읽는다. `ps -o lstart=` 는 부른 셸의
# 로캘 · 시간대로 적어, 적은 세션과 읽는 세션의 LANG · TZ 가 다르면 살아 있는 프로세스를 끝난 것으로 보았다(bug_1792168576710_qdniti).
# 이 규칙 전에 적힌 값은 차례를 쥔 쪽이 다음 vmq_require 에서 새 값으로 다시 적는다(vmq_attach). 그때까지는 마지막 활동에서 VM_QUEUE_LEASE 로 만료를 본다.
vmq_proc_id() {
  local s=$(LC_ALL=C TZ=UTC ps -o lstart= -p $1 2>/dev/null)
  [[ -n ${s// } ]] || return 1
  print -r -- "$1@${(j:_:)${=s}}"
}
# procs 의 프로세스 가운데 살아 있는 것: vmq_procs_alive <procs> → 살아 있는 것을 공백으로 찍는다. 하나도 없으면 1.
vmq_procs_alive() {
  local p out=()
  for p in ${=1}; do [[ $(vmq_proc_id ${p%%@*}) == $p ]] && out+=($p); done
  (( ${#out} )) || return 1
  print -r -- ${out}
}

# 후보 안의 대상: vmq_members <후보> → reply. `+` 로 이은 이름들이다.
vmq_members() { reply=(${(s:+:)1}) }
# 후보 여럿의 대상 전부(중복 없이): vmq_all_members <묶음>… → reply
vmq_all_members() {
  local g c out=()
  for g in "$@"; do for c in ${(s:,:)g}; do out+=(${(s:+:)c}); done; done
  reply=(${(u)out})
}

# 묶음 하나(쉼표로 적은 후보)를 풀어 쉼표 목록으로 낸다: vmq_expand <묶음>. 모르는 이름 · 역할이면 1.
# @<역할> 은 대상 목록에서 그 역할을 가진 대상 전부다(이름 순서). `+` 로 이은 후보에 역할이 있으면 Mac 마다(이름 순서) 그 Mac 의 대상으로
# 부분을 채운 조합을 후보로 낸다. 이름만으로 이은 후보는 적은 그대로 받는다.
vmq_expand() {
  local out=() x c r
  for x in ${(s:,:)1}; do
    if [[ $x == *+* ]]; then
      c=$(vmq_expand_joined $x) || return 1
      out+=(${=c})
    elif [[ $x == @* ]]; then
      r=(${(f)"$(vmq_with_role ${x#@})"})
      (( ${#r} )) || { print -u2 "그 역할의 대상이 없다: $x (대상 목록 $VMQ_REGISTRY)"; return 1 }
      out+=($r)
    else
      [[ -n ${VMQ_HOST[$x]:-} ]] || { print -u2 "모르는 대상: $x (대상 목록 $VMQ_REGISTRY: ${(ok)VMQ_HOST})"; return 1 }
      out+=($x)
    fi
  done
  out=(${(u)out})
  (( ${#out} )) || { print -u2 "후보가 없는 묶음: $1"; return 1 }
  print -r -- ${(j:,:)out}
}
# `+` 로 이은 후보 하나를 푼다: vmq_expand_joined <부분+부분…> → 공백으로 나눈 후보들. 한 후보 안에 같은 대상이 두 번 들어가지 않는다.
vmq_expand_joined() {
  local parts=(${(s:+:)1}) p host combos next c m here v roles=0 hosts
  for p in $parts; do
    if [[ $p == @* ]]; then
      roles=1
      [[ -n $(vmq_with_role ${p#@}) ]] || { print -u2 "그 역할의 대상이 없다: $p (대상 목록 $VMQ_REGISTRY)"; return 1 }
    else
      [[ -n ${VMQ_HOST[$p]:-} ]] || { print -u2 "모르는 대상: $p (대상 목록 $VMQ_REGISTRY: ${(ok)VMQ_HOST})"; return 1 }
    fi
  done
  (( roles )) || { print -r -- $1; return 0 }
  hosts=(${(ou)${(v)VMQ_HOST}})
  local out=()
  for host in $hosts; do
    combos=("")
    for p in $parts; do
      if [[ $p == @* ]]; then m=(${(f)"$(vmq_with_role ${p#@})"}); else m=($p); fi
      here=()
      for v in $m; do [[ ${VMQ_HOST[$v]} == $host ]] && here+=($v); done
      next=()
      for c in "${combos[@]}"; do for v in $here; do vmq_has "${c//+/ }" $v || next+=(${c:+$c+}$v); done; done
      combos=($next)
    done
    out+=($combos)
  done
  (( ${#out} )) || { print -u2 "같은 Mac 에서 채울 수 있는 후보가 없다: $1"; return 1 }
  print -r -- $out
}

# 마지막 활동에서 VMQ_LEASE 가 지난 차례를 지운다(잠금 안에서 부른다). 그 전에, 차례를 쥔 프로세스가 살아 있고 마지막 제어 명령에서
# VMQ_HOLD_MAX 가 지나지 않은 차례는 수정 시각을 새로 적어 지우지 않는다.
vmq_purge() {
  local vm f idle procs alive active why
  for vm in ${(ok)VMQ_HOST}; do
    vmq_tickets $vm
    for f in $reply; do
      why=
      procs=$(vmq_field $f procs)
      if [[ -n $procs ]] && alive=$(vmq_procs_alive "$procs"); then
        active=$(vmq_field $f active)
        if (( EPOCHSECONDS - ${active:-0} <= VMQ_HOLD_MAX )); then touch -- "$f"; continue; fi
        why=", 프로세스 $alive 는 살아 있지만 마지막 제어 명령에서 상한 ${VMQ_HOLD_MAX}초가 지났다"
      fi
      idle=$(vmq_idle $f)
      (( idle > VMQ_LEASE )) || continue
      rm -f -- "$f" && vmq_log "만료 $vm $(vmq_key_owner ${f:t}) (마지막 활동 ${idle}초 전$why)"
    done
  done
}

# 차례표를 읽는다(잠금 안에서). 이 형식 전의 차례(need 줄이 없다)는 파일이 있는 VM 을 하나씩 받는 요청이고, 그 VM 들 모두에서 맨 앞이면
# 잡은 것이다(전의 규칙). 읽을 때 새 형식으로 다시 쓴다.
vmq_scan() {
  Q_vms=() Q_file=() Q_need=() Q_held=()
  local vm f k head m
  for vm in ${(ok)VMQ_HOST}; do
    vmq_tickets $vm
    for f in $reply; do
      k=${f:t}
      Q_vms[$k]+="${Q_vms[$k]:+ }$vm"
      [[ -n ${Q_file[$k]:-} ]] || Q_file[$k]=$f
    done
  done
  for k in ${(k)Q_vms}; do
    Q_need[$k]=$(vmq_field ${Q_file[$k]} need)
    Q_held[$k]=$(vmq_field ${Q_file[$k]} held)
    [[ -n ${Q_need[$k]} ]] && continue
    Q_need[$k]=${Q_vms[$k]}
    head=1
    for vm in ${=Q_vms[$k]}; do vmq_tickets $vm; [[ ${reply[1]:t} == $k ]] || head=0; done
    (( head )) && Q_held[$k]=${Q_vms[$k]}
    # 다시 쓰는 것은 활동이 아니므로 마지막 활동 시각(수정 시각)을 그대로 둔다
    for vm in ${=Q_vms[$k]}; do
      f="$VMQ_DIR/$vm/$k"
      m=$(zstat +mtime -- $f)
      vmq_write $f "$(vmq_field $f owner)" "$(vmq_field $f label)" "$(vmq_field $f created)" "${Q_need[$k]}" "${Q_held[$k]}"
      touch -t $(strftime '%Y%m%d%H%M.%S' $m) -- $f
    done
  done
}

# 차례를 VM 에 배정한다(잠금 안에서, vmq_scan 뒤). 결과: Q_alloc[키] = 묶음 순서대로 배정한 VM, Q_busy[VM] = 잡거나 배정되거나 맡아 둔 차례
vmq_plan() {
  Q_alloc=() Q_busy=()
  local k vm g c pick picks ok free
  for k in ${(k)Q_held}; do
    [[ -n ${Q_held[$k]} ]] || continue
    Q_alloc[$k]=${Q_held[$k]}
    for vm in ${=Q_held[$k]}; do Q_busy[$vm]=$k; done
  done
  for k in ${(ok)Q_vms}; do
    [[ -n ${Q_held[$k]} ]] && continue
    picks=() ok=1
    for g in ${=Q_need[$k]}; do
      pick=
      for c in ${(s:,:)g}; do
        # 후보의 대상이 모두 비어 있어야 한다. 차례 파일이 없는 대상(만료로 지워진 것)이 있는 후보는 고르지 않는다
        vmq_members $c; free=1
        for vm in $reply; do
          vmq_has "${Q_vms[$k]}" $vm && [[ -z ${Q_busy[$vm]:-} ]] && (( ! ${picks[(Ie)$vm]} )) || { free=0; break }
        done
        (( free )) && { pick=$c; break }
      done
      [[ -n $pick ]] || { ok=0; break }
      picks+=(${(s:+:)pick})
    done
    if (( ok )); then
      Q_alloc[$k]=${(j: :)picks}
      for vm in $picks; do Q_busy[$vm]=$k; done
    elif (( EPOCHSECONDS - $(vmq_field ${Q_file[$k]} created) > VMQ_STARVE )); then
      for vm in ${=Q_vms[$k]}; do [[ -n ${Q_busy[$vm]:-} ]] || Q_busy[$vm]="~$k"; done
    fi
  done
}

# 그 소유자의 차례 키. 없으면 빈 줄(vmq_scan 뒤).
vmq_key() { local k; for k in ${(k)Q_vms}; do [[ ${k#*-} == $1 ]] && { print -r -- $k; return }; done }

# 배정된 차례를 잡는다(잠금 안에서): 배정한 VM 의 차례 파일에 held 를 적고, 배정하지 않은 후보의 파일을 지운다.
vmq_commit() {
  local k=$1 vm f
  [[ -n $k && -z ${Q_held[$k]:-} && -n ${Q_alloc[$k]:-} ]] || return 1
  f=${Q_file[$k]}
  local o=$(vmq_field $f owner) l=$(vmq_field $f label) c=$(vmq_field $f created)
  for vm in ${=Q_vms[$k]}; do
    if vmq_has "${Q_alloc[$k]}" $vm; then
      vmq_write "$VMQ_DIR/$vm/$k" $o "$l" $c "${Q_need[$k]}" "${Q_alloc[$k]}"
    else
      rm -f -- "$VMQ_DIR/$vm/$k"
    fi
  done
  Q_held[$k]=${Q_alloc[$k]} Q_vms[$k]=${Q_alloc[$k]}
  Q_file[$k]="$VMQ_DIR/${Q_alloc[$k]%% *}/$k"
  vmq_log "잡음 $o ${Q_alloc[$k]}${l:+ ($l)}"
}

# 차례표를 정리하고 그 소유자의 차례를 갱신한다(잠금 안에서): 만료 정리 → 읽기 → 배정 → 배정되었으면 잡기 → 내 차례 파일의 시각을 새로 적기.
# REPLY 에 그 소유자의 키(없으면 빈 값)를 남긴다.
vmq_sync() {
  local owner=$1 vm
  vmq_purge
  vmq_scan
  vmq_plan
  REPLY=$(vmq_key $owner)
  [[ -n $REPLY ]] || return 0
  vmq_commit $REPLY
  for vm in ${=Q_vms[$REPLY]}; do touch -- "$VMQ_DIR/$vm/$REPLY"; done
  return 0
}

# 소유자가 그 VM 들을 모두 잡았는가(vmq_sync 뒤)
vmq_holds() {
  local owner=$1 k vm; shift
  k=$(vmq_key $owner)
  [[ -n $k && -n ${Q_held[$k]} ]] || return 1
  for vm in "$@"; do vmq_has "${Q_held[$k]}" $vm || return 1; done
}

# 그 VM 을 잡은 차례의 키(vmq_scan 뒤). 없으면 빈 줄.
vmq_holder() { local k; for k in ${(k)Q_held}; do vmq_has "${Q_held[$k]}" $1 && { print -r -- $k; return }; done }

# 차례를 잡은 쪽의 한 줄 설명: vmq_holder_line <vm>(vmq_scan 뒤)
vmq_holder_line() {
  local k=$(vmq_holder $1) n=0 x
  for x in ${(k)Q_vms}; do [[ -z ${Q_held[$x]} ]] && vmq_has "${Q_vms[$x]}" $1 && (( n++ )); done
  [[ -n $k ]] || { print "없음, 대기 $n"; return }
  local f="$VMQ_DIR/$1/$k" l
  l=$(vmq_field $f label)
  print "$(vmq_key_owner $k)${l:+ ($l)}, 마지막 활동 $(vmq_idle $f)초 전, 대기 $n"
}

# 잡은 차례에 제어 명령의 시각과 그 명령을 부른 프로세스를 적는다(잠금 안에서, vmq_sync 뒤): vmq_attach <키> <PID>.
# 끝난 프로세스는 procs 에서 뺀다.
vmq_attach() {
  local k=$1 me vm f procs
  me=$(vmq_proc_id $2) || return 0
  f=${Q_file[$k]}
  procs=$(vmq_procs_alive "$(vmq_field $f procs)")
  vmq_has "$procs" $me || procs="${procs:+$procs }$me"
  for vm in ${=Q_vms[$k]}; do
    f="$VMQ_DIR/$vm/$k"
    vmq_write $f "$(vmq_field $f owner)" "$(vmq_field $f label)" "$(vmq_field $f created)" "$(vmq_field $f need)" "$(vmq_field $f held)" $EPOCHSECONDS "$procs"
  done
}

# 프로젝트 도구가 제어 명령 앞에서 부른다: vmq_require <대상>… 차례를 가졌으면 시각과 이 셸 프로세스($$)를 적고 0, 아니면 이유를
# stderr 에 쓰고 1. 적은 프로세스가 살아 있는 동안 차례는 만료되지 않는다(위 「만료」, 상한 VM_QUEUE_HOLD_MAX).
vmq_require() {
  [[ ${VM_QUEUE_INTERNAL:-} == 1 ]] && return 0
  local owner vm ok=0
  owner=$(vmq_owner) || return 1
  vmq_lock || return 1
  {
    vmq_sync $owner
    if vmq_holds $owner "$@"; then
      ok=1
      vmq_attach $REPLY $$
    else
      for vm in "$@"; do
        vmq_holds $owner $vm && continue
        print -u2 "제어 대상 큐: $vm 의 차례가 없다(소유자 $owner). 지금 잡은 쪽: $(vmq_holder_line $vm)"
      done
      print -u2 "  먼저 차례를 받는다: ~/.claude/tools/vmq/bin/vmq acquire [-l 설명] $* (상태: vmq status)"
    fi
  } always { vmq_unlock }
  (( ok ))
}
