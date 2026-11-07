<?php

/**
 * The container SP's result page: ReturnTo of every /sp/ login, and the SP's RelayState for
 * IdP-initiated ones.
 *
 * Issuer, NameID and attributes come from the container SP's session. Flow and Signed come from
 * the latest /var/saml-data/acs.log line (site/lib/capture.php) whose issuer is the session's IdP.
 * A response that fails SimpleSAMLphp's checks never gets here: its error page shows the exception,
 * and acs.log still holds the raw structure.
 */

declare(strict_types=1);

require_once '/var/simplesamlphp/public/_include.php';
require_once __DIR__ . '/../lib/trees.php';

use SimpleSAML\Auth;

$h = static fn (string $s): string => htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
$yesNo = static fn (mixed $b): string => $b === true ? 'yes' : 'no';

/** The newest acs.log entry whose issuer is $issuer, or null. */
$latestAcsEntry = static function (string $issuer): ?array {
    $lines = is_readable('/var/saml-data/acs.log')
        ? file('/var/saml-data/acs.log', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES)
        : false;
    foreach (array_reverse($lines ?: []) as $line) {
        $entry = json_decode($line, true);
        if (is_array($entry) && ($entry['issuer'] ?? null) === $issuer) {
            return $entry;
        }
    }
    return null;
};

$as = new Auth\Simple('container-sp');
$lines = null;
$attributeLines = [];
if ($as->isAuthenticated()) {
    $issuer = (string) $as->getAuthData('saml:sp:IdP');
    $nameId = $as->getAuthData('saml:sp:NameID');

    $tree = $issuer === SAML_TEST_ORIGIN . '/idp' ? 'self' : 'unknown';
    foreach (linkedTrees() as $linked) {
        if ($linked['idpEntityId'] === $issuer) {
            $tree = $linked['tree'];
        }
    }

    $entry = $latestAcsEntry($issuer);
    if ($entry === null) {
        $flow = $signed = 'unknown (no acs.log line from this issuer)';
    } else {
        $flow = is_string($entry['inResponseTo'] ?? null) && $entry['inResponseTo'] !== '' ? 'SP-initiated' : 'IdP-initiated';
        $responseSigned = ($entry['responseSigned'] ?? null) === true;
        $assertionSigned = ($entry['assertionSigned'] ?? null) === true;
        $signed = $yesNo($responseSigned || $assertionSigned)
            . ' (response: ' . $yesNo($responseSigned) . ', assertion: ' . $yesNo($assertionSigned) . ')';
    }

    $lines = [
        'Flow: ' . $flow,
        'Tree: ' . $tree,
        'Issuer: ' . $issuer,
        'NameID: ' . (is_object($nameId) && method_exists($nameId, 'getValue') ? (string) $nameId->getValue() : '(none)'),
        'Signed: ' . $signed,
    ];
    foreach ($as->getAttributes() as $name => $values) {
        $shown = array_map(
            static fn (mixed $v): string => is_scalar($v) ? (string) $v : '[' . get_debug_type($v) . ']',
            is_array($values) ? $values : [$values],
        );
        $attributeLines[] = $name . ': ' . implode(', ', $shown);
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SAML test SP: result</title>
<style>
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 48rem; margin: 3rem auto; padding: 0 1rem; }
  li { margin: .25rem 0; overflow-wrap: anywhere; }
</style>
</head>
<body>
<?php if ($lines === null): ?>
<h1>SAML test SP</h1>
<p>Not logged in. <a href="/sp/">SP page</a></p>
<?php else: ?>
<h1>Logged in at the SAML test SP</h1>
<ul>
<?php foreach ($lines as $line): ?>
  <li><?= $h($line) ?></li>
<?php endforeach; ?>
</ul>
<h2>Attributes</h2>
<ul>
<?php foreach ($attributeLines as $line): ?>
  <li><?= $h($line) ?></li>
<?php endforeach; ?>
</ul>
<p><a href="/sp/">SP page</a></p>
<?php endif; ?>
</body>
</html>
