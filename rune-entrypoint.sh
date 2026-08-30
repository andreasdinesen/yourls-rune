#!/usr/bin/env bash
# Container entrypoint: prepare env, secrets, webroot, DB data dir, optional
# self-update, then hand off to supervisord (which starts MariaDB + Apache).
set -Eeuo pipefail

DATA=/data
SRC=/usr/src/yourls
WEBROOT=/var/www/html

log() { echo "[rune] $*" >&2; }

mkdir -p "$DATA/mysql" "$DATA/user" "$DATA/secrets" "$DATA/db-dump" "$DATA/cache"

# --- Secrets: generated once, then stable across restarts ---------------------
gen_secret() { # $1 = file path -> prints the secret
    if [ ! -s "$1" ]; then
        head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1 > "$1"
        chmod 600 "$1"
    fi
    cat "$1"
}
DB_PASSWORD="$(gen_secret "$DATA/secrets/db-password")"
# The official image generates a cookie key but never exports it, so PHP falls
# back to the hard-coded default and logins break on restart. Generate a stable
# one ourselves and export it.
YOURLS_COOKIEKEY="$(gen_secret "$DATA/secrets/cookiekey")"
export YOURLS_COOKIEKEY

# --- Point YOURLS at the built-in MariaDB (over TCP loopback) -----------------
export YOURLS_DB_HOST="127.0.0.1"
export YOURLS_DB_USER="yourls"
export YOURLS_DB_PASS="$DB_PASSWORD"
export YOURLS_DB_NAME="yourls"
export YOURLS_DB_PREFIX="${YOURLS_DB_PREFIX:-yourls_}"

# yggdrasil is the source of truth for the admin password, so store it verbatim
# and stop YOURLS from rewriting config.php with a hash.
export YOURLS_NO_HASH_PASSWORD="true"

# --- Normalize "empty means unset" booleans (yggdrasil sends "" for blanks) ---
# A blank YOURLS_PRIVATE would otherwise evaluate to false and expose the admin
# area publicly, so every boolean is coerced to an explicit true/false here.
norm_bool() { # $1 = var name, $2 = default -> prints true/false
    eval "_v=\"\${$1-}\""
    _v="$(printf '%s' "$_v" | tr '[:upper:]' '[:lower:]')"
    case "$_v" in
        1|true|yes|on)  printf 'true' ;;
        0|false|no|off) printf 'false' ;;
        *)              printf '%s' "$2" ;;
    esac
}
export YOURLS_PRIVATE="$(norm_bool YOURLS_PRIVATE true)"
export YOURLS_UNIQUE_URLS="$(norm_bool YOURLS_UNIQUE_URLS true)"
export YOURLS_NO_VERSION_CHECK="$(norm_bool YOURLS_NO_VERSION_CHECK false)"
AUTO_UPDATE="$(norm_bool AUTO_UPDATE false)"
# Exported: start-apache.sh applies this to active_plugins once the DB is up.
export QR_CODE="$(norm_bool QR_CODE false)"

# --- YOURLS core helpers ------------------------------------------------------
# /var/www/html is NOT a volume, so the core is rebuilt from scratch each boot.
copy_core() { # $1 = source tree -> lays it into a CLEAN webroot (keeps user/)
    find "$WEBROOT" -mindepth 1 -maxdepth 1 ! -name user -exec rm -rf {} +
    ( cd "$1" && for item in * .[!.]*; do
        [ "$item" = user ] && continue
        [ -e "$item" ] || continue
        cp -a "$item" "$WEBROOT/"
    done )
}
version_of() { # $1 = a YOURLS tree -> its version.php string, or empty
    sed -n "s/.*define( *'YOURLS_VERSION', *'\([^']*\)'.*/\1/p" \
        "$1/includes/version.php" 2>/dev/null | head -1
}
latest_release() { # newest STABLE release tag (the API excludes pre-releases)
    curl -fsSL --max-time 15 \
        https://api.github.com/repos/YOURLS/YOURLS/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name" *: *"v?([^"]+)".*/\1/'
}
extract_release() { # $1 = tag -> prints extracted source dir on stdout, or fails
    local ver="$1" tb tmp src
    tb="$DATA/cache/yourls-$ver.tar.gz"
    if [ ! -s "$tb" ]; then
        log "Henter YOURLS $ver ..."
        curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --max-time 120 -o "$tb.part" \
            "https://github.com/YOURLS/YOURLS/archive/refs/tags/$ver.tar.gz" \
            && mv "$tb.part" "$tb" || { rm -f "$tb.part"; return 1; }
    fi
    tmp="$(mktemp -d)"
    tar -xzf "$tb" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; rm -f "$tb"; return 1; }
    src="$(find "$tmp" -maxdepth 1 -type d -name 'YOURLS-*' | head -1)"
    [ -n "$src" ] || { rm -rf "$tmp"; return 1; }
    printf '%s' "$src"
}

# --- Choose which YOURLS core to serve, then lay it down cleanly --------------
# Priority (highest first):
#   1. YOURLS_VERSION env  — explicit pin / rollback (power users)
#   2. /data/core-version  — written by the "Opdater YOURLS" panel button
#   3. AUTO_UPDATE         — newest stable release, every boot
#   4. image               — the version bundled in this image
# NOTE: the base image ships ENV YOURLS_VERSION=<bundled>; an unset panel
# variable leaks that value through, which equals the image version (a no-op).
sanitize_ver() { printf '%s' "$1" | tr -d ' \t\r\n' | sed 's/^v//'; }
CORE_SRC="$SRC"     # image default (/usr/src/yourls)
CORE_TMP=""         # extracted dir to remove after lay-down
want=""; why=""

env_pin="$(sanitize_ver "${YOURLS_VERSION:-}")"
case "$env_pin" in
    *[!0-9.]*) [ -n "$env_pin" ] && log "YOURLS_VERSION '$env_pin' ugyldig (forventer fx 1.10.6); ignorerer"; env_pin="" ;;
esac
# The base image ships ENV YOURLS_VERSION=<bundled>. When the panel variable is
# unset that value leaks in; treat "same as image" as unset so it does not shadow
# the Update button's pin file. (Pinning to the image version is a no-op anyway.)
[ "$env_pin" = "$YOURLS_RUNE_VERSION" ] && env_pin=""
file_pin=""
[ -s "$DATA/core-version" ] && file_pin="$(sanitize_ver "$(cat "$DATA/core-version" 2>/dev/null)")"
case "$file_pin" in *[!0-9.]*) file_pin="" ;; esac

if [ -n "$env_pin" ]; then
    want="$env_pin"; why="YOURLS_VERSION"
    [ "$AUTO_UPDATE" = true ] && log "YOURLS_VERSION er sat; AUTO_UPDATE ignoreres"
elif [ -n "$file_pin" ]; then
    want="$file_pin"; why="Opdater-knap"
elif [ "$AUTO_UPDATE" = true ]; then
    want="$(latest_release)"; why="AUTO_UPDATE"
    if [ -n "$want" ]; then
        newer="$(printf '%s\n%s\n' "$YOURLS_RUNE_VERSION" "$want" | sort -V | tail -1)"
        [ "$newer" = "$want" ] || { log "AUTO_UPDATE: image ($YOURLS_RUNE_VERSION) >= release ($want); beholder image"; want=""; }
    else
        log "AUTO_UPDATE: kunne ikke hente seneste version; beholder image"
    fi
fi

if [ -n "$want" ] && [ "$want" != "$YOURLS_RUNE_VERSION" ]; then
    if _d="$(extract_release "$want")"; then
        CORE_SRC="$_d"; CORE_TMP="$(dirname "$_d")"
        _rv="$(version_of "$_d")"
        case "$_rv" in
            *-*) log "ADVARSEL: YOURLS $want er mærket som udvikling ($_rv) — kan være ustabil; brug en stabil version (fx nyeste udgivelse)" ;;
        esac
        log "YOURLS-kerne: $want valgt via $why (imaget indeholder $YOURLS_RUNE_VERSION)"
    else
        log "Kunne ikke hente YOURLS $want ($why); kører imagets $YOURLS_RUNE_VERSION"
    fi
fi

copy_core "$CORE_SRC"
[ -n "$CORE_TMP" ] && rm -rf "$CORE_TMP"

# --- Persist user/ (config, plugins, pages) on the volume ---------------------
# Seeded from the IMAGE. config-container.php is OUR template (shipped in the
# image), never the stock one from a fetched release.
if [ -z "$(ls -A "$DATA/user" 2>/dev/null || true)" ]; then
    cp -a "$SRC/user/." "$DATA/user/"
fi
rm -rf "$WEBROOT/user"
ln -s "$DATA/user" "$WEBROOT/user"

# config.php is 100% env-driven, so regenerating it every boot is safe and keeps
# it upgradeable. Personal tweaks live in config-extra.php (never overwritten).
cp "$SRC/user/config-container.php" "$DATA/user/config.php"
[ -f "$DATA/user/config-extra.php" ] || : > "$DATA/user/config-extra.php"

# Landing page for "/" -> /admin/ (YOURLS ships no webroot index).
cp -a /usr/local/share/rune-webroot/index.php "$WEBROOT/index.php"

# --- Version report -----------------------------------------------------------
# The panel's settings form can only show static text, so the live status goes
# where it can be seen: the Console log and /data/YOURLS-VERSION.txt (Files tab).
RUNNING_VERSION="$(sed -n "s/.*define( *'YOURLS_VERSION', *'\([^']*\)'.*/\1/p" \
    "$WEBROOT/includes/version.php" 2>/dev/null | head -1)"
[ -n "$RUNNING_VERSION" ] || RUNNING_VERSION="$YOURLS_RUNE_VERSION"
LATEST_VERSION="$(latest_release || true)"
{
    echo "YOURLS-version"
    echo "=============="
    echo "Kører:            $RUNNING_VERSION"
    echo "Image indeholder: $YOURLS_RUNE_VERSION"
    echo "Nyeste udgivelse: ${LATEST_VERSION:-(kunne ikke tjekkes)}"
    echo ""
    if [ -n "$LATEST_VERSION" ] && [ "$LATEST_VERSION" != "$RUNNING_VERSION" ] \
       && [ "$(printf '%s\n%s\n' "$RUNNING_VERSION" "$LATEST_VERSION" | sort -V | tail -1)" = "$LATEST_VERSION" ]; then
        echo "NY VERSION TILGÆNGELIG: $LATEST_VERSION"
        echo ""
        echo "Sådan opdaterer du:"
        echo "  1. Tag en backup under Backups-fanen"
        echo "  2. Tryk knappen 'Opdater YOURLS til nyeste' på serversiden"
        echo "     (kør /admin/upgrade.php hvis YOURLS beder om det)"
        echo ""
        echo "Går noget galt: gendan backuppen (og ryd evt. YOURLS_VERSION-feltet)."
    elif [ -n "$LATEST_VERSION" ]; then
        echo "Du kører den nyeste version."
    fi
    echo ""
    echo "Tjekket: $(date -u '+%Y-%m-%d %H:%M UTC') (opdateres ved hver genstart)"
} > "$DATA/YOURLS-VERSION.txt"
log "YOURLS-version: kører $RUNNING_VERSION, image $YOURLS_RUNE_VERSION, nyeste ${LATEST_VERSION:-ukendt}"
if [ -n "$LATEST_VERSION" ] && [ "$LATEST_VERSION" != "$RUNNING_VERSION" ] \
   && [ "$(printf '%s\n%s\n' "$RUNNING_VERSION" "$LATEST_VERSION" | sort -V | tail -1)" = "$LATEST_VERSION" ]; then
    log "NY YOURLS-VERSION TILGÆNGELIG: $LATEST_VERSION — tag backup og tryk 'Opdater YOURLS til nyeste' (se /data/YOURLS-VERSION.txt)"
fi

# --- Optional plugin installation ---------------------------------------------
# YOURLS has no plugin installer: a plugin is just a folder holding a plugin.php
# under user/plugins. Fetch each requested GitHub repo into the persisted plugins
# dir. We deliberately never auto-activate — activation is the user's call in the
# admin's "Manage Plugins" page, and it is stored in the database.
plugin_name_of() { # $1 = spec -> the folder name, or empty if the spec is invalid
    local spec="$1"
    spec="${spec#http://github.com/}"
    spec="${spec#https://github.com/}"
    spec="${spec%/}"
    spec="${spec%.git}"
    case "$spec" in *@*) spec="${spec%@*}" ;; esac
    case "$spec" in
        */*) printf '%s' "${spec#*/}" ;;
        *)   printf '' ;;
    esac
}
install_plugin() { # $1 = "owner/repo", "owner/repo@ref", or a GitHub URL
    local spec="$1" ref="" name url tmp found src dest
    spec="${spec#http://github.com/}"
    spec="${spec#https://github.com/}"
    spec="${spec%/}"
    spec="${spec%.git}"
    case "$spec" in *@*) ref="${spec##*@}"; spec="${spec%@*}" ;; esac
    name="$(plugin_name_of "$1")"
    if [ -z "$name" ]; then
        log "Plugin '$1' ignoreret (forventer owner/repo)"; return 0
    fi
    dest="$DATA/user/plugins/$name"

    # Already installed: leave it alone unless AUTO_UPDATE asks for a refresh.
    if [ -d "$dest" ] && [ "$AUTO_UPDATE" != true ]; then
        return 0
    fi

    # The tarball endpoint follows the repo's default branch when no ref given.
    url="https://api.github.com/repos/$spec/tarball"
    [ -n "$ref" ] && url="$url/$ref"

    tmp="$(mktemp -d)"
    if ! curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --max-time 60 "$url" 2>/dev/null | tar -xz -C "$tmp" 2>/dev/null; then
        rm -rf "$tmp"; log "Plugin '$spec': kunne ikke hentes"; return 1
    fi
    # GitHub tarballs unpack to <owner>-<repo>-<sha>/; plugin.php sits at that
    # root for most plugins, but occasionally one level further down. Pick the
    # SHALLOWEST one: a repo can ship helper files in subdirs that sort before
    # plugin.php, and taking whatever find hits first would install that instead.
    found="$(find "$tmp" -maxdepth 3 -name plugin.php -printf '%d\t%p\n' 2>/dev/null \
             | sort -n | head -1 | cut -f2-)"
    if [ -z "$found" ]; then
        rm -rf "$tmp"; log "Plugin '$spec': ingen plugin.php fundet"; return 1
    fi
    src="$(dirname "$found")"
    rm -rf "$dest"
    mkdir -p "$dest"
    cp -a "$src/." "$dest/"
    # Mark it as ours so prune_plugins may remove it later. YOURLS' own bundled
    # plugins and anything uploaded by hand never carry this, so they are safe.
    : > "$dest/.rune-installed"
    rm -rf "$tmp"
    log "Plugin '$name' installeret (aktivér det under Manage Plugins)"
}
# Drop plugins we installed earlier that are no longer listed in PLUGINS, so
# clearing the field actually uninstalls. Only marked folders are touched.
prune_plugins() { # $1 = space-separated list of still-wanted folder names
    local marker dir name
    [ -d "$DATA/user/plugins" ] || return 0
    for marker in "$DATA/user/plugins"/*/.rune-installed; do
        [ -f "$marker" ] || continue
        dir="$(dirname "$marker")"
        name="$(basename "$dir")"
        case " $1 " in
            *" $name "*) continue ;;
        esac
        rm -rf "$dir"
        log "Plugin '$name' fjernet (ikke længere i PLUGINS)"
    done
}
_wanted=""
if [ -n "${PLUGINS:-}" ]; then
    mkdir -p "$DATA/user/plugins"
    for _spec in $(printf '%s' "${PLUGINS}" | tr ',;' '  '); do
        [ -n "$_spec" ] || continue
        install_plugin "$_spec" || true
        _name="$(plugin_name_of "$_spec")"
        [ -n "$_name" ] && _wanted="$_wanted $_name"
    done
fi
# Runs even with an empty PLUGINS: emptying the field removes what we installed.
prune_plugins "$_wanted"

# --- Bundled QR-code feature (QR_CODE toggle) ---------------------------------
# YOURLS' own example plugin (yourls.org/docs/development/examples/qrcode): add
# ".qr" to a short URL to get its QR code. Shipped in the image so it can be
# switched on from yggdrasil. Refresh the file every boot so image upgrades ship
# fixes; activation happens in start-apache.sh once the options table exists.
if [ "$QR_CODE" = true ]; then
    mkdir -p "$DATA/user/plugins/qr-code"
    cp -a /usr/local/share/rune-plugins/qr-code/plugin.php \
          "$DATA/user/plugins/qr-code/plugin.php"
fi

# --- Ownership ----------------------------------------------------------------
chown -R www-data:www-data "$WEBROOT" 2>/dev/null || true
chown -R www-data:www-data "$DATA/user" 2>/dev/null || true

# --- Initialize the MariaDB data directory on first run -----------------------
chown -R mysql:mysql "$DATA/mysql"
if [ ! -d "$DATA/mysql/mysql" ]; then
    log "Initialiserer MariaDB-datamappe ..."
    mariadb-install-db --user=mysql --datadir="$DATA/mysql" \
        --auth-root-authentication-method=socket --skip-test-db >/dev/null 2>&1 || \
    mariadb-install-db --user=mysql --datadir="$DATA/mysql" \
        --auth-root-authentication-method=socket >/dev/null
fi
mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld

log "Klargøring færdig; starter tjenester ..."
exec "$@"
