#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
if [ -d ".millennium/dist" ] && [ ! -e ".millennium/Dist" ]; then
  ln -s dist ".millennium/Dist"
elif [ -d ".millennium/Dist" ] && [ ! -e ".millennium/dist" ]; then
  ln -s Dist ".millennium/dist"
fi
chmod -R u+rwX,go+rX "$DIR"
echo "[Repage SteamGrid] Permissions and links (.millennium/dist <-> Dist) fixed in: $DIR"
echo "Restart Steam to load the plugin."
