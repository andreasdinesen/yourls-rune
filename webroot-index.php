<?php
/* A URL shortener has no public landing page, and YOURLS ships no index at the
 * webroot root — without this "/" would 403 (no DirectoryIndex). Short URLs like
 * /abc are unaffected: they are not files, so Apache rewrites them to
 * yourls-loader.php and never reach this.
 *
 * The Location is deliberately RELATIVE. Behind a TLS-terminating proxy Apache
 * only ever sees plain http, so an Apache-side redirect would send visitors to
 * http://…/admin/ and downgrade the connection. A relative Location is resolved
 * by the browser against the URL it actually requested, so the original scheme
 * and host are preserved for free — and no Host header can steer it elsewhere.
 */
header('Location: /admin/', true, 302);
exit;
