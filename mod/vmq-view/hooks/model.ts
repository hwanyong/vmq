import type { Flag, Row, Snapshot, Verdict } from '../types'

// vmq status --json(version 1)에서 이 mod 가 읽는 칸. 형식은 vmq README 「status --json」 절.
type VmqRequest = {
  key: string
  seq: number
  owner: string
  label: string
  targets: string[]
  held: string[]
  assigned: string[]
  alive: string[]
  expiry: { basis: string; seconds: number; since: number }
}
type VmqStatus = { now: number; requests: VmqRequest[] }

// claude agents --json --all 의 한 줄에서 읽는 칸. name 은 null 일 수 있다.
// status 는 2026-11-11 실제 출력(21줄)에서 busy · idle · waiting(waitingFor: permission prompt) · null(state done) 네 가지였다.
type Agent = { sessionId?: string; name?: string | null; cwd?: string; status?: string | null }

// reservations.tsv 의 한 줄. 형식은 vmq README 「예약」 절(탭으로 나눈 일곱 칸).
type Rule = { kind: 'only' | 'max'; targets: string[]; path: string; limit: number; start: number; end: number; text: string }

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
const BUILD_PREFIX = 'smbbuild-'
const WORKTREE_PART = /\/\.claude\/worktrees\/.*$/
// 대상을 쥐었는데 살아 있는 프로세스가 없고 마지막 활동이 이만큼(초) 지났으면 프로세스 없음으로 본다.
// 짧은 명령이 번갈아 쥐는 차례는 활동이 몇 초 간격으로 갱신되므로 걸리지 않는다.
const DEAD_AFTER = 120
// 쥔 차례가 만료까지 이만큼(초) 남았으면 알린다. 알림이 vmq-main · 관리 세션 · 카드 세션을 거쳐 전달되는 시간을 두려고 정한 값이다
// (2026-11-11, 재지 않은 정책값). 30초 폴링이 열 번 돈다. 쉬는 세션이 메시지를 늦게 꺼내는 때가 있어(VMQ-MAIN.md 「알려진 한계」) 짧게 잡지 않았다.
const EXPIRING_WITHIN = 300
const FIELDS = 7

const basename = (path: string) => path.split('/').filter(part => part != '').pop() ?? path

const isUnder = (cwd: string, path: string) => cwd == path || cwd.startsWith(`${path}/`)

const parseTime = (text: string) => Date.parse(text) / 1000

// 주석 줄과 빈 줄을 뺀 줄 가운데 일곱 칸이 아니거나 종류 · 수 · 시각을 읽지 못한 줄은 badLines 로 센다.
const parseRules = (text: string): { rules: Rule[]; badLines: number } => {
  const lines = text.split('\n').filter(line => line.trim() != '' && !line.startsWith('#'))
  const rules: Rule[] = []
  for (const line of lines) {
    const cells = line.split('\t')
    const [kind, targets, path, limit, start, end] = cells
    const rule = cells.length == FIELDS && (kind == 'only' || kind == 'max') && targets && path && limit && start && end
      ? { kind, targets: targets.split(','), path, limit: kind == 'max' ? Number(limit) : 0, start: parseTime(start), end: parseTime(end), text: `${kind} ${targets} ${basename(path)} ~${end}` } as Rule
      : undefined
    const isReadable = rule != undefined && Number.isFinite(rule.start) && Number.isFinite(rule.end) && Number.isFinite(rule.limit)
    if (isReadable) rules.push(rule)
  }
  return { rules, badLines: lines.length - rules.length }
}

const overlaps = (a: readonly string[], b: readonly string[]) => a.some(name => b.includes(name))

// isBusy 는 주인 세션의 status 가 busy 인가. 주인 세션을 찾지 못하면(UUID 없음 · agents 에 없음) undefined.
type Owned = { request: VmqRequest; session: string; cwd: string | undefined; isBuild: boolean; isBusy: boolean | undefined }

const ownerOf = (request: VmqRequest, agents: readonly Agent[]): Owned => {
  const id = request.owner.match(UUID)?.[0]
  const agent = id ? agents.find(one => one.sessionId == id) : undefined
  const session = agent?.name ?? (id ? id.slice(0, 8) : request.owner)
  return { request, session, cwd: agent?.cwd, isBuild: request.owner.startsWith(BUILD_PREFIX), isBusy: agent ? agent.status == 'busy' : undefined }
}

// only 줄: 그 대상을 잡거나 기다리는 차례가 프로젝트 경로 밖 세션이면 위반. 세션을 모르면 판정하지 않는다.
// 예약 줄 하나를 가리키는 값. 시작 · 끝 · 근거 칸은 넣지 않는다.
const ruleKey = (rule: Rule) => `${rule.kind}:${rule.targets.join(',')}:${rule.path}`

const onlyVerdict = (rule: Rule, owned: Owned): Verdict | undefined => {
  if (!overlaps(owned.request.targets, rule.targets)) return undefined
  if (owned.cwd == undefined) return { kind: 'unknown', key: ruleKey(rule), text: `판정 못 함(${rule.kind} ${basename(rule.path)})` }
  if (isUnder(owned.cwd, rule.path)) return undefined
  return { kind: 'violation', key: ruleKey(rule), text: `위반: ${rule.targets.join(',')} 는 ${basename(rule.path)} 전용` }
}

// max 줄: 프로젝트 세션이 쥔 차례를 seq 순으로 세어 상한을 넘는 뒤쪽 차례가 위반.
const maxVerdicts = (rule: Rule, owned: readonly Owned[]): Map<string, Verdict> => {
  const verdicts = new Map<string, Verdict>()
  const holding = owned
    .filter(one => one.cwd != undefined && isUnder(one.cwd, rule.path) && overlaps(one.request.held, rule.targets))
    .sort((a, b) => a.request.seq - b.request.seq)
  for (const one of holding.slice(rule.limit)) {
    verdicts.set(one.request.key, { kind: 'violation', key: ruleKey(rule), text: `위반: ${basename(rule.path)} 는 ${rule.targets.join(',')} 를 동시에 ${rule.limit}개까지` })
  }
  return verdicts
}

// 주인 세션이 busy 면 프로세스 없음으로 보지 않는다. 짧은 명령마다 차례를 갱신하는 세션은 명령 사이에 살아 있는 프로세스가
// 0개라 프로세스 조건만으로는 오탐이 났다(seq 2704, 2026-11-11 사용자 결정 「응, 그 조건 더해」). 주인 세션을 찾지 못하면
// 프로세스 조건만으로 본다. idle · waiting · null 은 busy 가 아니다.
const isDead = ({ request, isBusy }: Owned) =>
  isBusy != true && request.held.length > 0 && request.alive.length == 0 && request.expiry.basis == 'lease' && request.expiry.since > DEAD_AFTER

// 대상을 쥔 차례가 lease 만료까지 EXPIRING_WITHIN 초 안이다. holdMax 기준은 보지 않는다. 그동안 vmq_purge 가 차례 파일을 touch 해
// (lib/vmq.zsh), 상한이 지나면 기준이 lease 로 바뀌고 그때부터 VMQ_LEASE 초 뒤에 지워진다. 차례를 지우는 것은 lease 판정뿐이다(0.1.8).
// dead 로 판정한 차례는 그 처리(force-release)가 먼저라 넣지 않는다.
const isExpiring = (owned: Owned) =>
  owned.request.held.length > 0 && owned.request.expiry.basis == 'lease' && owned.request.expiry.seconds <= EXPIRING_WITHIN && !isDead(owned)

const stateOf = (request: VmqRequest): Row['state'] => {
  if (request.held.length > 0) return 'held'
  if (request.assigned.length > 0) return 'assigned'
  return 'waiting'
}

const rowOf = (owned: Owned, verdicts: Verdict[]): Row => ({
  key: owned.request.key,
  seq: owned.request.seq,
  session: owned.session,
  project: owned.cwd ? basename(owned.cwd.replace(WORKTREE_PART, '')) : '-',
  isBuild: owned.isBuild,
  label: owned.request.label,
  targets: owned.request.held.length > 0 ? owned.request.held : owned.request.targets,
  state: stateOf(owned.request),
  basis: owned.request.expiry.basis,
  seconds: owned.request.expiry.seconds,
  verdicts,
})

const STATE_ORDER: Record<Row['state'], number> = { held: 0, assigned: 1, waiting: 2 }

// 알릴 판정 하나하나. unknown 은 알리지 않으므로 넣지 않는다.
export const flagEntries = (snapshot: Pick<Snapshot, 'rows' | 'ended'>): Flag[] => [
  ...snapshot.rows.flatMap(row => row.verdicts.flatMap((one): Flag[] => one.kind == 'unknown' ? [] : [{
    key: `${row.key}:${one.key}`,
    text: `${row.session} seq ${row.seq} (${row.label}): ${one.text}`,
    kind: one.kind,
    seq: row.seq,
  }])),
  ...snapshot.ended.map((text): Flag => ({ key: `ended:${text}`, text: `끝난 예약 줄: ${text}`, kind: 'ended' })),
]

// claude agents --json --all 의 출력에서 세션 id 의 이름. 없으면 undefined.
export const sessionNameOf = (agentsText: string, id: string): string | undefined =>
  (JSON.parse(agentsText) as Agent[]).find(one => one.sessionId == id)?.name ?? undefined

// 세 명령의 출력(문자열)으로 Snapshot 을 만든다. 출력이 JSON 이 아니면 JSON.parse 가 던지고, 부른 쪽이 error 칸에 적는다.
export const buildSnapshot = (statusText: string, agentsText: string, rulesText: string, at: number): Snapshot => {
  const status = JSON.parse(statusText) as VmqStatus
  const agents = JSON.parse(agentsText) as Agent[]
  const { rules, badLines } = parseRules(rulesText)
  const active = rules.filter(rule => rule.start <= status.now && status.now < rule.end)
  const owned = status.requests.map(request => ownerOf(request, agents))
  const fromMax = new Map(active.filter(rule => rule.kind == 'max').map(rule => [rule, maxVerdicts(rule, owned)]))
  const rows = owned.map(one => {
    const verdicts: Verdict[] = []
    for (const rule of active) {
      const verdict = rule.kind == 'only' ? onlyVerdict(rule, one) : fromMax.get(rule)?.get(one.request.key)
      if (verdict) verdicts.push(verdict)
    }
    if (isDead(one)) verdicts.push({ kind: 'dead', key: 'dead', text: `프로세스 없음 ${Math.floor(one.request.expiry.since / 60)}분` })
    if (isExpiring(one)) verdicts.push({ kind: 'expiring', key: 'expiring', text: `만료 임박 ${Math.max(0, one.request.expiry.seconds)}초` })
    return rowOf(one, verdicts)
  }).sort((a, b) => STATE_ORDER[a.state] - STATE_ORDER[b.state] || a.seq - b.seq)
  const ended = rules.filter(rule => rule.end <= status.now).map(rule => rule.text)
  const snapshot = { at, rows, ended, badLines, error: '' }
  return { ...snapshot, flagged: flagEntries(snapshot).map(one => one.key) }
}

export const countOf = (snapshot: Snapshot) => ({
  held: snapshot.rows.filter(row => row.state != 'waiting').length,
  waiting: snapshot.rows.filter(row => row.state == 'waiting').length,
  violations: snapshot.rows.filter(row => row.verdicts.some(one => one.kind == 'violation')).length,
  dead: snapshot.rows.filter(row => row.verdicts.some(one => one.kind == 'dead')).length,
  expiring: snapshot.rows.filter(row => row.verdicts.some(one => one.kind == 'expiring')).length,
})
