<?php
/* One-shot YOURLS installer for the rune.
 *
 * Bootstraps YOURLS with a trimmed-down init (no redirect-to-install, no
 * plugins, no option preload — the options table may not exist yet) and creates
 * the tables + admin the first time the database is empty. Idempotent: it exits
 * early once the options table holds a 'version' row, so it is safe to run on
 * every boot.
 *
 * Run from the webroot: `cd /var/www/html && php /usr/local/lib/yourls-install.php`.
 */

$webroot = '/var/www/html';

require $webroot . '/includes/vendor/autoload.php';

$config = new \YOURLS\Config\Config();
if (!defined('YOURLS_CONFIGFILE')) {
    define('YOURLS_CONFIGFILE', $webroot . '/user/config.php');
}
require_once YOURLS_CONFIGFILE;
$config->define_core_constants();

// Minimal init — see YOURLS\Config\InitDefaults (designed to be tuned like this).
// We keep it lean and CLI-safe: no request/SSL fixups, no install/upgrade
// redirects, no plugin loading, and no option preload (tables may not exist).
$defaults = new \YOURLS\Config\InitDefaults();
$defaults->fix_request_uri         = false;
$defaults->redirect_ssl            = false;
$defaults->get_all_options         = false;
$defaults->register_shutdown       = false;
$defaults->core_loaded             = false;
$defaults->redirect_to_install     = false;
$defaults->check_if_upgrade_needed = false;
$defaults->load_plugins            = false;
$defaults->plugins_loaded_action   = false;
$defaults->check_new_version       = false;
$defaults->init_admin              = false;
new \YOURLS\Config\Init($defaults);

// The trimmed init skips the 'plugins_loaded' action, which is what normally
// populates $yourls_allowedprotocols (via yourls_kses_init). Without it the
// sample-link insertion inside yourls_create_sql_tables() fatals in
// yourls_is_allowed_protocol(). Populate the KSES globals explicitly.
if (function_exists('yourls_kses_init')) {
    yourls_kses_init();
}

$ydb = yourls_get_db();

/** Installed == the options table exists and holds a 'version' row. */
function rune_is_installed($ydb): bool
{
    try {
        $v = $ydb->fetchValue(
            "SELECT option_value FROM `" . YOURLS_DB_TABLE_OPTIONS . "`"
            . " WHERE option_name = 'version' LIMIT 1"
        );
        return !empty($v);
    } catch (\Throwable $e) {
        return false;
    }
}

if (rune_is_installed($ydb)) {
    fwrite(STDERR, "[rune] YOURLS er allerede installeret.\n");
    exit(0);
}

fwrite(STDERR, "[rune] Installerer YOURLS-tabeller ...\n");

// yourls_create_sql_tables() forces verbose debug output; swallow it so the
// container log stays readable. Success is judged by rune_is_installed() below,
// not by the (cosmetic) messages it returns.
ob_start();
try {
    yourls_create_sql_tables();
} catch (\Throwable $e) {
    ob_end_clean();
    fwrite(STDERR, "[rune] Undtagelse under install: " . $e->getMessage() . "\n");
    exit(1);
}
ob_end_clean();

if (rune_is_installed($ydb)) {
    fwrite(STDERR, "[rune] YOURLS-installation fuldført.\n");
    exit(0);
}

fwrite(STDERR, "[rune] YOURLS-installation fejlede (ingen version-række).\n");
exit(1);
