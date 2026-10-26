<#
.SYNOPSIS
  Runs every probe behind docs\Toolchain.md and prints the numbers: builds of hello.ll, the lldb
  debug-info checks (DWARF, synthetic file names, CodeView), the C header import comparison
  (clang -ast-dump=json vs the libclang C API) and the 2,000-line IR -> exe timing.
.DESCRIPTION
  Everything is written below tools\probe\out (gitignored). Compiles run one at a time at BelowNormal
  priority. PowerShell 5.1 compatible. Sections can be skipped with -SkipDebug, -SkipHeaders, -SkipTiming.
  Toolchain root: -Toolchain, TREADLE_LLVM, else tools\llvm-mingw of the repository
  (scripts\get-llvm-mingw.ps1).
  SDL2 headers: -SdlInclude, else the x86_64-w64-mingw32\include folder of TREADLE_SDL2 or of
  tools\SDL2-2.32.10 of the repository (scripts\get-sdl2.ps1).
  The libclang part needs the clang-c headers and libclang.dll of an LLVM install built for MSVC
  (-MsvcLlvm, default C:\Program Files\LLVM); llvm-mingw ships no libclang.dll.
.EXAMPLE
  powershell -File tools\probe\probe_all.ps1 | Tee-Object tools\probe\out\probe_all.log
#>
param(
  [string]$Toolchain,
  [string]$MsvcLlvm = 'C:\Program Files\LLVM',
  [string]$SdlInclude = '',
  [int]$TimingRuns = 3,
  [switch]$SkipBuilds, [switch]$SkipDebug, [switch]$SkipHeaders, [switch]$SkipTiming
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path (Split-Path $here -Parent) -Parent
$llbuild = Join-Path $repo 'scripts\llbuild.ps1'
$rt = Join-Path $repo 'tools\runtime\treadle_rt.c'
$out = Join-Path $here 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$root = $Toolchain
if (-not $root) { $root = $env:TREADLE_LLVM }
if (-not $root) { $root = Join-Path $repo 'tools\llvm-mingw' }
if (-not $SdlInclude) {
  $sdlPkg = if ($env:TREADLE_SDL2) { $env:TREADLE_SDL2 } else { Join-Path $repo 'tools\SDL2-2.32.10' }
  $SdlInclude = Join-Path $sdlPkg 'x86_64-w64-mingw32\include'
}
$bin = Join-Path $root 'bin'
$clang = Join-Path $bin 'clang.exe'
$lldb = Join-Path $bin 'lldb.exe'
$objdump = Join-Path $bin 'llvm-objdump.exe'
if (-not (Test-Path $clang)) { throw "clang not found at $clang" }
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'

function Quote-Arg([string]$a) { if ($a -match '[\s"]') { return '"' + ($a -replace '(\\*)"', '$1$1\"') + '"' } return $a }
function Run-Timed([string]$exe, [string[]]$arguments, [string]$stdoutFile, [hashtable]$env) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = ($arguments | ForEach-Object { Quote-Arg $_ }) -join ' '
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  if ($env) { foreach ($k in $env.Keys) { $psi.EnvironmentVariables[$k] = $env[$k] } }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $p = [System.Diagnostics.Process]::Start($psi)
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $errTask = $p.StandardError.ReadToEndAsync()
  if ($stdoutFile) {
    $fs = [IO.File]::Create($stdoutFile)
    $p.StandardOutput.BaseStream.CopyTo($fs); $fs.Close()
    $stdout = ''
  } else { $stdout = $p.StandardOutput.ReadToEnd() }
  $p.WaitForExit(); $sw.Stop()
  return New-Object PSObject -Property @{ Ms = [int]$sw.ElapsedMilliseconds; Exit = $p.ExitCode; Out = $stdout; Err = $errTask.Result }
}
function Build([string[]]$extra) {
  # array -> hashtable splat (an array splat would bind everything positionally)
  $h = @{}
  for ($k = 0; $k -lt $extra.Count; $k++) {
    $name = $extra[$k].TrimStart('-')
    if ($k + 1 -lt $extra.Count -and -not $extra[$k + 1].StartsWith('-')) { $h[$name] = $extra[$k + 1]; $k++ } else { $h[$name] = $true }
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  & $llbuild @h | Out-Null
  $sw.Stop(); return [int]$sw.ElapsedMilliseconds
}
function Imports([string]$exe) {
  $r = Run-Timed $objdump @('-p', $exe) $null $null
  $dlls = @([regex]::Matches($r.Out, 'DLL Name:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
  return $dlls
}
function Lldb([string]$exe, [string[]]$cmds) {
  $arguments = @('--no-lldbinit', '-b')
  foreach ($c in $cmds) { $arguments += @('-o', $c) }
  $arguments += @('--', $exe)
  $r = Run-Timed $lldb $arguments $null $null
  return ($r.Out + $r.Err)
}

$cpu = (Get-CimInstance Win32_Processor).Name.Trim()
Write-Host "== machine: $cpu, $([Environment]::ProcessorCount) threads, $([Environment]::OSVersion.VersionString)"
Write-Host "== toolchain: $root"
Write-Host ((Run-Timed $clang @('--version') $null $null).Out.Split("`n")[0])

# ---------------------------------------------------------------- A. hello.ll builds
if (-not $SkipBuilds) {
Write-Host "`n== A. hello.ll + treadle_rt.c"
$hello = Join-Path $here 'hello.ll'
foreach ($cfg in @(@('Debug', 'hello_debug.exe', @()), @('Release', 'hello_release.exe', @()), @('Release', 'hello_lto.exe', @('-Lto')))) {
  $exe = Join-Path $out $cfg[1]
  $ms = Build (@('-IR', $hello, '-CSource', $rt, '-Out', $exe, '-Config', $cfg[0]) + $cfg[2])
  $run = Run-Timed $exe @() $null $null
  $imp = Imports $exe
  Write-Host ("{0,-8} {1,-18} build {2,5} ms  size {3,6} bytes  exit {4}  imports {5}: {6}" -f ($cfg[0] + $cfg[2]), $cfg[1], $ms, (Get-Item $exe).Length, $run.Exit, $imp.Count, ($imp -join ' '))
  Write-Host ("         output: " + ($run.Out.Trim() -replace "`r?`n", ' | '))
}
foreach ($cfg in @('Debug', 'Release')) {
  $exe = Join-Path $out "rtfault_$($cfg.ToLower()).exe"
  $ms = Build @('-IR', (Join-Path $here 'rtfault.ll'), '-CSource', $rt, '-Out', $exe, '-Config', $cfg)
  $run = Run-Timed $exe @() $null $null
  Write-Host ("rtfault {0,-8} exit {1} (0x{1:x8})  stderr: {2}" -f $cfg, $run.Exit, ($run.Err.Trim() -replace "`r?`n", ' | '))
}
}

# ---------------------------------------------------------------- B. debug info
if (-not $SkipDebug) {
  Write-Host "`n== B. debug info (lldb $((Run-Timed $lldb @('--version') $null $null).Out.Split("`n")[0].Trim()))"
  $exe = Join-Path $out 'hello_debug.exe'
  Write-Host "-- B1 DWARF, breakpoints hello.ll:88 (loop body) and hello.ll:63 (indirect call), variables"
  $t = Lldb $exe @('breakpoint set -f hello.ll -l 88', 'breakpoint set -f hello.ll -l 63', 'run', 'frame variable', 'breakpoint disable 1', 'continue', 'bt 2', 'register read rcx', 'p *(Shape*)$rcx', 'kill')
  $t.Split("`n") | Where-Object { $_ -match '^Breakpoint \d|stop reason|^\(int\)|^\(Shape\)|^\s+(vt|w|h) =|frame #|rcx =|error' } | ForEach-Object { Write-Host "   $_" }

  Write-Host "-- B2 DWARF with a synthetic file name (Main.treadle in K:/virtual/project), breakpoint Main.treadle:88"
  $src = [IO.File]::ReadAllText($hello)
  $virt = Join-Path $out 'hello_virt.ll'
  [IO.File]::WriteAllText($virt, $src.Replace('!DIFile(filename: "hello.ll", directory: "C:/src/treadle/tools/probe")', '!DIFile(filename: "Main.treadle", directory: "K:/virtual/project")'))
  $vexe = Join-Path $out 'hello_virt.exe'
  Build @('-IR', $virt, '-CSource', $rt, '-Out', $vexe, '-Config', 'Debug') | Out-Null
  $t = Lldb $vexe @('breakpoint set -f Main.treadle -l 88', 'run', 'frame variable', 'frame info', 'kill')
  $t.Split("`n") | Where-Object { $_ -match '^Breakpoint \d|stop reason|^\(int\)|^frame #|error' } | ForEach-Object { Write-Host "   $_" }

  Write-Host "-- B3 CodeView: module flag !{i32 2, !""CodeView"", i32 1} + llbuild -CodeView (lld writes a PDB)"
  $cv = Join-Path $out 'hello_cv.ll'
  [IO.File]::WriteAllText($cv, $src.Replace('!2 = !{i32 7, !"Dwarf Version", i32 4}', '!2 = !{i32 2, !"CodeView", i32 1}'))
  $cvexe = Join-Path $out 'hello_cv.exe'
  Build @('-IR', $cv, '-CSource', $rt, '-Out', $cvexe, '-Config', 'Debug', '-CodeView') | Out-Null
  $pdb = [IO.Path]::ChangeExtension($cvexe, '.pdb')
  Write-Host ("   exe {0} bytes, pdb {1}" -f (Get-Item $cvexe).Length, $(if (Test-Path $pdb) { "$((Get-Item $pdb).Length) bytes" } else { 'MISSING' }))
  $sec = (Run-Timed $objdump @('-h', $cvexe) $null $null).Out
  Write-Host ("   sections: " + (([regex]::Matches($sec, '\s(\.[a-zA-Z_$]+)\s') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ' '))
  $t = Lldb $cvexe @('breakpoint set -f hello.ll -l 88', 'run', 'frame variable', 'bt 2', 'kill')
  $t.Split("`n") | Where-Object { $_ -match '^Breakpoint \d|stop reason|^\(int\)|^frame #|error' } | ForEach-Object { Write-Host "   $_" }

  Write-Host "-- B4 -gcodeview WITHOUT the module flag (does clang add CodeView to IR input?)"
  $cv2exe = Join-Path $out 'hello_cv_noflag.exe'
  Build @('-IR', $hello, '-CSource', $rt, '-Out', $cv2exe, '-Config', 'Debug', '-CodeView') | Out-Null
  $pdb2 = [IO.Path]::ChangeExtension($cv2exe, '.pdb')
  $sec2 = (Run-Timed $objdump @('-h', $cv2exe) $null $null).Out
  Write-Host ("   pdb {0}; sections: {1}" -f $(if (Test-Path $pdb2) { "$((Get-Item $pdb2).Length) bytes" } else { 'none' }), (([regex]::Matches($sec2, '\s(\.[a-zA-Z_$]+)\s') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ' '))
  $t = Lldb $cv2exe @('breakpoint set -f hello.ll -l 88', 'run', 'kill')
  $t.Split("`n") | Where-Object { $_ -match '^Breakpoint \d|stop reason|error' } | ForEach-Object { Write-Host "   $_" }
}

# ---------------------------------------------------------------- C. header import
if (-not $SkipHeaders) {
  Write-Host "`n== C. C header import: clang -ast-dump=json vs libclang C API"
  $hdr = Join-Path $here 'headers'
  $cases = @(
    @('small', (Join-Path $hdr 'small.h'), @()),
    @('stdio', (Join-Path $hdr 'use_stdio.h'), @()),
    @('sdl', (Join-Path $hdr 'use_sdl.h'), @("-I$SdlInclude", '-DSDL_MAIN_HANDLED'))
  )
  Write-Host "-- C1 clang -Xclang -ast-dump=json -fsyntax-only (llvm-mingw clang, whole translation unit)"
  foreach ($c in $cases) {
    $json = Join-Path $out "ast_$($c[0]).json"
    $r = Run-Timed $clang (@('-x', 'c', '-fsyntax-only', '-Xclang', '-ast-dump=json') + $c[2] + @($c[1])) $json $null
    $kinds = 0; $decls = 0
    $sr = New-Object IO.StreamReader $json
    while (($line = $sr.ReadLine()) -ne $null) { if ($line.IndexOf('"kind":') -ge 0) { $kinds++; if ($line.IndexOf('Decl"') -ge 0) { $decls++ } } }
    $sr.Close()
    Write-Host ("   {0,-6} {1,6} ms  json {2,11:n0} bytes  nodes {3,8:n0}  decl nodes {4,7:n0}  exit {5} {6}" -f $c[0], $r.Ms, (Get-Item $json).Length, $kinds, $decls, $r.Exit, ($r.Err.Trim() -replace "`r?`n", ' | '))
    if ($c[0] -ne 'small') { Remove-Item $json }   # keep only the small one as a shape sample
  }
  Write-Host "-- C1b same, with -Xclang -ast-dump-filter=SDL_CreateWindow (one declaration)"
  $r = Run-Timed $clang (@('-x', 'c', '-fsyntax-only', '-Xclang', '-ast-dump=json', '-Xclang', '-ast-dump-filter=SDL_CreateWindow') + $cases[2][2] + @($cases[2][1])) (Join-Path $out 'ast_sdl_filter.json') $null
  Write-Host ("   sdl    {0,6} ms  json {1,11:n0} bytes  exit {2}" -f $r.Ms, (Get-Item (Join-Path $out 'ast_sdl_filter.json')).Length, $r.Exit)

  Write-Host "-- C2 libclang C API (libclang_probe.c, built with llvm-mingw clang against $MsvcLlvm)"
  $probe = Join-Path $out 'libclang_probe.exe'
  $inc = Join-Path $MsvcLlvm 'include'
  $lib = Join-Path $MsvcLlvm 'lib\libclang.lib'
  $dll = Join-Path $MsvcLlvm 'bin\libclang.dll'
  if (-not (Test-Path $lib)) { Write-Host "   libclang.lib not found at $lib; skipping" }
  else {
    $r = Run-Timed $clang @('-O2', '-std=c11', '-Wall', (Join-Path $here 'libclang_probe.c'), "-I$inc", $lib, '-o', $probe) $null $null
    Write-Host ("   build {0} ms exit {1} {2}; libclang.dll {3:n0} bytes" -f $r.Ms, $r.Exit, ($r.Err.Trim() -replace "`r?`n", ' | '), (Get-Item $dll).Length)
    if ($r.Exit -eq 0) {
      $penv = @{ PATH = (Join-Path $MsvcLlvm 'bin') + ';' + $env:PATH }
      # libclang needs clang's resource headers (stddef.h ...): point it at the llvm-mingw ones and the mingw sysroot
      $resDir = (Run-Timed $clang @('-print-resource-dir') $null $null).Out.Trim()
      $sysInc = @('-target', 'x86_64-w64-windows-gnu', "-isystem", (Join-Path $resDir 'include'), '-isystem', (Join-Path $root 'include'))
      foreach ($mode in @(@('main file only', @()), @('all, with macros', @('-all', '-macros')))) {
        foreach ($c in $cases) {
          $txt = Join-Path $out "libclang_$($c[0])_$($mode[1].Count).txt"
          $r = Run-Timed $probe ($mode[1] + @($c[1]) + $sysInc + $c[2]) $txt $penv
          $last = (Get-Content $txt | Select-Object -Last 1)
          Write-Host ("   {0,-6} {1,-17} {2,6} ms  text {3,11:n0} bytes  exit {4}  {5} {6}" -f $c[0], $mode[0], $r.Ms, (Get-Item $txt).Length, $r.Exit, $last, ($r.Err.Trim() -replace "`r?`n", ' | '))
        }
      }
    }
  }
}

# ---------------------------------------------------------------- D. 2,000-line timing
if (-not $SkipTiming) {
  Write-Host "`n== D. synthetic 2,000-line .ll -> exe ($TimingRuns runs each, wall ms incl. PowerShell overhead)"
  $gen = Join-Path $here 'gen_synthetic.ps1'
  foreach ($variant in @(@('plain', @()), @('dbg', @('-DebugInfo')))) {
    $ll = Join-Path $out "synth_$($variant[0]).ll"
    $gp = @{ Lines = 2000; Out = $ll }
    if ($variant[1].Count -gt 0) { $gp.DebugInfo = $true }
    & $gen @gp | Out-Null
    $lines = ([IO.File]::ReadAllLines($ll)).Length
    foreach ($cfg in @('Debug', 'Release')) {
      $exe = Join-Path $out "synth_$($variant[0])_$($cfg.ToLower()).exe"
      $times = @()
      for ($i = 0; $i -lt $TimingRuns; $i++) { $times += Build @('-IR', $ll, '-CSource', $rt, '-Out', $exe, '-Config', $cfg) }
      $run = Run-Timed $exe @() $null $null
      Write-Host ("   {0,-5} {1} lines {2,5} bytes  {3,-7}  build ms: {4}  (min {5})  size {6,6}  run: {7} exit {8}" -f $variant[0], $lines, (Get-Item $ll).Length, $cfg, ($times -join ' / '), ($times | Measure-Object -Minimum).Minimum, (Get-Item $exe).Length, $run.Out.Trim(), $run.Exit)
    }
  }
  Write-Host "-- D2 the same without the script: raw clang -c + link, one process each (Debug, dbg variant)"
  $ll = Join-Path $out 'synth_dbg.ll'; $o = Join-Path $out 'synth_raw.o'; $rto = Join-Path $out 'rt_raw.o'; $exe = Join-Path $out 'synth_raw.exe'
  $r1 = Run-Timed $clang @('-O0', '-g', '-c', $ll, '-o', $o) $null $null
  $r2 = Run-Timed $clang @('-O0', '-g', '-c', '-DTREADLE_DEBUG=1', $rt, '-o', $rto) $null $null
  $r3 = Run-Timed $clang @('-static', '-g', $o, $rto, '-o', $exe) $null $null
  Write-Host ("   clang -O0 -c {0} ms, runtime .c {1} ms, link {2} ms  => {3} ms" -f $r1.Ms, $r2.Ms, $r3.Ms, ($r1.Ms + $r2.Ms + $r3.Ms))
  $r1 = Run-Timed $clang @('-O2', '-c', $ll, '-o', $o) $null $null
  $r3 = Run-Timed $clang @('-static', '-s', $o, $rto, '-o', $exe) $null $null
  Write-Host ("   clang -O2 -c {0} ms, link {1} ms" -f $r1.Ms, $r3.Ms)
  Remove-Item $o, $rto, $exe -ErrorAction SilentlyContinue
}
Write-Host "`n== done"
