<#
.SYNOPSIS
  Builds the editor in the ReleasePackage configuration (Release without the self tests) and assembles a shippable
  Treadle folder, its zip and the zip's SHA-256.

.DESCRIPTION
  Output: dist\Treadle-<version>-win64\ and dist\Treadle-<version>-win64.zip (+ .zip.sha256). The zip holds the
  folder's contents at its root (what the in-app updater unpacks and checks). docs\Releasing.md is the full story.

  Layout of the folder:
    Treadle.exe, treadlehost.dll          the editor and its native ImGui/SDL2 host
    assets\fonts\                         the icon font and its licence
    core\                                 the core library (TreadleCore\core), found next to the exe
    tools\runtime\                        the C runtime sources every program is built with
    tools\llvm\                           the trimmed llvm-mingw toolchain (packaging\llvm-files.txt)
    tools\libclang\                       libclang.dll + its builtin headers (C header import)
    samples\m1, samples\m3-core           two small projects to open and build
    docs\                                 the user-facing pages (Getting-Started + the list in $Docs), docs\images\
    LICENSE, NOTICE, THIRD_PARTY.md, THIRD_PARTY\, VERSION.txt

  Inputs a clean clone gets with the get-*.ps1 scripts: the toolchain (scripts\get-llvm-mingw.ps1 ->
  tools\llvm-mingw) and libclang (scripts\get-libclang.ps1 -> tools\libclang). The version is VERSION.txt; it must
  agree with TreadleInfo (TreadleCore\src\Document\CommandLine.bf) and the [Platform.Windows] versions of
  TreadleEditor\BeefProj.toml, and the packaged exe's --version must print it.

.PARAMETER NoBuild
  Package whatever is already in build\ReleasePackage_Win64 (-Verify then uses build\Release_Win64 as it is).

.PARAMETER Llvm
  The llvm-mingw 20261006 root to trim from. Default: TREADLE_LLVM, else tools\llvm-mingw of the repository
  (scripts\get-llvm-mingw.ps1).

.PARAMETER LibClang
  The libclang install (bin\libclang.dll, lib\clang\23\include). Default: TREADLE_LIBCLANG, else tools\libclang of
  the repository, else of the main checkout when this is a git worktree.

.PARAMETER NoDebugger
  Leave lldb-dap and its DLLs out of tools\llvm (the "[debug]" lines of packaging\llvm-files.txt).

.PARAMETER Out
  The folder to assemble (default dist\Treadle-<version>-win64). An earlier package folder there is emptied first;
  any other non-empty folder is refused.

.PARAMETER ZipDir
  Where the zip and its .sha256 are written (default dist\).

.PARAMETER TrimToolchainTo
  Only copy the trimmed toolchain into this (empty or absent) folder and print its size; nothing else.

.PARAMETER Verify
  After zipping: unpack the zip into -VerifyDir and run the proof commands from the unpacked copy with
  TREADLE_LLVM / TREADLE_CORE / TREADLE_LIBCLANG unset, TREADLE_NO_FALLBACK=1 and a fresh LOCALAPPDATA:
  --version, --build-run m1, --build-run m3-core -- a b c, --import-c small.cimport; the packaged exe ignores
  TREADLE_SELFTEST (starts normally, logs no self-test line), holds no "SELFTEST" string and is smaller than the
  Release build of the same source; the Release build (with the self tests), put into a copy of the unpacked
  folder, runs TREADLE_SELFTEST=smoke,debug,quit there (the package's lldb-dap and toolchain).

.PARAMETER VerifyDir
  Where -Verify unpacks (default %TEMP%\treadle-pkg-verify-<stamp>). Emptied first when it holds an earlier run.
#>
param(
    [switch]$NoBuild,
    [string]$Llvm = "",
    [string]$LibClang = "",
    [switch]$NoDebugger,
    [string]$Out = "",
    [string]$ZipDir = "",
    [string]$TrimToolchainTo = "",
    [switch]$Verify,
    [string]$VerifyDir = ""
)

$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
# One BeefBuild / clang at a time on this machine, below normal priority (children inherit it).
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch {}

# ---------------------------------------------------------------------------------------------- inputs

function Find-Llvm {
    $cands = @()
    if ($Llvm) { $cands += $Llvm }
    elseif ($env:TREADLE_LLVM) { $cands += $env:TREADLE_LLVM }
    else { $cands += (Join-Path $Repo "tools\llvm-mingw") }
    foreach ($c in $cands) { if (Test-Path (Join-Path $c "bin\clang-23.exe")) { return (Resolve-Path $c).Path } }
    throw "llvm-mingw 20261006 not found ($($cands -join ', ')): run scripts\get-llvm-mingw.ps1 or pass -Llvm"
}

function Find-LibClang {
    $cands = @()
    if ($LibClang) { $cands += $LibClang }
    elseif ($env:TREADLE_LIBCLANG) { $cands += $env:TREADLE_LIBCLANG }
    else {
        $cands += (Join-Path $Repo "tools\libclang")
        $common = (git -C $Repo rev-parse --path-format=absolute --git-common-dir 2>$null)
        if ($common) { $cands += (Join-Path (Split-Path -Parent $common) "tools\libclang") }
    }
    foreach ($c in $cands) {
        if ((Test-Path (Join-Path $c "bin\libclang.dll")) -and (Test-Path (Join-Path $c "lib\clang\23\include\stddef.h"))) { return (Resolve-Path $c).Path }
    }
    throw "libclang not found ($($cands -join ', ')): run scripts\get-libclang.ps1 or pass -LibClang"
}

function Get-FolderBytes([string]$dir) {
    $sum = (Get-ChildItem -LiteralPath $dir -Recurse -Force -File | Measure-Object -Property Length -Sum).Sum
    if ($sum) { return [int64]$sum } else { return [int64]0 }
}

function Format-MB([int64]$bytes) { return "{0:N1} MB" -f ($bytes / 1MB) }

# Copies the subset of llvm-mingw listed in packaging\llvm-files.txt (a file, or a folder ending in "/"; "!" excludes;
# "[debug]" lines are skipped with -NoDebugger).
function Copy-ToolchainSubset([string]$src, [string]$dst, [bool]$withDebugger) {
    $list = Join-Path $Repo "packaging\llvm-files.txt"
    $includes = @(); $excludes = @()
    foreach ($raw in Get-Content -LiteralPath $list) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        $debug = $line.EndsWith("[debug]")
        if ($debug) { $line = $line.Substring(0, $line.Length - 7).Trim(); if (-not $withDebugger) { continue } }
        if ($line.StartsWith("!")) { $excludes += $line.Substring(1).Replace('/', '\').TrimEnd('\') } else { $includes += $line }
    }
    New-Item -ItemType Directory -Force $dst | Out-Null
    foreach ($inc in $includes) {
        $rel = $inc.Replace('/', '\')
        $from = Join-Path $src $rel.TrimEnd('\')
        if (-not (Test-Path -LiteralPath $from)) { throw "toolchain entry missing in $src`: $inc" }
        if ($rel.EndsWith('\')) {
            $base = $rel.TrimEnd('\')
            foreach ($f in Get-ChildItem -LiteralPath $from -Recurse -Force -File) {
                $r = $base + $f.FullName.Substring($from.Length)
                $skip = $false
                foreach ($ex in $excludes) { if ($r -eq $ex -or $r.StartsWith($ex + '\')) { $skip = $true; break } }
                if ($skip) { continue }
                $to = Join-Path $dst $r
                $toDir = Split-Path -Parent $to
                if (-not (Test-Path -LiteralPath $toDir)) { New-Item -ItemType Directory -Force $toDir | Out-Null }
                Copy-Item -LiteralPath $f.FullName $to
            }
        } else {
            $to = Join-Path $dst $rel
            $toDir = Split-Path -Parent $to
            if (-not (Test-Path -LiteralPath $toDir)) { New-Item -ItemType Directory -Force $toDir | Out-Null }
            Copy-Item -LiteralPath $from $to
        }
    }
}

$LlvmSrc = Find-Llvm

if ($TrimToolchainTo) {
    if ((Test-Path $TrimToolchainTo) -and @(Get-ChildItem -Force $TrimToolchainTo).Count -gt 0) { throw "$TrimToolchainTo is not empty" }
    Copy-ToolchainSubset $LlvmSrc $TrimToolchainTo (-not $NoDebugger)
    Write-Host "Trimmed toolchain from $LlvmSrc"
    Write-Host "  $TrimToolchainTo`: $(Format-MB (Get-FolderBytes $TrimToolchainTo))"
    exit 0
}

$LibClangSrc = Find-LibClang

# ---------------------------------------------------------------------------------------------- version

$VersionFile = Join-Path $Repo "VERSION.txt"
if (-not (Test-Path $VersionFile)) { throw "VERSION.txt missing at the repository root" }
$FullVersion = (Get-Content $VersionFile -TotalCount 1).Trim()
if ($FullVersion -notmatch '^(\d+)\.(\d+)\.(\d+)(?:-([a-z0-9.]+))?$') { throw "VERSION.txt says '$FullVersion', expected MAJOR.MINOR.PATCH[-channel]" }
$Version = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
$Channel = $Matches[4]
$info = [IO.File]::ReadAllText((Join-Path $Repo "TreadleCore\src\Document\CommandLine.bf"))
if ($info -notmatch 'public const String Version = "([^"]+)";') { throw "TreadleInfo.Version not found in CommandLine.bf" }
$codeVersion = $Matches[1]
if ($info -notmatch 'public const String Channel = "([^"]*)";') { throw "TreadleInfo.Channel not found in CommandLine.bf" }
$codeChannel = $Matches[1]
$codeFull = if ($codeChannel) { "$codeVersion-$codeChannel" } else { $codeVersion }
if ($codeFull -ne $FullVersion) { throw "VERSION.txt says $FullVersion, TreadleInfo (CommandLine.bf) says ${codeFull}: change both" }
$proj = [IO.File]::ReadAllText((Join-Path $Repo "TreadleEditor\BeefProj.toml"))
if ($proj -notmatch '(?m)^ProductVersion = "([^"]*)"' -or $Matches[1] -ne $Version) { throw "TreadleEditor\BeefProj.toml ProductVersion is not $Version" }
if ($proj -notmatch '(?m)^FileVersion = "([^"]*)"' -or $Matches[1] -ne "$Version.0") { throw "TreadleEditor\BeefProj.toml [Platform.Windows] FileVersion is not $Version.0" }
$Name = "Treadle-$FullVersion-win64"

# Licence texts that travel with the binaries.
foreach ($f in @("LICENSE", "NOTICE", "THIRD_PARTY.md")) {
    if (-not (Test-Path (Join-Path $Repo $f))) { throw "Missing required file: $f (repository root)" }
}
$ThirdPartyFiles = @(Get-ChildItem (Join-Path $Repo "THIRD_PARTY") -Filter *.txt | Sort-Object Name)
foreach ($need in @("LLVM-LICENSE.txt", "mingw-w64-runtime-COPYING.txt", "Python-LICENSE.txt")) {
    if (-not ($ThirdPartyFiles | Where-Object Name -eq $need)) { throw "Missing third-party licence text: THIRD_PARTY\$need" }
}

# The user-facing pages: Getting-Started (written for the package) and the pages the package names.
$Docs = @("Getting-Started.md", "Language-Guide.md", "Core-Library.md", "C-Import.md", "Debugging.md", "Keyboard.md", "Linux.md", "Performance.md", "Known-Issues.md")

# ---------------------------------------------------------------------------------------------- build

$BeefBuild = if ($env:TREADLE_BEEFBUILD) { $env:TREADLE_BEEFBUILD } else { "C:\Program Files\BeefLang\bin\BeefBuild.exe" }
# The package is built in the ReleasePackage configuration: Release settings without the TREADLE_SELFTEST define,
# so the developer self tests are not in the shipped exe (docs/Releasing.md, "Self tests and the package build").
# -Verify also builds Release (the same code with the self tests) to compare sizes and to run the debugger self test
# in the package's layout.
$Rel = Join-Path $Repo "build\ReleasePackage_Win64\TreadleEditor"
$TestRel = Join-Path $Repo "build\Release_Win64\TreadleEditor"
function Invoke-BeefBuild([string]$config) {
    if (Get-Process BeefBuild -ErrorAction SilentlyContinue) { Write-Warning "another BeefBuild is running; this build waits for nothing and may be slow" }
    Write-Host "== BeefBuild ($config)"
    $log = Join-Path ([IO.Path]::GetTempPath()) ("treadle-pkg-build-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $bp = Start-Process -FilePath $BeefBuild -ArgumentList "-workspace=$Repo", "-config=$config", "-platform=Win64" -NoNewWindow -PassThru -RedirectStandardOutput $log
    $null = $bp.Handle
    try { $bp.PriorityClass = 'BelowNormal' } catch {}
    $bp.WaitForExit()
    if ($bp.ExitCode -ne 0) { Get-Content $log | Select-String '^ERROR' -Context 0, 2 | Select-Object -First 20 | Out-Host; Remove-Item -Force $log; throw "BeefBuild $config failed (exit $($bp.ExitCode))" }
    Remove-Item -Force $log
}
if (-not $NoBuild) {
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Rel "Treadle.exe")
    Invoke-BeefBuild "ReleasePackage"
    if ($Verify) { Invoke-BeefBuild "Release" }
}
$exe = Join-Path $Rel "Treadle.exe"
$nativeHost = Join-Path $Rel "treadlehost.dll"
foreach ($f in @($exe, $nativeHost)) { if (-not (Test-Path $f)) { throw "Missing build output: $f" } }
$vi = (Get-Item $exe).VersionInfo
if ($vi.ProductVersion -ne $Version) { throw "Treadle.exe ProductVersion is '$($vi.ProductVersion)', expected $Version (rebuild without -NoBuild)" }

# ---------------------------------------------------------------------------------------------- assemble

if (-not $Out) { $Out = Join-Path $Repo "dist\$Name" }
if (-not $ZipDir) { $ZipDir = Join-Path $Repo "dist" }
if (Test-Path $Out) {
    $left = @(Get-ChildItem -LiteralPath $Out -Force)
    if ($left.Count -gt 0) {
        if ((Test-Path (Join-Path $Out "VERSION.txt")) -and (Test-Path (Join-Path $Out "Treadle.exe"))) {
            Write-Host "Emptying the earlier package folder $Out"
            $left | Remove-Item -Recurse -Force
        } else { throw "$Out is not empty and is not an earlier package folder (no VERSION.txt and Treadle.exe)" }
    }
}
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path

Copy-Item $exe (Join-Path $Out "Treadle.exe")
Copy-Item $nativeHost (Join-Path $Out "treadlehost.dll")
# Any other DLL the build put beside the exe (none today: the Beef runtime is linked in). vbhost.dll is the host
# under its earlier name, left in build folders made before the host was renamed; it is not shipped.
foreach ($d in Get-ChildItem $Rel -Filter *.dll) { if ($d.Name -ne "treadlehost.dll" -and $d.Name -ne "vbhost.dll") { Copy-Item $d.FullName (Join-Path $Out $d.Name) } }
New-Item -ItemType Directory -Force (Join-Path $Out "assets\fonts") | Out-Null
Copy-Item (Join-Path $Repo "TreadleEditor\assets\fonts\*") (Join-Path $Out "assets\fonts")

# The core library, as the editor finds it next to its exe (CoreSource.FindFolder).
Copy-Item -Recurse (Join-Path $Repo "TreadleCore\core") (Join-Path $Out "core")
# The C runtime sources (the back end also has them built in; the folder wins when present).
New-Item -ItemType Directory -Force (Join-Path $Out "tools\runtime") | Out-Null
Copy-Item (Join-Path $Repo "tools\runtime\treadle_rt.c"), (Join-Path $Repo "tools\runtime\treadle_rt.h") (Join-Path $Out "tools\runtime")

Write-Host "== Toolchain subset from $LlvmSrc"
Copy-ToolchainSubset $LlvmSrc (Join-Path $Out "tools\llvm") (-not $NoDebugger)
Write-Host "== libclang from $LibClangSrc"
New-Item -ItemType Directory -Force (Join-Path $Out "tools\libclang\bin") | Out-Null
Copy-Item (Join-Path $LibClangSrc "bin\libclang.dll") (Join-Path $Out "tools\libclang\bin")
New-Item -ItemType Directory -Force (Join-Path $Out "tools\libclang\lib\clang\23") | Out-Null
Copy-Item -Recurse (Join-Path $LibClangSrc "lib\clang\23\include") (Join-Path $Out "tools\libclang\lib\clang\23\include")

# Samples to open and build (copies of TreadleCore\samples\m1 and m3-core; SDL2's sample is not shipped).
foreach ($s in @("m1", "m3-core")) {
    New-Item -ItemType Directory -Force (Join-Path $Out "samples") | Out-Null
    Copy-Item -Recurse (Join-Path $Repo "TreadleCore\samples\$s") (Join-Path $Out "samples\$s")
    # A sample built or run in this checkout has a build folder: it does not ship.
    $sb = Join-Path $Out "samples\$s\build"
    if (Test-Path $sb) { Remove-Item -Recurse -Force $sb }
}

# Docs: the named user-facing pages only (no developer pages, tests or fixtures).
New-Item -ItemType Directory -Force (Join-Path $Out "docs") | Out-Null
foreach ($d in $Docs) {
    $p = Join-Path $Repo "docs\$d"
    if (Test-Path $p) { Copy-Item $p (Join-Path $Out "docs\$d") }
    elseif ($d -eq "Getting-Started.md") { throw "docs\Getting-Started.md is missing" }
    else { Write-Warning "docs\$d is not in this checkout; not shipped" }
}
# The pictures the pages show (docs\images, PNG only).
$images = Join-Path $Repo "docs\images"
if (Test-Path $images) {
    New-Item -ItemType Directory -Force (Join-Path $Out "docs\images") | Out-Null
    Copy-Item (Join-Path $images "*.png") (Join-Path $Out "docs\images")
}

foreach ($f in @("LICENSE", "NOTICE", "THIRD_PARTY.md")) { Copy-Item (Join-Path $Repo $f) (Join-Path $Out $f) }
New-Item -ItemType Directory -Force (Join-Path $Out "THIRD_PARTY") | Out-Null
foreach ($f in $ThirdPartyFiles) { Copy-Item $f.FullName (Join-Path $Out "THIRD_PARTY\$($f.Name)") }
Set-Content -Path (Join-Path $Out "VERSION.txt") -Value $FullVersion -Encoding ascii

# No build leftovers or test material outside the toolchain.
$bad = @(Get-ChildItem -Recurse -File $Out | Where-Object { $_.FullName -notlike "$Out\tools\*" -and ($_.Extension -in @(".o", ".a", ".obj", ".pdb", ".lib", ".ilk", ".exp", ".tir", ".expected")) })
if ($bad.Count -gt 0) { throw "Package contains build or test leftovers: $($bad.FullName -join ', ')" }

# The packaged exe must print the version VERSION.txt says (--version opens no window).
$vOut = Join-Path ([IO.Path]::GetTempPath()) ("treadle-version-" + [Guid]::NewGuid().ToString("N") + ".txt")
try {
    $vp = Start-Process -FilePath (Join-Path $Out "Treadle.exe") -ArgumentList "--version" -NoNewWindow -PassThru -RedirectStandardOutput $vOut
    $null = $vp.Handle
    if (-not $vp.WaitForExit(30000)) { try { Stop-Process -Id $vp.Id -Force } catch {}; throw "Treadle.exe --version did not exit in 30 s" }
    $reported = (Get-Content $vOut -TotalCount 1 -ErrorAction SilentlyContinue | Out-String).Trim()
} finally { Remove-Item -Force -ErrorAction SilentlyContinue $vOut }
if ($reported -notlike "Treadle $FullVersion (host contract *") { throw "Treadle.exe --version printed '$reported', expected 'Treadle $FullVersion (host contract n)'" }

# ---------------------------------------------------------------------------------------------- zip

New-Item -ItemType Directory -Force $ZipDir | Out-Null
$zip = Join-Path (Resolve-Path $ZipDir).Path "$Name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($item in Get-ChildItem -Recurse -Force -File $Out | Sort-Object FullName) {
        $relName = $item.FullName.Substring($Out.Length + 1).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $item.FullName, $relName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $archive.Dispose() }
$sha = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
Set-Content -Path "$zip.sha256" -Value "$sha  $(Split-Path -Leaf $zip)" -Encoding ascii

$folderBytes = Get-FolderBytes $Out
$llvmBytes = Get-FolderBytes (Join-Path $Out "tools\llvm")
$clangBytes = Get-FolderBytes (Join-Path $Out "tools\libclang")
Write-Host "Packaged $Out"
Write-Host "  folder $(Format-MB $folderBytes) (tools\llvm $(Format-MB $llvmBytes), tools\libclang $(Format-MB $clangBytes))"
Write-Host "  zip    $zip ($(Format-MB (Get-Item $zip).Length))"
Write-Host "  sha256 $sha"
Write-Host "  exe    $reported"

if (-not $Verify) { exit 0 }

# ---------------------------------------------------------------------------------------------- verify

# Runs the packaged exe with a clean environment: no TREADLE_* lookups, no machine fallback, a fresh LOCALAPPDATA
# (so no cached runtime object and no settings), and returns exit code + stdout + stderr.
function Invoke-Packaged([string]$exePath, [string[]]$argv, [hashtable]$extraEnv, [int]$timeoutSec) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exePath
    $psi.Arguments = (($argv | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = Split-Path -Parent $exePath
    foreach ($k in @("TREADLE_LLVM", "TREADLE_CORE", "TREADLE_LIBCLANG", "TREADLE_RUNTIME", "TREADLE_SAMPLES", "TREADLE_LLDB_DAP", "TREADLE_SELFTEST", "TREADLE_HOME", "TREADLE_UPDATE_REPOSITORY")) {
        if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) }
    }
    $psi.EnvironmentVariables["TREADLE_NO_FALLBACK"] = "1"
    foreach ($k in $extraEnv.Keys) { $psi.EnvironmentVariables[$k] = $extraEnv[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    try { $p.PriorityClass = 'BelowNormal' } catch {}
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (-not $p.WaitForExit($timeoutSec * 1000)) { try { $p.Kill() } catch {}; throw "$exePath $($psi.Arguments) did not exit in $timeoutSec s" }
    $p.WaitForExit()
    $sw.Stop()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $so.Result; Err = $se.Result; Ms = $sw.ElapsedMilliseconds }
}

if (-not $VerifyDir) { $VerifyDir = Join-Path ([IO.Path]::GetTempPath()) ("treadle-pkg-verify-" + (Get-Date -Format "yyyyMMdd-HHmmss")) }
if (Test-Path $VerifyDir) {
    if (Test-Path (Join-Path $VerifyDir "verify.marker")) { Remove-Item -Recurse -Force $VerifyDir }
    elseif (@(Get-ChildItem -Force $VerifyDir).Count -gt 0) { throw "$VerifyDir is not empty and is not an earlier verify folder" }
}
New-Item -ItemType Directory -Force $VerifyDir | Out-Null
Set-Content -Path (Join-Path $VerifyDir "verify.marker") -Value "scripts\package.ps1 -Verify" -Encoding ascii
$unz = Join-Path $VerifyDir $Name
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $unz)
$pexe = Join-Path $unz "Treadle.exe"
$work = Join-Path $VerifyDir "work"
$lad = Join-Path $VerifyDir "localappdata"
New-Item -ItemType Directory -Force $work, $lad | Out-Null
# Inputs: copies of the samples and the small C import fixture (header beside the set).
Copy-Item -Recurse (Join-Path $Repo "TreadleCore\samples\m1") (Join-Path $work "m1")
Copy-Item -Recurse (Join-Path $Repo "TreadleCore\samples\m3-core") (Join-Path $work "m3-core")
New-Item -ItemType Directory -Force (Join-Path $work "cimport"), (Join-Path $work "cimport-out") | Out-Null
Copy-Item (Join-Path $Repo "tools\probe\headers\small.h") (Join-Path $work "cimport\small.h")
(Get-Content -Raw (Join-Path $Repo "TreadleCImport\fixtures\small.cimport")).Replace("../../tools/probe/headers/small.h", "small.h") | Set-Content -NoNewline -Encoding ascii (Join-Path $work "cimport\small.cimport")
# The debug self test opens TreadleCore/samples/m1 (TREADLE_SAMPLES points at a copy of the samples folder).
Copy-Item -Recurse (Join-Path $Repo "TreadleCore\samples") (Join-Path $work "samples")
$env1 = @{ LOCALAPPDATA = $lad; TREADLE_HOME = (Join-Path $VerifyDir "home") }

$failures = 0
function Report([string]$what, $r, [bool]$ok) {
    $script:failures += [int](-not $ok)
    Write-Host ("[{0}] {1}  (exit {2}, {3} ms)" -f $(if ($ok) { "ok" } else { "FAIL" }), $what, $r.Code, $r.Ms)
    foreach ($l in ($r.Out.TrimEnd() -split "`r?`n")) { if ($l) { Write-Host "    $l" } }
    foreach ($l in ($r.Err.TrimEnd() -split "`r?`n")) { if ($l) { Write-Host "    ! $l" } }
}

$r = Invoke-Packaged $pexe @("--version") $env1 30
Report "--version" $r ($r.Code -eq 0 -and $r.Out.Trim() -like "Treadle $FullVersion (host contract *")
$r = Invoke-Packaged $pexe @("--build-run", (Join-Path $work "m1")) $env1 300
Report "--build-run m1 (fresh: no runtime cache)" $r ($r.Code -eq 0)
$r = Invoke-Packaged $pexe @("--build-run", (Join-Path $work "m1")) $env1 300
Report "--build-run m1 (again)" $r ($r.Code -eq 0)
$r = Invoke-Packaged $pexe @("--build-run", (Join-Path $work "m3-core"), "--", "a", "b", "c") $env1 300
Report "--build-run m3-core -- a b c" $r ($r.Code -eq 0)
$r = Invoke-Packaged $pexe @("--import-c", (Join-Path $work "cimport\small.cimport"), "--out", (Join-Path $work "cimport-out")) $env1 120
Report "--import-c small.cimport" $r ($r.Code -eq 0 -and (Test-Path (Join-Path $work "cimport-out\small.cdecl")))
# The self tests are not in the package (ReleasePackage, no TREADLE_SELFTEST define): no "SELFTEST" in the exe, a
# smaller exe than the Release build of the same source, and TREADLE_SELFTEST set changes nothing (a normal, quiet
# start that runs no self test: still running after 15 s, no [SELFTEST] line in its log; then closed).
$bytes = [IO.File]::ReadAllBytes($pexe)
$ascii = [Text.Encoding]::ASCII.GetString($bytes)
$utf16 = [Text.Encoding]::Unicode.GetString($bytes)
$testExe = Join-Path $TestRel "Treadle.exe"
$pSize = $bytes.Length; $tSize = if (Test-Path $testExe) { (Get-Item $testExe).Length } else { 0 }
$noString = -not $ascii.Contains("SELFTEST") -and -not $utf16.Contains("SELFTEST")
Report "no SELFTEST string in the packaged exe; $pSize bytes, the Release build with the self tests $tSize bytes" ([pscustomobject]@{ Code = 0; Out = ""; Err = ""; Ms = 0 }) ($noString -and $tSize -gt $pSize)
$stHome = Join-Path $VerifyDir "home-ignored"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $pexe; $psi.UseShellExecute = $false; $psi.WorkingDirectory = $unz
foreach ($k in @($psi.EnvironmentVariables.Keys)) { if ($k -like "TREADLE_*") { $psi.EnvironmentVariables.Remove($k) } }
$psi.EnvironmentVariables["TREADLE_SELFTEST"] = "smoke,quit"
$psi.EnvironmentVariables["TREADLE_WINDOW_HIDDEN"] = "1"
$psi.EnvironmentVariables["TREADLE_HOME"] = $stHome
$psi.EnvironmentVariables["LOCALAPPDATA"] = $lad
$sp = [System.Diagnostics.Process]::Start($psi)
$exited = $sp.WaitForExit(15000)
if (-not $exited) { try { $sp.Kill(); $sp.WaitForExit(10000) | Out-Null } catch {} }
$stLog = Get-ChildItem -Recurse $stHome -Filter "treadle-*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
$stLines = if ($stLog) { @(Select-String -Path $stLog.FullName -Pattern '\[SELFTEST\]') } else { @() }
$started = if ($stLog) { @(Select-String -Path $stLog.FullName -Pattern 'Treadle started') } else { @() }
$code = if ($exited) { $sp.ExitCode } else { "running" }
Report "TREADLE_SELFTEST=smoke,quit is ignored by the packaged exe (normal start, $($stLines.Count) self-test lines)" ([pscustomobject]@{ Code = $code; Out = ""; Err = ""; Ms = 15000 }) ((-not $exited -or $sp.ExitCode -eq 2) -and $stLines.Count -eq 0 -and $started.Count -ge 1)
# The Release build (the same source with the self tests) in a copy of the unpacked folder: the debugger self test
# runs on the package's toolchain (tools\llvm\bin\lldb-dap.exe).
$tl = Join-Path $VerifyDir "test-layout"
Copy-Item -Recurse $unz $tl
Copy-Item -Force $testExe (Join-Path $tl "Treadle.exe")
$env2 = $env1.Clone(); $env2["TREADLE_SELFTEST"] = "smoke,debug,quit"; $env2["TREADLE_SAMPLES"] = (Join-Path $work "samples")
$r = Invoke-Packaged (Join-Path $tl "Treadle.exe") @() $env2 600
$logFile = Get-ChildItem -Recurse (Join-Path $VerifyDir "home") -Filter "treadle-*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
$done = if ($logFile) { @(Select-String -Path $logFile.FullName -Pattern '\[SELFTEST\] done failures=(\d+)' | Select-Object -Last 1) } else { @() }
$dap = if ($logFile) { @(Select-String -Path $logFile.FullName -Pattern 'lldb-dap: ([^)]+)\)' | Select-Object -Last 1) } else { @() }
$r.Out = (@($done | ForEach-Object { $_.Line.Trim() }) + @($dap | ForEach-Object { $_.Line.Trim() })) -join "`n"
Report "TREADLE_SELFTEST=smoke,debug,quit (the Release build in the package layout)" $r ($done.Count -eq 1 -and $done[0].Matches[0].Groups[1].Value -eq "0" -and $dap.Count -eq 1 -and $dap[0].Matches[0].Groups[1].Value -like "$tl\tools\llvm\*")

if ($failures -gt 0) { throw "verify: $failures check(s) failed (work files in $VerifyDir)" }
Write-Host "Verified from $unz with only the package's contents. Work files: $VerifyDir"
