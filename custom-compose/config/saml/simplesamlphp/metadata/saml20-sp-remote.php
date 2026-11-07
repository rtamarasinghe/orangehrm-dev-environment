<?php

/**
 * SPs the container IdP answers: every linked tree's SP, plus the container's own SP, which is
 * always present so the container can be tested with no tree linked.
 */

require_once '/var/www/site/lib/trees.php';

$spAt = static fn (string $acsUrl): array => [
    'AssertionConsumerService' => [[
        'Binding' => 'urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST',
        'Location' => $acsUrl,
    ]],
    'NameIDFormat' => 'urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified',
    'saml20.sign.assertion' => true,
];

foreach (linkedTrees() as $tree) {
    $metadata[$tree['spEntityId']] = $spAt($tree['spAcsUrl']);
}

$metadata[SAML_TEST_ORIGIN . '/sp'] = $spAt(SAML_TEST_ORIGIN . '/simplesaml/module.php/saml/sp/saml2-acs.php/container-sp');
