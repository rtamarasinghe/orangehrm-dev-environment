<?php

/**
 * The secretsalt file lives in the gitignored keys/ folder (mounted at certdir) and is created
 * at run time; until it exists the salt is a placeholder.
 */

require '/var/simplesamlphp/config/config.php.dist';

$secretSaltFile = '/etc/simplesamlphp/cert/secretsalt';

$config['baseurlpath'] = 'https://saml.test/simplesaml/';
$config['certdir'] = '/etc/simplesamlphp/cert/';
$config['metadata.sources'] = [['type' => 'flatfile', 'directory' => '/etc/simplesamlphp/metadata']];
$config['secretsalt'] = is_file($secretSaltFile) ? trim(file_get_contents($secretSaltFile)) : 'not-yet-set';
$config['enable.saml20-idp'] = true;
$config['module.enable'] = ['testidp' => true, 'exampleauth' => false];
$config['session.cookie.secure'] = true;
$config['session.cookie.samesite'] = 'None';
$config['trusted.url.domains'] = ['saml.test'];
$config['showerrors'] = true;
$config['logging.handler'] = 'stderr';
$config['logging.level'] = \SimpleSAML\Logger::INFO;
$config['timezone'] = 'UTC';
