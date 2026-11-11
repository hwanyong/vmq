// 판정 한 가지. violation: reservations.tsv 의 줄에 어긋남. dead: 대상을 쥐었는데 살아 있는 프로세스가 없음.
// unknown: 소유자에 세션 id 가 없어 프로젝트를 알 수 없음(README 「예약」 절).
export type Verdict = { kind: 'violation' | 'dead' | 'unknown'; text: string }

// vmq status --json 의 requests[] 한 건에 세션 이름 · 프로젝트 · 판정을 붙인 것.
export type Row = {
  key: string
  seq: number
  session: string
  project: string
  isBuild: boolean
  label: string
  targets: string[]
  state: 'held' | 'assigned' | 'waiting'
  basis: string
  seconds: number
  verdicts: Verdict[]
}

// 한 번 읽은 결과. flagged 는 알린 판정의 키 목록이고, 다음 읽기에서 새로 생긴 것만 알리는 데 쓴다.
export type Snapshot = {
  at: number
  rows: Row[]
  ended: string[]
  badLines: number
  flagged: string[]
  error: string
}

declare module 'claude-code' {
  interface PluginState {
    'vmq-view': { snapshot: Shaped<Snapshot> }
  }
}
