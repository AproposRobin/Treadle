# get-libclang.ps1: installs the libclang used by the C header import (docs/C-Import.md).
#
#   Release   LLVM 23.1.3 (matches llvm-mingw 20261006's clang 23.1.3)
#   Archive   clang+llvm-23.1.3-x86_64-pc-windows-msvc.tar.xz
#   From      https://github.com/llvm/llvm-project/releases/download/llvmorg-23.1.3/
#   sha256    9ee6a2192fbb30c776415af529927f76ca6b5d1d55699bb1315f9878e610b5b8  (901,331,280 bytes)
#   Installs  <repo>\tools\libclang\bin\libclang.dll                     (MSVC build, C ABI)
#             <repo>\tools\libclang\lib\clang\23\include\*                (clang's builtin headers)
#             <repo>\tools\libclang\include\clang-c\*                     (the C API headers, reference)
#   License   Apache-2.0 WITH LLVM-exception (the archive has no top-level license file)
#   libclang.dll  89,376,256 bytes, file version 23.1.3, sha256 745395b6706e0f67b6a6632a6cd3a1fadefedf9e4e7b16e1d53ba7afb18456ba
#
# The archive is downloaded into a fresh, empty folder (tools\libclang-download), its sha256 is
# checked before anything is extracted, only the files above are taken out of it, and the
# download folder is deleted afterwards. tools\libclang\ is git-ignored: nothing here is committed.
# -From <folder> copies an installed libclang instead of downloading: a folder with the layout above
# (bin\libclang.dll, lib\clang\23\include, include\clang-c), such as another checkout's tools\libclang;
# its libclang.dll must match the sha256 above.
#
#   powershell -File scripts\get-libclang.ps1 [-Root <repo>] [-From <folder>] [-Force] [-KeepDownload]

param(
	# The repository root (default: the folder above scripts\). A worktree passes the main checkout.
	[string]$Root = '',
	# An installed libclang folder already on disk (copied, not downloaded).
	[string]$From = '',
	[switch]$Force,
	[switch]$KeepDownload
)

$ErrorActionPreference = 'Stop'

$Version     = '23.1.3'
$Archive     = "clang+llvm-$Version-x86_64-pc-windows-msvc.tar.xz"
$Url         = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$Version/$Archive"
$ArchiveHash = '9ee6a2192fbb30c776415af529927f76ca6b5d1d55699bb1315f9878e610b5b8'
$DllHash     = '745395b6706e0f67b6a6632a6cd3a1fadefedf9e4e7b16e1d53ba7afb18456ba'
$Major       = $Version.Split('.')[0]

$Repo     = if ($Root) { $Root } else { Split-Path -Parent $PSScriptRoot }
$Dest     = Join-Path $Repo 'tools\libclang'
$Download = Join-Path $Repo 'tools\libclang-download'
$Dll      = Join-Path $Dest 'bin\libclang.dll'

if ((Test-Path $Dll) -and -not $Force) {
	$h = (Get-FileHash -Algorithm SHA256 $Dll).Hash.ToLower()
	if ($h -eq $DllHash) {
		Write-Host "libclang $Version is already installed: $Dll"
		exit 0
	}
	Write-Host "libclang.dll present but its sha256 differs ($h); reinstalling"
}

if ($From) {
	$fromDll = Join-Path $From 'bin\libclang.dll'
	if (-not (Test-Path $fromDll)) { throw "$From has no bin\libclang.dll" }
	$fh = (Get-FileHash -Algorithm SHA256 $fromDll).Hash.ToLower()
	if ($fh -ne $DllHash) { throw "$fromDll is not libclang $Version (sha256 $fh, expected $DllHash)" }
	foreach ($sub in @("lib\clang\$Major\include", 'include\clang-c')) {
		if (-not (Test-Path (Join-Path $From $sub))) { throw "$From has no $sub" }
	}
	if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
	New-Item -ItemType Directory -Force $Dest | Out-Null
	Write-Host "Copying $From to $Dest"
	foreach ($sub in @('bin', 'lib', 'include')) { Copy-Item -Recurse (Join-Path $From $sub) (Join-Path $Dest $sub) }
	Write-Host "Installed libclang $Version`: $Dll"
	exit 0
}

$zst = Join-Path $Download $Archive
# A download kept with -KeepDownload is reused when it is the only thing in the folder and its
# sha256 matches; anything else there is thrown away and the archive is fetched again.
$reuse = (Test-Path $zst) -and (@(Get-ChildItem $Download).Count -le 2) -and ((Get-FileHash -Algorithm SHA256 $zst).Hash.ToLower() -eq $ArchiveHash)
if (-not $reuse) {
	if (Test-Path $Download) {
		Remove-Item -Recurse -Force $Download
	}
	New-Item -ItemType Directory -Force $Download | Out-Null
	Write-Host "Downloading $Url"
	$old = $ProgressPreference
	$ProgressPreference = 'SilentlyContinue'
	Invoke-WebRequest -Uri $Url -OutFile $zst -UseBasicParsing
	$ProgressPreference = $old
}
else {
	Write-Host "Reusing $zst"
}
$stageOld = Join-Path $Download 'x'
if (Test-Path $stageOld) {
	Remove-Item -Recurse -Force $stageOld
}

$got = (Get-FileHash -Algorithm SHA256 $zst).Hash.ToLower()
if ($got -ne $ArchiveHash) {
	Remove-Item -Recurse -Force $Download
	throw "sha256 mismatch for $Archive`: expected $ArchiveHash, got $got (the download was deleted)"
}
Write-Host "sha256 ok ($got)"

# Extract only what the import needs (bsdtar in Windows 10 1803+ / 11; the .tar.zst of the same release needs a larger zstd window than bsdtar allows).
$top = "clang+llvm-$Version-x86_64-pc-windows-msvc"
$stage = Join-Path $Download 'x'
New-Item -ItemType Directory -Force $stage | Out-Null
& tar.exe -x -f $zst -C $stage "$top/bin/libclang.dll" "$top/lib/clang/$Major/include" "$top/include/clang-c"
if ($LASTEXITCODE -ne 0) {
	throw "tar failed with exit code $LASTEXITCODE"
}

$dllNew = Join-Path $stage "$top\bin\libclang.dll"
$dh = (Get-FileHash -Algorithm SHA256 $dllNew).Hash.ToLower()
if ($dh -ne $DllHash) {
	throw "sha256 mismatch for libclang.dll: expected $DllHash, got $dh"
}

if (Test-Path $Dest) {
	Remove-Item -Recurse -Force $Dest
}
New-Item -ItemType Directory -Force $Dest | Out-Null
Move-Item (Join-Path $stage "$top\bin") $Dest
Move-Item (Join-Path $stage "$top\lib") $Dest
Move-Item (Join-Path $stage "$top\include") $Dest

if (-not $KeepDownload) {
	Remove-Item -Recurse -Force $Download
}

$size = (Get-Item $Dll).Length
Write-Host "Installed libclang $Version`: $Dll ($size bytes, sha256 $dh)"
Write-Host "Builtin headers: $(Join-Path $Dest "lib\clang\$Major\include")"
