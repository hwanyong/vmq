# vmq: Claude Code 세션 여럿이 함께 다루는 VM · 장치의 제어 큐

[English](README.md)

Claude Code 세션 여럿이 같은 시험 VM · 장치 · 앱 창을 다루면 한 세션의 클릭 · 키 입력 · 스냅숏 되돌리기가 다른 세션의 시험을 깨뜨립니다. vmq 는 그런 대상의 큐입니다. 세션은 대상의 차례를 받고, 그 대상을 다루고, 차례를 놓습니다. 대상을 다루는 스크립트가 제어 명령마다 `vmq_require` 를 부르므로 차례가 없는 세션은 아무것도 하기 전에 거절됩니다.

plugin 은 네 부분으로 되어 있습니다.

| 부분 | 경로 | 하는 일 |
|---|---|---|
| CLI | `bin/vmq` | `acquire` · `release` · `run` · `status` 등. plugin 이 켜져 있는 동안 Bash 도구의 PATH 에 있습니다 |
| 셸 라이브러리 | `lib/vmq.zsh` · `lib/peek.zsh` | 프로젝트 스크립트가 쓰는 `vmq_require` · `vmq_keepalive` · `vmq_ssh` · `peek_allowed` |
| mod | `hooks/register.tsx` | 큐를 status line · pane(`/vmq`) · toast 에 보이고, 세션 `vmq-main` 을 열고 판정을 넘깁니다 |
| 스킬 | `skills/queue/SKILL.md` | 모든 세션에 규칙을 알립니다: 함께 쓰는 대상을 다루기 전에 차례를 받는다 |

## 요구 사항

- macOS(큐가 `~/Library/Application Support` 에 있고, `nc -G` 는 BSD `nc` 의 선택 사항입니다)
- zsh, `jq`
- plugin hooks 모듈(mod)과 plugin `bin/` 의 PATH 등록을 지원하는 Claude Code. 2.1.332 에서 시험했습니다

## 설치

Claude Code 안에서:

```
/plugin marketplace add hwanyong/vmq
/plugin install vmq@vmq
```

또는 셸에서:

```sh
claude plugin marketplace add hwanyong/vmq
claude plugin install vmq@vmq --scope user
```

그다음 세션들이 함께 쓰는 대상을 등록합니다(아래 「대상」). Claude 에게 말로 요청하면(「이 Mac 의 시험 VM TestServer · TestClient 를 등록해 줘. 역할은 server · client」) 스킬 `vmq:queue` 가 명령을 실행합니다. 직접 실행해도 됩니다.

```sh
vmq init
vmq target add TestServer localhost server,myproject macOS
vmq target add TestClient localhost client,myproject macOS
vmq list
```

대상이 하나도 없는 동안 status line 은 `vmq: no targets yet` 을 보이고 `vmq-main` 은 열리지 않습니다.

## 대상

대상 목록은 `~/Library/Application Support/vmq/resources.tsv`(`VMQ_REGISTRY`)입니다. 파일을 직접 고치지 않고 아래 명령으로 바꿉니다. 명령은 값을 검사하고, 이미 있는 이름을 거절하고, 차례가 쥐거나 기다리는 대상은 지우지 않고, 바꾼 내용을 큐 로그에 적습니다.

| 명령 | 하는 일 |
|---|---|
| `vmq init` | 데이터 폴더와 빈 대상 목록을 만듭니다(없을 때만) |
| `vmq target add <이름> <mac> <역할> <운영체제>` | 대상을 더합니다(목록이 없으면 만듭니다) |
| `vmq target remove <이름>` | 쥐거나 기다리는 차례가 없는 대상을 지웁니다 |
| `vmq list` | 대상 목록을 찍습니다 |

대상을 바꾸려면 지운 뒤 새 값으로 다시 더합니다.

| 값 | 규칙 | 예 |
|---|---|---|
| 이름 | 영문 · 숫자 · `. _ -`. 차례가 이 이름 아래에 저장되므로 바꾸지 않습니다 | `TestServer` · `Pixel8` · `MiniDesktop` |
| mac | 그 대상이 있는 Mac 의 SSH 주소, 또는 이 Mac 을 가리키는 아무 이름(`localhost`). 값이 같은 대상은 `@server+@client` 에서 같은 Mac 으로 봅니다 | `localhost` · `mac-mini.local` |
| 역할 | `,` 로 이은 낱말, 없으면 `-`. 역할은 같은 일을 할 수 있는 대상들의 이름입니다: `vmq acquire @server` 는 그 가운데 먼저 비는 것을 줍니다. 프로젝트 이름을 역할로 붙이면 그 프로젝트의 스크립트가 자기 대상을 고릅니다(`vmq_with_role myproject`) | `server,myproject` |
| 운영체제 | 그 대상 안에서 도는 운영체제: `macOS` · `Windows` · `Linux`, 없으면 `-` | `macOS` |

말로 요청하는 방법은 스킬(`skills/queue/SKILL.md` 의 「Adding and removing targets」 절)이 처리합니다. Claude 가 네 가지 값을 모으고, 요청에서 알 수 없는 값은 사용자에게 묻고, `vmq target add` 를 실행한 뒤 `vmq list` 를 보입니다.

빌드 차례는 운영체제가 없는 대상입니다. 빌드를 동시에 두 개까지만 돌리려면 같은 역할의 차례 두 개를 더하고 빌드를 큐를 거쳐 실행합니다.

```sh
vmq target add Build1 localhost build -
vmq target add Build2 localhost build -
vmq run @build -- make
```

`hosts.tsv`(선택, 같은 폴더)는 Mac 하나의 주소를 여러 개 적어 앞부터 시도합니다. 직결 링크와 LAN 양쪽으로 접속되는 Mac 에 씁니다. 형식은 `examples/hosts.tsv` 입니다.

## 설정

### plugin 선택 사항

설치할 때 정하거나 나중에 `/config` 의 vmq plugin 항목에서 바꿉니다.

| 선택 사항 | 기본값 | 하는 일 |
|---|---|---|
| `autoStartMain` | 켬 | 세션이 시작될 때 대상 목록에 대상이 있고 살아 있는 `vmq-main` 세션이 없으면 mod 가 `bin/vmq-main --if-absent` 로 background 세션을 엽니다. 그 세션은 권한 모드 `bypassPermissions` 로 돌고, 쥔 프로세스가 끝난 차례에 `vmq force-release` 를 실행할 수 있습니다(아래 「세션 vmq-main」). 끄면 `/vmq-main` 으로 직접 엽니다 |

`autoStartMain` 이 켜져 있으면 `vmq-main` 을 멈춰도 다음 세션이 시작될 때 다시 열립니다. 계속 닫아 두려면 이 선택 사항을 끕니다.

### 환경 변수

CLI 와 라이브러리가 읽습니다. Claude Code 안에서 `bin/vmq` 를 실행하는 mod 에는 `~/.claude/settings.json` 의 `env` 에, 프로젝트 스크립트에는 그 스크립트의 환경에 정합니다.

| 변수 | 기본값 | 뜻 |
|---|---|---|
| `VMQ_DATA` | `~/Library/Application Support/vmq` | 데이터 폴더: 대상 목록 · 큐 · 예약 |
| `VMQ_REGISTRY` | `$VMQ_DATA/resources.tsv` | 대상 목록 |
| `VMQ_HOSTS_FILE` | `$VMQ_DATA/hosts.tsv` | Mac 마다 더 시도할 SSH 주소 |
| `VM_QUEUE_DIR` | `$VMQ_DATA/queue` | 큐. 로컬 디스크에 둡니다. 잠금이 `mkdir` 이고, SMB 에서는 `mkdir` 이 원자적이라고 믿지 않습니다 |
| `VM_QUEUE_LEASE` | 1200 | 마지막 활동에서 차례가 유지되는 초 |
| `VM_QUEUE_HOLD_MAX` | 3600 | 쥔 프로세스가 살아 있을 때 마지막 제어 명령에서 차례가 유지되는 초 |
| `VM_QUEUE_STARVE` | 1800 | 기다리는 차례가 자기 후보 중 빈 대상을 맡아 두기 시작하는 초 |
| `VM_QUEUE_OWNER` | `CLAUDE_CODE_SESSION_ID` | 소유자 이름(영문 · 숫자 · `. _ -`). 따로 대상을 다루는 하위 에이전트에는 따로 줍니다 |
| `VM_QUEUE_LABEL` | 없음 | 차례의 설명. `-l` 과 같습니다 |
| `VM_QUEUE_TICKET` | 없음 | `vmq_require` · `vmq release` 등을 차례 키 하나(`vmq ticket`)에 고정합니다 |
| `VM_QUEUE_INTERNAL` | 없음 | `1` 이면 검사를 건너뜁니다. 다른 Mac 에서 자기를 다시 실행하는 도구가 씁니다 |
| `VMQ_SSH_RETRY_S` | 30 | 배너 교환에서 끝난 연결을 `vmq_ssh` 가 다시 시도하는 초 |
| `VMQ_REQUIRED_REF` | `main` | `.vmq-required` 를 읽는 브랜치(「규칙」) |

## 명령

| 명령 | 하는 일 |
|---|---|
| `vmq acquire [-w 초] [-l 설명] <묶음>…` | 묶음마다 후보 하나를 받습니다. 기본 90초 기다리고, 종료 코드 75 는 아직 기다리는 중입니다(다시 실행합니다) |
| `vmq release [<대상>…]` | 내 차례를 놓습니다. 대상을 주면 그 대상만 놓습니다 |
| `vmq run [-l 설명] <묶음>… -- <명령…>` | 차례를 받아 `VM_QUEUE_GRANTED` 와 함께 명령을 실행하고 놓습니다(TERM · INT · HUP 에도 놓습니다) |
| `vmq status [--json] [<대상>…]` | 대상마다 잡은 소유자와 기다리는 소유자 |
| `vmq mine` · `vmq ticket` | 내가 잡은 대상 · 내 차례 키 |
| `vmq ended <대상>` | 그 대상에서 내 마지막 차례가 끝난 사건(`released` · `expired` · `force-released`) · 시각 · 그 뒤 잡은 소유자 |
| `vmq force-release <대상>` | 그 대상을 잡은 차례를 지웁니다. 사용자가 지시할 때, 또는 쥔 프로세스가 끝난 차례에 `vmq-main` 이 씁니다 |
| `vmq list` · `vmq init` · `vmq target add` · `vmq target remove` | 대상 목록(「대상」) |
| `vmq peek-check '<명령 한 줄>'` | 차례 없이 실행해도 되는 읽기인지 판별합니다 |
| `/vmq` · `/vmq-main` | pane 을 엽니다 · `vmq-main` 세션을 엽니다 |

묶음은 대상 이름, 쉼표로 적은 후보(`Server1,Server2`), 역할(`@server`), `+` 로 이어 함께 받는 대상(`Server2+Client2`) 가운데 하나입니다. `@server+@client` 는 같은 Mac 의 서버 · 클라이언트를 받습니다. 종료 코드: 0 완료, 1 거절 · 오류, 2 사용법, 75 기다리는 중.

## 프로젝트 스크립트에 붙이는 법

대상을 다루는 스크립트는 라이브러리를 source 하고 제어 명령마다 `vmq_require` 를 부릅니다.

```zsh
source "${VMQ_HOME:-$(dirname "$(command -v vmq)")/..}/lib/vmq.zsh"
vmq_require TestServer || exit 1
# ... TestServer 를 다룹니다 ...
```

`command -v vmq` 는 Claude Code 세션이 연 셸에서 됩니다(plugin 의 `bin/` 이 PATH 에 있습니다). 그 밖에서는 `VMQ_HOME` 에 plugin 폴더를 줍니다.

1. 시작할 때 쓸 대상 전부로 `vmq_require <대상>…` 를 부릅니다. 그러면 도중에 거절되어 대상이 반쯤 바뀐 채 남지 않습니다. 스크립트의 프로세스가 살아 있는 동안 그 차례는 마지막 제어 명령에서 `VM_QUEUE_HOLD_MAX` 초까지 만료되지 않습니다.
2. 제어 명령 없이 오래 기다리는 단계는 600초마다 `vmq_keepalive` 를 부릅니다. 시작에서 한 번만 `vmq_require` 를 부르는 스크립트는 긴 단계 사이에 `vmq_keepalive_or_exit` 를 불러, 차례를 잃으면 끝나게 합니다.
3. 차례 없이 실행할 읽기 명령은 접속하기 전에 `source .../lib/peek.zsh` 와 `peek_allowed "<명령 한 줄>"` 로 판별합니다.
4. 다른 Mac 에서 자기를 다시 실행하는 스크립트는 그 실행에 `VM_QUEUE_INTERNAL=1` 을 줍니다. 검사는 이 Mac 에서 이미 했고, 큐는 이 Mac 에만 있습니다.
5. `vmq_ssh <주소> …` 는 `VMQ_SSH_BASE`(BatchMode · ConnectTimeout 5 · ServerAlive 15 × 4)와 `hosts.tsv` 의 주소로 ssh 를 실행하고, 배너 교환 시간 초과는 새 연결로 다시 시도합니다.

## 규칙

| 항목 | 규칙 |
|---|---|
| 차례 | 대상을 바꾸는 명령(켜기 · 끄기 · 스냅숏 · 되돌리기 · 설치 · 화면 조작 · 화면 캡처 · 시험 실행)은 그 대상의 차례를 잡은 소유자만 실행합니다. 프로젝트 도구가 명령마다 `vmq_require <대상>…` 를 부르고, 거절되면 종료 코드 1 로 끝납니다 |
| 요청 | 소유자마다 요청 하나입니다. 묶음마다 대상 하나를 받고, 후보 가운데 먼저 비는 것을 받고, `+` 로 이은 후보는 그 대상이 모두 빌 때 받습니다. 대상을 한꺼번에 받으므로 하나를 쥔 채 다른 것을 기다리는 일(교착)이 없습니다. 잡은 뒤 더 받으려면 놓고 함께 다시 받습니다. 기다리는 동안 다른 묶음으로 `acquire` 하면 같은 일련번호로 요청이 바뀝니다 |
| 배정 | 기다리는 차례를 일련번호 순으로 보며 묶음마다 빈 후보를 고릅니다. 채워지지 않는 차례는 건너뛰므로 뒤 차례가 빈 대상을 씁니다. `VM_QUEUE_STARVE` 보다 오래 기다린 차례는 자기 후보 중 빈 대상을 맡아 둡니다 |
| 만료 | `VM_QUEUE_LEASE` 초 동안 활동이 없는 차례는 지워집니다. `vmq_require` 는 부른 셸의 PID 와 시작 시각을 차례에 적고, 그 프로세스가 살아 있는 동안은 마지막 제어 명령 또는 `vmq_keepalive` 에서 `VM_QUEUE_HOLD_MAX` 초까지 차례를 지우지 않습니다. 시작 시각은 `LC_ALL=C TZ=UTC` 로 읽으므로 다시 쓰인 PID 를 살아 있는 것으로 보지 않습니다 |
| 끝난 사슬 | 사슬은 차례를 한 번 받아 대상을 다루고 끝나는 셸입니다. `vmq_chain_mark <pid> <대상>…` 가 그 셸을 차례에 적습니다. 사슬이 끝난 차례는 그 뒷정리가 놓거나 만료될 때까지 같은 소유자의 다음 `acquire` 에도 넘기지 않으므로, 뒷정리가 다음 사슬의 대상을 다루지 않습니다 |
| 차례 고정 | `VM_QUEUE_TICKET=<키>` 를 주면 `vmq_require` · `vmq_keepalive` · `vmq_chain_of` · `vmq_chain_mark` · `vmq release` · `vmq mine` 이 그 차례에만 동작하므로, 뒷정리가 같은 소유자의 새 차례에 적용되지 않습니다 |
| 도구의 판 | 부른 스크립트가 있는 git 작업 트리의 `main` 에 `.vmq-required`(줄 형식 `<커밋>\t<경로>\t<설명>`)가 있으면, HEAD 가 줄마다 그 커밋을 포함하거나 그 경로가 `main` 과 같을 때만 `vmq_require` 가 통과합니다. 오래된 작업 트리의 도구는 `main` 에 들어간 고침 없이 대상을 다루지 못합니다 |
| 차례 없는 읽기 | `lib/peek.zsh` 가 읽기 명령과 인자 규칙을 갖습니다. 명령을 잇거나 파일에 쓰는 문법(`;` · `&` · `>` · `<` · 역따옴표 · `$(` · 줄바꿈)과 목록에 없는 명령은 접속하기 전에 거절합니다. 다른 소유자가 잡은 대상에서 읽은 값은 그 소유자가 다루는 도중의 상태이므로 시험 근거로 쓰지 않습니다 |
| 기록 | `$VM_QUEUE_DIR/log` 에 `registered` · `changed` · `held` · `released` · `expired` · `force-released` · `chain` · `target-added` · `target-removed` 를 한 줄씩 적습니다. 도구는 이 파일을 직접 읽지 않고 `vmq ended` 로 읽습니다 |

## status --json

`vmq status --json [<대상>…]` 은 `vmq status` 와 같은 잠금 · 만료 · 배정을 거친 뒤 JSON 객체 한 개를 찍습니다. 프로그램은 문장 출력이 아니라 이것을 읽습니다.

| 필드 | 값 |
|---|---|
| `version` | 형식 판. 지금 1 |
| `now` · `lease` · `holdMax` · `starve` | 판정한 시각(epoch 초)과 상한(초) |
| `owner` | 부른 쪽의 소유자, 없으면 `null` |
| `targets[]` | 대상마다 `name` · `host` · `roles[]` · `os`(`-` 이면 `null`) · `holder`(키 또는 `null`) · `assigned` · `reserved` · `waiting[]` |
| `requests[]` | 준 대상에 파일이 있는 차례마다 `key`(`<일련번호>-<소유자>`) · `seq` · `owner` · `isMine` · `label` · `need[]` · `targets[]` · `held[]` · `assigned[]` · `created` · `active` · `procs[]` · `alive[]` · `expiry` |
| `expiry` | `basis` 가 `holdMax`(쥔 프로세스가 살아 있어 `active` 에서 `holdMax` 초에 만료) 또는 `lease`(마지막 활동에서 `lease` 초에 만료), `seconds` 는 남은 초, `since` 는 그 기준에서 지난 초 |

## 예약

`$VMQ_DATA/reservations.tsv` 에 예약 · 우선순위를 둡니다. `vmq` 명령은 이 파일을 읽지 않습니다. 각 세션이 대상을 고르기 전에 읽고, mod 가 차례를 이 파일과 대조하고, `vmq-main` 이 적습니다. 줄마다 탭으로 나눈 일곱 칸이고 `#` 으로 시작하는 줄과 빈 줄은 읽지 않습니다.

| 칸 | 값 |
|---|---|
| 1 종류 | `only`: 그 대상은 프로젝트 경로 아래 세션만 잡고 기다립니다. `max`: 프로젝트 경로 아래 세션이 그 대상 가운데 동시에 잡는 수가 넷째 칸 이하입니다 |
| 2 대상 | 대상 이름을 `,` 로 이은 것 |
| 3 프로젝트 경로 | 절대 경로. 작업 폴더가 이 경로이거나 그 아래인 세션이 그 프로젝트입니다 |
| 4 수 | `max` 의 상한. `only` 는 `-` |
| 5 시작 · 6 끝 | UTC 의 ISO 8601(`2026-11-11T15:00Z`). 끝이 지난 줄은 `vmq-main` 이 지웁니다 |
| 7 근거 | 누가 언제 정했나 |

세션 id 가 없는 소유자(`VM_QUEUE_OWNER=build-1`)는 프로젝트를 알 수 없어 판정하지 않습니다.

## mod

mod 는 30초마다 `vmq status --json` · `claude agents --json --all` · `reservations.tsv` 를 읽어 차례마다 세션 이름 · 프로젝트 · 판정을 붙입니다. 큐는 바꾸지 않습니다. 두 명령의 stdout 은 `~/Library/Caches/vmq/status.json` 에 25초 동안 캐시해 세션들이 함께 씁니다. `vmq status` 가 큐 잠금을 약 2초 쥐기 때문입니다.

| 자리 | 보이는 것 |
|---|---|
| status line | `vmq held <n> · waiting <n> · violations <n>`, 해당하는 차례가 있으면 `no process` · `expiring` · `ended reservations` 수 |
| pane(`/vmq`) | 차례마다 상태 · 세션 · 프로젝트 · 대상 · 운영체제 · 만료 · 판정 한 줄과 그 아래 설명. 예약 위반은 빨강, 프로세스 없음은 노랑, 만료 임박은 청록 |
| pane-grid 칸 | [pane-grid](https://github.com/hwanyong/pane-grid) 가 설치되어 있으면 grid 칸에 `vmq` 를 놓을 수 있습니다 |
| toast | 새 판정을 8초 동안 |

| 판정 | 조건 |
|---|---|
| `violation` | `only` 줄의 대상을 그 프로젝트 밖 세션이 잡거나 기다림, 또는 `max` 줄의 상한을 넘음(일련번호 순으로 뒤쪽 차례) |
| `dead` | 대상을 잡았고, 살아 있는 쥔 프로세스가 없고, 기준이 `lease` 이고, 120초 넘게 활동이 없고, 주인 세션이 busy 가 아님 |
| `expiring` | 대상을 잡았고, 기준이 `lease` 이고, 300초 이하로 남았고, `dead` 가 아님 |

mod 를 로드한 뒤 첫 읽기는 목록만 채웁니다. 그 뒤 새 판정은 toast 로 보이고, 이름이 `vmq-main` 인 세션에서는 `[vmq]` 프롬프트로 모델에도 넘깁니다. 그 프롬프트에는 mod 가 만든 값(판정 종류 · 일련번호)만 넣습니다. 설명 · 세션 이름 · 예약 근거는 다른 세션이 적은 글이라, 넣으면 `vmq force-release` 를 실행할 수 있는 `vmq-main` 에 지시로 들어가기 때문입니다.

## 세션 vmq-main

`vmq-main` 은 큐를 지켜보는 background 세션 한 개입니다. 큐는 이 세션 없이도 돕니다. 이 세션은 예약을 적고, 예약에 어긋난 차례를 그 프로젝트의 관리 세션에 알리고, 만료가 가까운 차례를 알리고, 쥔 프로세스가 끝난 차례를 놓습니다. 역할 지시문은 `VMQ-MAIN.md` 이고, mod 가 이름이 `vmq-main` 인 세션의 시스템 프롬프트에 요청마다 넣으므로 `/clear` · compact 뒤에도 남습니다.

자동(`autoStartMain`) · `/vmq-main` · 셸의 `vmq-main` 으로 엽니다. `bin/vmq-main` 은 잠금 안에서 살아 있는 `vmq-main` 을 확인하므로, 세션 여럿이 함께 시작해도 하나만 열립니다. 이름 `vmq-main`(다른 세션이 이 이름으로 보냅니다) · 권한 모드 `bypassPermissions`(권한 모드가 다른 세션의 메시지는 승인을 기다립니다) · 작업 폴더 `$VMQ_DATA` 로 엽니다. 같은 이름의 세션이 둘이 되면 나중 세션은 역할 대신 경고를 받습니다.

## 시험

시험은 준 폴더 아래에 자기 큐와 대상 목록을 만듭니다.

```sh
zsh tests/peek.zsh                                        # 읽기 판별: 읽기 18가지 통과, 거절 33가지
zsh tests/stress.zsh bin/vmq "$TMPDIR/vmq-s" "$TMPDIR/vmq-s.out"   # 소유자 10개 동시: 대상마다 최대 1
zsh tests/pair.zsh bin/vmq "$TMPDIR/vmq-p"                 # 같은 Mac 의 server+client 짝(15가지)
zsh tests/keepalive.zsh bin/vmq "$TMPDIR/vmq-k"            # 쥔 프로세스와 만료(11가지, 약 2분)
zsh tests/run-signal.zsh bin/vmq "$TMPDIR/vmq-r"           # TERM · KILL 로 끝난 vmq run(6가지)
```

모든 항목이 맞으면 종료 코드 0 입니다. 큐를 바꾸면 바꾼 줄을 복사본에서 일부러 깨 시험이 실패하는 것을 본 뒤 믿습니다.

## 라이선스

MIT
