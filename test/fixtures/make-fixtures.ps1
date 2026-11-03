<#
  Makes the four fixtures of the sign-windows self-test at run time. Nothing binary is committed.

    app.exe              an UNSIGNED apphost: `dotnet new console`, then `dotnet publish -r win-x64 --self-contained false -m:4`
    vendor.exe           a copy of C:\Program Files\dotnet\dotnet.exe: Microsoft-signed with an EMBEDDED Authenticode signature
    vendor-flipped.exe   vendor.exe with one byte in the middle of the file changed (HashMismatch)
    extra.dll            a copy of app.exe

  Every premise is asserted before the file is used; a wrong premise is a loud failure, never a silent fallback.
  Usage: make-fixtures.ps1 -OutDir <existing empty dir> -WorkDir <existing empty dir for the throwaway project>
#>
param(
  [Parameter(Mandatory)][string]$OutDir,
  [Parameter(Mandatory)][string]$WorkDir
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'

function Assert-Sig([string]$Path, [string]$Status, [string]$What) {
  $sig = Get-AuthenticodeSignature -LiteralPath $Path
  if ([string]$sig.Status -ne $Status) {
    throw "fixture premise broken: $What is '$($sig.Status)', expected '$Status' ($Path)"
  }
  return $sig
}

function Invoke-Dotnet([string[]]$Arguments) {
  & dotnet @Arguments 2>&1 | ForEach-Object { Write-Host "  dotnet: $_" }
  if ($LASTEXITCODE -ne 0) { throw "dotnet $($Arguments -join ' ') exited $LASTEXITCODE" }
}

# app.exe: the unsigned apphost of a throwaway console project.
$proj = Join-Path $WorkDir 'fixapp'
$pub = Join-Path $WorkDir 'publish'
Invoke-Dotnet @('new', 'console', '--name', 'fixapp', '--output', $proj, '--no-restore')
Invoke-Dotnet @('publish', $proj, '-c', 'Release', '-r', 'win-x64', '--self-contained', 'false', '--output', $pub, '-m:4', '-nodeReuse:false', '-p:UseSharedCompilation=false')
$built = Join-Path $pub 'fixapp.exe'
if (-not (Test-Path -LiteralPath $built -PathType Leaf)) { throw "the apphost was not built: $built" }
Copy-Item -LiteralPath $built -Destination (Join-Path $OutDir 'app.exe')
[void](Assert-Sig (Join-Path $OutDir 'app.exe') 'NotSigned' 'the built apphost app.exe')

# vendor.exe: an embedded-signed Microsoft file. System32 files are catalog-signed and do not qualify.
$dotnetExe = 'C:\Program Files\dotnet\dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnetExe -PathType Leaf)) { throw "fixture source missing: $dotnetExe" }
Copy-Item -LiteralPath $dotnetExe -Destination (Join-Path $OutDir 'vendor.exe')
$vendorSig = Assert-Sig (Join-Path $OutDir 'vendor.exe') 'Valid' 'the vendor copy vendor.exe'
if ([string]$vendorSig.SignatureType -ne 'Authenticode') {
  throw "fixture premise broken: vendor.exe has SignatureType '$($vendorSig.SignatureType)', expected 'Authenticode' (an embedded signature)"
}

# vendor-flipped.exe: one byte in the middle of the file changed.
$bytes = [System.IO.File]::ReadAllBytes((Join-Path $OutDir 'vendor.exe'))
$mid = [int][Math]::Floor($bytes.Length / 2)
$bytes[$mid] = $bytes[$mid] -bxor 0xFF
[System.IO.File]::WriteAllBytes((Join-Path $OutDir 'vendor-flipped.exe'), $bytes)
[void](Assert-Sig (Join-Path $OutDir 'vendor-flipped.exe') 'HashMismatch' 'the flipped copy vendor-flipped.exe')

# extra.dll: a copy of app.exe (an unsigned PE that is not the product's declared binary).
Copy-Item -LiteralPath (Join-Path $OutDir 'app.exe') -Destination (Join-Path $OutDir 'extra.dll')
[void](Assert-Sig (Join-Path $OutDir 'extra.dll') 'NotSigned' 'extra.dll')

Write-Host "fixtures ready in $OutDir (vendor signer: $($vendorSig.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)), $($vendorSig.SignatureType))"
