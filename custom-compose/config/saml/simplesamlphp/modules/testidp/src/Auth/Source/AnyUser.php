<?php

declare(strict_types=1);

namespace SimpleSAML\Module\testidp\Auth\Source;

use SimpleSAML\Auth;
use SimpleSAML\Configuration;
use SimpleSAML\Utils;

/**
 * Signs in whatever username is typed, with no password.
 *
 * authenticate() hands the login to the page at `loginUrl` as `?AuthState=<id>`. That page resumes
 * with Auth\State::loadState($id, self::STAGE), sets $state['Attributes'] and calls
 * Auth\Source::completeAuth($state).
 */
class AnyUser extends Auth\Source
{
    public const STAGE = 'testidp:AnyUser';

    private string $loginUrl;

    public function __construct(array $info, array &$config)
    {
        parent::__construct($info, $config);

        $this->loginUrl = Configuration::loadFromArray($config, 'authsources[' . var_export($this->authId, true) . ']')
            ->getString('loginUrl');
    }

    public function authenticate(array &$state): void
    {
        $id = Auth\State::saveState($state, self::STAGE);
        (new Utils\HTTP())->redirectTrustedURL($this->loginUrl, ['AuthState' => $id]);
    }
}
