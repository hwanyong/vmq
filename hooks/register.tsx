import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, StateWrite } from 'claude-code'

import type { DataPaths, Flag, Row, Snapshot } from '../types'
import { buildSnapshot, countOf, flagEntries, parseAgents, roleOf } from './model'
import { fillSlot, offerChoice, placementIn, readPlacement } from './pane-grid'

const PLUGIN = 'vmq'
const PANE = 'vmq'
const TITLE = 'vmq'
// The session that handles new verdicts (VMQ-MAIN.md). Other sessions use the status line and toasts only.
const CONTROL_SESSION = 'vmq-main'
const POLL_MS = 30_000
// vmq status runs for about 2 seconds holding the queue lock. With this mod in several sessions, the commands run again only
// when the shared cache is older than this (ms).
const CACHE_MS = 25_000
const RUN_MS = 20_000
// bin/vmq-main waits up to 30 s for the new session to be listed, and up to 60 s for its lock.
const START_MS = 100_000
const ROLE_SECTION = 'vmq:main-role'

const EMPTY: Snapshot = { at: 0, targets: 0, rows: [], ended: [], badLines: 0, flagged: [], error: '' }
// When the fields of Snapshot change, change shape. Values a former version stored stay across a reload.
const snapshot = atom({ plugin: 'vmq', key: 'snapshot' } as const, EMPTY, { shape: 'snapshot-5' })
// Empty strings until the first read of `vmq paths --json` in this session.
const NO_PATHS: DataPaths = { rules: '', cache: '' }
const dataPaths = atom({ plugin: 'vmq', key: 'paths' } as const, NO_PATHS, { shape: 'paths-1' })

type Resolvable = Parameters<EngineInterface['ui']['resolve']>[0]
type Raw = { status: string; agents: string }
type Options = { autoStartMain?: boolean }

// The CLI ships in this plugin (bin/ is also on the Bash tool's PATH).
const filesOf = ($: EngineInterface) => ({
  vmq: `${$.plugin.root}/bin/vmq`,
  main: `${$.plugin.root}/bin/vmq-main`,
  role: `${$.plugin.root}/VMQ-MAIN.md`,
})

const firstLine = (text: string) => text.trim().split('\n')[0] ?? ''

// The status line, pane and toasts draw each line as one line. Line breaks and control characters (C0, DEL, C1, U+2028,
// U+2029) in free strings other sessions set (a turn's label, session names, projects, reservations.tsv lines, stderr) become
// spaces.
const oneLine = (text: string) => text.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, ' ')

const parseRaw = (text: string): Raw | undefined => {
  try {
    const raw = JSON.parse(text) as Partial<Raw>
    return typeof raw.status == 'string' && typeof raw.agents == 'string' ? { status: raw.status, agents: raw.agents } : undefined
  } catch {
    // Read a file another session is writing. Run the commands again.
    return undefined
  }
}

const readCache = async ($: EngineInterface, path: string): Promise<Raw | undefined> => {
  if (!(await $.fs.exists(path))) return undefined
  const { mtimeMs } = await $.fs.stat(path)
  if ((await $.clock.now()) - mtimeMs > CACHE_MS) return undefined
  return parseRaw(await $.fs.read(path))
}

const run = async ($: EngineInterface, argv: string[], timeoutMs = RUN_MS): Promise<string> => {
  const { exitCode, stdout, stderr } = await $.process.run(argv, { timeoutMs })
  if (exitCode != 0) throw new Error(`${argv.slice(-3).join(' ')} exit code ${exitCode}: ${firstLine(stderr)}`)
  return stdout
}

// The data and cache folders differ per host operating system and VMQ_DATA moves them. lib/paths.zsh holds those defaults,
// so they are read from `vmq paths --json` once per session and kept in $.state.
const dataPathsOf = async ($: EngineInterface): Promise<DataPaths> => {
  const known = await read($, dataPaths)
  if (known.cache != '') return known
  const out = JSON.parse(await run($, [filesOf($).vmq, 'paths', '--json'])) as { data: string; cache: string }
  const found = { rules: `${out.data}/reservations.tsv`, cache: `${out.cache}/status.json` }
  await update($, dataPaths, () => found)
  return found
}

const readRaw = async ($: EngineInterface): Promise<Raw> => {
  const paths = await dataPathsOf($)
  const cached = await readCache($, paths.cache)
  if (cached) return cached
  const status = await run($, [filesOf($).vmq, 'status', '--json'])
  const agents = await run($, ['claude', 'agents', '--json', '--all'])
  await $.fs.write(paths.cache, JSON.stringify({ status, agents }))
  return { status, agents }
}

// Shown in place of the counts while the target list is empty or missing (a new install), instead of a failure on every read.
const NO_TARGETS = 'vmq: no targets yet. Ask Claude to add one, or run vmq target add (README "Targets")'

const statusLine = (snap: Snapshot) => {
  if (snap.error != '') return oneLine(`vmq read failed: ${snap.error}`)
  if (snap.targets == 0) return NO_TARGETS
  const count = countOf(snap)
  const parts = [`vmq held ${count.held}`, `waiting ${count.waiting}`, `violations ${count.violations}`]
  if (count.dead > 0) parts.push(`no process ${count.dead}`)
  if (count.expiring > 0) parts.push(`expiring ${count.expiring}`)
  if (snap.ended.length > 0) parts.push(`ended reservations ${snap.ended.length}`)
  return oneLine(parts.join(' · '))
}

// The text handed to the model holds only values this mod makes (verdict kinds, sequence numbers, line counts). A turn's label,
// session names and the reason column of reservations.tsv are free strings other sessions set; in this text they would read as
// instructions to vmq-main, which may run vmq force-release. They show in the pane and toasts only.
// How to handle verdicts is in the "Handling verdicts" section of VMQ-MAIN.md; this text points there.
const seqText = (seq: number) => (Number.isSafeInteger(seq) ? String(seq) : '?')

const controlPrompt = (fresh: readonly Flag[]) => {
  const requests = fresh.flatMap(one => (one.kind == 'ended' ? [] : [`- seq ${seqText(one.seq)} ${one.kind}`]))
  const ended = fresh.filter(one => one.kind == 'ended').length
  return [
    `[vmq] New verdicts in the queue: ${requests.length}, ended reservation lines: ${ended}.`,
    ...requests,
    'Handle them as the "Handling verdicts" section of the vmq-main role in your system prompt says.',
  ].join('\n')
}

// A failed command (exit code, failed start, timeout) or output that is not JSON comes back as error.
const load = async ($: EngineInterface, rulesText: string, at: number): Promise<{ raw: Raw; next: Snapshot } | { error: string }> => {
  try {
    const raw = await readRaw($)
    return { raw, next: buildSnapshot(raw.status, raw.agents, rulesText, at) }
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error) }
  }
}

// This session's process id, as the engine gives a command hook (CLAUDE_PID). undefined when it is not a number.
const ownPid = async ($: EngineInterface) => {
  const pid = Number((await $.process.hookEnv()).CLAUDE_PID)
  return Number.isSafeInteger(pid) ? pid : undefined
}

// Whether this read succeeded at least once since the module loaded. register makes a new one on each load.
type Polling = { hasSucceeded: boolean }

// Reads, updates snapshot, shows a toast for new verdicts, and in vmq-main hands them to the model.
// The first successful read after the module loads only fills snapshot.flagged with its verdict keys and shows no toast or
// prompt. snapshot in $.state outlasts a reload and is empty in a new session, so to keep from announcing verdicts that were
// already there it counts per module load. A failed read does not count as a success.
const poll = async ($: EngineInterface, polling: Polling) => {
  const at = await $.clock.now()
  const previous = await read($, snapshot)
  const paths = await dataPathsOf($).catch(() => NO_PATHS)
  // When vmq paths fails, load below reads it again and reports that failure in snapshot.error
  const rulesText = paths.rules != '' && (await $.fs.exists(paths.rules)) ? await $.fs.read(paths.rules) : ''
  const loaded = await load($, rulesText, at)
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
  $.ui.toast(oneLine(`vmq: ${fresh[0]?.text}${fresh.length > 1 ? ` and ${fresh.length - 1} more` : ''} (/vmq)`), { timeoutMs: 8000 })
  const pid = await ownPid($)
  if (pid == undefined || roleOf(parseAgents(raw.agents), pid, CONTROL_SESSION)?.kind != 'role') return
  void $.prompt.submit({ text: controlPrompt(fresh) })
}

// Opens vmq-main when none is live and the target list holds a target (option autoStartMain). bin/vmq-main --if-absent checks again under its own lock, so sessions
// starting together open one. A session with nothing drawing it (`-p`, the SDK) does not open one.
const startMain = async ($: EngineInterface) => {
  if ((await $.session.surfaces()).length == 0) return
  const raw = await readRaw($)
  // No vmq-main before any target is listed: there is nothing to watch yet
  if ((JSON.parse(raw.status) as { targets: unknown[] }).targets.length == 0) return
  const agents = parseAgents(raw.agents)
  if (agents.some(one => one.name == CONTROL_SESSION && one.pid != null)) return
  const { exitCode, stderr } = await $.process.run([filesOf($).main, '--if-absent'], { timeoutMs: START_MS })
  if (exitCode != 0) $.ui.toast(oneLine(`vmq: could not start vmq-main: ${firstLine(stderr)}`), { timeoutMs: 8000 })
}

// The vmq-main role, added to the system prompt of the session named vmq-main: VMQ-MAIN.md, or a warning when an earlier live
// session has the same name. Read on every composition, so it stays after /clear and compact and applies after a rename.
// The shared cache can be older than this session (a vmq-main bin/vmq-main just opened), so when it does not list this pid,
// claude agents is read again.
const roleSection = async ($: EngineInterface) => {
  const pid = await ownPid($)
  if (pid == undefined) return undefined
  const cached = parseAgents((await readRaw($)).agents)
  const agents = cached.some(one => one.pid == pid) ? cached : parseAgents(await run($, ['claude', 'agents', '--json', '--all']))
  const role = roleOf(agents, pid, CONTROL_SESSION)
  if (role == undefined) return undefined
  if (role.kind == 'role') return (await $.fs.read(filesOf($).role))
  return [
    `# vmq-main: duplicate session`,
    `Another live session named ${CONTROL_SESSION} started before this one (pid ${role.earlier.pid}, session ${role.earlier.sessionId}).`,
    `So the vmq mod did not give this session the vmq-main role: do not take it, and do not handle [vmq] prompts.`,
    `In your first answer, tell the user: with two sessions of one name, other sessions cannot send to it by name, so this session should be closed (claude stop with this session's id, for a background session).`,
  ].join('\n')
}

const STATE_TEXT: Record<Row['state'], string> = { held: 'held', assigned: 'assigned', waiting: 'waiting' }

// Columns one character takes in a terminal: Hangul, CJK and fullwidth characters take 2, the rest 1 (the W and F ranges of
// East Asian Width).
const WIDE = /[\u1100-\u115f\u2e80-\u303e\u3041-\u33ff\u3400-\u4dbf\u4e00-\u9fff\ua960-\ua97f\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60\uffe0-\uffe6]/u
const widthOf = (text: string) => [...text].reduce((sum, char) => sum + (WIDE.test(char) ? 2 : 1), 0)

// The table's columns. The verdict column takes the remaining width, so it is not here. max is the column's width limit
// (columns); longer values are cut at the end.
type Column = { title: string; max: number; text: (row: Row) => string }
const COLUMNS: readonly Column[] = [
  { title: 'state', max: 8, text: row => STATE_TEXT[row.state] },
  { title: 'session', max: 18, text: row => row.session },
  { title: 'project', max: 14, text: row => row.project },
  { title: 'targets', max: 30, text: row => row.targets.join(',') },
  { title: 'os', max: 14, text: row => row.systems.join(',') || '-' },
  { title: 'expiry', max: 12, text: row => `${Math.floor(row.seconds / 60)} min ${row.basis == 'holdMax' ? 'limit' : 'lease'}` },
]
const COLUMN_GAP = 2
const LABEL_INDENT = 2

// A column's width is the widest of its title and values, up to its max.
const widthsOf = (rows: readonly Row[]) =>
  COLUMNS.map(column => Math.min(column.max, Math.max(widthOf(column.title), ...rows.map(row => widthOf(oneLine(column.text(row)))))))

const colorOf = (row: Row) => {
  if (row.verdicts.some(one => one.kind == 'violation')) return 'red'
  if (row.verdicts.some(one => one.kind == 'dead')) return 'yellow'
  if (row.verdicts.some(one => one.kind == 'expiring')) return 'cyan'
  return undefined
}

const headerText = (snap: Snapshot) => {
  if (snap.at == 0) return 'vmq reading'
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
      {snap.ended.map(text => <Text color="yellow" wrap="truncate-end">{oneLine(`ended reservation line: ${text}`)}</Text>)}
      {snap.badLines > 0 && <Text color="yellow" wrap="truncate-end">unreadable lines in reservations.tsv: {snap.badLines}</Text>}
      {snap.at != 0 && snap.targets > 0 && snap.rows.length == 0 && <Text dimColor>The queue has no requests.</Text>}
      {snap.rows.length > 0 && cells(COLUMNS.map(column => column.title), undefined, true, 'verdicts')}
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

// While placed in a cell, the mod's own pane stays closed. It opens again only when the cell is emptied, so a pane the person
// closed stays closed.
const placeOwnPane = async ($: EngineInterface, layout: unknown, previous: unknown) => {
  const isPlaced = placementIn(layout, PLUGIN) != undefined
  const isOpen = (await $.ui.panes()).some(pane => pane.id == PANE)
  if (isPlaced && isOpen) return $.ui.close({ id: PANE })
  if (isPlaced || isOpen || placementIn(previous, PLUGIN) == undefined) return
  await $.ui.open({ id: PANE, title: TITLE })
}

export const register: Register = (on, options) => {
  const { autoStartMain = true } = options as Options

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'vmq', description: 'Show the vmq queue with sessions, projects and reservation verdicts in a pane' })
    await $.command.register({ name: 'vmq-main', description: 'Open the vmq-main session in the background (one at most)' })
    // The first read runs on a timer too: using $ after session.start's dispatch ends could be cut off with it.
    const polling: Polling = { hasSucceeded: false }
    $.clock.after(1, () => { void poll($, polling) })
    $.clock.every(POLL_MS, () => { void poll($, polling) })
    if (autoStartMain) $.clock.after(1, () => { void startMain($).catch(() => undefined) })
    return next(e)
  })

  on('command.run', { command: 'vmq' }, async $ => {
    const placement = await readPlacement($, PLUGIN)
    if (placement) return { text: `vmq is drawn in pane-grid tab ${placement.tab}, cell ${placement.cell}.` }
    await $.ui.open({ id: PANE, title: TITLE })
    return { text: 'Opened the vmq pane.' }
  })

  on('command.run', { command: 'vmq-main' }, async $ => {
    const { exitCode, stdout, stderr } = await $.process.run([filesOf($).main], { timeoutMs: START_MS })
    return { text: exitCode == 0 ? `Opened vmq-main: ${firstLine(stdout)}` : oneLine(stderr.trim()) }
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    const text = await roleSection($).catch(() => undefined)
    if (!text) return composed
    return { sections: [...composed.sections, { id: ROLE_SECTION, text, scope: 'session' as const }] }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => drawView($, e, e.props.bodyColumns))

  // Claude Code 2.1.325 and later match a hook without plugin in its matcher only to panes the hooking plugin opened. The grid
  // pane (grid-<tab>) is opened by pane-grid, so without plugin: 'pane-grid' this hook is not called when the grid draws.
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
