<?php

/**
 * The container SP's page: an SP-initiated login at each linked tree's IdP and at the container's
 * own IdP, and "Clear SP session".
 *
 * GET ?idp=<entity id> starts a login at that IdP that returns to result.php. Only a linked tree's
 * idpEntityId or the container IdP is accepted; anything else answers 400 and never reaches
 * login(). POST action=clear ends the container SP's session here only: no single logout, and the
 * IdP session stays.
 */

declare(strict_types=1);

require_once '/var/simplesamlphp/public/_include.php';
require_once __DIR__ . '/../lib/trees.php';

use SimpleSAML\Auth;
use SimpleSAML\Session;
use SimpleSAML\Utils;

$h = static fn (string $s): string => htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');

/** @var array<string, string> $idps entity id => button label */
$idps = [];
foreach (linkedTrees() as $tree) {
    $idps[$tree['idpEntityId']] = 'Log in at ' . $tree['tree'];
}
$idps[SAML_TEST_ORIGIN . '/idp'] = 'Log in at saml.test (self-test)';

if ($_SERVER['REQUEST_METHOD'] === 'POST' && ($_POST['action'] ?? null) === 'clear') {
    Session::getSessionFromRequest()->doLogout('container-sp');
    (new Utils\HTTP())->redirectTrustedURL(SAML_TEST_ORIGIN . '/sp/', ['cleared' => '1']);
}

$refused = null;
if (array_key_exists('idp', $_GET)) {
    $idp = $_GET['idp'];
    if (is_string($idp) && isset($idps[$idp])) {
        (new Auth\Simple('container-sp'))->login([
            'saml:idp' => $idp,
            'ReturnTo' => SAML_TEST_ORIGIN . '/sp/result.php',
        ]);
    }
    http_response_code(400);
    $refused = 'Not a known IdP: ' . (is_string($idp) ? $idp : '(not a string)');
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SAML test SP</title>
<style>
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 40rem; margin: 3rem auto; padding: 0 1rem; }
  form { margin: .5rem 0; }
  button { font: inherit; padding: .4rem .8rem; }
  .error { color: #b00020; }
</style>
</head>
<body>
<h1>SAML test SP</h1>
<p>Entity ID: <code><?= $h(SAML_TEST_ORIGIN . '/sp') ?></code></p>
<?php if ($refused !== null): ?>
<p class="error" role="alert"><?= $h($refused) ?></p>
<?php endif; ?>
<?php if (($_GET['cleared'] ?? null) === '1'): ?>
<p><?= $h('SP session cleared.') ?></p>
<?php endif; ?>
<?php foreach ($idps as $entityId => $label): ?>
<form method="get" action="/sp/">
  <input type="hidden" name="idp" value="<?= $h((string) $entityId) ?>">
  <button type="submit"><?= $h($label) ?></button>
</form>
<?php endforeach; ?>
<form method="post" action="/sp/">
  <input type="hidden" name="action" value="clear">
  <button type="submit">Clear SP session</button>
</form>
</body>
</html>
