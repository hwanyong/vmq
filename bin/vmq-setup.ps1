# vmq-setup.ps1 [-Check]: the Windows start of vmq-setup, for a Claude Code that has no Git Bash yet.
# Without Git for Windows, Claude Code on Windows runs commands with its PowerShell tool and has no Bash tool
# (https://code.claude.com/docs/en/setup.md, "Install on native Windows"). vmq needs Git Bash, so this script:
#   1 looks for Git Bash's bash.exe: CLAUDE_CODE_GIT_BASH_PATH, then <Git>\bin\bash.exe for the git.exe on PATH, then
#     %ProgramFiles%\Git and %LOCALAPPDATA%\Programs\Git
#   2 when none is found and -Check is not given, installs Git for Windows with winget, for this user first (no administrator
#     rights), and for all users when that fails (Windows asks for administrator rights once)
#   3 runs bin/vmq-setup (bash) in that Git Bash, with --check when -Check is given, which installs zsh and jq
# Exit codes: 0 everything is there, 1 missing (with -Check) or a step failed.
param([switch]$Check)
$ErrorActionPreference = 'Stop'

function Find-GitBash {
  if ($env:CLAUDE_CODE_GIT_BASH_PATH -and (Test-Path $env:CLAUDE_CODE_GIT_BASH_PATH)) { return $env:CLAUDE_CODE_GIT_BASH_PATH }
  $git = Get-Command git.exe -ErrorAction SilentlyContinue
  if ($git) {
    # git.exe on PATH is <Git>\cmd\git.exe
    $bash = Join-Path (Split-Path (Split-Path $git.Source)) 'bin\bash.exe'
    if (Test-Path $bash) { return $bash }
  }
  foreach ($root in @("$env:ProgramFiles\Git", "$env:LOCALAPPDATA\Programs\Git")) {
    $bash = Join-Path $root 'bin\bash.exe'
    if (Test-Path $bash) { return $bash }
  }
  return $null
}

$bash = Find-GitBash
if (-not $bash) {
  if ($Check) { Write-Output 'missing: Git for Windows (Git Bash)'; exit 1 }
  if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    Write-Output 'vmq-setup: winget is missing. Install Git for Windows from https://git-scm.com/downloads/win, then run vmq-setup again'
    exit 1
  }
  Write-Output 'vmq-setup: installing Git for Windows for this user (winget install --id Git.Git --scope user)'
  & winget.exe install --id Git.Git --exact --scope user --silent --accept-source-agreements --accept-package-agreements
  $bash = Find-GitBash
  if (-not $bash) {
    Write-Output 'vmq-setup: installing Git for Windows for all users; Windows asks for administrator rights once (UAC)'
    & winget.exe install --id Git.Git --exact --silent --accept-source-agreements --accept-package-agreements
    $bash = Find-GitBash
  }
  if (-not $bash) { Write-Output 'vmq-setup: Git for Windows did not install'; exit 1 }
  Write-Output "vmq-setup: Git Bash is $bash. Restart Claude Code so its Bash tool uses Git Bash."
  Write-Output "vmq-setup: if Claude Code does not find it, add to settings.json: `"env`": { `"CLAUDE_CODE_GIT_BASH_PATH`": `"$($bash -replace '\\', '\\')`" }"
}

$setup = (Join-Path $PSScriptRoot 'vmq-setup') -replace '\\', '/'
$arguments = @($setup)
if ($Check) { $arguments += '--check' }
& $bash @arguments
exit $LASTEXITCODE
