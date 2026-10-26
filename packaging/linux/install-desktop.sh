#!/bin/sh
# Adds Treadle to the desktop's application menu for this user: writes
# ~/.local/share/applications/treadle.desktop pointing at the treadle executable and the icon next to this
# script (the unpacked package folder). Run it again after moving the folder; delete that file to remove the entry.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -x "$DIR/treadle" ] || { echo "install-desktop.sh: no treadle executable in $DIR" >&2; exit 1; }
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$APPS"
cat > "$APPS/treadle.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Treadle
Comment=Visual programming language and IDE
Exec="$DIR/treadle" %f
Icon=$DIR/treadle.png
Terminal=false
Categories=Development;IDE;
StartupWMClass=treadle
DESKTOP
echo "Wrote $APPS/treadle.desktop"
