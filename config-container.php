<?php
/* YOURLS config for the yggdrasil all-in-one rune.
 * Based on the official container template: every setting is read from the
 * environment at request time. Additions vs. upstream:
 *   - YOURLS_SITE is auto-detected from the request when left blank, so it
 *     matches whatever host:port yggdrasil exposes (no need to know the random
 *     port up front). Set YOURLS_SITE explicitly to pin a custom domain.
 *   - YOURLS_NO_HASH_PASSWORD keeps yggdrasil as the single source of the admin
 *     password (YOURLS must not rewrite this file with a hash).
 *   - user/config-extra.php is included at the end for persistent custom tweaks.
 */

// a helper function to lookup "env_FILE", "env", then fallback
if (!function_exists('getenv_container')) {
    function getenv_container(string $name, ?string $default = null): ?string
    {
        if ($fileEnv = getenv($name . '_FILE')) {
            return trim(file_get_contents($fileEnv));
        }
        if (($value = getenv($name)) !== false) {
            return $value;
        }

        return $default;
    }
}

/*
 ** MySQL settings
 */
define( 'YOURLS_DB_USER', getenv_container('YOURLS_DB_USER', 'root') );
define( 'YOURLS_DB_PASS', getenv_container('YOURLS_DB_PASS') );
define( 'YOURLS_DB_NAME', getenv_container('YOURLS_DB_NAME', 'yourls') );
define( 'YOURLS_DB_HOST', getenv_container('YOURLS_DB_HOST', '127.0.0.1') );
define( 'YOURLS_DB_PREFIX', getenv_container('YOURLS_DB_PREFIX', 'yourls_') );

/*
 ** Site options
 */

/** YOURLS installation URL -- all lowercase, no trailing slash.
 ** When YOURLS_SITE is empty we derive it from the current request, so the rune
 ** works on whatever port yggdrasil assigns and behind a reverse proxy. */
$__yourls_site = getenv_container('YOURLS_SITE');
if ($__yourls_site === null || $__yourls_site === '') {
    $__proto = 'http';
    if (!empty($_SERVER['HTTP_X_FORWARDED_PROTO'])) {
        $__proto = trim(explode(',', $_SERVER['HTTP_X_FORWARDED_PROTO'])[0]);
    } elseif (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') {
        $__proto = 'https';
    }
    $__host = '';
    if (!empty($_SERVER['HTTP_X_FORWARDED_HOST'])) {
        $__host = trim(explode(',', $_SERVER['HTTP_X_FORWARDED_HOST'])[0]);
    } elseif (!empty($_SERVER['HTTP_HOST'])) {
        $__host = trim($_SERVER['HTTP_HOST']);
    }
    $__yourls_site = ($__host !== '') ? $__proto . '://' . $__host : 'http://localhost';
}
define( 'YOURLS_SITE', rtrim($__yourls_site, '/') );

/** Server timezone GMT offset */
define( 'YOURLS_HOURS_OFFSET', filter_var(getenv('YOURLS_HOURS_OFFSET'), FILTER_VALIDATE_INT) ?: 0 );

/** YOURLS language (a .mo file in user/language). Empty = English. */
define( 'YOURLS_LANG', getenv('YOURLS_LANG') ?: '' );

/** Allow multiple short URLs for the same long URL */
define( 'YOURLS_UNIQUE_URLS', getenv('YOURLS_UNIQUE_URLS') === false ?: filter_var(getenv('YOURLS_UNIQUE_URLS'), FILTER_VALIDATE_BOOLEAN) );

/** Private: admin area requires login. Set false only for public/test setups. */
define( 'YOURLS_PRIVATE', getenv('YOURLS_PRIVATE') === false ?: filter_var(getenv('YOURLS_PRIVATE'), FILTER_VALIDATE_BOOLEAN) );

/** Random secret used to encrypt cookies (provided by the rune entrypoint). */
define( 'YOURLS_COOKIEKEY', getenv('YOURLS_COOKIEKEY') ?: 'modify this text with something random' );

/** Store admin passwords verbatim — yggdrasil owns the password, so YOURLS must
 ** not encrypt it back into this file (which the rune regenerates each boot). */
define( 'YOURLS_NO_HASH_PASSWORD', filter_var(getenv('YOURLS_NO_HASH_PASSWORD'), FILTER_VALIDATE_BOOLEAN) );

/** Username(s) and password(s) allowed to access the site. */
$yourls_user_passwords = [
    getenv_container('YOURLS_USER') => getenv_container('YOURLS_PASS'),
];

/** Debug mode */
define( 'YOURLS_DEBUG', filter_var(getenv('YOURLS_DEBUG'), FILTER_VALIDATE_BOOLEAN) );

/** Skip the "new version available" check. */
define( 'YOURLS_NO_VERSION_CHECK', getenv('YOURLS_NO_VERSION_CHECK') === false ?: filter_var(getenv('YOURLS_NO_VERSION_CHECK'), FILTER_VALIDATE_BOOLEAN) );

/*
** URL Shortening settings
*/

/** URL shortening method: 36 (lowercase) or 62 (mixed case). */
define( 'YOURLS_URL_CONVERT', filter_var(getenv('YOURLS_URL_CONVERT'), FILTER_VALIDATE_INT) ?: 36 );

/** Disable stat logging if set. */
define( 'YOURLS_NOSTATS', filter_var(getenv('YOURLS_NOSTATS'), FILTER_VALIDATE_BOOLEAN) );

/** Reserved keywords (generated URLs won't match them). */
$yourls_reserved_URL = [
    'porn', 'faggot', 'sex', 'nigger', 'fuck', 'cunt', 'dick',
];

/*
 ** Persistent personal settings (survives image upgrades; never overwritten).
 */
if ( is_readable( __DIR__ . '/config-extra.php' ) ) {
    require __DIR__ . '/config-extra.php';
}
