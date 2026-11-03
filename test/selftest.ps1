#Requires -Version 7
<#
  Self-test of .github/workflows/sign-windows.yml: runs single steps of the workflow the way the GitHub runner runs them.

  - `node test/run-step.mjs <workflow> <id>` gives the step's shell and run text (refuses `${{` inside any run:).
  - shell pwsh: a .ps1 with `$ErrorActionPreference = 'stop'` before the text and
    `if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit $LASTEXITCODE }` after it, run as
    pwsh -NoLogo -NoProfile -NonInteractive -Command ". '<file>'"   (actions/runner ScriptHandlerHelpers).
  - shell bash: Git Bash by full path, never a bare `bash` (which may be WSL's), as
    bash --noprofile --norc -eo pipefail <file>
  - GITHUB_OUTPUT is a fresh temp file per step; the working directory is the case's tree.
  - Fixtures are made at run time (test/fixtures/make-fixtures.ps1) in a run folder whose path CONTAINS A SPACE;
    the folder is removed at the end.

  Prints `case <id>: pass|FAIL - <reason>` per case. Exit code: 0 when every case passes, 1 otherwise.
#>
param(
  [string]$Workflow = '.github/workflows/sign-windows.yml'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$workflowPath = if ([System.IO.Path]::IsPathRooted($Workflow)) { $Workflow } else { Join-Path $repo $Workflow }
$runStep = Join-Path $repo 'test/run-step.mjs'
$nodeExe = (Get-Command node -CommandType Application | Select-Object -First 1).Source
$pwshExe = (Get-Process -Id $PID).Path
$gitBash = 'C:\Program Files\Git\bin\bash.exe'
$utf8 = [System.Text.UTF8Encoding]::new($false)

# ---------------------------------------------------------------------------------------------------------------
# Child processes. The exit code is read from the process object itself, so nothing can overwrite it.
# ---------------------------------------------------------------------------------------------------------------
$cleanEnvRe = '^(GITHUB_|ACTIONS_|AZURE_|SIGNING_|INPUT_)'
$cleanEnvNames = @('REQUIRED', 'ENVIRONMENT', 'ARTIFACT', 'ARTIFACTS', 'OWN_FILES', 'EXTRA_FILES', 'PKG_DIR', 'PKG_NAME', 'IN_DIR')

function Invoke-Child {
  param([string]$File, [string[]]$Arguments, [string]$WorkDir, [hashtable]$ChildEnv = @{})
  $psi = [System.Diagnostics.ProcessStartInfo]::new($File)
  foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
  $psi.WorkingDirectory = $WorkDir
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $utf8
  $psi.StandardErrorEncoding = $utf8
  # The runner's own variables must not leak into a case: only what the case sets is set.
  foreach ($k in @($psi.Environment.Keys)) {
    if (($k -match $cleanEnvRe) -or ($cleanEnvNames -contains $k)) { [void]$psi.Environment.Remove($k) }
  }
  foreach ($k in $ChildEnv.Keys) { $psi.Environment[$k] = [string]$ChildEnv[$k] }
  $p = [System.Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEndAsync()
  $stderr = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit(240000)) {
    try { $p.Kill($true) } catch { }
    throw "child timed out: $File $($Arguments -join ' ')"
  }
  $p.WaitForExit()
  $code = $p.ExitCode
  return [pscustomobject]@{ ExitCode = $code; Output = ($stdout.Result + $stderr.Result) }
}

# The step text as the runner would run it: file contents and command line per shell.
function Invoke-WorkflowStep {
  param([string]$WorkflowFile, [string]$StepId, [string]$CaseDir, [hashtable]$StepEnv, [string]$ScratchDir)
  $def = Invoke-Child -File $nodeExe -Arguments @($runStep, $WorkflowFile, $StepId) -WorkDir $CaseDir
  if ($def.ExitCode -ne 0) {
    return [pscustomobject]@{ ExitCode = $def.ExitCode; Output = $def.Output; Outputs = @{}; OutputText = ''; RunStepFailed = $true }
  }
  $step = ConvertFrom-Json -InputObject ($def.Output.Trim())
  $outFile = Join-Path $ScratchDir ("gh-output-" + [guid]::NewGuid().ToString('N') + '.txt')
  [System.IO.File]::WriteAllText($outFile, '', $utf8)
  $envFor = @{} + $StepEnv
  $envFor['GITHUB_OUTPUT'] = $outFile
  $text = $step.run -replace "`r`n", "`n"
  if ($step.shell -eq 'pwsh') {
    $file = Join-Path $ScratchDir ("step-" + [guid]::NewGuid().ToString('N') + '.ps1')
    $body = "`$ErrorActionPreference = 'stop'`n" + $text + "`nif ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit `$LASTEXITCODE }"
    [System.IO.File]::WriteAllText($file, $body, $utf8)
    $res = Invoke-Child -File $pwshExe -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', ". '$file'") -WorkDir $CaseDir -ChildEnv $envFor
  } elseif ($step.shell -eq 'bash') {
    if (-not (Test-Path -LiteralPath $gitBash -PathType Leaf)) { throw "Git Bash not found at $gitBash" }
    $file = Join-Path $ScratchDir ("step-" + [guid]::NewGuid().ToString('N') + '.sh')
    [System.IO.File]::WriteAllText($file, $text, $utf8)
    $res = Invoke-Child -File $gitBash -Arguments @('--noprofile', '--norc', '-eo', 'pipefail', ($file -replace '\\', '/')) -WorkDir $CaseDir -ChildEnv $envFor
  } else {
    throw "step '$StepId' has shell '$($step.shell)'; the harness knows pwsh and bash"
  }
  $outputText = [System.IO.File]::ReadAllText($outFile)
  return [pscustomobject]@{ ExitCode = $res.ExitCode; Output = $res.Output; Outputs = (Read-GithubOutput $outputText); OutputText = $outputText; RunStepFailed = $false }
}

# GITHUB_OUTPUT: `name=value` lines and `name<<DELIM` ... `DELIM` blocks.
function Read-GithubOutput([string]$Text) {
  $result = [ordered]@{}
  $lines = $Text -split "`r?`n"
  $i = 0
  while ($i -lt $lines.Count) {
    $line = $lines[$i]
    if ($line -eq '') { $i++; continue }
    if ($line -match '^([^=<]+)<<(.+)$') {
      $name = $Matches[1]; $delim = $Matches[2]
      $value = New-Object System.Collections.Generic.List[string]
      $i++
      $closed = $false
      while ($i -lt $lines.Count) {
        if ($lines[$i] -eq $delim) { $closed = $true; break }
        $value.Add($lines[$i]); $i++
      }
      if (-not $closed) { throw "GITHUB_OUTPUT: heredoc '$name' is not closed" }
      $result[$name] = ($value -join "`n")
      $i++
    } elseif ($line -match '^([^=]+)=(.*)$') {
      $result[$Matches[1]] = $Matches[2]
      $i++
    } else {
      throw "GITHUB_OUTPUT: unreadable line '$line'"
    }
  }
  return $result
}

# ---------------------------------------------------------------------------------------------------------------
# Run folder (its path contains a space) and fixtures
# ---------------------------------------------------------------------------------------------------------------
$runRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sign windows selftest " + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $runRoot
$fixDir = Join-Path $runRoot 'fixtures'
$workDir = Join-Path $runRoot 'fixture-build'
$scratch = Join-Path $runRoot 'scratch'
$null = New-Item -ItemType Directory -Path $fixDir, $workDir, $scratch

$defaultTree = [ordered]@{ 'in/pkg/app.exe' = 'app.exe'; 'in/pkg/vendor.exe' = 'vendor.exe' }
$sixVars = @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'SIGNING_ENDPOINT', 'SIGNING_ACCOUNT', 'SIGNING_PROFILE', 'SIGNING_PUBLISHER')

function New-Tree([string]$CaseDir, $Tree) {
  foreach ($key in $Tree.Keys) {
    $dest = Join-Path $CaseDir ($key -replace '/', '\')
    $kind = $Tree[$key]
    if ($kind -eq '<dir>') {
      $null = New-Item -ItemType Directory -Path $dest -Force
      continue
    }
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
    if ($kind -like 'text:*') {
      [System.IO.File]::WriteAllText($dest, $kind.Substring(5), $utf8)
    } else {
      Copy-Item -LiteralPath (Join-Path $fixDir $kind) -Destination $dest
    }
  }
}

# One run of one step of the workflow in a fresh tree. Returns the verdict of its assertions.
$caseCounter = 0
function Test-StepRun($Case, $Tree, [string]$WorkflowFile) {
  $script:caseCounter++
  $caseDir = Join-Path $runRoot ("case-" + $script:caseCounter)
  $null = New-Item -ItemType Directory -Path $caseDir
  New-Tree $caseDir $Tree
  $pkgDir = Join-Path $caseDir 'in\pkg'
  $stepEnv = @{
    ARTIFACTS = '["cli-win-x64"]'
    ARTIFACT = 'cli-win-x64'
    OWN_FILES = '["app.exe"]'
    EXTRA_FILES = '[]'
    PKG_DIR = $pkgDir
    PKG_NAME = 'pkg'
    IN_DIR = 'in'
    REQUIRED = 'false'
    GITHUB_REF = 'refs/heads/main'
    ENVIRONMENT = 'release-signing'
  }
  foreach ($v in $sixVars) { $stepEnv[$v] = '' }
  if ($Case.Env) { foreach ($k in $Case.Env.Keys) { $stepEnv[$k] = [string]$Case.Env[$k] } }

  $r = Invoke-WorkflowStep -WorkflowFile $WorkflowFile -StepId $Case.Step -CaseDir $caseDir -StepEnv $stepEnv -ScratchDir $scratch
  if ($r.RunStepFailed) { return "run-step.mjs exited $($r.ExitCode) for step '$($Case.Step)': $($r.Output.Trim())" }

  $problems = New-Object System.Collections.Generic.List[string]
  if ($r.ExitCode -ne $Case.Exit) { $problems.Add("exit code $($r.ExitCode), expected $($Case.Exit)") }
  foreach ($frag in @($Case.Expect)) {
    if ($r.Output.IndexOf($frag, [System.StringComparison]::Ordinal) -lt 0) { $problems.Add("output lacks '$frag'") }
  }
  if ($Case.NoOutput -and $r.OutputText.Trim() -ne '') { $problems.Add("outputs were written but none expected: $($r.OutputText.Trim() -replace "`n", ' | ')") }
  if ($Case.Outputs) {
    foreach ($name in $Case.Outputs.Keys) {
      $want = ([string]$Case.Outputs[$name]).Replace('{PKG}', $pkgDir)
      if (-not $r.Outputs.Contains($name)) { $problems.Add("output '$name' is missing"); continue }
      if ($r.Outputs[$name] -ine $want) { $problems.Add("output '$name' is '$($r.Outputs[$name] -replace "`n", ' | ')', expected '$($want -replace "`n", ' | ')'") }
    }
  }
  if ($problems.Count -gt 0) {
    return ($problems -join '; ') + " [output: " + (($r.Output.Trim() -replace '\s*\r?\n\s*', ' / ')) + "]"
  }
  return $null
}

# ---------------------------------------------------------------------------------------------------------------
# The cases: the E1.1 spec table (S1.7) and E1's added cases. Env overrides the defaults of the spec.
# ---------------------------------------------------------------------------------------------------------------
function With-Tree([hashtable]$Add = @{}, [string[]]$Remove = @()) {
  $t = [ordered]@{}
  foreach ($k in $defaultTree.Keys) { if ($Remove -notcontains $k) { $t[$k] = $defaultTree[$k] } }
  foreach ($k in $Add.Keys) { $t[$k] = $Add[$k] }
  return $t
}

$fifthMissing = @{}
foreach ($v in $sixVars) { if ($v -ne 'SIGNING_PUBLISHER') { $fifthMissing[$v] = 'x' } }
$fifthMissing['REQUIRED'] = 'true'
$allSix = @{}
foreach ($v in $sixVars) { $allSix[$v] = 'x' }

$cases = @(
  @{ Id = '2'; Step = 'mode'; Env = @{ REQUIRED = 'true' }; Exit = 1; Expect = @('signing is required'); NoOutput = $true }
  @{ Id = '3'; Step = 'mode'; Env = @{ AZURE_CLIENT_ID = 'x' }; Exit = 1; Expect = @('partial signing configuration', 'missing AZURE_TENANT_ID'); NoOutput = $true }
  @{ Id = '9'; Step = 'mode'; Env = @{ GITHUB_REF = 'refs/tags/x' }; Exit = 1; Expect = @('signing is required', 'refs/tags/x'); NoOutput = $true }
  @{ Id = '4'; Step = 'inventory'; Tree = (With-Tree -Remove 'in/pkg/app.exe'); Exit = 1; Expect = @("own file 'app.exe' not found"); NoOutput = $true }
  @{ Id = '5'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/app.exe' = 'vendor.exe' }); Exit = 1; Expect = @("own file 'app.exe' is Valid"); NoOutput = $true }
  @{ Id = '6'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/vendor-flipped.exe' = 'vendor-flipped.exe' }); Exit = 1; Expect = @("file 'vendor-flipped.exe' has signature status HashMismatch"); NoOutput = $true }
  @{ Id = '7'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/extra.dll' = 'extra.dll' }); Exit = 1; Expect = @("unsigned file 'extra.dll' is neither an own file"); NoOutput = $true }
  @{ Id = '8'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/extra.dll' = 'extra.dll' }); Env = @{ EXTRA_FILES = '["extra.dll"]' }; Exit = 0
     Expect = @("extra file extra.dll: NotSigned, matched 'extra.dll'")
     Outputs = [ordered]@{ count = '2'; files = "{PKG}\app.exe`n{PKG}\extra.dll"; 'kept-count' = '1'; 'kept-files' = '{PKG}\vendor.exe' } }
  @{ Id = 'S1.A1'; Step = 'inputs'; Env = @{ OWN_FILES = '["creds.exe"' }; Exit = 1; Expect = @('own-files is not a JSON list') }
  @{ Id = 'S1.A2'; Step = 'inputs'; Env = @{ ARTIFACTS = '["cli win"]'; OWN_FILES = '["../x.exe"]' }; Exit = 1; Expect = @("artifact name 'cli win'", "own-files entry '../x.exe'") }
  @{ Id = 'S1.A3'; Step = 'inputs'; Env = @{ OWN_FILES = '[]' }; Exit = 1; Expect = @('own-files is empty') }
  @{ Id = 'S1.A4'; Step = 'pkg'; Exit = 1; Expect = @('exactly one directory', 'found: '); NoOutput = $true
     Trees = @(
       [ordered]@{ 'in/pkg' = '<dir>'; 'in/other' = '<dir>' },
       [ordered]@{ 'in/pkg' = '<dir>'; 'in/readme.txt' = 'text:x' }
     ) }
  @{ Id = 'S1.A5'; Step = 'mode'; Env = $allSix; Exit = 0; Expect = @('mode: sign'); Outputs = @{ mode = 'sign' } }
  @{ Id = 'S1.A6'; Step = 'mode'; Exit = 0; Expect = @('UNSIGNED trial'); Outputs = @{ mode = 'skip' } }
  @{ Id = 'S1.A7'; Step = 'inventory'; Exit = 0; Expect = @('kept vendor file vendor.exe: Valid'); Outputs = @{ count = '1'; 'kept-count' = '1' } }
  @{ Id = 'S1.A8'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/extra.dll' = 'extra.dll' }); Env = @{ EXTRA_FILES = '["*.DLL"]' }; Exit = 0; Expect = @("matched '*.DLL'"); Outputs = @{ count = '2' } }
  @{ Id = 'E1.A1'; Step = 'pkg'; Exit = 1; Expect = @('exactly one directory', 'found: '); NoOutput = $true
     Trees = @(
       [ordered]@{ 'in/a' = '<dir>'; 'in/b' = '<dir>' },
       [ordered]@{ 'in/pkg/app.exe' = 'app.exe'; 'in/notes.txt' = 'text:x' }
     ) }
  @{ Id = 'E1.A2'; Step = 'mode'; Env = $fifthMissing; Exit = 1; Expect = @('partial signing configuration', 'missing SIGNING_PUBLISHER'); NoOutput = $true }
  @{ Id = 'E1.A3'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/sub/app.exe' = 'app.exe' }); Exit = 1; Expect = @("unsigned file 'sub/app.exe' is neither an own file"); NoOutput = $true }
  # Added by the implementation: the two green paths no listed case reaches.
  @{ Id = 'X.pkg-ok'; Step = 'pkg'; Exit = 0; Expect = @('package: '); Outputs = @{ name = 'pkg'; dir = '{PKG}' } }
  @{ Id = 'X.inputs-ok'; Step = 'inputs'; Exit = 0; Expect = @('inputs ok: 1 artifacts, 1 own files, 0 extra-file globs') }
)

# E1.A5: run-step.mjs refuses a workflow with `${{` inside a run: block, and names the step.
function Test-RunStepRefusal {
  $caseDir = Join-Path $runRoot 'case-runstep'
  $null = New-Item -ItemType Directory -Path $caseDir
  $before = Invoke-Child -File $nodeExe -Arguments @($runStep, $workflowPath, 'mode') -WorkDir $caseDir
  if ($before.ExitCode -ne 0) { return "run-step.mjs refused the real workflow (exit $($before.ExitCode)): $($before.Output.Trim())" }
  $text = [System.IO.File]::ReadAllText($workflowPath)
  # Put an expression on the first line of the mode step's run: text, whatever else the text holds.
  $pattern = '(?s)(id: mode\b.*?run: \|\r?\n)([ ]+)'
  $m = [regex]::Match($text, $pattern)
  if (-not $m.Success) { return "the mode step has no 'run: |' block after 'id: mode'; the case cannot place its expression" }
  $indent = $m.Groups[2].Value
  $mutant = $text.Substring(0, $m.Index) + $m.Groups[1].Value + $indent + 'echo "${{ inputs.required }}"' + "`n" + $indent + $text.Substring($m.Index + $m.Length)
  $mutantPath = Join-Path $caseDir 'sign-windows-mutant.yml'
  [System.IO.File]::WriteAllText($mutantPath, $mutant, $utf8)
  $after = Invoke-Child -File $nodeExe -Arguments @($runStep, $mutantPath, 'mode') -WorkDir $caseDir
  $problems = @()
  if ($after.ExitCode -ne 2) { $problems += "exit code $($after.ExitCode), expected 2" }
  if ($after.Output -notmatch "step 'mode'") { $problems += "output does not name step 'mode'" }
  if ($problems.Count -gt 0) { return ($problems -join '; ') + " [output: $($after.Output.Trim())]" }
  return $null
}

# ---------------------------------------------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------------------------------------------
$passed = 0
$failed = 0
try {
  Write-Host "run folder: $runRoot"
  try {
    & (Join-Path $PSScriptRoot 'fixtures/make-fixtures.ps1') -OutDir $fixDir -WorkDir $workDir
  } catch {
    Write-Host "FIXTURES FAILED: $($_.Exception.Message)"
    Write-Host "::error::selftest: the fixtures could not be made: $($_.Exception.Message)"
    $failed++
    throw
  }

  foreach ($case in $cases) {
    $reason = $null
    try {
      $trees = if ($case.Trees) { @($case.Trees) } elseif ($case.Tree) { @($case.Tree) } else { @($defaultTree) }
      foreach ($tree in $trees) {
        $reason = Test-StepRun $case $tree $workflowPath
        if ($reason) { break }
      }
    } catch {
      $reason = "harness error: $($_.Exception.Message)"
    }
    if ($reason) { $failed++; Write-Host "case $($case.Id): FAIL — $reason" } else { $passed++; Write-Host "case $($case.Id): pass" }
  }

  $reason = $null
  try { $reason = Test-RunStepRefusal } catch { $reason = "harness error: $($_.Exception.Message)" }
  if ($reason) { $failed++; Write-Host "case E1.A5: FAIL — $reason" } else { $passed++; Write-Host "case E1.A5: pass" }
} catch {
  if ($failed -eq 0) { $failed++; Write-Host "selftest: aborted: $($_.Exception.Message)" }
} finally {
  try { & dotnet build-server shutdown 2>&1 | Out-Null } catch { }
  for ($try = 1; $try -le 3; $try++) {
    try { Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction Stop; break } catch { Start-Sleep -Seconds 2 }
  }
  if (Test-Path -LiteralPath $runRoot) { Write-Host "warning: the run folder could not be removed: $runRoot" }
}

Write-Host "selftest: $passed pass, $failed FAIL"
if ($failed -gt 0) { exit 1 }
exit 0
