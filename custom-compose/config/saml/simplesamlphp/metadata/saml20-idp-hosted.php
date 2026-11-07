<?php

/**
 * The container IdP. The key and certificate are file names in certdir (keys/, written by
 * `ohrm saml up`). NameID and the one `username` attribute both carry the typed username.
 */
$metadata['https://saml.test/idp'] = [
    'host' => '__DEFAULT__',
    'privatekey' => 'container.key',
    'certificate' => 'container.crt',
    'auth' => 'testidp-any',
    'authproc' => [
        10 => [
            'class' => 'saml:AttributeNameID',
            'identifyingAttribute' => 'username',
            'Format' => 'urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified',
        ],
    ],
];
