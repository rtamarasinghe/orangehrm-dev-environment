<?php

/**
 * IdPs the container SP accepts: every linked tree's IdP, plus the container's own IdP, which is
 * always present so the container can be tested with no tree linked. The container IdP's entry is
 * left out only while keys/container.crt can't be read (before `ohrm saml up` has made it).
 */

require_once '/var/www/site/lib/trees.php';

$idpAt = static fn (string $ssoUrl, string $certData): array => [
    'SingleSignOnService' => [[
        'Binding' => 'urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect',
        'Location' => $ssoUrl,
    ]],
    'certData' => $certData,
];

foreach (linkedTrees() as $tree) {
    $metadata[$tree['idpEntityId']] = $idpAt($tree['idpSsoUrl'], $tree['idpCert']);
}

$containerPem = @file_get_contents('/etc/simplesamlphp/cert/container.crt');
if (is_string($containerPem)
    && preg_match('/-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----/s', $containerPem, $m)) {
    $metadata[SAML_TEST_ORIGIN . '/idp'] = $idpAt(
        SAML_TEST_ORIGIN . '/simplesaml/module.php/saml/idp/singleSignOnService',
        preg_replace('/\s+/', '', $m[1]),
    );
}
