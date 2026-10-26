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
    tools\SDL2\                           SDL2 2.32.10 headers, import library and SDL2.dll for the SDL samples
    samples\                              the sample projects of packaging\samples.txt and their index README.md
    docs\                                 the user-facing pages (Getting-Started + the list in $Docs), docs\images\
    LICENSE, NOTICE, THIRD_PARTY.md, THIRD_PARTY\, VERSION.txt
    files.txt                             every other file of the package (relative, / separators): the list the
                                          in-app updater replaces and removes files by

  Inputs a clean clone gets with the get-*.ps1 scripts: the toolchain (scripts\get-llvm-mingw.ps1 ->
  tools\llvm-mingw) and libclang (scripts\get-libclang.ps1 -> tools\libclang) and SDL2 for the samples (scripts\get-sdl2.ps1 -> tools\SDL2-2.32.10, run by this script
  when no SDL2 is found). The version is VERSION.txt; it must
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

.PARAMETER Sdl2
  The SDL2 2.32.10 mingw development package root (the folder holding x86_64-w64-mingw32) whose files
  packaging\sdl2-files.txt names. Default: TREADLE_SDL2, else tools\SDL2-2.32.10 of the repository, else of the
  main checkout when this is a git worktree, else scripts\get-sdl2.ps1 installs it (pinned archive sha256).

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
  --version, --build-run m1, --build-run m3-core -- a b c, --import-c small.cimport, then three shipped samples
  built in place in the unpacked folder (samples\m3-core, samples\m2-sdl -- --frames 60 with SDL2 from
  tools\SDL2, samples\m4-breakout -- --headless); the packaged exe ignores
  TREADLE_SELFTEST (starts normally, logs no self-test line), holds no "SELFTEST" string and is smaller than the
  Release build of the same source; the Release build (with the self tests), put into a copy of the unpacked
  folder, runs TREADLE_SELFTEST=smoke,debug,quit there (the package's lldb-dap and toolchain). Last, the update
  rehearsal: a copy of the package claiming an older version updates itself to this zip through a local release
  index (TREADLE_UPDATE_INDEX) with `Treadle.exe --update`; the new VERSION.txt and --version, B's files.txt, the
  removal of a file only A listed and the survival of user files are checked.

.PARAMETER VerifyDir
  Where -Verify unpacks (default %TEMP%\treadle-pkg-verify-<stamp>). Emptied first when it holds an earlier run.
#>
param(
    [switch]$NoBuild,
    [string]$Llvm = "",
    [string]$LibClang = "",
    [string]$Sdl2 = "",
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

# SDL2 for the SDL samples (tools\SDL2): the files of packaging\sdl2-files.txt, each checked against its sha256.
$SdlFiles = @()
foreach ($raw in Get-Content -LiteralPath (Join-Path $Repo "packaging\sdl2-files.txt")) {
    $line = $raw.Trim()
    if (-not $line -or $line.StartsWith("#")) { continue }
    $parts = $line -split '\s+', 2
    $SdlFiles += [pscustomobject]@{ Sha = $parts[0].ToLowerInvariant(); Rel = $parts[1].Replace('/', '\') }
}
function Test-Sdl2Root([string]$root) {
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return $false }
    foreach ($s in $SdlFiles) {
        $p = Join-Path $root $s.Rel
        if (-not (Test-Path -LiteralPath $p)) { return $false }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLowerInvariant() -ne $s.Sha) { Write-Warning "$p does not match packaging\sdl2-files.txt"; return $false }
    }
    return (Test-Path -LiteralPath (Join-Path $root "x86_64-w64-mingw32\include\SDL2\SDL.h"))
}
function Find-Sdl2 {
    $cands = @()
    if ($Sdl2) { $cands += $Sdl2 }
    elseif ($env:TREADLE_SDL2) { $cands += $env:TREADLE_SDL2 }
    else {
        $cands += (Join-Path $Repo "tools\SDL2-2.32.10")
        $common = (git -C $Repo rev-parse --path-format=absolute --git-common-dir 2>$null)
        if ($common) { $cands += (Join-Path (Split-Path -Parent $common) "tools\SDL2-2.32.10") }
    }
    foreach ($c in $cands) { if (Test-Sdl2Root $c) { return (Resolve-Path $c).Path } }
    if ($Sdl2 -or $env:TREADLE_SDL2) { throw "SDL2 2.32.10 not found or not the pinned files ($($cands -join ', ')): packaging\sdl2-files.txt" }
    Write-Host "== SDL2 not found ($($cands -join ', ')): scripts\get-sdl2.ps1"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "get-sdl2.ps1") -Root $Repo
    if ($LASTEXITCODE -ne 0) { throw "scripts\get-sdl2.ps1 failed (exit $LASTEXITCODE)" }
    $got = Join-Path $Repo "tools\SDL2-2.32.10"
    if (-not (Test-Sdl2Root $got)) { throw "scripts\get-sdl2.ps1 did not install the files of packaging\sdl2-files.txt into $got" }
    return (Resolve-Path $got).Path
}
$SdlSrc = Find-Sdl2

# The samples that ship (packaging\samples.txt): each needs a project file and a README.md. A folder with both that
# the list does not name ships too, with a warning; "!name" lines keep folders out.
$Samples = @()
$NotShipped = @()
foreach ($raw in Get-Content -LiteralPath (Join-Path $Repo "packaging\samples.txt")) {
    $line = $raw.Trim()
    if (-not $line -or $line.StartsWith("#")) { continue }
    $name = ($line -split '\|', 2)[0].Trim()
    if ($name.StartsWith("!")) { $NotShipped += $name.Substring(1); continue }
    $sdir = Join-Path $Repo "TreadleCore\samples\$name"
    if (-not (Test-Path -LiteralPath $sdir)) { throw "packaging\samples.txt names $name, which is not in TreadleCore\samples" }
    if (-not (Get-ChildItem -LiteralPath $sdir -Filter *.tproj -File)) { throw "sample $name has no .tproj" }
    if (-not (Test-Path -LiteralPath (Join-Path $sdir "README.md"))) { throw "sample $name has no README.md" }
    $Samples += $name
}
foreach ($d in Get-ChildItem -LiteralPath (Join-Path $Repo "TreadleCore\samples") -Directory | Sort-Object Name) {
    if ($Samples -contains $d.Name -or $NotShipped -contains $d.Name) { continue }
    if ((Get-ChildItem -LiteralPath $d.FullName -Filter *.tproj -File) -and (Test-Path -LiteralPath (Join-Path $d.FullName "README.md"))) {
        Write-Warning "sample $($d.Name) is not in packaging\samples.txt: it ships; add its line (or a !$($d.Name) line)"
        $Samples += $d.Name
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $Repo "TreadleCore\samples\README.md"))) { throw "TreadleCore\samples\README.md (the samples index) is missing" }

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

# SDL2 for the SDL samples: headers, import library, DLL and licence (x86_64 only; packaging\sdl2-files.txt).
Write-Host "== SDL2 from $SdlSrc"
$SdlOut = Join-Path $Out "tools\SDL2"
New-Item -ItemType Directory -Force (Join-Path $SdlOut "x86_64-w64-mingw32\include"), (Join-Path $SdlOut "x86_64-w64-mingw32\lib"), (Join-Path $SdlOut "x86_64-w64-mingw32\bin") | Out-Null
Copy-Item -Recurse (Join-Path $SdlSrc "x86_64-w64-mingw32\include\SDL2") (Join-Path $SdlOut "x86_64-w64-mingw32\include\SDL2")
foreach ($s in $SdlFiles) {
    if ($s.Rel -like "x86_64-w64-mingw32\include\*") { continue }
    Copy-Item -LiteralPath (Join-Path $SdlSrc $s.Rel) (Join-Path $SdlOut $s.Rel)
}
if (-not (Test-Sdl2Root $SdlOut)) { throw "tools\SDL2 in the package does not match packaging\sdl2-files.txt" }

# The samples (packaging\samples.txt) and their index. A sample built or run in this checkout has a build folder and
# may have written files next to its input: they do not ship. Paths that lead out of the source tree's sample are
# rewritten for the package's layout: the SDL2 fallback (../../../tools/SDL2-2.32.10 -> ../../tools/SDL2, the
# package's tools\SDL2 from samples\<name>) and m2-frontend's probe header (copied beside its set).
New-Item -ItemType Directory -Force (Join-Path $Out "samples") | Out-Null
Copy-Item (Join-Path $Repo "TreadleCore\samples\README.md") (Join-Path $Out "samples\README.md")
foreach ($s in $Samples) {
    $dst = Join-Path $Out "samples\$s"
    Copy-Item -Recurse (Join-Path $Repo "TreadleCore\samples\$s") $dst
    foreach ($left in @("build", "m3-files-out")) { $p = Join-Path $dst $left; if (Test-Path -LiteralPath $p) { Remove-Item -Recurse -Force $p } }
    Get-ChildItem -LiteralPath $dst -Recurse -File -Filter *.pretty.json | Remove-Item -Force
    foreach ($ci in Get-ChildItem -LiteralPath $dst -Recurse -File -Filter *.cimport) {
        $text = [IO.File]::ReadAllText($ci.FullName)
        $new = $text.Replace('${TREADLE_SDL2:-../../../tools/SDL2-2.32.10}', '${TREADLE_SDL2:-../../tools/SDL2}')
        if ($new.Contains('../../../../tools/probe/headers/small.h')) {
            $new = $new.Replace('../../../../tools/probe/headers/small.h', 'small.h')
            Copy-Item (Join-Path $Repo "tools\probe\headers\small.h") (Join-Path $ci.DirectoryName "small.h") -Force
        }
        if ($new -ne $text) { [IO.File]::WriteAllText($ci.FullName, $new, (New-Object Text.UTF8Encoding $false)) }
        if ($new -match '\.\./\.\./\.\./') { throw "$($ci.FullName) still names a path outside the package" }
    }
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

# The file list the updater installs by (docs\Releasing.md, "The update path"): every file of the package, relative,
# with / separators; files.txt itself is not listed.
$manifest = @(Get-ChildItem -Recurse -Force -File $Out | ForEach-Object { $_.FullName.Substring($Out.Length + 1).Replace('\', '/') } | Where-Object { $_ -ne "files.txt" } | Sort-Object)
[IO.File]::WriteAllText((Join-Path $Out "files.txt"), (($manifest -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))

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
# What tools\SDL2 and samples\ add to the zip (the compressed sizes of their entries).
$za = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $sdlZip = [int64](($za.Entries | Where-Object { $_.FullName.StartsWith("tools/SDL2/") } | Measure-Object -Property CompressedLength -Sum).Sum)
    $samplesZip = [int64](($za.Entries | Where-Object { $_.FullName.StartsWith("samples/") } | Measure-Object -Property CompressedLength -Sum).Sum)
} finally { $za.Dispose() }
$zipBytes = (Get-Item $zip).Length
Write-Host "  folder $(Format-MB $folderBytes) (tools\llvm $(Format-MB $llvmBytes), tools\libclang $(Format-MB $clangBytes), tools\SDL2 $(Format-MB (Get-FolderBytes $SdlOut)), samples $(Format-MB (Get-FolderBytes (Join-Path $Out 'samples'))))"
Write-Host "  zip    $zip ($(Format-MB $zipBytes); tools\SDL2 $(Format-MB $sdlZip), samples $(Format-MB $samplesZip) of it)"
Write-Host "  samples $($Samples -join ', ')"
if ($zipBytes -gt 150MB) { throw "the zip is $(Format-MB $zipBytes): over the 150 MB limit (docs\Releasing.md)" }
Write-Host "  sha256 $sha"
Write-Host "  exe    $reported"

if (-not $Verify) { exit 0 }

# ---------------------------------------------------------------------------------------------- verify

# Runs the packaged exe with a clean environment: no TREADLE_* lookups, no machine fallback, a fresh LOCALAPPDATA
# (so no cached runtime object and no settings), and returns exit code + stdout + stderr.
function Invoke-Packaged([string]$exePath, [string[]]$argv, [hashtable]$extraEnv, [int]$timeoutSec) {
    if (-not [IO.Path]::IsPathRooted($exePath) -or -not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw "not starting $exePath`: no such file" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exePath
    $psi.Arguments = (($argv | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = Split-Path -Parent $exePath
    foreach ($k in @("TREADLE_LLVM", "TREADLE_CORE", "TREADLE_LIBCLANG", "TREADLE_RUNTIME", "TREADLE_SAMPLES", "TREADLE_LLDB_DAP", "TREADLE_SELFTEST", "TREADLE_HOME", "TREADLE_SDL2", "TREADLE_UPDATE_INDEX")) {
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

# Shipped samples, built and run in place in the unpacked folder (their build folders land there): no TREADLE_SDL2,
# so the SDL samples take SDL2 from the package's tools\SDL2 through the rewritten fallback of their sdl2.cimport,
# and Build copies tools\SDL2's SDL2.dll next to the program. m2-sdl opens a 640x480 window for about one second.
$ps = Join-Path $unz "samples"
$r = Invoke-Packaged $pexe @("--build-run", (Join-Path $ps "m3-core")) $env1 300
Report "--build-run samples\m3-core (shipped, in place)" $r ($r.Code -eq 0 -and $r.Out -match "counted in")
$r = Invoke-Packaged $pexe @("--build-run", (Join-Path $ps "m2-sdl"), "--", "--frames", "60") $env1 300
$sdlDll = Join-Path $ps "m2-sdl\build\Debug\SDL2.dll"
$sdlSame = (Test-Path -LiteralPath $sdlDll) -and ((Get-FileHash -Algorithm SHA256 -LiteralPath $sdlDll).Hash -eq (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $unz "tools\SDL2\x86_64-w64-mingw32\bin\SDL2.dll")).Hash)
$sdlPaths = ($r.Out + $r.Err).Contains($unz.Replace('\', '/') + "/tools/SDL2/")
Report "--build-run samples\m2-sdl -- --frames 60 (SDL2.dll from tools\SDL2: $sdlSame, its paths named: $sdlPaths)" $r ($r.Code -eq 0 -and $r.Out -match "frames 60" -and $sdlSame -and $sdlPaths)
$r = Invoke-Packaged $pexe @("--build-run", (Join-Path $ps "m4-breakout"), "--", "--headless") $env1 300
Report "--build-run samples\m4-breakout -- --headless" $r ($r.Code -eq 0 -and $r.Out -match "frames 600 score")

# The update rehearsal (docs\Releasing.md, "The update path"): package A is this package with an older VERSION.txt, one
# extra listed file (docs\rehearsal-old-page.md, which B no longer has) and user files the update must keep; a local
# release index (TREADLE_UPDATE_INDEX, the same override every build honours) holds this zip as release B with its
# SHA256SUMS. A's `Treadle.exe --update` checks, downloads, verifies and starts the helper; the helper replaces A's files
# by B's files.txt and restarts with --update-health. Every process here is started and waited for by this script.
$reh = Join-Path $VerifyDir "update-rehearsal"
$rA = Join-Path $reh "Treadle"
$rIndex = Join-Path $reh "index"
New-Item -ItemType Directory -Force $rIndex | Out-Null
Copy-Item -Recurse $unz $rA
Set-Content -Path (Join-Path $rA "VERSION.txt") -Value "0.0.1-rehearsal" -Encoding ascii
New-Item -ItemType Directory -Force (Join-Path $rA "projects\MyGame"), (Join-Path $rA "samples\m1") | Out-Null
Set-Content -Path (Join-Path $rA "projects\MyGame\MyGame.tproj") -Value "user project" -Encoding ascii
Set-Content -Path (Join-Path $rA "samples\m1\my-notes.txt") -Value "user notes inside a package folder" -Encoding ascii
Set-Content -Path (Join-Path $rA "docs\rehearsal-old-page.md") -Value "only in A" -Encoding ascii
Add-Content -Path (Join-Path $rA "files.txt") -Value "docs/rehearsal-old-page.md" -Encoding ascii
Copy-Item $zip (Join-Path $rIndex (Split-Path -Leaf $zip))
$zipLen = (Get-Item $zip).Length
Set-Content -Path (Join-Path $rIndex "SHA256SUMS") -Value "$sha  $(Split-Path -Leaf $zip)" -Encoding ascii
$relJson = '[{"tag_name": "v' + $FullVersion + '", "draft": false, "prerelease": false, "body": "Rehearsal release", "assets": [{"name": "' + (Split-Path -Leaf $zip) + '", "size": ' + $zipLen + '}, {"name": "SHA256SUMS", "size": 100}]}]'
[IO.File]::WriteAllText((Join-Path $rIndex "releases.json"), $relJson)
$rEnv = @{ LOCALAPPDATA = $lad; TREADLE_HOME = (Join-Path $reh "home"); TREADLE_UPDATE_INDEX = $rIndex }
$r = Invoke-Packaged (Join-Path $rA "Treadle.exe") @("--update") $rEnv 600
$helperOk = $r.Out -match 'Update helper started \(process (\d+)\)'
Report "update rehearsal: 0.0.1-rehearsal --update finds $FullVersion in the local index, verifies it and starts the helper" $r ($r.Code -eq 0 -and $helperOk)
$updLog = Join-Path $rA "update\update.log"
if ($helperOk) {
    $hp = Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue
    if ($hp) {
        $null = $hp.Handle
        if (-not $hp.WaitForExit(600000)) { try { $hp.Kill(); $hp.WaitForExit(10000) | Out-Null } catch {}; Write-Host "    ! the helper did not finish in 600 s (stopped)" }
    }
    # The helper's last step: it ends after the restarted --update-health process; wait for the log line too.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 60000 -and -not ((Test-Path $updLog) -and (Select-String -Path $updLog -Pattern "update complete|restoring|update failed|did not close" -Quiet))) { Start-Sleep -Milliseconds 250 }
}
$logText = if (Test-Path $updLog) { Get-Content -Raw $updLog } else { "" }
$vA = (Get-Content (Join-Path $rA "VERSION.txt") -TotalCount 1).Trim()
$r2 = Invoke-Packaged (Join-Path $rA "Treadle.exe") @("--version") $rEnv 30
$kept = (Test-Path (Join-Path $rA "projects\MyGame\MyGame.tproj")) -and (Test-Path (Join-Path $rA "samples\m1\my-notes.txt"))
$gone = -not (Test-Path (Join-Path $rA "docs\rehearsal-old-page.md"))
$sameList = (Get-FileHash (Join-Path $rA "files.txt")).Hash -eq (Get-FileHash (Join-Path $unz "files.txt")).Hash
$noPrev = -not (Test-Path (Join-Path $rA "update\old"))
$r2.Out = ($r2.Out.Trim() + "`n" + (($logText -split "`r?`n" | Where-Object { $_ }) -join "`n")).Trim()
Report "update rehearsal: VERSION.txt $vA, user files kept $kept, A-only file removed $gone, files.txt is B's $sameList, rollback copy cleared $noPrev" $r2 ($r2.Code -eq 0 -and $vA -eq $FullVersion -and $r2.Out -like "Treadle $FullVersion (host contract *" -and $kept -and $gone -and $sameList -and $noPrev -and $logText -match "update complete")
# A second --update on the updated copy: up to date, nothing started.
$r3 = Invoke-Packaged (Join-Path $rA "Treadle.exe") @("--update") $rEnv 120
Report "update rehearsal: --update again says up to date" $r3 ($r3.Code -eq 0 -and $r3.Out -match "is up to date")

if ($failures -gt 0) { throw "verify: $failures check(s) failed (work files in $VerifyDir)" }
Write-Host "Verified from $unz with only the package's contents. Work files: $VerifyDir"
