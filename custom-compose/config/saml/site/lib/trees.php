<?php

declare(strict_types=1);

const SAML_TEST_ORIGIN = 'https://saml.test';

/**
 * The linked trees' registrations: /var/saml-trees/<tree>.json, written by `ohrm saml link <tree>`.
 *
 * A file that can't be read, isn't a JSON object, or lacks one of the string fields below is
 * skipped, so one bad file never breaks the metadata or the pages.
 *
 * @return list<array{tree: string, host: string, idpEntityId: string, idpSsoUrl: string, idpCert: string,
 *     spEntityId: string, spAcsUrl: string, spRelayState: string}> sorted by tree
 */
function linkedTrees(): array
{
    $fields = ['tree', 'host', 'idpEntityId', 'idpSsoUrl', 'idpCert', 'spEntityId', 'spAcsUrl', 'spRelayState'];
    $trees = [];
    foreach (glob('/var/saml-trees/*.json') ?: [] as $file) {
        $json = is_file($file) && is_readable($file) ? file_get_contents($file) : false;
        $tree = is_string($json) ? json_decode($json, true) : null;
        if (!is_array($tree)) {
            continue;
        }
        foreach ($fields as $field) {
            if (!is_string($tree[$field] ?? null)) {
                continue 2;
            }
        }
        $trees[] = $tree;
    }
    usort($trees, static fn (array $a, array $b): int => strcmp($a['tree'], $b['tree']));
    return $trees;
}
