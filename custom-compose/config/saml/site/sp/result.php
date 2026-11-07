<?php

/**
 * The container SP's result page: ReturnTo of every /sp/ login, and the SP's RelayState for
 * IdP-initiated ones. It describes the response that created the current container-sp session.
 *
 * Issuer, Response ID, NameID and attributes come from the session. Flow comes from what the ACS
 * did with that response: saml:sp:prevAuth (its ID and InResponseTo) and saml:sp:isUnsolicited,
 * which the core:PHP authproc in authsources.php keeps in the session. Signed and Assertions come
 * from the /var/saml-data/acs.log line (site/lib/capture.php) with that response's ID and issuer.
 * A response that fails SimpleSAMLphp's checks never gets here: its error page shows the exception,
 * and acs.log still holds the raw structure.
 */

declare(strict_types=1);

require_once '/var/simplesamlphp/public/_include.php';
require_once __DIR__ . '/../lib/trees.php';

use SimpleSAML\Auth;

const ACS_LOG = '/var/saml-data/acs.log';

$h = static fn (string $s): string => htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
$yesNo = static fn (mixed $b): string => $b === true ? 'yes' : 'no';

/**
 * The acs.log entries for the response with this ID from this issuer, oldest first, or why acs.log
 * could not be read.
 *
 * @return list<array<string, mixed>>|string
 */
$acsEntries = static function (string $responseId, string $issuer): array|string {
    if (!file_exists(ACS_LOG)) {
        return 'there is no acs.log: the container could not write custom-compose/config/saml/data; see docker logs dev_saml';
    }
    $lines = is_readable(ACS_LOG) ? file(ACS_LOG, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) : false;
    if ($lines === false) {
        return 'acs.log is not readable';
    }
    $entries = [];
    foreach ($lines as $line) {
        $entry = json_decode($line, true);
        if (is_array($entry) && ($entry['responseId'] ?? null) === $responseId && ($entry['issuer'] ?? null) === $issuer) {
            $entries[] = $entry;
        }
    }
    return $entries;
};

$as = new Auth\Simple('container-sp');
$lines = null;
$attributeLines = [];
if ($as->isAuthenticated()) {
    $issuer = (string) $as->getAuthData('saml:sp:IdP');
    $nameId = $as->getAuthData('saml:sp:NameID');
    // Set by the ACS for the response that created this session (ServiceProvider::assertionConsumerService).
    $prevAuth = $as->getAuthData('saml:sp:prevAuth');
    $responseId = is_array($prevAuth) && is_string($prevAuth['id'] ?? null) ? $prevAuth['id'] : null;
    $inResponseTo = is_array($prevAuth) && is_string($prevAuth['inResponseTo'] ?? null) && $prevAuth['inResponseTo'] !== ''
        ? $prevAuth['inResponseTo'] : null;
    $unsolicited = $as->getAuthData('saml:sp:isUnsolicited') === true;

    $tree = $issuer === SAML_TEST_ORIGIN . '/idp' ? 'self' : 'unknown';
    foreach (linkedTrees() as $linked) {
        if ($linked['idpEntityId'] === $issuer) {
            $tree = $linked['tree'];
        }
    }

    if ($responseId === null) {
        $flow = 'unknown (the session holds no saml:sp:prevAuth)';
    } elseif ($inResponseTo === null) {
        $flow = 'IdP-initiated';
    } elseif ($unsolicited) {
        // SimpleSAMLphp 2.4.1 logs a warning and goes on when it can't load the request state.
        $flow = 'InResponseTo ' . $inResponseTo . ' matched no pending request (accepted as unsolicited)';
    } else {
        $flow = 'SP-initiated (InResponseTo matched a pending request)';
    }

    $entries = $responseId === null ? 'the session holds no response ID' : $acsEntries($responseId, $issuer);
    if ($entries === []) {
        $entries = 'no acs.log line for response ' . $responseId;
    }
    $acsNote = null;
    if (is_string($entries)) {
        $signed = $assertions = 'unknown (' . $entries . ')';
    } else {
        $entry = $entries[count($entries) - 1];
        if (count($entries) > 1) {
            $acsNote = 'acs.log: ' . count($entries) . ' lines carry this response ID; Signed and Assertions come from the newest';
        }
        $responseSigned = ($entry['responseSigned'] ?? null) === true;
        $assertionSigned = ($entry['assertionSigned'] ?? null) === true;
        $signed = $yesNo($responseSigned || $assertionSigned)
            . ' (response: ' . $yesNo($responseSigned) . ', assertion: ' . $yesNo($assertionSigned) . ')';
        // SimpleSAMLphp accepts several Assertions and decrypts an EncryptedAssertion, so it never
        // enforces "exactly one unencrypted Assertion"; this line reports it.
        $assertions = (is_int($entry['assertionCount'] ?? null) ? (string) $entry['assertionCount'] : 'unknown')
            . ' (encrypted: ' . $yesNo($entry['encrypted'] ?? null) . ')';
    }

    $lines = [
        'Flow: ' . $flow,
        'Tree: ' . $tree,
        'Issuer: ' . $issuer,
        'Response ID: ' . ($responseId ?? '(none)'),
        'NameID: ' . (is_object($nameId) && method_exists($nameId, 'getValue') ? (string) $nameId->getValue() : '(none)'),
        'Signed: ' . $signed,
        'Assertions: ' . $assertions,
    ];
    if ($acsNote !== null) {
        $lines[] = $acsNote;
    }
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
