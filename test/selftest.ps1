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
$cleanEnvNames = @('REQUIRED', 'ENVIRONMENT', 'ARTIFACT', 'ARTIFACTS', 'OWN_FILES', 'EXTRA_FILES', 'PKG_DIR', 'PKG_NAME', 'IN_DIR', 'PKG', 'MODE', 'FILES', 'KEPT_FILES', 'VERIFIED_MANIFEST')

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

# {PKG}, {SIGNER} and {SIGNER_LOWER} in case texts: the package directory of the case, and the signer simple name
# the vendor fixture really has (read at run time).
$script:signer = ''
function Expand-Text([string]$Text, [string]$PkgDir) {
  return $Text.Replace('{PKG}', $PkgDir).Replace('{SIGNER_LOWER}', $script:signer.ToLowerInvariant()).Replace('{SIGNER}', $script:signer)
}

# One case: a fresh tree, then one step (the case itself) or a chain of steps (Case.Steps) run in that tree.
# In a chain the outputs of pkg, mode and inventory reach the later steps as env, as the workflow's env: does.
# Step keys: Step, Env, Exit, Expect, NoOutput, Outputs, Prepare (scriptblock run before the step).
# Returns $null when every assertion holds, else the reason.
$caseCounter = 0
function Test-StepRun($Case, $Tree, [string]$WorkflowFile) {
  $script:caseCounter++
  $caseDir = Join-Path $runRoot ("case-" + $script:caseCounter)
  $null = New-Item -ItemType Directory -Path $caseDir
  New-Tree $caseDir $Tree
  $pkgDir = Join-Path $caseDir 'in\pkg'
  $base = @{
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
    VERIFIED_MANIFEST = (Join-Path $caseDir 'verified.sha256')
  }
  foreach ($v in $sixVars) { $base[$v] = '' }
  $flow = @{}
  $steps = if ($Case.Steps) { @($Case.Steps) } else { @($Case) }

  foreach ($spec in $steps) {
    if ($spec.Prepare) { & $spec.Prepare $caseDir $pkgDir }
    $stepEnv = $base.Clone()
    foreach ($k in $flow.Keys) { $stepEnv[$k] = $flow[$k] }
    foreach ($src in @($Case.Env, $spec.Env)) {
      if ($src) { foreach ($k in $src.Keys) { $stepEnv[$k] = Expand-Text ([string]$src[$k]) $pkgDir } }
    }

    $r = Invoke-WorkflowStep -WorkflowFile $WorkflowFile -StepId $spec.Step -CaseDir $caseDir -StepEnv $stepEnv -ScratchDir $scratch
    if ($r.RunStepFailed) { return "run-step.mjs exited $($r.ExitCode) for step '$($spec.Step)': $($r.Output.Trim())" }

    $problems = New-Object System.Collections.Generic.List[string]
    $wantExit = if ($null -ne $spec.Exit) { $spec.Exit } else { 0 }
    if ($r.ExitCode -ne $wantExit) { $problems.Add("exit code $($r.ExitCode), expected $wantExit") }
    foreach ($frag in @($spec.Expect)) {
      $want = Expand-Text ([string]$frag) $pkgDir
      if ($r.Output.IndexOf($want, [System.StringComparison]::Ordinal) -lt 0) { $problems.Add("output lacks '$want'") }
    }
    if ($spec.NoOutput -and $r.OutputText.Trim() -ne '') { $problems.Add("outputs were written but none expected: $($r.OutputText.Trim() -replace "`n", ' | ')") }
    if ($spec.Outputs) {
      foreach ($name in $spec.Outputs.Keys) {
        $want = Expand-Text ([string]$spec.Outputs[$name]) $pkgDir
        if (-not $r.Outputs.Contains($name)) { $problems.Add("output '$name' is missing"); continue }
        if ($r.Outputs[$name] -ine $want) { $problems.Add("output '$name' is '$($r.Outputs[$name] -replace "`n", ' | ')', expected '$($want -replace "`n", ' | ')'") }
      }
    }
    if ($problems.Count -gt 0) {
      return "step '$($spec.Step)': " + ($problems -join '; ') + " [output: " + (($r.Output.Trim() -replace '\s*\r?\n\s*', ' / ')) + "]"
    }

    switch ($spec.Step) {
      'pkg' { $flow['PKG_DIR'] = $r.Outputs['dir']; $flow['PKG_NAME'] = $r.Outputs['name']; $flow['PKG'] = $r.Outputs['name'] }
      'mode' { $flow['MODE'] = $r.Outputs['mode'] }
      'inventory' { $flow['FILES'] = $r.Outputs['files']; $flow['KEPT_FILES'] = $r.Outputs['kept-files'] }
    }
  }
  if ($Case.Final) { return (& $Case.Final $caseDir) }
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

# 200 and 199 declared copies of an unsigned PE, for the bound on the signing list.
$manyExtras = @{}
foreach ($n in 1..200) { $manyExtras[('in/pkg/x{0:D3}.dll' -f $n)] = 'extra.dll' }
$fewExtras = @{}
foreach ($n in 1..199) { $fewExtras[('in/pkg/x{0:D3}.dll' -f $n)] = 'extra.dll' }

$cases = @(
  @{ Id = '2'; Step = 'mode'; Env = @{ REQUIRED = 'true' }; Exit = 1; Expect = @('signing is required'); NoOutput = $true }
  @{ Id = '3'; Step = 'mode'; Env = @{ AZURE_CLIENT_ID = 'x' }; Exit = 1; Expect = @('partial signing configuration', 'missing AZURE_TENANT_ID'); NoOutput = $true }
  @{ Id = '9'; Step = 'mode'; Env = @{ GITHUB_REF = 'refs/tags/x' }; Exit = 1; Expect = @('signing is required', 'refs/tags/x'); NoOutput = $true }
  @{ Id = '4'; Step = 'inventory'; Tree = (With-Tree -Remove 'in/pkg/app.exe'); Exit = 1; Expect = @("own file 'app.exe' not found"); NoOutput = $true }
  @{ Id = '5'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/app.exe' = 'vendor.exe' }); Exit = 1; Expect = @("own file 'app.exe' is Valid"); NoOutput = $true }
  @{ Id = '6'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/vendor-flipped.exe' = 'vendor-flipped.exe' }); Exit = 1; Expect = @("file 'vendor-flipped.exe' has signature status HashMismatch"); NoOutput = $true }
  @{ Id = '7'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/extra.dll' = 'extra.dll' }); Exit = 1; Expect = @("unsigned file 'extra.dll' is neither an own file"); NoOutput = $true }
  # Case 8 runs the whole road of an extra file: mode, pkg, inventory, verify (skip), pack and check, all green.
  @{ Id = '8'; Tree = (With-Tree -Add @{ 'in/pkg/extra.dll' = 'extra.dll' }); Env = @{ EXTRA_FILES = '["extra.dll"]' }
     Steps = @(
       @{ Step = 'mode'; Expect = @('UNSIGNED trial'); Outputs = @{ mode = 'skip' } },
       @{ Step = 'pkg'; Outputs = @{ name = 'pkg' } },
       @{ Step = 'inventory'; Expect = @("extra file extra.dll: NotSigned, matched 'extra.dll'")
          Outputs = [ordered]@{ count = '2'; files = "{PKG}\app.exe`n{PKG}\extra.dll"; 'kept-count' = '1'; 'kept-files' = '{PKG}\vendor.exe' } },
       @{ Step = 'verify'; Expect = @('unsigned') },
       @{ Step = 'pack' },
       @{ Step = 'check' }
     )
     Final = {
       param($caseDir)
       $names = @(Get-ChildItem -LiteralPath (Join-Path $caseDir 'out') -Name | Sort-Object)
       if (($names -join ',') -ne 'pkg.zip,pkg.zip.sha256') { return "out/ holds '$($names -join ', ')', expected pkg.zip and pkg.zip.sha256" }
       return $null
     } }
  @{ Id = 'S1.A1'; Step = 'inputs'; Env = @{ OWN_FILES = '["creds.exe"' }; Exit = 1; Expect = @('own-files is not a JSON list') }
  @{ Id = 'S1.A2'; Step = 'inputs'; Env = @{ ARTIFACTS = '["cli win"]'; OWN_FILES = '["../x.exe"]' }; Exit = 1; Expect = @("artifact name 'cli win'", "own-files entry '../x.exe'") }
  @{ Id = 'S1.A3'; Step = 'inputs'; Env = @{ OWN_FILES = '[]' }; Exit = 1; Expect = @('own-files is empty') }
  # Win32 strips a trailing dot, so 'app.exe.' names the same file as 'app.exe': refused, not left to the duplicate check.
  @{ Id = 'S1.A9'; Step = 'inputs'; Env = @{ OWN_FILES = '["app.exe","app.exe."]' }; Exit = 1; Expect = @("own-files entry 'app.exe.'") }
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
  # E1.A4: the zip is compared with what was VERIFIED. Here the zip gets an extra file after pack: check is red and names it.
  @{ Id = 'E1.A4'
     Steps = @(
       @{ Step = 'pkg' },
       @{ Step = 'verify'; Env = @{ MODE = 'skip' } },
       @{ Step = 'pack' },
       @{ Step = 'check'; Exit = 1; Expect = @('injected.txt'); NoOutput = $true
          Prepare = {
            param($caseDir, $pkgDir)
            $inj = Join-Path $caseDir 'inj\pkg'
            $null = New-Item -ItemType Directory -Path $inj -Force
            [System.IO.File]::WriteAllText((Join-Path $inj 'injected.txt'), 'tampered')
            Push-Location (Join-Path $caseDir 'inj')
            try { & 7z u (Join-Path $caseDir 'out\pkg.zip') 'pkg\injected.txt' | Out-Null; if ($LASTEXITCODE -ne 0) { throw "7z u exited $LASTEXITCODE" } } finally { Pop-Location }
          } }
     ) }
  # B (TOCTOU): a file under in/pkg changes AFTER verify and BEFORE pack. The zip holds the changed bytes, so it differs from
  # what was verified: check must be red and name the file.
  @{ Id = 'B.toctou'
     Steps = @(
       @{ Step = 'pkg' },
       @{ Step = 'verify'; Env = @{ MODE = 'skip' } },
       @{ Step = 'pack'
          Prepare = {
            param($caseDir, $pkgDir)
            $fs = [System.IO.File]::Open((Join-Path $pkgDir 'app.exe'), [System.IO.FileMode]::Append)
            try { $fs.WriteByte(0) } finally { $fs.Dispose() }
          } },
       @{ Step = 'check'; Exit = 1; Expect = @('app.exe'); NoOutput = $true }
     ) }
  # B: verify writes the manifest of every file under in/pkg (both modes): sha256, two spaces, a relative path with '/'.
  @{ Id = 'B.manifest'; Step = 'verify'; Env = @{ MODE = 'skip' }; Exit = 0
     Final = {
       param($caseDir)
       $f = Join-Path $caseDir 'verified.sha256'
       if (-not (Test-Path -LiteralPath $f)) { return 'verify wrote no manifest' }
       $lines = @([System.IO.File]::ReadAllText($f) -split "`r?`n" | Where-Object { $_ -ne '' })
       foreach ($name in 'app.exe', 'vendor.exe') {
         $h = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $caseDir "in\pkg\$name")).Hash.ToLowerInvariant()
         if ($lines -cnotcontains "$h  $name") { return "manifest lacks '$h  $name': $($lines -join ' | ')" }
       }
       if ($lines.Count -ne 2) { return "manifest has $($lines.Count) lines, expected 2" }
       return $null
     } }
  # The verify step, without Azure: the signer and the status are read from files that are signed already.
  @{ Id = 'V-pos'; Step = 'verify'; Env = @{ MODE = 'sign'; FILES = '{PKG}\vendor.exe'; KEPT_FILES = ''; SIGNING_PUBLISHER = '{SIGNER}' }; Exit = 0; Expect = @('verified ', 'timestamped') }
  @{ Id = 'V-pub'; Step = 'verify'; Env = @{ MODE = 'sign'; FILES = '{PKG}\vendor.exe'; KEPT_FILES = ''; SIGNING_PUBLISHER = 'Wrong Org' }; Exit = 1; Expect = @('vendor.exe', "signed by '{SIGNER}'", "expected publisher 'Wrong Org'") }
  @{ Id = 'V-case'; Step = 'verify'; Env = @{ MODE = 'sign'; FILES = '{PKG}\vendor.exe'; KEPT_FILES = ''; SIGNING_PUBLISHER = '{SIGNER_LOWER}' }; Exit = 1; Expect = @('vendor.exe', "expected publisher '{SIGNER_LOWER}'") }
  @{ Id = 'V-unsigned'; Step = 'verify'; Env = @{ MODE = 'sign'; FILES = '{PKG}\app.exe'; KEPT_FILES = ''; SIGNING_PUBLISHER = '{SIGNER}' }; Exit = 1; Expect = @('app.exe', 'NotSigned') }
  @{ Id = 'V-kept'; Step = 'verify'; Tree = (With-Tree -Add @{ 'in/pkg/vendor-flipped.exe' = 'vendor-flipped.exe' })
     Env = @{ MODE = 'sign'; FILES = '{PKG}\vendor.exe'; KEPT_FILES = '{PKG}\vendor-flipped.exe'; SIGNING_PUBLISHER = '{SIGNER}' }; Exit = 1; Expect = @('vendor-flipped.exe', 'HashMismatch') }
  @{ Id = 'V-skip'; Step = 'verify'; Env = @{ MODE = 'skip'; FILES = '{PKG}\app.exe'; KEPT_FILES = '' }; Exit = 0; Expect = @('unsigned') }
  # A: a PE is found by its first two bytes (MZ), whatever its name. Unsigned and undeclared is red; declared is signed; Valid is kept.
  @{ Id = 'A.bin'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/helper.bin' = 'app.exe' }); Exit = 1; Expect = @("unsigned file 'helper.bin' is neither an own file"); NoOutput = $true }
  @{ Id = 'A.noext'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/noext' = 'app.exe' }); Exit = 1; Expect = @("unsigned file 'noext' is neither an own file"); NoOutput = $true }
  @{ Id = 'A.extra'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/helper.bin' = 'app.exe' }); Env = @{ EXTRA_FILES = '["helper.bin"]' }; Exit = 0
     Expect = @("extra file helper.bin: NotSigned, matched 'helper.bin'"); Outputs = @{ count = '2'; 'kept-count' = '1' } }
  @{ Id = 'A.kept'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/vendor.dat' = 'vendor.exe' }); Exit = 0
     Expect = @('kept vendor file vendor.dat: Valid'); Outputs = @{ count = '1'; 'kept-count' = '2' } }
  @{ Id = 'A.text'; Step = 'inventory'; Tree = (With-Tree -Add @{ 'in/pkg/notes.txt' = 'text:hello' }); Exit = 0; Outputs = @{ count = '1'; 'kept-count' = '1' } }
  # C: the package folder name has no leading dash (7z would read it as a switch) and no comma (the signing action splits on it).
  @{ Id = 'C.dash'; Step = 'pkg'; Tree = [ordered]@{ 'in/-x' = '<dir>' }; Exit = 1; Expect = @("package folder name '-x'"); NoOutput = $true }
  @{ Id = 'C.comma'; Step = 'pkg'; Tree = [ordered]@{ 'in/a,b' = '<dir>' }; Exit = 1; Expect = @("package folder name 'a,b'"); NoOutput = $true }
  # E: more than 200 files to sign is one finding (the list travels through an environment variable).
  @{ Id = 'E.201'; Step = 'inventory'; Tree = (With-Tree -Add $manyExtras); Env = @{ EXTRA_FILES = '["x*.dll"]' }; Exit = 1; Expect = @('more than 200 files to sign'); NoOutput = $true }
  @{ Id = 'E.200'; Step = 'inventory'; Tree = (With-Tree -Add $fewExtras); Env = @{ EXTRA_FILES = '["x*.dll"]' }; Exit = 0; Outputs = @{ count = '200' } }
  # F: the one-directory error says how to cure it when the package folder itself was uploaded.
  @{ Id = 'F.cure'; Step = 'pkg'; Tree = [ordered]@{ 'in/app.exe' = 'app.exe'; 'in/vendor.exe' = 'vendor.exe' }; Exit = 1; Expect = @('exactly one directory', 'upload its PARENT'); NoOutput = $true }
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

  $vendorSig = Get-AuthenticodeSignature -LiteralPath (Join-Path $fixDir 'vendor.exe')
  $script:signer = [string]$vendorSig.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
  if (($script:signer -eq '') -or ($script:signer -ceq $script:signer.ToLowerInvariant())) { throw "fixture premise broken: the vendor signer '$($script:signer)' must be non-empty and have an upper-case letter" }
  Write-Host "vendor signer: '$($script:signer)'"

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
