<#
.SYNOPSIS
  Builds a Windows executable (or DLL) from LLVM IR text files (.ll) with the pinned llvm-mingw toolchain.

.DESCRIPTION
  llbuild.ps1 is the last stage of the Treadle pipeline: the compiler writes one or more .ll files,
  this script turns them (plus optional C runtime sources and libraries) into a self-contained
  x86-64 Windows binary with clang + lld from llvm-mingw.

  Toolchain root (first hit wins): -Toolchain, $env:TREADLE_LLVM, tools\llvm-mingw of the repository
  (scripts\get-llvm-mingw.ps1). See docs\Toolchain.md for what is pinned.

  Configs
    Debug     -O0 -g, DWARF debug info kept in the binary, C sources get -DTREADLE_DEBUG=1
              (allocation bookkeeping in tools\runtime\treadle_rt.c).
    Release   -O2, -ffunction-sections -fdata-sections + --gc-sections, stripped (-s) unless -KeepSymbols;
              -Lto adds -flto (thin bitcode objects, whole-program optimisation in lld).

  The C++ runtime pieces that llvm-mingw might pull in (libunwind, libc++) are linked statically
  (-static). The C library is the Windows Universal CRT (ucrtbase.dll, part of Windows 10+), so the
  exe imports only system DLLs (KERNEL32, api-ms-win-crt-*). -ShowImports prints the import list from
  llvm-objdump so that claim can be checked for any build.

  PowerShell 5.1 compatible (no &&/|| chains, no ternaries). clang and lld run one at a time at
  BelowNormal priority (the script lowers its own priority class; children inherit it).

.PARAMETER IR
  One or more .ll (LLVM IR text) or .bc (bitcode) files.
.PARAMETER CSource
  Optional C sources compiled with the same config and linked in (e.g. tools\runtime\treadle_rt.c).
.PARAMETER Libs
  Extra libraries: a bare name becomes -l<name> (user32, SDL2 ...), a path to a .a/.lib/.dll/.o is passed as is.
.PARAMETER LibDirs
  Extra -L search directories.
.PARAMETER Out
  Output path. Default: <first IR name>.exe (or .dll with -Shared) next to the first IR file.
.PARAMETER Config
  Debug (default) or Release.
.PARAMETER Lto
  Release only: link-time optimisation (-flto).
.PARAMETER Subsystem
  console (default) or windows (no console window; main() still works, mingw's startup calls it).
.PARAMETER Shared
  Build a DLL instead of an exe; also writes <name>.def and an MSVC-style <name>.lib import library
  (llvm-dlltool) so lld-link based tools (Beef) can link against it.
.PARAMETER CodeView
  Debug only: ask for CodeView instead of DWARF and let lld write <Out>.pdb. Only effective if the
  IR carries the CodeView module flag (see docs\Toolchain.md, "Debug info").
.PARAMETER KeepSymbols
  Release: do not strip.
.PARAMETER ObjDir
  Where the intermediate objects go. Default: <out dir>\obj\<out name>. Removed afterwards unless -KeepObjects.
.PARAMETER Timing
  Print per-step wall times (also on -Verbose).
.PARAMETER ShowImports
  Print the output's size and its DLL import list (llvm-objdump -p).
.PARAMETER ExtraCFlags / ExtraLinkFlags
  Passed through to the compile / link step.

.EXAMPLE
  powershell -File scripts\llbuild.ps1 -IR tools\probe\hello.ll -CSource tools\runtime\treadle_rt.c -Out tools\probe\out\hello_debug.exe -Timing -ShowImports
.EXAMPLE
  powershell -File scripts\llbuild.ps1 -IR a.ll,b.ll -Config Release -Lto -Subsystem windows -Libs user32,gdi32 -Out game.exe
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)][string[]]$IR,
  [string[]]$CSource = @(),
  [string[]]$Libs = @(),
  [string[]]$LibDirs = @(),
  [string]$Out,
  [ValidateSet('Debug', 'Release')][string]$Config = 'Debug',
  [switch]$Lto,
  [ValidateSet('console', 'windows')][string]$Subsystem = 'console',
  [switch]$Shared,
  [switch]$CodeView,
  [switch]$KeepSymbols,
  [string]$ObjDir,
  [switch]$KeepObjects,
  [switch]$Timing,
  [switch]$ShowImports,
  [string[]]$ExtraCFlags = @(),
  [string[]]$ExtraLinkFlags = @(),
  [string]$Toolchain
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($VerbosePreference -ne 'SilentlyContinue') { $Timing = $true }

# ---- toolchain ----------------------------------------------------------------------------------
$root = $Toolchain
if (-not $root) { $root = $env:TREADLE_LLVM }
if (-not $root) { $root = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\llvm-mingw' }
$bin = Join-Path $root 'bin'
$clang = Join-Path $bin 'clang.exe'
if (-not (Test-Path $clang)) {
  throw "llvm-mingw not found: '$clang' is missing. Set TREADLE_LLVM to the llvm-mingw root (see docs\Toolchain.md)."
}
$objdump = Join-Path $bin 'llvm-objdump.exe'
$dlltool = Join-Path $bin 'llvm-dlltool.exe'

# ---- helpers ------------------------------------------------------------------------------------
function Quote-Arg([string]$a) {
  if ($a -match '[\s"]') { return '"' + ($a -replace '(\\*)"', '$1$1\"') + '"' }
  if ($a.Length -eq 0) { return '""' }
  return $a
}
$script:Steps = @()
function Invoke-Tool([string]$exe, [string[]]$arguments, [string]$label) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = ($arguments | ForEach-Object { Quote-Arg $_ }) -join ' '
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  Write-Verbose "$label`n  $exe $($psi.Arguments)"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $p = [System.Diagnostics.Process]::Start($psi)
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  $p.WaitForExit()
  $sw.Stop()
  $stdout = $outTask.Result
  $stderr = $errTask.Result
  if ($stdout) { Write-Host $stdout.TrimEnd() }
  if ($stderr) { Write-Host $stderr.TrimEnd() }
  $script:Steps += New-Object PSObject -Property @{ Step = $label; Ms = [int]$sw.ElapsedMilliseconds; Exit = $p.ExitCode }
  if ($Timing) { Write-Host ("  [{0,6} ms] {1}" -f $sw.ElapsedMilliseconds, $label) }
  return $p.ExitCode
}
function Resolve-Input([string]$path) {
  $r = Resolve-Path -LiteralPath $path -ErrorAction SilentlyContinue
  if (-not $r) { throw "input not found: $path" }
  return $r.Path
}

# ---- inputs and outputs -------------------------------------------------------------------------
$irFiles = @($IR | ForEach-Object { Resolve-Input $_ })
$cFiles = @($CSource | ForEach-Object { Resolve-Input $_ })
$ext = '.exe'
if ($Shared) { $ext = '.dll' }
if (-not $Out) {
  $Out = Join-Path (Split-Path $irFiles[0] -Parent) ([IO.Path]::GetFileNameWithoutExtension($irFiles[0]) + $ext)
}
if (-not [IO.Path]::IsPathRooted($Out)) { $Out = Join-Path (Get-Location).Path $Out }
$Out = [IO.Path]::GetFullPath($Out)
$outDir = Split-Path $Out -Parent
$outName = [IO.Path]::GetFileNameWithoutExtension($Out)
if (-not $ObjDir) { $ObjDir = Join-Path $outDir ("obj\" + $outName) }
New-Item -ItemType Directory -Force $outDir, $ObjDir | Out-Null

$isDebug = ($Config -eq 'Debug')
if ($Lto -and $isDebug) { Write-Warning '-Lto ignored in Debug'; $Lto = $false }
if ($CodeView -and -not $isDebug) { Write-Warning '-CodeView ignored in Release'; $CodeView = $false }

# ---- flags --------------------------------------------------------------------------------------
$cflags = @('-c', '--target=x86_64-w64-windows-gnu')
if ($isDebug) {
  $cflags += @('-O0', '-g')
  if ($CodeView) { $cflags += '-gcodeview' }
} else {
  $cflags += @('-O2', '-ffunction-sections', '-fdata-sections')
  if ($Lto) { $cflags += '-flto' }
}
$cOnly = @('-std=c11', '-Wall')
if ($isDebug) { $cOnly += '-DTREADLE_DEBUG=1' } else { $cOnly += '-DNDEBUG' }
$cflags += $ExtraCFlags

$ldflags = @('--target=x86_64-w64-windows-gnu', '-static')
if ($Shared) { $ldflags += '-shared' }
if ($Subsystem -eq 'windows') { $ldflags += '-mwindows' } else { $ldflags += '-mconsole' }
if ($isDebug) {
  $ldflags += '-g'
  if ($CodeView) { $ldflags += @('-gcodeview', "-Wl,--pdb=$([IO.Path]::ChangeExtension($Out, '.pdb'))") }
} else {
  $ldflags += @('-O2', '-Wl,--gc-sections')
  if ($Lto) { $ldflags += '-flto' }
  if (-not $KeepSymbols) { $ldflags += '-s' }
}
if ($Shared) {
  $def = [IO.Path]::ChangeExtension($Out, '.def')
  $ldflags += "-Wl,--output-def,$def"
}
foreach ($d in $LibDirs) { $ldflags += "-L$d" }

# ---- lower our own priority: clang/lld inherit BelowNormal --------------------------------------
$me = Get-Process -Id $PID
$oldPriority = $me.PriorityClass
try { $me.PriorityClass = 'BelowNormal' } catch { }
$total = [System.Diagnostics.Stopwatch]::StartNew()
try {
  $objs = @()
  $i = 0
  foreach ($f in $irFiles) {
    $o = Join-Path $ObjDir (("{0:d3}_" -f $i) + [IO.Path]::GetFileNameWithoutExtension($f) + '.o')
    $code = Invoke-Tool $clang ($cflags + @($f, '-o', $o)) ("clang IR  " + [IO.Path]::GetFileName($f))
    if ($code -ne 0) { throw "IR compile failed ($code): $f" }
    $objs += $o; $i++
  }
  foreach ($f in $cFiles) {
    $o = Join-Path $ObjDir (("{0:d3}_" -f $i) + [IO.Path]::GetFileNameWithoutExtension($f) + '.o')
    $code = Invoke-Tool $clang ($cflags + $cOnly + @($f, '-o', $o)) ("clang C   " + [IO.Path]::GetFileName($f))
    if ($code -ne 0) { throw "C compile failed ($code): $f" }
    $objs += $o; $i++
  }
  $libArgs = @()
  foreach ($l in $Libs) {
    if ($l -match '\.(a|lib|dll|o|obj)$' -or $l -match '[\\/]') { $libArgs += (Resolve-Input $l) } else { $libArgs += "-l$l" }
  }
  $code = Invoke-Tool $clang ($ldflags + $objs + @('-o', $Out) + $libArgs + $ExtraLinkFlags) ("lld link  " + [IO.Path]::GetFileName($Out))
  if ($code -ne 0) { throw "link failed ($code): $Out" }

  if ($Shared -and (Test-Path $dlltool)) {
    $lib = [IO.Path]::ChangeExtension($Out, '.lib')
    $code = Invoke-Tool $dlltool @('-m', 'i386:x86-64', '-d', $def, '-D', [IO.Path]::GetFileName($Out), '-l', $lib) 'dlltool   import .lib'
    if ($code -ne 0) { throw "dlltool failed ($code)" }
  }
  $total.Stop()
  $size = (Get-Item $Out).Length
  Write-Host ("Built {0}  ({1} bytes, {2}, {3} ms total)" -f $Out, $size, $Config, $total.ElapsedMilliseconds)

  if ($ShowImports) {
    if (Test-Path $objdump) {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $objdump; $psi.Arguments = '-p ' + (Quote-Arg $Out)
      $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
      $p = [System.Diagnostics.Process]::Start($psi)
      $text = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
      $dlls = @([regex]::Matches($text, 'DLL Name:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
      Write-Host ("Imports ({0} DLLs): {1}" -f $dlls.Count, ($dlls -join ', '))
    } else { Write-Warning "llvm-objdump not found at $objdump" }
  }
}
finally {
  try { $me.PriorityClass = $oldPriority } catch { }
  if (-not $KeepObjects -and (Test-Path $ObjDir)) {
    Remove-Item -Recurse -Force $ObjDir -ErrorAction SilentlyContinue
    $parent = Split-Path $ObjDir -Parent
    if ((Split-Path $parent -Leaf) -eq 'obj' -and -not (Get-ChildItem $parent -Force -ErrorAction SilentlyContinue)) {
      Remove-Item -Force $parent -ErrorAction SilentlyContinue
    }
  }
}
