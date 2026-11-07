<?php

/**
 * The container IdP. The key and certificate are file names in certdir (keys/, written by
 * `ohrm saml up`). NameID and the one `username` attribute both carry the typed username.
 *
 * No single logout: an empty SingleLogoutServiceBinding leaves SingleLogoutService out of the
 * exported metadata (SAML2::getHostedMetadata), so a linked tree's SP logs out locally instead of
 * sending a LogoutRequest here. NameIDFormat is what the metadata advertises; the format issued
 * comes from each SP's entry in saml20-sp-remote.php.
 */
$metadata['https://saml.test/idp'] = [
    'host' => '__DEFAULT__',
    'privatekey' => 'container.key',
    'certificate' => 'container.crt',
    'auth' => 'testidp-any',
    'SingleLogoutServiceBinding' => [],
    'NameIDFormat' => 'urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified',
    'authproc' => [
        10 => [
            'class' => 'saml:AttributeNameID',
            'identifyingAttribute' => 'username',
            'Format' => 'urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified',
        ],
    ],
];
