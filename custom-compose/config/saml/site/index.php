<?php

/**
 * Apps page: per linked tree, an IdP-initiated sign-in at the container IdP, and the tree's own
 * IdP-initiated URL for the container SP.
 */

declare(strict_types=1);

require_once __DIR__ . '/lib/trees.php';

$h = static fn (string $s): string => htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
$trees = linkedTrees();
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SAML test container</title>
<style>
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 40rem; margin: 3rem auto; padding: 0 1rem; }
  li { margin: .5rem 0; }
</style>
</head>
<body>
<h1>SAML test container</h1>
<?php if ($trees === []): ?>
<p><?= $h('No trees linked. Run: ohrm saml link <tree>') ?></p>
<?php else: ?>
<ul>
<?php foreach ($trees as $tree):
    $signIn = SAML_TEST_ORIGIN . '/simplesaml/module.php/saml/idp/singleSignOnService'
        . '?spentityid=' . rawurlencode($tree['spEntityId'])
        . '&RelayState=' . rawurlencode($tree['spRelayState']);
    $startAtTree = 'https://' . $tree['host'] . '/saml/saml2/idp/SSOService.php'
        . '?spentityid=' . rawurlencode(SAML_TEST_ORIGIN . '/sp');
    ?>
  <li><strong><?= $h($tree['tree']) ?></strong>:
    <a href="<?= $h($signIn) ?>">Sign in to <?= $h($tree['tree']) ?></a> ·
    <a href="<?= $h($startAtTree) ?>">Start at <?= $h($tree['tree']) ?>'s IdP</a></li>
<?php endforeach; ?>
</ul>
<?php endif; ?>
</body>
</html>
