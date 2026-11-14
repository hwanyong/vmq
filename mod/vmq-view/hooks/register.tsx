import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, StateWrite } from 'claude-code'

import type { Flag, Row, Snapshot } from '../types'
import { buildSnapshot, countOf, flagEntries, sessionNameOf } from './model'
import { fillSlot, offerChoice, placementIn, readPlacement } from './pane-grid'

const PLUGIN = 'vmq-view'
const PANE = 'vmq-view'
const TITLE = 'vmq'
// 새 판정을 모델에 넘기는 세션의 이름(~/.claude/CLAUDE.md §18). 다른 세션은 status line 과 toast 만 쓴다.
const CONTROL_SESSION = 'vmq-main'
const POLL_MS = 30_000
// vmq status 는 큐 잠금을 쥔 채 2초쯤 돈다. 여러 세션이 이 mod 를 쓰면 캐시가 이만큼(ms) 지났을 때만 다시 부른다.
const CACHE_MS = 25_000
const RUN_MS = 20_000

const EMPTY: Snapshot = { at: 0, rows: [], ended: [], badLines: 0, flagged: [], error: '' }
// Snapshot 의 칸이 바뀌면 shape 를 바꾼다. 이전 판이 남긴 값은 reload 뒤에도 남는다.
const snapshot = atom({ plugin: 'vmq-view', key: 'snapshot' } as const, EMPTY, { shape: 'snapshot-3' })

type Resolvable = Parameters<EngineInterface['ui']['resolve']>[0]
type Raw = { status: string; agents: string }

const pathsOf = (home: string) => ({
  vmq: `${home}/.claude/tools/vmq/bin/vmq`,
  cache: `${home}/Library/Caches/vmq-view/status.json`,
  rules: `${home}/Library/Application Support/vmq/reservations.tsv`,
})

const firstLine = (text: string) => text.trim().split('\n')[0] ?? ''

// status line · pane · toast 는 줄마다 한 줄로 그린다. 다른 세션이 정하는 자유 문자열(차례의 label · 세션 이름 · 프로젝트 ·
// reservations.tsv 의 줄 · stderr)에 든 줄바꿈 · 제어 문자(C0 · DEL · C1 · U+2028 · U+2029)를 공백으로 바꾼다.
// 2026-11-11 사용자 결정으로 toast 에 이어 pane 에도 쓴다.
const oneLine = (text: string) => text.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, ' ')

const parseRaw = (text: string): Raw | undefined => {
  try {
    const raw = JSON.parse(text) as Partial<Raw>
    return typeof raw.status == 'string' && typeof raw.agents == 'string' ? { status: raw.status, agents: raw.agents } : undefined
  } catch {
    // 다른 세션이 쓰는 중인 파일을 읽었다. 명령을 다시 부른다.
    return undefined
  }
}

const readCache = async ($: EngineInterface, path: string): Promise<Raw | undefined> => {
  if (!(await $.fs.exists(path))) return undefined
  const { mtimeMs } = await $.fs.stat(path)
  if ((await $.clock.now()) - mtimeMs > CACHE_MS) return undefined
  return parseRaw(await $.fs.read(path))
}

const run = async ($: EngineInterface, argv: string[]): Promise<string> => {
  const { exitCode, stdout, stderr } = await $.process.run(argv, { timeoutMs: RUN_MS })
  if (exitCode != 0) throw new Error(`${argv.slice(-3).join(' ')} 종료 코드 ${exitCode}: ${firstLine(stderr)}`)
  return stdout
}

const readRaw = async ($: EngineInterface, home: string): Promise<Raw> => {
  const paths = pathsOf(home)
  const cached = await readCache($, paths.cache)
  if (cached) return cached
  const status = await run($, [paths.vmq, 'status', '--json'])
  const agents = await run($, ['claude', 'agents', '--json', '--all'])
  await $.fs.write(paths.cache, JSON.stringify({ status, agents }))
  return { status, agents }
}

const statusLine = (snap: Snapshot) => {
  if (snap.error != '') return oneLine(`vmq 읽기 실패: ${snap.error}`)
  const count = countOf(snap)
  const parts = [`vmq 잡음 ${count.held}건`, `대기 ${count.waiting}건`, `예약 위반 ${count.violations}건`]
  if (count.dead > 0) parts.push(`프로세스 없음 ${count.dead}건`)
  if (count.expiring > 0) parts.push(`만료 임박 ${count.expiring}건`)
  if (snap.ended.length > 0) parts.push(`끝난 예약 ${snap.ended.length}줄`)
  return oneLine(parts.join(' · '))
}

// 모델에 넘기는 글에는 이 mod 가 만든 값(판정 종류 · 일련번호 · 줄 수)만 넣는다. 차례의 label · 세션 이름 ·
// reservations.tsv 의 근거 칸은 다른 세션이 정하는 자유 문자열이라 넣으면 그 글이 vmq-main 의 지시로 읽힌다
// (커밋 da99dc4 보안 검토). 그것들은 pane · toast 에만 보인다.
// 판정을 처리하는 차례(세부 확인 · 데이터 취급 · 판정별 처리)의 원본은 VMQ-MAIN.md 「판정 처리」 절이다. 이 글에는 그 절을 가리키는 줄만 둔다.
const seqText = (seq: number) => (Number.isSafeInteger(seq) ? String(seq) : '?')

const controlPrompt = (fresh: readonly Flag[]) => {
  const requests = fresh.flatMap(one => (one.kind == 'ended' ? [] : [`- seq ${seqText(one.seq)} ${one.kind}`]))
  const ended = fresh.filter(one => one.kind == 'ended').length
  return [
    `[vmq-view] 큐에서 새로 생긴 판정 ${requests.length}건, 끝난 예약 줄 ${ended}줄.`,
    ...requests,
    '처리는 역할 지시문 ~/.claude/tools/vmq/VMQ-MAIN.md 의 「판정 처리」 절을 따른다. 문맥에 그 문서가 없으면 먼저 읽는다.',
  ].join('\n')
}

// 명령이 실패하거나(종료 코드 · 시작 실패 · 시간 초과) 출력이 JSON 이 아니면 error 로 돌려준다.
const load = async ($: EngineInterface, home: string, rulesText: string, at: number): Promise<{ raw: Raw; next: Snapshot } | { error: string }> => {
  try {
    const raw = await readRaw($, home)
    return { raw, next: buildSnapshot(raw.status, raw.agents, rulesText, at) }
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error) }
  }
}

// 이번 로드에서 읽기가 한 번이라도 성공했는가. register 가 로드마다 새로 만든다.
type Polling = { hasSucceeded: boolean }

// 읽어서 snapshot 을 바꾸고, 새 판정이 있으면 toast 를 띄우고, vmq-main 세션이면 모델에 넘긴다.
// 2026-11-11 사용자 결정 「첫 폴링은 알리지 말고 목록만 채워」: 이번 로드에서 처음 성공한 읽기는 snapshot.flagged 만
// 그때의 판정 키로 채우고 toast · prompt 를 하지 않는다. $.state 의 snapshot 은 reload 를 넘어 남고 새 세션에서는 비므로,
// 어느 경우든 이미 있던 판정을 새것으로 알리지 않으려고 모듈 로드 단위로 센다. 읽기 실패는 성공으로 세지 않는다.
const poll = async ($: EngineInterface, polling: Polling) => {
  const home = await $.env.get('HOME')
  if (!home) return $.ui.status('vmq 읽기 실패: HOME 이 없다')
  const at = await $.clock.now()
  const previous = await read($, snapshot)
  const paths = pathsOf(home)
  const rulesText = (await $.fs.exists(paths.rules)) ? await $.fs.read(paths.rules) : ''
  const loaded = await load($, home, rulesText, at)
  if ('error' in loaded) {
    const failed = { ...previous, at, error: loaded.error }
    await update($, snapshot, () => failed)
    return $.ui.status(statusLine(failed))
  }
  const { raw, next } = loaded
  await update($, snapshot, () => next)
  $.ui.status(statusLine(next))
  const isFirstSuccess = !polling.hasSucceeded
  polling.hasSucceeded = true
  if (isFirstSuccess) return
  const fresh = flagEntries(next).filter(one => !previous.flagged.includes(one.key))
  if (fresh.length == 0) return
  $.ui.toast(oneLine(`vmq: ${fresh[0]?.text}${fresh.length > 1 ? ` 외 ${fresh.length - 1}건` : ''} (/vmq)`), { timeoutMs: 8000 })
  const name = sessionNameOf(raw.agents, await $.session.id())
  if (name != CONTROL_SESSION) return
  void $.prompt.submit({ text: controlPrompt(fresh) })
}

const STATE_TEXT: Record<Row['state'], string> = { held: '잡음', assigned: '배정', waiting: '대기' }

// 터미널에서 한 글자가 차지하는 칸 수. 한글 · 한자 · 전각 문자는 2칸, 나머지는 1칸으로 센다(East Asian Width 의 W · F 범위).
const WIDE = /[\u1100-\u115f\u2e80-\u303e\u3041-\u33ff\u3400-\u4dbf\u4e00-\u9fff\ua960-\ua97f\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60\uffe0-\uffe6]/u
const widthOf = (text: string) => [...text].reduce((sum, char) => sum + (WIDE.test(char) ? 2 : 1), 0)

// 표의 열. 판정 열은 남은 폭을 모두 쓰므로 여기 넣지 않는다. max 는 열 폭의 상한(칸)이고, 넘는 값은 끝을 자른다.
type Column = { title: string; max: number; text: (row: Row) => string }
const COLUMNS: readonly Column[] = [
  { title: '상태', max: 4, text: row => STATE_TEXT[row.state] },
  { title: '세션', max: 18, text: row => (row.isBuild ? `${row.session} 빌드` : row.session) },
  { title: '프로젝트', max: 14, text: row => row.project },
  { title: '대상', max: 30, text: row => row.targets.join(',') },
  { title: '운영체제', max: 14, text: row => row.systems.join(',') || '-' },
  { title: '만료', max: 10, text: row => `${Math.floor(row.seconds / 60)}분 ${row.basis == 'holdMax' ? '상한' : 'lease'}` },
]
const COLUMN_GAP = 2
const LABEL_INDENT = 2

// 열 폭은 머리 글자와 그 열 값 가운데 가장 넓은 것이고, 열의 max 를 넘지 않는다.
const widthsOf = (rows: readonly Row[]) =>
  COLUMNS.map(column => Math.min(column.max, Math.max(widthOf(column.title), ...rows.map(row => widthOf(oneLine(column.text(row)))))))

const colorOf = (row: Row) => {
  if (row.verdicts.some(one => one.kind == 'violation')) return 'red'
  if (row.verdicts.some(one => one.kind == 'dead')) return 'yellow'
  if (row.verdicts.some(one => one.kind == 'expiring')) return 'cyan'
  return undefined
}

const headerText = (snap: Snapshot) => {
  if (snap.at == 0) return 'vmq 읽는 중'
  const time = new Date(snap.at).toISOString().slice(11, 19)
  return `${time} UTC · ${statusLine(snap)}`
}

const drawView = async ($: EngineInterface, e: Resolvable, columns: number) => {
  const { Box, Text } = $.ui.resolve(e)
  const snap = await read($, snapshot)
  const widths = widthsOf(snap.rows)
  const cells = (texts: readonly string[], color: string | undefined, isDim: boolean, rest: string) => (
    <Box flexDirection="row" columnGap={COLUMN_GAP}>
      {texts.map((text, index) => (
        <Box width={widths[index]} flexShrink={0}>
          <Text color={color} dimColor={isDim} wrap="truncate-end">{text}</Text>
        </Box>
      ))}
      <Box flexGrow={1} flexShrink={1}>
        <Text color={color} dimColor={isDim} wrap="truncate-end">{rest}</Text>
      </Box>
    </Box>
  )
  return (
    <Box flexDirection="column" width={columns}>
      <Text bold wrap="truncate-end">{headerText(snap)}</Text>
      {snap.ended.map(text => <Text color="yellow" wrap="truncate-end">{oneLine(`끝난 예약 줄: ${text}`)}</Text>)}
      {snap.badLines > 0 && <Text color="yellow" wrap="truncate-end">reservations.tsv 에서 읽지 못한 줄 {snap.badLines}줄</Text>}
      {snap.at != 0 && snap.rows.length == 0 && <Text dimColor>큐에 요청이 없다.</Text>}
      {snap.rows.length > 0 && cells(COLUMNS.map(column => column.title), undefined, true, '판정')}
      {snap.rows.map(row => {
        const color = colorOf(row)
        const isDim = row.state == 'waiting' && color == undefined
        return (
          <Box flexDirection="column">
            {cells(COLUMNS.map(column => oneLine(column.text(row))), color, isDim, oneLine(row.verdicts.map(one => one.text).join(' · ')))}
            {row.label != '' && (
              <Box marginLeft={LABEL_INDENT}>
                <Text dimColor wrap="truncate-end">{oneLine(row.label)}</Text>
              </Box>
            )}
          </Box>
        )
      })}
    </Box>
  )
}

// 칸에 놓인 동안에는 자기 pane 을 열지 않는다. 칸이 비워졌을 때만 다시 열어, 사람이 닫은 pane 은 닫힌 채로 둔다.
const placeOwnPane = async ($: EngineInterface, layout: unknown, previous: unknown) => {
  const isPlaced = placementIn(layout, PLUGIN) != undefined
  const isOpen = (await $.ui.panes()).some(pane => pane.id == PANE)
  if (isPlaced && isOpen) return $.ui.close({ id: PANE })
  if (isPlaced || isOpen || placementIn(previous, PLUGIN) == undefined) return
  await $.ui.open({ id: PANE, title: TITLE })
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'vmq', description: 'vmq 큐의 요청을 세션 · 프로젝트 · 예약 판정과 함께 pane 에 보여 준다' })
    // 첫 읽기도 타이머로 돌린다. session.start 의 dispatch 가 끝난 뒤까지 $ 를 쓰면 그 dispatch 와 함께 끊길 수 있다.
    const polling: Polling = { hasSucceeded: false }
    $.clock.after(1, () => { void poll($, polling) })
    $.clock.every(POLL_MS, () => { void poll($, polling) })
    return next(e)
  })

  on('command.run', { command: 'vmq' }, async $ => {
    const placement = await readPlacement($, PLUGIN)
    if (placement) return { text: `vmq-view 는 pane-grid 의 ${placement.tab} 탭 ${placement.cell} 칸에 그려져 있다.` }
    await $.ui.open({ id: PANE, title: TITLE })
    return { text: 'vmq pane 을 열었다.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => drawView($, e, e.props.bodyColumns))

  // Claude Code 2.1.325 이상은 matcher 에 plugin 이 없으면 이 hook 을 등록한 plugin(vmq-view)이 연 pane 에만 맞춘다.
  // grid pane(grid-<tab>)은 pane-grid 가 열므로 plugin: 'pane-grid' 가 없으면 이 hook 은 grid 를 그릴 때 불리지 않는다.
  on('ui.render', { component: 'Pane', requestId: /^grid-/, plugin: 'pane-grid' }, async ($, e, next) => {
    const placement = await readPlacement($, PLUGIN)
    const below = await next(e)
    const { Box, Button } = $.ui.resolve(e)
    const offered = offerChoice(below, PLUGIN, placement, choice => <Button key={choice.key} plain label={choice.label} hotkey={choice.hotkey} onPress={() => {}} />)
    if (!placement || placement.requestId != e.requestId) return offered
    const columns = placement.columns > 0 ? placement.columns : e.props.bodyColumns
    const cell = (
      <Box key={`cell:${PLUGIN}`} flexDirection="column">
        {await drawView($, e, columns)}
      </Box>
    )
    return fillSlot(offered, PLUGIN, cell) ?? <Box flexDirection="column">{offered}{cell}</Box>
  })

  on('state.set', { plugin: 'pane-grid' as never, key: 'layout' as never }, async ($, e, next) => {
    const write = e as StateWrite
    const result = await next(e)
    await placeOwnPane($, write.value, write.previous)
    return result
  })
}
