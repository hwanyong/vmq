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

// 알릴 판정 한 건. key 는 중복 판정에, text 는 사람에게(pane · toast) 쓴다. text 에는 다른 세션이 정한 자유 문자열
// (차례의 label · 세션 이름 · reservations.tsv 의 근거 칸)이 들어가므로 모델에 넘길 때는 kind · seq 만 쓴다.
export type Flag =
  | { key: string; text: string; kind: 'violation' | 'dead'; seq: number }
  | { key: string; text: string; kind: 'ended' }

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
