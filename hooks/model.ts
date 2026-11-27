import type { Flag, Row, Snapshot, Verdict } from '../types'

// The fields of vmq status --json (version 1) this mod reads. Format: README "status --json".
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
// os is the fourth column of resources.tsv, null for a target with none (`-`).
type VmqTarget = { name: string; os: string | null }
type VmqStatus = { now: number; targets: VmqTarget[]; requests: VmqRequest[] }

// The fields read from one entry of claude agents --json --all. name, pid and status may be null.
// status takes busy, idle, waiting (a permission prompt) or null (state done).
export type Agent = { sessionId?: string; name?: string | null; cwd?: string; status?: string | null; pid?: number | null; startedAt?: number | null }

// One line of reservations.tsv. Format: README "Reservations" (seven tab-separated columns).
type Rule = { kind: 'only' | 'max'; targets: string[]; path: string; limit: number; start: number; end: number; text: string }

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
const WORKTREE_PART = /\/\.claude\/worktrees\/.*$/
// A turn that holds targets, has no live process and has been idle this many seconds is judged to have no process.
// A turn that short commands take in turn is refreshed every few seconds, so it is not caught.
const DEAD_AFTER = 120
// A held turn with this many seconds or less before it expires is announced. The value leaves time for the notice to pass from
// vmq-main to the project's main session and on to the session that holds the turn (a policy value, not measured). It is ten
// 30-second polls, and an idle session may take a while to pick up a message (VMQ-MAIN.md "Known limits").
const EXPIRING_WITHIN = 300
const FIELDS = 7

const basename = (path: string) => path.split('/').filter(part => part != '').pop() ?? path

const isUnder = (cwd: string, path: string) => cwd == path || cwd.startsWith(`${path}/`)

const parseTime = (text: string) => Date.parse(text) / 1000

// Of the lines that are not comments or blank, a line that is not seven columns or whose kind, number or times cannot be read
// is counted in badLines.
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

// isBusy: is the owning session's status busy. undefined when the owning session is not found (no UUID, or not in agents).
type Owned = { request: VmqRequest; session: string; cwd: string | undefined; isBusy: boolean | undefined }

const ownerOf = (request: VmqRequest, agents: readonly Agent[]): Owned => {
  const id = request.owner.match(UUID)?.[0]
  const agent = id ? agents.find(one => one.sessionId == id) : undefined
  const session = agent?.name ?? (id ? id.slice(0, 8) : request.owner)
  return { request, session, cwd: agent?.cwd, isBusy: agent ? agent.status == 'busy' : undefined }
}

// A value naming one reservation line. The start, end and reason columns are left out.
const ruleKey = (rule: Rule) => `${rule.kind}:${rule.targets.join(',')}:${rule.path}`

// only line: a turn that holds or waits for its targets from a session outside the project path breaks it. Not judged when the
// session is not known.
const onlyVerdict = (rule: Rule, owned: Owned): Verdict | undefined => {
  if (!overlaps(owned.request.targets, rule.targets)) return undefined
  if (owned.cwd == undefined) return { kind: 'unknown', key: ruleKey(rule), text: `not judged (${rule.kind} ${basename(rule.path)})` }
  if (isUnder(owned.cwd, rule.path)) return undefined
  return { kind: 'violation', key: ruleKey(rule), text: `violation: ${rule.targets.join(',')} is reserved for ${basename(rule.path)}` }
}

// max line: the project's sessions' held turns are counted in seq order, and the later turns past the limit break it.
const maxVerdicts = (rule: Rule, owned: readonly Owned[]): Map<string, Verdict> => {
  const verdicts = new Map<string, Verdict>()
  const holding = owned
    .filter(one => one.cwd != undefined && isUnder(one.cwd, rule.path) && overlaps(one.request.held, rule.targets))
    .sort((a, b) => a.request.seq - b.request.seq)
  for (const one of holding.slice(rule.limit)) {
    verdicts.set(one.request.key, { kind: 'violation', key: ruleKey(rule), text: `violation: ${basename(rule.path)} may hold at most ${rule.limit} of ${rule.targets.join(',')} at once` })
  }
  return verdicts
}

// While the owning session is busy, the turn is not judged to have no process: a session that refreshes its turn with each short
// command has no live process between commands, so the process condition alone gave false verdicts. When the owning session is
// not found, the process condition alone is used. idle, waiting and null are not busy.
const isDead = ({ request, isBusy }: Owned) =>
  isBusy != true && request.held.length > 0 && request.alive.length == 0 && request.expiry.basis == 'lease' && request.expiry.since > DEAD_AFTER

// A turn holding targets is within EXPIRING_WITHIN seconds of its lease expiry. The holdMax basis is not looked at: meanwhile
// vmq_purge touches the turn files (lib/vmq.zsh), and once the limit passes the basis becomes lease and the turn is removed
// VMQ_LEASE seconds later. Only the lease judgement removes turns. A turn judged dead is left out: its handling (force-release)
// comes first.
const isExpiring = (owned: Owned) =>
  owned.request.held.length > 0 && owned.request.expiry.basis == 'lease' && owned.request.expiry.seconds <= EXPIRING_WITHIN && !isDead(owned)

const stateOf = (request: VmqRequest): Row['state'] => {
  if (request.held.length > 0) return 'held'
  if (request.assigned.length > 0) return 'assigned'
  return 'waiting'
}

// Target name → operating system. Targets with none are left out.
const systemsOf = (targets: readonly VmqTarget[]) =>
  new Map(targets.flatMap((one): [string, string][] => one.os == null ? [] : [[one.name, one.os]]))

const rowOf = (owned: Owned, verdicts: Verdict[], systems: ReadonlyMap<string, string>): Row => {
  const targets = owned.request.held.length > 0 ? owned.request.held : owned.request.targets
  return {
    key: owned.request.key,
    seq: owned.request.seq,
    session: owned.session,
    project: owned.cwd ? basename(owned.cwd.replace(WORKTREE_PART, '')) : '-',
    label: owned.request.label,
    targets,
    systems: [...new Set(targets.flatMap(name => systems.get(name) ?? []))],
    state: stateOf(owned.request),
    basis: owned.request.expiry.basis,
    seconds: owned.request.expiry.seconds,
    verdicts,
  }
}

const STATE_ORDER: Record<Row['state'], number> = { held: 0, assigned: 1, waiting: 2 }

// Each verdict to announce. unknown is not announced, so it is left out.
export const flagEntries = (snapshot: Pick<Snapshot, 'rows' | 'ended'>): Flag[] => [
  ...snapshot.rows.flatMap(row => row.verdicts.flatMap((one): Flag[] => one.kind == 'unknown' ? [] : [{
    key: `${row.key}:${one.key}`,
    text: `${row.session} seq ${row.seq} (${row.label}): ${one.text}`,
    kind: one.kind,
    seq: row.seq,
  }])),
  ...snapshot.ended.map((text): Flag => ({ key: `ended:${text}`, text: `ended reservation line: ${text}`, kind: 'ended' })),
]

export const parseAgents = (agentsText: string) => JSON.parse(agentsText) as Agent[]

// Builds a Snapshot from the commands' output (strings). When an output is not JSON, JSON.parse throws and the caller writes it
// into the error field.
export const buildSnapshot = (statusText: string, agentsText: string, rulesText: string, at: number): Snapshot => {
  const status = JSON.parse(statusText) as VmqStatus
  const agents = parseAgents(agentsText)
  const { rules, badLines } = parseRules(rulesText)
  const active = rules.filter(rule => rule.start <= status.now && status.now < rule.end)
  const owned = status.requests.map(request => ownerOf(request, agents))
  const systems = systemsOf(status.targets)
  const fromMax = new Map(active.filter(rule => rule.kind == 'max').map(rule => [rule, maxVerdicts(rule, owned)]))
  const rows = owned.map(one => {
    const verdicts: Verdict[] = []
    for (const rule of active) {
      const verdict = rule.kind == 'only' ? onlyVerdict(rule, one) : fromMax.get(rule)?.get(one.request.key)
      if (verdict) verdicts.push(verdict)
    }
    if (isDead(one)) verdicts.push({ kind: 'dead', key: 'dead', text: `no process for ${Math.floor(one.request.expiry.since / 60)} min` })
    if (isExpiring(one)) verdicts.push({ kind: 'expiring', key: 'expiring', text: `expires in ${Math.max(0, one.request.expiry.seconds)} s` })
    return rowOf(one, verdicts, systems)
  }).sort((a, b) => STATE_ORDER[a.state] - STATE_ORDER[b.state] || a.seq - b.seq)
  const ended = rules.filter(rule => rule.end <= status.now).map(rule => rule.text)
  const snapshot = { at, targets: status.targets.length, rows, ended, badLines, error: '' }
  return { ...snapshot, flagged: flagEntries(snapshot).map(one => one.key) }
}

export const countOf = (snapshot: Snapshot) => ({
  held: snapshot.rows.filter(row => row.state != 'waiting').length,
  waiting: snapshot.rows.filter(row => row.state == 'waiting').length,
  violations: snapshot.rows.filter(row => row.verdicts.some(one => one.kind == 'violation')).length,
  dead: snapshot.rows.filter(row => row.verdicts.some(one => one.kind == 'dead')).length,
  expiring: snapshot.rows.filter(row => row.verdicts.some(one => one.kind == 'expiring')).length,
})

// Which role text the session with this pid gets: 'role' when it is named vmq-main and no live vmq-main started before it,
// 'duplicate' when such an earlier one exists (its pid and id in `earlier`), undefined when it is not named vmq-main or is not
// in the list. Two sessions with one name break sending by name, and both would get the mod's verdict prompts.
export const roleOf = (agents: readonly Agent[], pid: number, name: string): { kind: 'role' } | { kind: 'duplicate'; earlier: Agent } | undefined => {
  const self = agents.find(one => one.pid == pid)
  if (self?.name != name) return undefined
  const started = self.startedAt ?? Number.POSITIVE_INFINITY
  const earlier = agents.find(one => one.name == name && one.pid != null && one.pid != pid && typeof one.startedAt == 'number' && one.startedAt < started)
  return earlier ? { kind: 'duplicate', earlier } : { kind: 'role' }
}
