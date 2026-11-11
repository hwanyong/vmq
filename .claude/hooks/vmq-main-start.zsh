#!/bin/zsh
# SessionStart 훅(.claude/settings.json): 이름이 vmq-main 인 세션에 역할 지시문 VMQ-MAIN.md 전문을 additionalContext 로 넣는다.
# startup · resume · /clear · compact 모두 돈다. /clear 는 대화를 비우지만 이 훅이 다시 넣으므로 역할이 남는다.
# 판정 차례:
#   ① 이 세션의 이름은 stdin 의 session_title(-n 으로 연 시작), 없으면 claude agents --json 에서 pid 가 CLAUDE_PID 인 줄의 name.
#      vmq-main 이 아니면 아무것도 하지 않는다. cwd 는 보지 않는다. mod vmq-view 와 다른 세션의 SendMessage 는 이름으로 이 세션을
#      찾으므로, vmq-main 이 worktree 로 작업 폴더를 옮긴 채 /clear · compact 해도 역할을 넣어야 한다. 그래서 문서도 어느 사본의
#      훅이 돌든 main 체크아웃(~/.claude/tools/vmq)의 것을 읽는다.
#   ② 이 세션보다 먼저 시작한(startedAt 이 작은) vmq-main 이 claude agents --json 에 있으면 역할 지시문 대신 경고만 넣는다.
#      같은 이름이 둘이면 다른 세션이 이름만으로 보낼 수 없고 mod vmq-view 가 두 세션 모두에 판정 프롬프트를 넣는다.
#      먼저 연 세션은 나중 세션이 있는 동안 /clear · compact 해도 역할을 그대로 받는다.
#      이름은 바꾸지 않는다. 2026-11-11 시험에서 출력 sessionTitle 은 대화 기록의 customTitle 만 바꾸고 claude agents --json ·
#      ListAgents 의 name 은 -n 으로 준 값 그대로였다. 중복을 막는 것은 bin/vmq-main 의 거절이다.
# 권한 모드는 보지 않는다. 2026-11-11 에 잰 SessionStart 입력에 permission_mode 칸이 없었다. 모드는 bin/vmq-main 이 정한다.
# 출력은 hookSpecificOutput JSON 한 개(stdout). 판정할 수 없으면(CLAUDE_PID 가 수가 아님, claude · jq 실패, 목록에 이 세션이 없음,
# 문서를 읽지 못함) 아무것도 찍지 않고 종료 코드 0. 그때는 bin/vmq-main 의 첫 프롬프트가 문서가 없음을 사용자에게 알리게 한다.
set -uo pipefail

readonly name=vmq-main
readonly home_repo=$HOME/.claude/tools/vmq
readonly doc=$home_repo/VMQ-MAIN.md
# 세션을 가리키는 값: background 세션이면 claude attach · stop 이 받는 id, 아니면 session id.
readonly ref='"\(.id // .sessionId) pid \(.pid)"'

input=$(cat)
[[ ${CLAUDE_PID:-} == <-> ]] || exit 0
agents=$(claude agents --json) || exit 0
self=$(print -r -- "$agents" | jq -c --argjson pid $CLAUDE_PID 'first(.[] | select(.pid == $pid)) // empty') || exit 0
[[ -n $self ]] || exit 0

title=$(print -r -- "$input" | jq -r '.session_title // empty' 2>/dev/null)
[[ -n $title ]] || title=$(print -r -- "$self" | jq -r '.name // empty') || exit 0
[[ $title == $name ]] || exit 0

started=$(print -r -- "$self" | jq -r '.startedAt | numbers') || exit 0
[[ -n $started ]] || exit 0
other=$(print -r -- "$agents" | jq -r --arg name $name --argjson pid $CLAUDE_PID --argjson started $started \
  "first(.[] | select(.name == \$name and .pid != null and .pid != \$pid and (.startedAt | type) == \"number\" and .startedAt < \$started)) | $ref") || exit 0
if [[ -n $other ]]; then
  jq -n --arg name $name --arg other "$other" --arg self "$(print -r -- "$self" | jq -r $ref)" '{hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: "이름이 \($name) 인 세션이 이 세션보다 먼저 열려 있다(\($other)). 그래서 SessionStart 훅 .claude/hooks/vmq-main-start.zsh 가 이 세션(\($self))에 역할 지시문 VMQ-MAIN.md 를 넣지 않았다. 이 세션은 \($name) 역할을 맡지 않고 [vmq-view] 프롬프트도 처리하지 않는다. 첫 답변에서 사용자에게 알린다: 같은 이름의 세션이 둘이라 다른 세션이 이름만으로 보낼 수 없고 mod vmq-view 가 두 세션 모두에 판정 프롬프트를 넣으므로 이 세션을 닫아야 한다(background 세션이면 claude stop 에 이 세션의 id). 먼저 연 세션은 claude attach 에 그 세션의 id 를 주어 연다."
  }}'
  exit 0
fi

[[ -r $doc ]] || exit 0
jq -n --rawfile doc $doc '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $doc}}'
