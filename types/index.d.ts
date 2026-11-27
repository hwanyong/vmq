// One verdict. violation: the turn breaks a line of reservations.tsv. dead: the turn holds targets but no process holds it.
// expiring: a turn that holds targets has 300 s or less left before its lease expires (when not dead).
// unknown: the owner has no session id, so the project is not known (README "Reservations").
// key tells one verdict from another, so it holds no value that changes with time (violation: the reservation line's kind,
// targets and project path; dead: `dead`; expiring: `expiring`). text is for display; the text of dead and expiring holds a time.
export type Verdict = { kind: 'violation' | 'dead' | 'expiring' | 'unknown'; key: string; text: string }

// One requests[] entry of vmq status --json with the session name, project and verdicts added.
export type Row = {
  key: string
  seq: number
  session: string
  project: string
  label: string
  targets: string[]
  // The operating systems (fourth column of resources.tsv) of targets, without repeats. Targets with none (`-`) are left out.
  systems: string[]
  state: 'held' | 'assigned' | 'waiting'
  basis: string
  seconds: number
  verdicts: Verdict[]
}

// One verdict to announce. key is for repeats, text is for people (pane, toast). text holds free strings other sessions set
// (the turn's label, session names, the reason column of reservations.tsv), so only kind and seq go to a model.
export type Flag =
  | { key: string; text: string; kind: 'violation' | 'dead' | 'expiring'; seq: number }
  | { key: string; text: string; kind: 'ended' }

// One read. flagged is the keys of the verdicts announced, so the next read announces only new ones.
// targets: how many targets the target list holds (0 before any is added).
export type Snapshot = {
  at: number
  targets: number
  rows: Row[]
  ended: string[]
  badLines: number
  flagged: string[]
  error: string
}

// Where this host keeps reservations.tsv and the mod's shared read cache (from `vmq paths --json`, lib/paths.zsh).
// mainFailed: a file in the cache folder holding the last stderr line of a failed automatic vmq-main start (empty after a
// start that worked), so every new session does not show the same failure again.
export type DataPaths = { rules: string; cache: string; mainFailed: string }

// What goes before a script of this plugin in a command line. Empty on macOS and Linux (the script runs by its #! line). On
// Windows a process cannot start a #! script, so it runs through Git Bash: [<Git>\bin\bash.exe, -c, exec "$0" "$@"].
// isKnown is false until the first look in this session.
export type Shell = { isKnown: boolean; argv: string[] }

declare module 'claude-code' {
  interface PluginState {
    'vmq': { snapshot: Shaped<Snapshot>; paths: Shaped<DataPaths>; shell: Shaped<Shell> }
  }
}
