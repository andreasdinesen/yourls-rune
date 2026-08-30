#!/usr/bin/env bash
# Panel "Opdater YOURLS" button (yggdrasil `update:` section). Runs in a throwaway
# container with /data mounted, the app stopped. It resolves the newest STABLE
# release, downloads + sanity-checks it, and records it in /data/core-version so
# the entrypoint lays it down on the restart that follows.
set -Eeuo pipefail

DATA=/data

latest="$(curl -fsSL --max-time 20 \
    https://api.github.com/repos/YOURLS/YOURLS/releases/latest 2>/dev/null \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name" *: *"v?([^"]+)".*/\1/')"
[ -n "$latest" ] || { echo "FEJL: kunne ikke hente nyeste YOURLS-version fra GitHub."; exit 1; }
echo "Nyeste stabile YOURLS: $latest"

mkdir -p "$DATA/cache"
tb="$DATA/cache/yourls-$latest.tar.gz"
if [ ! -s "$tb" ]; then
    echo "Henter YOURLS $latest ..."
    curl -fsSL --max-time 180 -o "$tb.part" \
        "https://github.com/YOURLS/YOURLS/archive/refs/tags/$latest.tar.gz"
    mv "$tb.part" "$tb"
fi

# Sanity: the archive must extract and expose a version.php.
tmp="$(mktemp -d)"
tar -xzf "$tb" -C "$tmp"
d="$(find "$tmp" -maxdepth 1 -type d -name 'YOURLS-*' | head -1)"
rv="$(sed -n "s/.*define( *'YOURLS_VERSION', *'\([^']*\)'.*/\1/p" \
    "$d/includes/version.php" 2>/dev/null | head -1)"
rm -rf "$tmp"
[ -n "$rv" ] || { echo "FEJL: hentet arkiv ser ikke ud som YOURLS."; rm -f "$tb"; exit 1; }
case "$rv" in *-*) echo "ADVARSEL: $latest rapporterer en udviklingsversion ($rv)." ;; esac

printf '%s' "$latest" > "$DATA/core-version"

echo ""
echo "YOURLS $latest er hentet og valgt. Appen genstartes nu og kører $latest."
echo "Kør /admin/upgrade.php hvis YOURLS beder om det efter opstart."
echo ""
echo "OBS: er YOURLS_VERSION-feltet sat i Settings, vinder det over denne knap."
echo "     Ryd feltet for at lade knappen styre versionen."
