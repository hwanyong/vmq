# vmq: 세션 여럿이 함께 다루는 VM · 장치의 제어 큐

전역 규약 `~/.claude/CLAUDE.md` §18 의 도구다. 2026-10-12 사용자 지시 「Vm 운영 방법은글로벌 규칙과 툴로 적용해줘 그래야 다양한 업무를 동시 다발로 할 수 있으니까」로 poieve 의 `CloudLLM-Claude-code/tools` 에서 이 폴더로 옮겼다(그 저장소 커밋 `01ba392` · `e5e2b60` · `b787e7b` 가 처음 구현).

이 문서의 `vmq` 는 `~/.claude/tools/vmq/bin/vmq` 다(PATH 에 넣지 않았다).

## 파일

| 경로 | 무엇 |
|---|---|
| `resources.tsv` | 대상 목록. 줄마다 `<이름>` · `<그 대상이 있는 Mac 의 SSH 주소>` · `<역할, 쉼표로>`(탭). 이 Mac 에 하나뿐이고, 대상을 더하거나 지우면 이 파일만 고친다 |
| `bin/vmq` | 명령. `vmq help` 가 사용법을 찍는다 |
| `lib/vmq.zsh` | 큐 · 배정 · `vmq_require`. 프로젝트 도구가 `source` 한다 |
| `lib/peek.zsh` | 차례 없는 읽기의 판별(`peek_allowed`). 프로젝트 도구가 `source` 한다 |
| `tests/stress.zsh` · `tests/peek.zsh` | 회귀 시험(아래 「시험」) |
| `~/Library/Application Support/vmq/queue/` | 차례표 · `log`. 로컬 디스크에 둔다(SMB 에서는 원자적 `mkdir` 을 믿지 않는다). poieve 의 옛 경로 `~/Library/Application Support/Poieve-CloudLLM-VM/queue` 는 2026-10-12 01:31 에 이곳을 가리키는 심볼릭 링크로 바꿨다 |

## 규칙

| 항목 | 정한 것 |
|---|---|
| 차례 | 대상을 바꾸는 명령(켜기 · 끄기 · 스냅숏 · 되돌리기 · 설치 · 화면 조작 · 화면 캡처 · 시험 실행)은 그 대상의 차례를 잡은 소유자만 실행한다. 대상을 다루는 프로젝트 도구가 제어 명령 앞에서 `vmq_require <대상>…` 를 부르고, 차례가 없으면 아무것도 하기 전에 종료 코드 1 로 거절한다 |
| 소유자 | `VM_QUEUE_OWNER`, 없으면 Claude Code 의 `CLAUDE_CODE_SESSION_ID`. 하위 에이전트(Agent 도구)는 부모의 세션 ID 를 물려받으므로 따로 대상을 다루면 `VM_QUEUE_OWNER` 를 따로 정한다 |
| 요청 | `vmq acquire [-w 초] [-l 설명] <묶음>…`. 묶음마다 대상 하나를 받는다. 묶음은 이름 · 쉼표로 적은 후보(`A,B`) · 역할(`@server`) 중 하나다. 후보 중 먼저 비는 대상을 받는다. 받을 대상을 한꺼번에 잡으므로 하나를 잡은 채 다른 것을 기다리는 일(교착)이 없다. 잡은 뒤 더 받으려면 놓고 함께 다시 받는다 |
| 배정 | 기다리는 차례를 일련번호 순으로 보며 묶음마다 빈 후보를 고른다. 채워지지 않은 차례는 건너뛰어, 앞 차례가 다른 대상을 기다리는 동안 뒤 차례가 빈 대상을 쓴다. 등록에서 `VM_QUEUE_STARVE` 초(기본 1800)가 지난 차례는 자기 후보 중 빈 대상을 맡아 둔다 |
| 요청 바꾸기 | 기다리는 동안 다른 묶음으로 `acquire` 를 다시 실행하면 같은 순번으로 요청이 바뀐다(「바꿈」). 큐의 항목을 다른 대상으로 옮길 때 쓴다 |
| 기다림 · 만료 | `acquire` 가 `-w` 초 안에 못 잡으면 종료 코드 75 이고 차례는 남는다. 같은 명령을 다시 실행해 이어서 기다린다. 마지막 활동에서 `VM_QUEUE_LEASE` 초(기본 1200) 동안 활동이 없는 차례는 지워진다 |
| 받은 대상 | 「잡음」 줄, `vmq mine`(묶음 순서), `vmq run … -- <명령>` 의 환경 변수 `VM_QUEUE_GRANTED` |
| 차례 없는 읽기 | 상태만 읽는 명령(프로세스 · 파일 · 로그 · 설정 · DB 값)은 차례 없이 실행한다. 읽기인지는 `lib/peek.zsh` 의 목록(명령 · 인자 규칙)이 판별하고, 명령을 잇거나 파일에 쓰는 문법(`;` · `&` · `>` · `<` · 역따옴표 · `$(` · 줄바꿈)과 목록 밖의 명령은 대상에 접속하기 전에 거절한다. 첫 낱말은 이름이나 `/usr/bin` · `/bin` · `/usr/sbin` · `/sbin` 의 절대 경로이고, 그 밖의 절대 경로는 거절한다. `log` 는 `/usr/bin/log` 로만 받는다. 대상의 셸이 zsh 라 이름으로 부르면 zsh 의 내장 명령 `log` 가 불려 `zsh:log:1: too many arguments` 로 끝난다(2026-10-12 까지는 판별이 이름을 받고 실행은 늘 실패했다). 다른 소유자가 잡은 대상에서 읽은 값은 그 소유자가 다루는 도중의 상태이므로 시험 근거로 쓰지 않는다 |
| 기록 | 등록 · 바꿈 · 잡음 · 놓음 · 만료 · 강제로 놓음을 차례표의 `log` 에 한 줄씩 남긴다. 프로젝트 도구가 되돌림 같은 상태 변화를 `vmq_log` 로 더한다 |

## 프로젝트에 붙이는 법

1. 대상을 `resources.tsv` 에 적는다. 프로젝트를 가리키는 역할(예: `poieve`)을 하나 붙여 두면 프로젝트 도구가 `vmq_with_role <역할>` 로 자기 대상만 고른다.
2. 대상을 다루는 스크립트가 `source ~/.claude/tools/vmq/lib/vmq.zsh` 하고 제어 명령 앞에서 `vmq_require <대상>… || exit 1`. 시작할 때 쓸 대상을 모두 확인하면 도중에 거절되어 대상이 반쯤 바뀐 채 남지 않는다.
3. 차례 없는 읽기 명령을 둘 때는 `source ~/.claude/tools/vmq/lib/peek.zsh` 하고 접속하기 전에 `peek_allowed "<명령 한 줄>"`.
4. 다른 Mac 에서 자기를 다시 실행하는 스크립트는 그 실행에 `VM_QUEUE_INTERNAL=1` 을 붙인다(이 Mac 에서 이미 확인한 명령의 일부라서). 이 도구는 차례표가 있는 Mac 에만 있으므로 다른 Mac 쪽에서는 `lib/*.zsh` 를 source 하지 않는다. 필요한 대상 목록은 부르는 쪽이 환경 변수로 넘긴다(poieve 는 `VMQ_HOST_LIST`, `tools/lib/common.zsh` 의 `vm_remote_env`). 다른 Mac 에 목록을 따로 두지 않는다. 원본이 둘이 된다. 2026-10-12 에 이것을 빠뜨려 Mac mini 에서 다시 실행한 `tools/vm.sh` 가 종료 코드 127 로 끝났다(poieve 커밋 `cfe273c`, 고친 커밋 `835b4da`).
5. 시험 결과에는 그 대상에 설치된 빌드의 식별값(커밋 · 커밋하지 않은 변경 · 실행 파일 해시)을 함께 적는다. 대상이 여럿이면 대상마다 빌드가 다를 수 있다(전역 규약 §18). poieve 의 구현은 `CloudLLM-Claude-code/tools/build.sh` · `vm_install_app`(빌드 표지)이다.

첫 적용: poieve `CloudLLM-Claude-code/tools/lib/common.zsh`(대상 목록에서 `VM_HOST`), `tools/vm.sh`(`vmq_require` · `peek`), `tools/vm-queue.sh`(이 명령을 부르는 입구).

## 하위 세션 지시문에 넣을 것

- 대상을 다루기 전에 `vmq acquire -w 300 -l "<설명>" <묶음>…`(Bash timeout 330000 이상), 75 면 다시 실행. 끝나면 `vmq release`. 상태는 `vmq status`.
- 대상의 이전 상태에 기대지 않는 일은 역할(`@server`)로 받고, 기대는 일은 이름으로 받는다.
- 상태 확인은 프로젝트의 차례 없는 읽기 명령(poieve 는 `tools/vm.sh peek`)으로 한다.
- 결과에는 빌드 식별값 줄을 적는다.
- 「부모의 메시지를 기다려라」 같은 말로 순서를 정하지 않는다. 그 말은 도구가 막지 않는다.

## 시험

차례표를 실제 것과 따로 두고 돌린다(`VM_QUEUE_DIR`).

| 시험 | 명령 | 2026-10-12 01:30 결과 |
|---|---|---|
| 동시 실행 | `tests/stress.zsh ~/.claude/tools/vmq/bin/vmq /tmp/q /tmp/s.out` | 대상마다 최대 동시 1. 배정에서 「잡거나 배정된 대상은 고르지 않는다」 줄을 지운 복사본은 `PoieveServer` 최대 5 · `PoieveClient` 최대 2 |
| 읽기 판별 | `tests/peek.zsh` | 42가지 모두 맞음(01:21). 같은 날 `system_profiler` · `ioreg` 를 읽기 목록에 더한 뒤 44가지 모두 맞음. `peek_allowed` 가 늘 통과하는 복사본(poieve 커밋 `b787e7b` 때)은 28가지를 잘못 통과. 02:16 에 절대 경로 · `log` 규칙을 더한 뒤 51가지(읽기 18 · 거절 33) 모두 맞음. 시스템 폴더 검사를 뺀 복사본은 `/tmp/cat x` · `/usr/bin/../../tmp/log show` 를, `PEEK_SHELL_BUILTINS` 를 비운 복사본은 `log show --last 1m` 을 잘못 통과. 이때 동시 실행 시험도 다시 돌려 대상마다 최대 동시 1. poieve `tools/vm.sh peek PoieveServer "/usr/bin/log show …"` 는 VM 에서 실행되어 종료 코드 0, `'log show --last 1m'` 은 접속 전에 종료 코드 1 |
| 옛 형식 차례표 · 후보 · 바꿈 · 놓음 · 모르는 대상 · 역할 | 실제 차례표의 복사본으로 `acquire` · `release` · `vmq_require` | 옛 차례가 새 형식으로 이어지고, `@server` 가 빈 `PoieveServer2` 를 받고, 바꿈이 순번을 지키고, 모르는 이름 · 역할은 종료 코드 1 |

큐나 판별을 바꾸면 위 두 시험을 다시 돌리고, 바꾼 자리를 일부러 깬 복사본에서 시험이 실패하는 것을 본 뒤 복사본을 지운다(전역 규약 §8 ③).
