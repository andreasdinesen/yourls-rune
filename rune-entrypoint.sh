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

# --- Lay down YOURLS core fresh from the image each boot ----------------------
# /var/www/html is NOT a volume, so copying core on every start means a newer
# image automatically ships newer core. Only user/ is persisted (below).
copy_core() { # $1 = source tree
    ( cd "$1" && for item in * .[!.]*; do
        [ "$item" = user ] && continue
        [ -e "$item" ] || continue
        rm -rf "$WEBROOT/$item"
        cp -a "$item" "$WEBROOT/"
    done )
}
find "$WEBROOT" -mindepth 1 -maxdepth 1 ! -name user -exec rm -rf {} +
copy_core "$SRC"

# --- Persist user/ (config, plugins, pages) on the volume ---------------------
if [ -z "$(ls -A "$DATA/user" 2>/dev/null || true)" ]; then
    cp -a "$SRC/user/." "$DATA/user/"
fi
rm -rf "$WEBROOT/user"
ln -s "$DATA/user" "$WEBROOT/user"

# config.php is 100% env-driven, so regenerating it every boot is safe and keeps
# it upgradeable. Personal tweaks live in config-extra.php (never overwritten).
cp "$SRC/user/config-container.php" "$DATA/user/config.php"
[ -f "$DATA/user/config-extra.php" ] || : > "$DATA/user/config-extra.php"

# --- Optional live self-update from YOURLS' GitHub releases -------------------
update_core() {
    local current="${YOURLS_RUNE_VERSION:-0}" latest tb tmp src item newer
    latest="$(curl -fsSL --max-time 20 \
        https://api.github.com/repos/YOURLS/YOURLS/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name" *: *"v?([^"]+)".*/\1/')"
    [ -n "$latest" ] || { log "AUTO_UPDATE: kunne ikke hente seneste version"; return 1; }
    if [ "$latest" = "$current" ]; then
        log "AUTO_UPDATE: allerede nyeste ($current)"; return 0
    fi
    newer="$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -1)"
    if [ "$newer" != "$latest" ]; then
        log "AUTO_UPDATE: image ($current) er nyere end release ($latest); beholder image"
        return 0
    fi
    tb="$DATA/cache/yourls-$latest.tar.gz"
    if [ ! -s "$tb" ]; then
        log "AUTO_UPDATE: henter YOURLS $latest ..."
        curl -fsSL --max-time 120 -o "$tb.part" \
            "https://github.com/YOURLS/YOURLS/archive/refs/tags/$latest.tar.gz" \
            && mv "$tb.part" "$tb" || { rm -f "$tb.part"; return 1; }
    fi
    tmp="$(mktemp -d)"
    tar -xzf "$tb" -C "$tmp" || { rm -rf "$tmp"; return 1; }
    src="$(find "$tmp" -maxdepth 1 -type d -name 'YOURLS-*' | head -1)"
    [ -n "$src" ] || { rm -rf "$tmp"; return 1; }
    copy_core "$src"
    rm -rf "$tmp"
    log "AUTO_UPDATE: opdateret til YOURLS $latest (kør evt. /admin/upgrade.php hvis promptet)"
}
if [ "$AUTO_UPDATE" = true ]; then
    update_core || log "AUTO_UPDATE fejlede; fortsætter på image-versionen ${YOURLS_RUNE_VERSION}"
fi

# --- Optional plugin installation ---------------------------------------------
# YOURLS has no plugin installer: a plugin is just a folder holding a plugin.php
# under user/plugins. Fetch each requested GitHub repo into the persisted plugins
# dir. We deliberately never auto-activate — activation is the user's call in the
# admin's "Manage Plugins" page, and it is stored in the database.
install_plugin() { # $1 = "owner/repo", "owner/repo@ref", or a GitHub URL
    local spec="$1" ref="" name url tmp found src dest
    spec="${spec#http://github.com/}"
    spec="${spec#https://github.com/}"
    spec="${spec%/}"
    spec="${spec%.git}"
    case "$spec" in *@*) ref="${spec##*@}"; spec="${spec%@*}" ;; esac
    case "$spec" in
        */*) : ;;
        *) log "Plugin '$1' ignoreret (forventer owner/repo)"; return 0 ;;
    esac
    name="${spec#*/}"
    dest="$DATA/user/plugins/$name"

    # Already installed: leave it alone unless AUTO_UPDATE asks for a refresh.
    if [ -d "$dest" ] && [ "$AUTO_UPDATE" != true ]; then
        return 0
    fi

    # The tarball endpoint follows the repo's default branch when no ref given.
    url="https://api.github.com/repos/$spec/tarball"
    [ -n "$ref" ] && url="$url/$ref"

    tmp="$(mktemp -d)"
    if ! curl -fsSL --max-time 60 "$url" 2>/dev/null | tar -xz -C "$tmp" 2>/dev/null; then
        rm -rf "$tmp"; log "Plugin '$spec': kunne ikke hentes"; return 1
    fi
    # GitHub tarballs unpack to <owner>-<repo>-<sha>/; plugin.php sits at that
    # root for most plugins, but occasionally one level further down.
    found="$(find "$tmp" -maxdepth 3 -name plugin.php -print -quit 2>/dev/null || true)"
    if [ -z "$found" ]; then
        rm -rf "$tmp"; log "Plugin '$spec': ingen plugin.php fundet"; return 1
    fi
    src="$(dirname "$found")"
    rm -rf "$dest"
    mkdir -p "$dest"
    cp -a "$src/." "$dest/"
    rm -rf "$tmp"
    log "Plugin '$name' installeret (aktivér det under Manage Plugins)"
}
if [ -n "${PLUGINS:-}" ]; then
    mkdir -p "$DATA/user/plugins"
    for _spec in $(printf '%s' "${PLUGINS}" | tr ',;' '  '); do
        [ -n "$_spec" ] || continue
        install_plugin "$_spec" || true
    done
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
