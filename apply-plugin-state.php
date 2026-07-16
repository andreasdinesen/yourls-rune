<?php
/* Apply the QR_CODE toggle to YOURLS' active_plugins option.
 *
 * Active plugins live in the options table as a serialized array of paths
 * relative to the plugins dir (e.g. "qr-code/plugin.php"), so this can only run
 * once the database is installed — start-apache.sh calls it right after the
 * installer. We talk to MySQL over PDO rather than bootstrapping YOURLS: a CLI
 * bootstrap is fragile, and all we need is one option.
 *
 * The toggle is authoritative: it activates when on and deactivates when off,
 * every boot. Other plugins in the list are preserved untouched.
 */

$id     = 'qr-code/plugin.php';
$want   = getenv('QR_CODE') === 'true';
$prefix = getenv('YOURLS_DB_PREFIX') ?: 'yourls_';
$table  = $prefix . 'options';

try {
    $pdo = new PDO(
        'mysql:host=127.0.0.1;dbname=' . (getenv('YOURLS_DB_NAME') ?: 'yourls') . ';charset=utf8mb4',
        getenv('YOURLS_DB_USER') ?: 'yourls',
        (string) getenv('YOURLS_DB_PASS'),
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );

    $st = $pdo->prepare("SELECT option_value FROM `$table` WHERE option_name = 'active_plugins' LIMIT 1");
    $st->execute();
    $raw = $st->fetchColumn();

    $active = [];
    if (is_string($raw) && $raw !== '') {
        $decoded = @unserialize($raw);
        if (is_array($decoded)) {
            $active = $decoded;
        }
    }

    $has = in_array($id, $active, true);
    if ($want === $has) {
        exit(0); // already in the desired state
    }

    if ($want) {
        $active[] = $id;
    } else {
        $active = array_filter($active, static function ($p) use ($id) {
            return $p !== $id;
        });
    }
    $value = serialize(array_values($active));

    if ($raw === false) {
        $q = $pdo->prepare("INSERT INTO `$table` (option_name, option_value) VALUES ('active_plugins', ?)");
    } else {
        $q = $pdo->prepare("UPDATE `$table` SET option_value = ? WHERE option_name = 'active_plugins'");
    }
    $q->execute([$value]);

    fwrite(STDERR, '[rune] QR-kode-plugin ' . ($want ? 'aktiveret' : 'deaktiveret') . "\n");
} catch (Throwable $e) {
    fwrite(STDERR, '[rune] Kunne ikke sætte QR-plugin-status: ' . $e->getMessage() . "\n");
    exit(1);
}
