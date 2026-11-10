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
# need(묶음을 공백으로, 후보를 쉼표로, 후보 안의 대상을 +로. `+` 가 없는 옛 요청은 대상 하나짜리 후보로 그대로 읽는다) · held(잡은 대상, 잡은 뒤에만) · active(마지막 제어 명령 또는 vmq_keepalive 의 시각) · procs(그 제어 명령을 부른
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
# 차례표를 처음 읽은 때부터 VM_QUEUE_LEASE 초 뒤 지워진다(기다리는 쪽이 2초마다 읽는다). 마지막 제어 명령 · 갱신(active)에서 VM_QUEUE_HOLD_MAX 초
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
# 차례 파일 하나의 만료 판정(vmq_expiry)
typeset -ga Q_exp

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
# Mac 으로 가는 ssh 의 선택 사항: vmq_ssh_opts <식별 주소> → reply. 식별 주소(resources.tsv 둘째 열)는 ssh 의 목적지로 그대로 쓰고,
# 이 함수가 돌려준 선택 사항을 그 앞에 끼운다: `vmq_ssh_opts $h; ssh "${reply[@]}" $h …`. reply 는 늘 VMQ_SSH_BASE(아래)로 시작한다.
# 그 뒤에 hosts.tsv 의 주소를 앞부터 2초씩 시도해(nc -z -G 2 <주소> 22) 된 주소가 식별 주소면 더하는 것이 없고, 다른 주소면
# -o HostName=<그 주소> -o HostKeyAlias=<식별 주소> 를 더해 같은 키를 확인한다. 아무것도 안 되면 종료 코드 1(ssh 가 그 실패를 그대로 낸다).
# hosts.tsv 에 없는 식별 주소는 VMQ_SSH_BASE 만이다.
# Thunderbolt 브리지가 끊길 때 LAN 주소로 가기 위해서다(2026-10-23 사용자, poieve task_1792776616889_c8rezv). 2026-10-23 잰 시간:
# 브리지가 살아 있으면 0.02초, LAN 주소 0.08초, 닿지 않는 주소 2.02초.
# VMQ_SSH_BASE: Mac · VM 으로 가는 ssh 의 공통 선택 사항. 암호를 묻지 않고(BatchMode), 연결은 5초 안에 열리지 않으면 끊고(ConnectTimeout),
# 응답하지 않는 상대는 15초마다 묻고 4번 답이 없으면 끊는다(첫 묻기까지 15초를 더해 약 75초, 종료 코드 255). keepalive 는 원격 명령과
# 따로 sshd 가 답하므로 오래 걸리는 정상 명령은 끊기지 않는다. 전에는 poieve 의 tools/vm.sh 만 이 값을 갖고(bug_1792775158909_k5mr0k)
# 다른 자리의 Mac mini ssh 에는 없어, 원격 rm 이 끝난 뒤에도 ssh 가 35분 남았다(2026-10-23, poieve bug_1792793532531_0ks4u2).
# 그래서 자리마다 붙이지 않고 이곳 한 곳에서 준다. 부르는 쪽이 게스트(VM)로 가는 ssh 에도 같은 값을 쓸 때는 이 배열을 그대로 쓴다.
typeset -ga VMQ_SSH_BASE=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
VMQ_HOSTS_FILE=${VMQ_HOSTS_FILE:-$VMQ_ROOT/hosts.tsv}
vmq_ssh_opts() {
  local id=$1 key addrs a
  reply=($VMQ_SSH_BASE)
  [[ -r $VMQ_HOSTS_FILE ]] || return 0
  while IFS=$'\t' read -r key addrs; do
    [[ $key == $id ]] && break
    addrs=
  done < "$VMQ_HOSTS_FILE"
  [[ -n $addrs ]] || return 0
  for a in ${=addrs}; do
    nc -z -G 2 $a 22 >/dev/null 2>&1 || continue
    [[ $a == $id ]] || reply+=(-o "HostName=$a" -o "HostKeyAlias=$id")
    return 0
  done
  return 1
}
# Mac 으로 가는 ssh 를 실행한다: vmq_ssh <식별 주소> [ssh 선택 사항…] [원격 명령…] → ssh 의 종료 코드. 선택 사항은 시도마다 vmq_ssh_opts 가
# 정한다. ssh 는 목적지 뒤의 선택 사항도 받는다(`vmq_ssh $h -n uptime`). 원격 명령의 stdout · stderr 는 그대로 지나가고, ssh 자신의
# 진단(-E 로 받은 것)은 시도마다 stderr 에 옮긴다. 다시 시도의 몸통은 아래 vmq_ssh_retry 이고, scp · 게스트로 가는 ssh 는 그것을 직접 부른다.
# 배너 교환에서 끝난 연결(종료 코드 255 와 「during banner exchange」)만 새 연결로 다시 시도한다. 배너 전에는 원격 명령이 시작되지 않았고
# 표준 입력도 읽지 않았다(2026-10-24 재현: 배너 전에 끝난 ssh 다음의 ssh 가 here-string 11 바이트를 그대로 받았다). 첫 시도부터
# VMQ_SSH_RETRY_S 초가 지나면 더 시도하지 않는다. 다시 시도할 때마다 stderr 와 차례표 기록(vmq_log)에 횟수와 경과 초를 적는다.
# 까닭(2026-10-23 08:00 ~ 20:06 PDT, Mac Studio 커널 로그): 이 Mac 의 ssh 흐름 14767개 중 81개에서 들어오는 패킷이 「reason: NECP」 로
# 버려졌다. 연결 직후 버림이 시작된 19개 중 3개는 ConnectTimeout 5 안에 배너를 받지 못해 끝났고(poieve bug_1792810184598_skyztm, gkmbfo
# 사슬의 「주소 없음」), 세 번 모두 1.6 ~ 4.4초 뒤에 연 새 연결은 정상이었다. 같은 연결을 계속 기다린 것 중에는 60초 ServerAlive 로 끊긴 것이
# 4개라 시간 제한을 늘리지 않고 새 연결로 다시 시도한다. 버림의 원인(그 프로세스 계열의 Local Network 판정)은 poieve bug_1792778607255_ahb398 이 갖는다.
# VMQ_SSH_RETRY_S 기본 30 은 어림이다. 잰 것은 위 3번(n=3)이 모두 다음 연결에서 됐다는 것뿐이고, 이 함수에서 2번째 시도는 첫 시도부터
# 약 5.1초에 시작한다(ConnectTimeout 5, 2026-10-24 깨 보기 poieve build/0a28779b/skyztm/run1.log). 늘 실패하면 시도마다 약 5.1초라
# (같은 깨 보기의 한도 12초에서 3번 시도 · 15.2초) 30 이면 6번째 시도(약 25.5초에 시작)까지 간다. 2번째 시도가 실패한 경우는 아직 재지 못했다.
# 다시 재는 법: 차례표 기록에서
# `grep -E '(ssh|scp) [^ ]+: [0-9]+번 시도' "$VMQ_DIR/log"` 로 시도 횟수 · 경과 초 · 종료 코드를 모아, 몇 번째 시도에서 됐는지와 한도에 걸려
# 종료 코드 255 로 끝난 것이 있는지 본다. 한도에 걸린 것이 있으면 그 경과 초를 근거로 값을 다시 정한다.
VMQ_SSH_RETRY_S=${VMQ_SSH_RETRY_S:-30}
# 다시 시도의 몸통: vmq_ssh_retry <기록 이름> <준비 함수> [준비 함수 인자…] → 그 명령의 종료 코드. Mac 으로 가는 vmq_ssh 와, 프로젝트 도구가
# 게스트(VM)로 가는 ssh · scp(poieve tools/vm.sh 의 vssh · push)가 같은 규칙을 쓰려고 한 곳에 둔다(poieve bug_1792822845742_xbheol).
# <준비 함수> 는 시도마다 불려 reply 에 실행할 명령 전체를 넣는다. 그 명령의 ssh 진단은 $VMQ_SSH_ERR 파일로 가야 한다: ssh 는
# `-E "$VMQ_SSH_ERR"`, scp 는 `-S <vmq>/bin/vmq-ssh-e`(그 파일로 -E 를 붙여 ssh 를 실행한다). 그 파일은 시도마다 stderr 에 옮긴다.
# 기록 이름은 「ssh <식별 주소>」 · 「scp <VM>」 처럼 공백 없는 대상을 붙인다(다시 재는 grep 이 그 꼴을 찾는다).
vmq_ssh_retry() {
  local name=$1 prep=$2 rc n=0 t0=$EPOCHREALTIME msg
  shift 2
  local -x VMQ_SSH_ERR
  VMQ_SSH_ERR=$(mktemp -t vmq-ssh) || return 255
  while :; do
    (( ++n ))
    $prep "$@"
    # set -e 인 셸에서 불러도 실패한 명령에서 끝나지 않게 종료 코드를 목록으로 받는다
    "${reply[@]}" && rc=0 || rc=$?
    [[ -s $VMQ_SSH_ERR ]] && cat -- $VMQ_SSH_ERR >&2
    (( rc == 255 )) && grep -q 'during banner exchange' $VMQ_SSH_ERR && (( EPOCHREALTIME - t0 < VMQ_SSH_RETRY_S )) || break
    : >| $VMQ_SSH_ERR
    msg=$(printf '%s: 배너 교환에서 끝나 새 연결로 다시 시도(%d번째 시도, 첫 시도부터 %.1f초)' $name $(( n + 1 )) $(( EPOCHREALTIME - t0 )))
    print -u2 -r -- "vmq_ssh: $msg"
    vmq_log "$msg" 2>/dev/null || true
  done
  if (( n > 1 )); then
    msg=$(printf '%s: %d번 시도, %.1f초, 종료 코드 %d' $name $n $(( EPOCHREALTIME - t0 )) $rc)
    print -u2 -r -- "vmq_ssh: $msg"
    vmq_log "$msg" 2>/dev/null || true
  fi
  rm -f -- $VMQ_SSH_ERR
  return $rc
}
# vmq_ssh 의 준비 함수: 시도마다 주소를 다시 고른다(Thunderbolt 브리지가 그 사이에 끊겼을 수 있다)
vmq_ssh_cmd() { local id=$1; shift; vmq_ssh_opts $id || true; reply=(ssh -E "$VMQ_SSH_ERR" "${reply[@]}" $id "$@") }
vmq_ssh() { vmq_ssh_retry "ssh $1" vmq_ssh_cmd "$@" }

# 역할을 가진 대상, 이름 순서: vmq_with_role <역할>
vmq_with_role() { local v; for v in ${(ok)VMQ_HOST}; do vmq_has "${VMQ_ROLES[$v]}" $1 && print -r -- $v; done; true }

# 소유자 이름. 파일 이름에 들어가므로 영문 · 숫자 · . _ - 만 받는다.
vmq_owner() {
  local o=${VM_QUEUE_OWNER:-${CLAUDE_CODE_SESSION_ID:-}}
  [[ -n $o ]] || { print -u2 "제어 대상 큐: 소유자가 없다. VM_QUEUE_OWNER=<이름> 을 정한다(Claude Code 세션이면 CLAUDE_CODE_SESSION_ID 를 쓴다)"; return 1 }
  [[ $o =~ '^[A-Za-z0-9._-]+$' ]] || { print -u2 "제어 대상 큐: 소유자 이름에는 영문 · 숫자 · . _ - 만 쓴다: $o"; return 1 }
  print -r -- $o
}

# 부른 도구의 판 검사: vmq_tool_current. 이 파일을 source 한 스크립트($ZSH_ARGZERO 를 source 할 때의 작업 폴더로 푼 경로, 파일이 아니면
# 그 작업 폴더)가 git 작업 트리 안에 있고 그 저장소의 main 브랜치에 .vmq-required 가 있으면, 그 파일의 줄마다 이 작업 트리가 통과해야
# 한다: HEAD 가 그 커밋을 포함하거나, 그 줄에 적은 경로의 작업 트리 내용이 main 과 같다. 하나라도 어기면 까닭과 고치는 법을 stderr 에
# 쓰고 1. 그 저장소 · 파일이 없으면 0. 줄 형식: <커밋>\t<경로(공백으로 나눔)>\t<설명>. # 으로 시작하는 줄과 빈 줄은 건너뛴다.
# 목록을 읽는 브랜치는 VMQ_REQUIRED_REF(기본 main)로 바꿀 수 있다. 목록을 main 에 올리기 전에 시험 브랜치로 확인할 때 쓴다.
# 2026-10-23 에 main 에서 오래전에 갈라진 작업 트리의 옛 도구로 VM 사슬을 두 번 돌려, main 에만 있던 ssh 끊기(ServerAliveInterval)가 없는
# ssh 가 VM 짝을 19 ~ 30분 쥐었다(poieve task_1792779841439_8iolnc). 옛 도구 자신은 새 검사를 갖고 있지 않으므로, 옛 도구도 반드시
# source 하는 이 파일이 vmq_require 에서 검사한다. 목록은 작업 트리가 아니라 main 에서 읽으므로 목록에 줄을 더하면 떠 있는 사슬에도
# 바로 걸린다. 줄을 더하기 전에 떠 있는 사슬의 작업 트리가 그 커밋을 가졌는지 본다(거절되면 그 사슬의 뒷정리도 거절된다).
VMQ_CALLER=${ZSH_ARGZERO:A}
[[ -f $VMQ_CALLER ]] && VMQ_CALLER_DIR=${VMQ_CALLER:h} || VMQ_CALLER_DIR=$PWD
vmq_tool_current() {
  local top c paths note line ref=refs/heads/${VMQ_REQUIRED_REF:-main}
  local -a missing
  top=$(git -C "$VMQ_CALLER_DIR" rev-parse --show-toplevel 2>/dev/null) || return 0
  git -C "$top" cat-file -e $ref:.vmq-required 2>/dev/null || return 0
  while IFS=$'\t' read -r c paths note; do
    [[ -z $c || $c == \#* ]] && continue
    git -C "$top" merge-base --is-ancestor "$c" HEAD 2>/dev/null && continue
    [[ -n $paths ]] && git -C "$top" diff --quiet $ref -- ${=paths} 2>/dev/null && continue
    missing+=("$c"$'\t'"$paths"$'\t'"$note")
  done < <(git -C "$top" show $ref:.vmq-required)
  (( ${#missing} )) || return 0
  print -u2 "제어 대상 큐: 이 도구의 판에 VM 을 다루는 데 필요한 main 커밋이 없어 거절한다(아무것도 하지 않았다)."
  print -u2 "  도구: $VMQ_CALLER"
  print -u2 "  작업 트리: $top (HEAD $(git -C "$top" rev-parse --short HEAD 2>/dev/null))"
  for line in $missing; do
    IFS=$'\t' read -r c paths note <<< "$line"
    print -u2 "  없는 커밋: $c $note"
    print -u2 "    고치는 법: 그 브랜치에 main 을 합치거나(git -C ${(q)top} merge ${ref#refs/heads/}) 그 경로만 그 판으로 바꾼다(git -C ${(q)top} checkout ${ref#refs/heads/} -- $paths)"
  done
  print -u2 "  목록: ${ref#refs/heads/} 브랜치의 .vmq-required"
  return 1
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

# 차례 파일을 다시 쓴다: vmq_write <파일> <owner> <label> <created> <need> [held] [active] [procs] [chain]
# chain 은 이 차례를 쥔 사슬 셸의 `<PID>@<시작 시각>` 이다(vmq_chain_mark). 그 사슬이 끝난 차례는 같은 소유자의 acquire 에도 넘기지 않는다(bin/vmq 의 register).
vmq_write() {
  print -l "owner=$2" "label=$3" "created=$4" "need=$5" ${6:+"held=$6"} ${7:+"active=$7"} ${8:+"procs=$8"} ${9:+"chain=$9"} > "$1"
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

# 마지막 활동에서 VMQ_LEASE 가 지난 차례를 지운다(잠금 안에서 부른다). 그 전에, 차례를 쥔 프로세스가 살아 있고 마지막 제어 명령 · 갱신에서
# VMQ_HOLD_MAX 가 지나지 않은 차례는 수정 시각을 새로 적어 지우지 않는다.
vmq_purge() {
  local vm f why
  for vm in ${(ok)VMQ_HOST}; do
    vmq_tickets $vm
    for f in $reply; do
      vmq_expiry $f
      [[ ${Q_exp[1]} == holdMax ]] && { touch -- "$f"; continue }
      (( Q_exp[4] > VMQ_LEASE )) || continue
      why=; [[ -n ${Q_exp[3]} ]] && why=", 프로세스 ${Q_exp[3]} 는 살아 있지만 마지막 제어 명령 · 갱신에서 상한 ${VMQ_HOLD_MAX}초가 지났다"
      rm -f -- "$f" && vmq_log "만료 $vm $(vmq_key_owner ${f:t}) (마지막 활동 ${Q_exp[4]}초 전$why)"
    done
  done
}

# 차례 파일 하나가 언제 무엇으로 만료되는지: vmq_expiry <파일> → Q_exp=(<근거> <만료까지 초> <살아 있는 프로세스> <근거의 시작에서 지난 초>).
# 근거는 holdMax(쥔 프로세스가 살아 있고 마지막 제어 명령 · 갱신에서 VMQ_HOLD_MAX 가 지나지 않았다. 지난 초는 active 에서 잰다) 또는
# lease(그 밖. 지난 초는 마지막 활동(수정 시각)에서 잰다). 살아 있는 프로세스는 근거가 lease 여도 적는다(상한이 지난 경우).
# vmq_purge 와 vmq status(문장 · --json)가 이 한 곳의 판정을 쓴다.
vmq_expiry() {
  local f=$1 active alive idle
  active=$(vmq_field $f active)
  alive=$(vmq_procs_alive "$(vmq_field $f procs)") || alive=
  if [[ -n $alive ]] && (( EPOCHSECONDS - ${active:-0} <= VMQ_HOLD_MAX )); then
    Q_exp=(holdMax $(( VMQ_HOLD_MAX - EPOCHSECONDS + active )) "$alive" $(( EPOCHSECONDS - active )))
    return
  fi
  idle=$(vmq_idle $f)
  Q_exp=(lease $(( VMQ_LEASE - idle )) "$alive" $idle)
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
    vmq_write $f "$(vmq_field $f owner)" "$(vmq_field $f label)" "$(vmq_field $f created)" "$(vmq_field $f need)" "$(vmq_field $f held)" $EPOCHSECONDS "$procs" "$(vmq_field $f chain)"
  done
}

# 잡은 차례에 그 차례를 쥔 사슬을 적는다: vmq_chain_mark <사슬 셸의 PID> <대상>… 차례를 가졌으면 0, 아니면 1.
# 사슬(한 번 받아 VM 을 다루고 끝나는 셸, poieve 의 vm_chain_guard 가 부른다)이 끝난 뒤 그 뒷정리가 차례를 놓기 전에 같은 소유자의 다음 사슬이
# acquire 하면, 전에는 register 가 「이미 있음」 으로 그 차례를 넘겨 앞 사슬의 뒷정리가 다음 사슬의 VM 을 끄고 되돌렸다
# (2026-10-22 23:57 PDT, poieve tracker bug_1792779968019_9ycb6f). 사슬이 살아 있을 때 적어 두므로 사슬 셸이 끝나는 순간부터 막힌다.
vmq_chain_mark() {
  [[ ${VM_QUEUE_INTERNAL:-} == 1 ]] && return 0
  local pid=$1 owner vm f chain ok=0
  shift
  chain=$(vmq_proc_id $pid) || { print -u2 "제어 대상 큐: 사슬 프로세스 $pid 가 없다"; return 1 }
  owner=$(vmq_owner) || return 1
  vmq_lock || return 1
  {
    vmq_sync $owner
    if vmq_holds $owner "$@"; then
      ok=1
      for vm in ${=Q_vms[$REPLY]}; do
        f="$VMQ_DIR/$vm/$REPLY"
        vmq_write $f "$(vmq_field $f owner)" "$(vmq_field $f label)" "$(vmq_field $f created)" "$(vmq_field $f need)" "$(vmq_field $f held)" $EPOCHSECONDS "$(vmq_field $f procs)" $chain
      done
      vmq_log "사슬 $owner ${Q_vms[$REPLY]} $chain"
    fi
  } always { vmq_unlock }
  (( ok ))
}
# 내가 잡은 차례에 적힌 사슬: vmq_chain_of <대상>… → 적힌 `<PID>@<시작 시각>` 을 찍는다(없으면 빈 줄). 차례가 없으면 1.
vmq_chain_of() {
  local owner ok=0 out=
  owner=$(vmq_owner) || return 1
  vmq_lock || return 1
  {
    vmq_sync $owner
    vmq_holds $owner "$@" && { ok=1; out=$(vmq_field ${Q_file[$REPLY]} chain) }
  } always { vmq_unlock }
  (( ok )) && print -r -- $out
}

# 차례를 쥔 프로세스가 제어 명령 없이 오래 기다리는 동안 부른다: vmq_keepalive. 이 소유자가 잡은 차례의 procs 에 이 셸($$)이 살아 있는
# 것으로 적혀 있을 때만 active(마지막 활동 확인)를 지금 시각으로 다시 적고 0, 아니면 1(아무것도 바꾸지 않는다). procs · chain 은 그대로 둔다.
# 소유자가 다르거나(다른 세션) 같은 소유자라도 vmq_require 로 차례에 적히지 않은 프로세스는 남의 차례를 늘리지 못한다.
# 부르는 간격은 VMQ_KEEPALIVE 초(VM_QUEUE_HOLD_MAX 의 1/6, 기본 600)다. 상한의 1/6 이라, 갱신이 다섯 번 잇달아 실패해야(차례표 잠금을
# 얻지 못함 등) 상한에 걸린다.
# 2026-10-28 에 VM 사슬의 한 단계(VM 안에서 조건을 보는 ssh 한 번, poieve car7gz 사슬의 waitc 3600초)가 제어 명령 없이 상한 3600초에 다가가,
# 사슬이 도는 중에 차례가 지워질 수 있었다(2026-10-16 bug_1792137322422_fwsach 와 같은 일, poieve task_1793209230273_b2regj). 사슬의 단계는
# 모두 poieve 의 chain_step 기다림 반복을 지나므로 그 반복 한 곳이 이 함수를 부른다. 부르는 프로세스가 끝나면 갱신도 멈춰 위 「만료」 규칙이 그대로
# 걸린다. 살아 있지만 멈춘 사슬은 chain_step 의 단계 한도가 끝내므로, 갱신이 이어지는 시간은 그 사슬에 적힌 단계 한도의 합을 넘지 않는다.
VMQ_KEEPALIVE=$(( VMQ_HOLD_MAX / 6 ))
vmq_keepalive() {
  [[ ${VM_QUEUE_INTERNAL:-} == 1 ]] && return 0
  local owner me vm f ok=0
  me=$(vmq_proc_id $$) || return 1
  owner=$(vmq_owner) || return 1
  vmq_lock || return 1
  {
    vmq_sync $owner
    if [[ -n $REPLY && -n ${Q_held[$REPLY]:-} ]] && vmq_has "$(vmq_procs_alive "$(vmq_field ${Q_file[$REPLY]} procs)")" $me; then
      ok=1
      for vm in ${=Q_vms[$REPLY]}; do
        f="$VMQ_DIR/$vm/$REPLY"
        vmq_write $f "$(vmq_field $f owner)" "$(vmq_field $f label)" "$(vmq_field $f created)" "$(vmq_field $f need)" "$(vmq_field $f held)" $EPOCHSECONDS "$(vmq_field $f procs)" "$(vmq_field $f chain)"
      done
    fi
  } always { vmq_unlock }
  (( ok ))
}

# 프로젝트 도구가 제어 명령 앞에서 부른다: vmq_require <대상>… 차례를 가졌으면 시각과 이 셸 프로세스($$)를 적고 0, 아니면 이유를
# stderr 에 쓰고 1. 적은 프로세스가 살아 있는 동안 차례는 만료되지 않는다(위 「만료」, 상한 VM_QUEUE_HOLD_MAX).
# 차례보다 먼저 부른 도구의 판을 본다(위 vmq_tool_current).
vmq_require() {
  [[ ${VM_QUEUE_INTERNAL:-} == 1 ]] && return 0
  local owner vm ok=0
  vmq_tool_current || return 1
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
