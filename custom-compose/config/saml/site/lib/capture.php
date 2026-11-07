<?php

/**
 * Prepended (Apache auto_prepend_file, apache-site.conf) to the container SP's ACS. For a POST
 * that carries SAMLResponse, appends one JSON line describing the raw response to
 * /var/saml-data/acs.log before SimpleSAMLphp checks it, so a refused response is on record too.
 *
 * Keys, always all present (null when not found):
 *   time
 *   issuer, inResponseTo, destination  as in the samlp:Response
 *   responseId       the samlp:Response's ID, which site/sp/result.php matches on
 *   responseSigned   a ds:Signature is a direct child of samlp:Response
 *   assertionSigned  every saml:Assertion has a ds:Signature as a direct child (false with none)
 *   assertionCount   saml:Assertion children of samlp:Response
 *   encrypted        samlp:Response has a saml:EncryptedAssertion child
 *   nameId           the first Assertion's Subject/NameID
 *   error            why the response could not be read, else null
 * Signatures are only located here, never verified; SimpleSAMLphp verifies them.
 *
 * Must never stop, alter or print anything for the request it runs in: everything is inside a
 * closure and try/catch, libxml errors stay internal (display_errors is on in this image), and a
 * log that can't be written goes to Apache's error log instead.
 */

declare(strict_types=1);

(static function (): void {
    if (!isset($_POST['SAMLResponse'])) {
        return;
    }
    $samlp = 'urn:oasis:names:tc:SAML:2.0:protocol';
    $saml = 'urn:oasis:names:tc:SAML:2.0:assertion';
    $ds = 'http://www.w3.org/2000/09/xmldsig#';

    $entry = [
        'time' => gmdate('c'),
        'issuer' => null,
        'responseId' => null,
        'inResponseTo' => null,
        'destination' => null,
        'responseSigned' => null,
        'assertionSigned' => null,
        'assertionCount' => null,
        'encrypted' => null,
        'nameId' => null,
        'error' => null,
    ];

    $hasSignatureChild = static function (\DOMElement $element) use ($ds): bool {
        foreach ($element->childNodes as $child) {
            if ($child instanceof \DOMElement && $child->namespaceURI === $ds && $child->localName === 'Signature') {
                return true;
            }
        }
        return false;
    };

    $libxmlInternal = libxml_use_internal_errors(true);
    try {
        if (!is_string($_POST['SAMLResponse'])) {
            throw new \RuntimeException('SAMLResponse is not a string');
        }
        $raw = base64_decode($_POST['SAMLResponse'], true);
        if ($raw === false || $raw === '') {
            throw new \RuntimeException('SAMLResponse is not base64');
        }
        // Same refusal as SimpleSAMLphp's DOMDocumentFactory: no DOCTYPE means no entities to load.
        if (preg_match('/<(\s*)!(\s*)DOCTYPE/', $raw)) {
            throw new \RuntimeException('SAMLResponse has a DOCTYPE');
        }
        $doc = new \DOMDocument();
        if (!$doc->loadXML($raw, LIBXML_NONET)) {
            throw new \RuntimeException('SAMLResponse is not XML');
        }
        $xp = new \DOMXPath($doc);
        $xp->registerNamespace('samlp', $samlp);
        $xp->registerNamespace('saml', $saml);
        $response = $xp->query('/samlp:Response')->item(0);
        if (!$response instanceof \DOMElement) {
            throw new \RuntimeException('root is not samlp:Response');
        }

        $issuer = $xp->query('saml:Issuer', $response)->item(0);
        $entry['issuer'] = $issuer ? trim($issuer->textContent) : null;
        $entry['responseId'] = $response->hasAttribute('ID') ? $response->getAttribute('ID') : null;
        $entry['inResponseTo'] = $response->hasAttribute('InResponseTo') ? $response->getAttribute('InResponseTo') : null;
        $entry['destination'] = $response->hasAttribute('Destination') ? $response->getAttribute('Destination') : null;
        $entry['responseSigned'] = $hasSignatureChild($response);

        $assertions = iterator_to_array($xp->query('saml:Assertion', $response));
        $entry['assertionCount'] = count($assertions);
        $entry['assertionSigned'] = $assertions !== [] && count(array_filter($assertions, $hasSignatureChild)) === count($assertions);
        $entry['encrypted'] = $xp->query('saml:EncryptedAssertion', $response)->length > 0;
        $nameId = $assertions !== [] ? $xp->query('saml:Subject/saml:NameID', $assertions[0])->item(0) : null;
        $entry['nameId'] = $nameId ? trim($nameId->textContent) : null;
    } catch (\Throwable $e) {
        $entry['error'] = $e->getMessage();
    } finally {
        libxml_clear_errors();
        libxml_use_internal_errors($libxmlInternal);
    }

    try {
        $line = json_encode($entry, JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE | JSON_THROW_ON_ERROR) . "\n";
        if (@file_put_contents('/var/saml-data/acs.log', $line, FILE_APPEND | LOCK_EX) === false) {
            error_log('capture.php: cannot append to /var/saml-data/acs.log');
        }
    } catch (\Throwable $e) {
        error_log('capture.php: ' . $e->getMessage());
    }
})();
