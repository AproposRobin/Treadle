# get-llvm-mingw.ps1: installs the pinned llvm-mingw toolchain the back end, the C import and the debugger use
# (docs/Toolchain.md, "What is pinned").
#
#   Release   llvm-mingw 20261006, UCRT, x86_64 host (clang / lld / lldb 23.1.3)
#   Archive   llvm-mingw-20261006-ucrt-x86_64.zip
#   From      https://github.com/mstorsjo/llvm-mingw/releases/download/20261006/
#   sha256    317492c456aa27ee607a5919f1d2d38dcdc1112516a24d0bf4b00d078f52d17a
#   Installs  <repo>\tools\llvm-mingw\  (the whole toolchain; scripts\package.ps1 ships a trimmed copy of it)
#   License   Apache-2.0 WITH LLVM-exception, mingw-w64 runtime licences (LICENSE.TXT in the archive root)
#
# The archive is downloaded into a fresh, empty folder (tools\llvm-mingw-download), its sha256 is checked
# before anything is extracted, and the download folder is deleted afterwards. tools\llvm-mingw\ is
# git-ignored: nothing here is committed. When the toolchain is already installed (clang-23.exe reports
# 23.1.3) nothing is downloaded; -From <folder> copies an existing unpacked llvm-mingw instead of downloading.
#
#   powershell -File scripts\get-llvm-mingw.ps1 [-Root <repo>] [-From <unpacked llvm-mingw>] [-Force] [-KeepDownload]

param(
	# The repository root (default: the folder above scripts\). A worktree passes the main checkout.
	[string]$Root = '',
	# An unpacked llvm-mingw 20261006-ucrt-x86_64 already on disk (copied, not downloaded).
	[string]$From = '',
	[switch]$Force,
	[switch]$KeepDownload
)

$ErrorActionPreference = 'Stop'

$Release     = '20261006'
$Name        = "llvm-mingw-$Release-ucrt-x86_64"
$Archive     = "$Name.zip"
$Url         = "https://github.com/mstorsjo/llvm-mingw/releases/download/$Release/$Archive"
$ArchiveHash = '317492c456aa27ee607a5919f1d2d38dcdc1112516a24d0bf4b00d078f52d17a'
$ClangVersion = '23.1.3'

$Repo     = if ($Root) { $Root } else { Split-Path -Parent $PSScriptRoot }
$Dest     = Join-Path $Repo 'tools\llvm-mingw'
$Download = Join-Path $Repo 'tools\llvm-mingw-download'

function Test-Toolchain([string]$dir) {
	$clang = Join-Path $dir 'bin\clang-23.exe'
	if (-not (Test-Path $clang)) { return $false }
	$v = (& $clang --version 2>$null | Select-Object -First 1)
	return ($v -match [regex]::Escape($ClangVersion))
}

if ((Test-Toolchain $Dest) -and -not $Force) {
	Write-Host "llvm-mingw $Release is already installed: $Dest"
	exit 0
}

if ($From) {
	if (-not (Test-Toolchain $From)) { throw "$From is not llvm-mingw $Release (bin\clang-23.exe reporting $ClangVersion)" }
	if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
	Write-Host "Copying $From to $Dest"
	Copy-Item -Recurse $From $Dest
	Write-Host "Installed llvm-mingw $Release`: $Dest"
	exit 0
}

$zip = Join-Path $Download $Archive
$reuse = (Test-Path $zip) -and (@(Get-ChildItem $Download).Count -le 2) -and ((Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower() -eq $ArchiveHash)
if (-not $reuse) {
	if (Test-Path $Download) { Remove-Item -Recurse -Force $Download }
	New-Item -ItemType Directory -Force $Download | Out-Null
	Write-Host "Downloading $Url"
	$old = $ProgressPreference
	$ProgressPreference = 'SilentlyContinue'
	Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing
	$ProgressPreference = $old
}
else {
	Write-Host "Reusing $zip"
}

$got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
if ($got -ne $ArchiveHash) {
	Remove-Item -Recurse -Force $Download
	throw "sha256 mismatch for $Archive`: expected $ArchiveHash, got $got (the download was deleted)"
}
Write-Host "sha256 ok ($got)"

$stage = Join-Path $Download 'x'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
& tar.exe -x -f $zip -C $stage
if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }
$top = Join-Path $stage $Name
if (-not (Test-Toolchain $top)) { throw "the archive did not unpack to $Name\bin\clang-23.exe ($ClangVersion)" }

if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
Move-Item $top $Dest
if (-not $KeepDownload) { Remove-Item -Recurse -Force $Download }
Write-Host "Installed llvm-mingw $Release`: $Dest"
