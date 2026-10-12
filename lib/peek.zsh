# 차례 없는 읽기(전역 규약 §18, ~/.claude/tools/vmq/README.md). 프로젝트의 도구가 source 하고, 대상에서 명령을 실행하기 전에
# peek_allowed 로 판별한다(예: poieve 의 tools/vm.sh peek). 판별만 하려면 `vmq peek-check '<명령 한 줄>'`.
# 2026-10-12 사용자 지시 「VM의 ssh 명령을 할 때 무조건 큐에 넣을 필요는 없잖아? 즉석으로 확인 가능한 것은 바로 실행해도 되니까 이러한
# 항목은 큐에 등록하지 않고 바로 실행할 수 있도록 판별해서」. VM 의 상태를 바꾸지 않는 명령만 차례 없이 실행한다. 판별은 부르는 쪽의
# 판단에 맡기지 않고 아래 목록으로 한다(전역 규약 §18 ②: 규칙을 아는 쪽의 준수에 기대지 않는다). 목록에 없는 명령은 거절하고
# 차례를 받아 실행하게 한다.
#
# 명령 한 줄은 `|` 로 이은 단계들이다. 단계마다 첫 낱말이 PEEK_COMMANDS 에 있어야 하고, 그 명령의 인자 규칙(peek_args)을 지켜야 한다.
# 첫 낱말은 이름이나 시스템 폴더(PEEK_SYSTEM_DIRS)의 절대 경로다. 그 밖의 절대 경로는 목록의 이름이어도 받지 않는다.
# `log` 는 이름으로 받지 않고 `/usr/bin/log` 로만 받는다(PEEK_SHELL_BUILTINS): 대상의 셸이 zsh 라 이름으로 부르면 zsh 의 내장 명령
# log(로그인 감시)가 불려 `zsh:log:1: too many arguments` 로 끝난다(2026-10-12, poieve `tools/vm.sh peek PoieveServer 'log show …'` 의
# 종료 코드 1). 전에는 판별은 통과하고 실행은 늘 실패했다.
# `;` · `&` · `>` · `<` · 역따옴표 · `$(` · 줄바꿈은 받지 않는다(명령을 잇거나 파일에 쓰거나 다른 명령을 끼워 넣는 문법이다). sudo 는
# 목록에 없다. 화면 캡처 · cua-driver 는 읽기여도 다른 소유자가 조작하는 도중의 화면이라 차례 안에서 한다(§18).

typeset -ga PEEK_COMMANDS=(
  cat head tail ls stat readlink realpath file wc grep egrep fgrep cut sort uniq tr awk
  pgrep ps lsof netstat df du sw_vers scutil uname id whoami date uptime hostname
  defaults launchctl log sqlite3 plutil mdls xattr shasum md5 find sysctl codesign pluginkit system_profiler ioreg sw_vers
)

# 첫 낱말을 절대 경로로 적을 때 받는 폴더. 목록의 명령이 macOS 에서 있는 곳이다.
typeset -ga PEEK_SYSTEM_DIRS=(/usr/bin /bin /usr/sbin /sbin)

# 이름으로 부르면 대상의 zsh 에서 같은 이름의 내장 명령이 불리는 것. 시스템 폴더의 절대 경로로만 받는다.
typeset -ga PEEK_SHELL_BUILTINS=(log)

# 인자 규칙: peek_args <명령> <인자…>. 위반이면 이유를 stderr 에 쓰고 1.
peek_args() {
  local c=$1 a; shift
  case $c in
  defaults) [[ ${1:-} == (read|read-type|domains|find) ]] || { print -u2 "defaults 는 read · read-type · domains · find 만"; return 1 } ;;
  launchctl) [[ ${1:-} == (print|list|print-disabled|blame|managername|manageruid) ]] || { print -u2 "launchctl 은 print · list · print-disabled · blame 만"; return 1 } ;;
  log) [[ ${1:-} == show ]] || { print -u2 "log 는 show 만"; return 1 } ;;
  scutil) [[ ${1:-} == --get ]] || { print -u2 "scutil 은 --get 만"; return 1 } ;;
  plutil) [[ ${1:-} == (-p|-lint) ]] || { print -u2 "plutil 은 -p · -lint 만"; return 1 } ;;
  pluginkit) [[ ${1:-} == -m* ]] || { print -u2 "pluginkit 은 -m 만"; return 1 } ;;
  awk) for a in "$@"; do [[ $a == *(system|getline|'print >'|'printf >'|'| '|fflush)* ]] && { print -u2 "awk 의 system · getline · 출력 돌리기는 받지 않는다"; return 1 }; done ;;
  sqlite3)
    (( ${@[(Ie)-readonly]} )) || { print -u2 "sqlite3 는 -readonly 를 붙인다"; return 1 }
    for a in "$@"; do [[ ${a:l} == *(.shell|.system|.output|.once|.import|.save|.backup|.restore|.load|.open|.cd|load_extension|attach|vacuum|pragma)* ]] && { print -u2 "sqlite3 의 그 명령은 받지 않는다: $a"; return 1 }; done ;;
  find) for a in "$@"; do [[ $a == (-delete|-exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls) ]] && { print -u2 "find 의 $a 는 받지 않는다"; return 1 }; done ;;
  xattr) for a in "$@"; do [[ $a == -*[wdcs]* ]] && { print -u2 "xattr 는 읽기(-l · -p · -x)만"; return 1 }; done ;;
  sysctl) for a in "$@"; do [[ $a == -w || $a == *=* ]] && { print -u2 "sysctl 은 읽기만"; return 1 }; done ;;
  codesign) for a in "$@"; do [[ $a == (-s|--sign|-f|--force|--remove-signature) ]] && { print -u2 "codesign 은 -d · -v 만"; return 1 }; done ;;
  sort) for a in "$@"; do [[ $a == (-o*|--output*) ]] && { print -u2 "sort 의 -o 는 받지 않는다"; return 1 }; done ;;
  esac
  return 0
}

# 명령 한 줄이 차례 없이 실행해도 되는 읽기인가: peek_allowed <명령 한 줄>
peek_allowed() {
  local line=$1 seg w name
  [[ -n ${line//[[:space:]]/} ]] || { print -u2 "명령이 없다"; return 1 }
  if [[ $line == *[\;\&\<\>\`$'\n']* || $line == *'$('* ]]; then
    print -u2 "명령을 잇거나 파일에 쓰는 문법(; & > < 역따옴표 \$( 줄바꿈)은 받지 않는다"; return 1
  fi
  for seg in "${(@s:|:)line}"; do
    w=(${(Q)${(z)seg}})
    (( ${#w} )) || { print -u2 "빈 단계가 있다(|| 등)"; return 1 }
    name=${w[1]}
    if [[ $name == /* ]]; then
      (( ${PEEK_SYSTEM_DIRS[(Ie)${name:h}]} )) || { print -u2 "절대 경로는 ${PEEK_SYSTEM_DIRS} 의 명령만 받는다: $name"; return 1 }
      name=${name:t}
    elif (( ${PEEK_SHELL_BUILTINS[(Ie)$name]} )); then
      print -u2 "대상의 zsh 에서 같은 이름의 내장 명령이 불리는 명령: $name. 절대 경로로 적는다(예: /usr/bin/$name)"; return 1
    fi
    (( ${PEEK_COMMANDS[(Ie)$name]} )) || { print -u2 "차례 없이 실행할 수 없는 명령: ${w[1]} (읽기 목록: ${PEEK_COMMANDS})"; return 1 }
    peek_args $name "${(@)w[2,-1]}" || return 1
  done
}
