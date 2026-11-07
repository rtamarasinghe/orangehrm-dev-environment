<?php

/**
 * The container IdP's sign-in page: asserts whatever username is typed, trimmed.
 *
 * Reached only through AnyUser::authenticate(), which supplies ?AuthState=<id>. On POST,
 * Auth\State::loadState() resumes it: a lost state whose AuthState carries a restart URL (IdP SSO
 * requests set one) restarts that SSO request; any other missing or stale AuthState ends on
 * SimpleSAMLphp's own error page.
 */

declare(strict_types=1);

require_once '/var/simplesamlphp/public/_include.php';

use SimpleSAML\Auth;
use SimpleSAML\Module\testidp\Auth\Source\AnyUser;

$h = static fn (string $s): string => htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');

$authState = is_string($_REQUEST['AuthState'] ?? null) ? $_REQUEST['AuthState'] : '';
$error = null;

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $username = is_string($_POST['username'] ?? null) ? trim($_POST['username']) : '';
    if ($username === '') {
        $error = 'Enter a username';
    } else {
        $state = Auth\State::loadState($authState, AnyUser::STAGE);
        $state['Attributes'] = ['username' => [$username]];
        Auth\Source::completeAuth($state);
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in: SAML test IdP</title>
<style>
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 28rem; margin: 3rem auto; padding: 0 1rem; }
  input[type=text] { width: 100%; box-sizing: border-box; padding: .5rem; font: inherit; }
  button { font: inherit; padding: .4rem .8rem; margin: .5rem .5rem 0 0; }
  .error { color: #b00020; }
</style>
</head>
<body>
<h1>SAML test IdP</h1>
<p>Any username is accepted and asserted as typed. There is no password.</p>
<form id="login" method="post" action="/login.php">
  <input type="hidden" name="AuthState" value="<?= $h($authState) ?>">
  <label for="username">Username</label>
  <input type="text" id="username" name="username" autocomplete="off" autofocus>
<?php if ($error !== null): ?>
  <p class="error" role="alert"><?= $h($error) ?></p>
<?php endif; ?>
  <button type="submit">Sign in</button>
</form>
<section id="recent" hidden>
  <h2>Recent</h2>
  <div id="recent-list"></div>
</section>
<script>
(function () {
  // Kept in this browser only; the server never echoes a username back.
  var KEY = 'samlTestRecentUsernames';
  var MAX = 5;
  var form = document.getElementById('login');
  var input = document.getElementById('username');

  function load() {
    try {
      var list = JSON.parse(localStorage.getItem(KEY) || '[]');
      return Array.isArray(list) ? list.filter(function (u) { return typeof u === 'string' && u !== ''; }) : [];
    } catch (e) {
      return [];
    }
  }

  form.addEventListener('submit', function () {
    var u = input.value.trim();
    if (u === '') {
      return;
    }
    var list = [u].concat(load().filter(function (x) { return x !== u; })).slice(0, MAX);
    try {
      localStorage.setItem(KEY, JSON.stringify(list));
    } catch (e) {}
  });

  var recent = load().slice(0, MAX);
  var holder = document.getElementById('recent-list');
  recent.forEach(function (u) {
    var b = document.createElement('button');
    b.type = 'button';
    b.textContent = u;
    b.addEventListener('click', function () {
      input.value = u;
      form.requestSubmit();
    });
    holder.appendChild(b);
  });
  document.getElementById('recent').hidden = recent.length === 0;
})();
</script>
</body>
</html>
