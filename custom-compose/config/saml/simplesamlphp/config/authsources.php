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
        'authproc' => [
            // The ACS sets saml:sp:isUnsolicited in the SP state when it processes a response as
            // unsolicited: no InResponseTo, or one whose request state it could not load. Listing it
            // in PersistentAuthData keeps it in the session (only when set), where site/sp/result.php
            // reads it. $state here is the processing-chain state; the SP state is under saml:sp:State.
            10 => [
                'class' => 'core:PHP',
                'code' => '$state["saml:sp:State"]["PersistentAuthData"][] = "saml:sp:isUnsolicited";',
            ],
        ],
    ],
];
