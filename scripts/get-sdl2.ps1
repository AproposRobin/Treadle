# get-sdl2.ps1: installs the SDL2 development package the native host (Native\build_windows.ps1) and the
# m2-sdl sample (TreadleCore\samples\m2-sdl\sdl2.cimport) use.
#
#   Release   SDL 2.32.10, mingw development build
#   Archive   SDL2-devel-2.32.10-mingw.zip
#   From      https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/
#   sha256    f15cff5fca62ec9381a016ef1d42a95c638cd72d2f226ba5781c76fe43dbd1ac
#   Installs  <repo>\tools\SDL2-2.32.10\x86_64-w64-mingw32\  (include\SDL2, lib\libSDL2.a, lib\libSDL2.dll.a, bin\SDL2.dll)
#             <repo>\tools\SDL2-2.32.10\LICENSE.txt
#   License   Zlib (LICENSE.txt)
#
# The archive is downloaded into a fresh, empty folder (tools\SDL2-download), its sha256 is checked before
# anything is extracted, only the files above are taken out of it, and the download folder is deleted
# afterwards. tools\SDL2-2.32.10\ is git-ignored: nothing here is committed. When the package is already
# installed nothing is downloaded; -From <folder> copies an existing unpacked SDL2-2.32.10 (a folder holding
# x86_64-w64-mingw32\lib\libSDL2.a) instead of downloading.
#
#   powershell -File scripts\get-sdl2.ps1 [-Root <repo>] [-From <unpacked SDL2-2.32.10>] [-Force] [-KeepDownload]

param(
	# The repository root (default: the folder above scripts\). A worktree passes the main checkout.
	[string]$Root = '',
	# An unpacked SDL2-2.32.10 mingw devel package already on disk (copied, not downloaded).
	[string]$From = '',
	[switch]$Force,
	[switch]$KeepDownload
)

$ErrorActionPreference = 'Stop'

$Version     = '2.32.10'
$Name        = "SDL2-$Version"
$Archive     = "SDL2-devel-$Version-mingw.zip"
$Url         = "https://github.com/libsdl-org/SDL/releases/download/release-$Version/$Archive"
$ArchiveHash = 'f15cff5fca62ec9381a016ef1d42a95c638cd72d2f226ba5781c76fe43dbd1ac'
$Arch        = 'x86_64-w64-mingw32'

$Repo     = if ($Root) { $Root } else { Split-Path -Parent $PSScriptRoot }
$Dest     = Join-Path $Repo "tools\$Name"
$Download = Join-Path $Repo 'tools\SDL2-download'

function Test-Sdl([string]$dir) {
	foreach ($f in @('lib\libSDL2.a', 'lib\libSDL2.dll.a', 'bin\SDL2.dll', 'include\SDL2\SDL_version.h')) {
		if (-not (Test-Path (Join-Path $dir "$Arch\$f"))) { return $false }
	}
	$h = Get-Content -Raw (Join-Path $dir "$Arch\include\SDL2\SDL_version.h")
	return ($h -match '#define SDL_MINOR_VERSION\s+32') -and ($h -match '#define SDL_PATCHLEVEL\s+10')
}

function Install-From([string]$src) {
	if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
	New-Item -ItemType Directory -Force $Dest | Out-Null
	Copy-Item -Recurse (Join-Path $src $Arch) (Join-Path $Dest $Arch)
	$lic = Join-Path $src 'LICENSE.txt'
	if (Test-Path $lic) { Copy-Item $lic $Dest }
}

if ((Test-Sdl $Dest) -and -not $Force) {
	Write-Host "SDL2 $Version is already installed: $Dest"
	exit 0
}

if ($From) {
	if (-not (Test-Sdl $From)) { throw "$From is not SDL2 $Version mingw devel ($Arch\lib\libSDL2.a, bin\SDL2.dll, include\SDL2)" }
	Write-Host "Copying $From to $Dest"
	Install-From $From
	Write-Host "Installed SDL2 $Version`: $Dest"
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
& tar.exe -x -f $zip -C $stage "$Name/$Arch" "$Name/LICENSE.txt"
if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }
$top = Join-Path $stage $Name
if (-not (Test-Sdl $top)) { throw "the archive did not unpack to $Name\$Arch" }

Install-From $top
if (-not $KeepDownload) { Remove-Item -Recurse -Force $Download }
Write-Host "Installed SDL2 $Version`: $Dest"
