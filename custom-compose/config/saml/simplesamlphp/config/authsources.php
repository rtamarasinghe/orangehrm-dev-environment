<?php

$config = [
    // The container IdP's sign-in: any username, no password (site/login.php).
    'testidp-any' => ['testidp:AnyUser', 'loginUrl' => 'https://saml.test/login.php'],

    // The container SP. 'idp' => null: the IdP comes from each login's 'saml:idp' (site/sp/index.php),
    // limited to saml20-idp-remote.php. A configured RelayState wins over the response's for
    // unsolicited responses, so IdP-initiated logins land on the result page.
    'container-sp' => [
        'saml:SP',
        'entityID' => 'https://saml.test/sp',
        'idp' => null,
        'privatekey' => 'container.key',
        'certificate' => 'container.crt',
        'RelayState' => 'https://saml.test/sp/result.php',
    ],
];
