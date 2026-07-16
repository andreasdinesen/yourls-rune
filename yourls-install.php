<?php
/* One-shot YOURLS installer for the rune.
 *
 * Bootstraps YOURLS with a trimmed-down init (no redirect-to-install, no
 * plugins, no option preload — the options table may not exist yet) and creates
 * the tables + admin the first time the database is empty. Idempotent: it exits
 * early once YOURLS reports itself installed, so it is safe to run on every boot.
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
$defaults = new \YOURLS\Config\InitDefaults();
$defaults->redirect_to_install    = false;
$defaults->check_if_upgrade_needed = false;
$defaults->load_plugins           = false;
$defaults->plugins_loaded_action  = false;
$defaults->check_new_version      = false;
$defaults->register_shutdown      = false;
$defaults->init_admin             = false;
$defaults->core_loaded            = false;
$defaults->get_all_options        = false;
new \YOURLS\Config\Init($defaults);

// The trimmed init skips the 'plugins_loaded' action, which is what normally
// populates $yourls_allowedprotocols (via yourls_kses_init). Without it the
// sample-link insertion inside yourls_create_sql_tables() fatals in
// yourls_is_allowed_protocol(). Populate the KSES globals explicitly.
if (function_exists('yourls_kses_init')) {
    yourls_kses_init();
}

$installed = false;
try {
    $installed = yourls_is_installed();
} catch (\Throwable $e) {
    $installed = false;
}

if ($installed) {
    fwrite(STDERR, "[rune] YOURLS er allerede installeret.\n");
    exit(0);
}

fwrite(STDERR, "[rune] Installerer YOURLS-tabeller ...\n");
$result = yourls_create_sql_tables();

foreach (($result['error'] ?? []) as $msg) {
    fwrite(STDERR, "[rune]   FEJL: $msg\n");
}
foreach (($result['success'] ?? []) as $msg) {
    fwrite(STDERR, "[rune]   $msg\n");
}

// Non-zero exit if tables clearly failed, so the log makes the failure visible.
exit(empty($result['error']) ? 0 : 1);
