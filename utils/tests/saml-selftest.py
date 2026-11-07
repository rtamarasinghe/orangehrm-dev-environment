#!/usr/bin/env python3
"""Live round trips against the SAML test container at https://saml.test.

Usage: python3 -I utils/tests/saml-selftest.py --cafile "$(mkcert -CAROOT)/rootCA.pem" MODE [TREE]

  idp         IdP-initiated sign-ins at the container IdP for the container's own SP
              (https://saml.test/sp). Each case decodes the SAMLResponse in the IdP's auto-submit
              form and never posts it on.
  sp          Full round trips between the container SP and the container IdP, SP- and
              IdP-initiated, posted on to the SP's ACS and checked on its result page. Includes a
              response to an SP-initiated request posted from a browser that never sent the request,
              and a refused response posted after a login.
  tree TREE   IdP-initiated sign-in as admin at the container IdP for the linked TREE's SP, posted
              on to the tree's ACS, then the same sign-in followed by the tree's logout. Needs
              `ohrm saml link TREE`. The tree records the logins (login history, and an
              ohrm_saml_user_identity row for admin on the first one).

Each case uses its own cookie jars, so no IdP or SP session carries over between cases.
Needs `ohrm saml up` and a running dev_saml. Only the tree mode touches a tree. Prints one
`ok <case>` or `FAIL <case>: <reason>` line per case and exits 0 only when every case passed.
Stdlib only: the host has Python 3.9 without lxml.
"""
import argparse
import base64
import html.parser
import http.cookiejar
import json
import os
import re
import ssl
import sys
import time
import traceback
import types
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from urllib.parse import urlparse

ORIGIN = "https://saml.test"
CONTAINER_IDP = ORIGIN + "/idp"
CONTAINER_SP = ORIGIN + "/sp"
CONTAINER_SP_ACS = ORIGIN + "/simplesaml/module.php/saml/sp/saml2-acs.php/container-sp"
IDP_SSO = ORIGIN + "/simplesaml/module.php/saml/idp/singleSignOnService"
LOGIN_PAGE = ORIGIN + "/login.php"
SP_PAGE = ORIGIN + "/sp/"
RESULT_PAGE = ORIGIN + "/sp/result.php"
TREES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "custom-compose", "config", "saml", "trees")
NS = {
    "samlp": "urn:oasis:names:tc:SAML:2.0:protocol",
    "saml": "urn:oasis:names:tc:SAML:2.0:assertion",
    "ds": "http://www.w3.org/2000/09/xmldsig#",
}

CAFILE = None  # set from --cafile


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class FormParser(html.parser.HTMLParser):
    """The first <form> of a page: its action and the values of its named inputs."""

    def __init__(self, page):
        super().__init__()
        self.action, self.fields, self._open = None, {}, False
        self.feed(page)

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form" and self.action is None:
            self.action, self._open = a.get("action") or "", True
        elif tag == "input" and self._open and a.get("name"):
            self.fields[a["name"]] = a.get("value") or ""

    def handle_endtag(self, tag):
        if tag == "form":
            self._open = False


def new_browser():
    """An opener with its own cookie jar that trusts only CAFILE and never follows redirects."""
    ctx = ssl.create_default_context(cafile=CAFILE)
    return urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=ctx), NoRedirect)


def fetch(browser, url, form=None):
    """GET url, or POST form to it. Returns (status, Location, body)."""
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    try:
        resp = browser.open(urllib.request.Request(url, data=data))
    except urllib.error.HTTPError as e:
        resp = e
    return resp.getcode(), resp.headers.get("Location", ""), resp.read().decode("utf-8", "replace")


def follow(browser, url, form=None, hops=10):
    """Request url, then follow redirects with GET. Returns (final url, status, body)."""
    status, location, body = fetch(browser, url, form)
    while status in (301, 302, 303, 307, 308) and location and hops:
        url = urllib.parse.urljoin(url, location)
        status, location, body = fetch(browser, url)
        hops -= 1
    return url, status, body


def excerpt(body):
    """The cause line of a SimpleSAMLphp error page, else the page's leading text."""
    cause = re.search(r"Caused by: [^\n<]+", body)
    if cause:
        return cause.group(0)
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", body)).strip()[:300]


def open_login_page(browser, start=None):
    """GET start, by default IdP-initiated SSO for the container SP, and follow it to the container
    IdP's login page. Returns (login page URL, login page HTML)."""
    start = start or IDP_SSO + "?spentityid=" + urllib.parse.quote(CONTAINER_SP, safe="")
    url, status, body = follow(browser, start)
    if status != 200 or not url.startswith(LOGIN_PAGE + "?AuthState="):
        at = "" if url == start else f" at {url}"
        raise AssertionError(
            f"GET {start} ended with {status}{at}, expected 200 at {LOGIN_PAGE}?AuthState=…: {excerpt(body)}")
    return url, body


def submit_username(browser, page_url, page, username):
    """Post username through the login page's form. Returns (status, body) after redirects."""
    form = FormParser(page)
    if "username" not in form.fields or "AuthState" not in form.fields:
        raise AssertionError(f"the form at {page_url} lacks a username or AuthState field: {sorted(form.fields)}")
    fields = dict(form.fields, username=username)
    _, status, body = follow(browser, urllib.parse.urljoin(page_url, form.action), fields)
    return status, body


def decode_response(saml_response):
    root = ET.fromstring(base64.b64decode(saml_response))
    assertion = root.find("saml:Assertion", NS)
    if assertion is None:
        raise AssertionError("the SAMLResponse has no unencrypted Assertion")
    name_id = assertion.find("saml:Subject/saml:NameID", NS)
    if name_id is None:
        raise AssertionError("the Assertion has no NameID")
    return types.SimpleNamespace(
        response_id=root.get("ID"),
        in_response_to=root.get("InResponseTo"),
        issuer=root.findtext("saml:Issuer", namespaces=NS),
        name_id=name_id.text or "",
        name_id_format=name_id.get("Format"),
        attributes={
            a.get("Name"): [v.text or "" for v in a.findall("saml:AttributeValue", NS)]
            for a in assertion.findall("saml:AttributeStatement/saml:Attribute", NS)
        },
        response_signed=root.find("ds:Signature", NS) is not None,
        assertion_signed=assertion.find("ds:Signature", NS) is not None,
    )


def idp_login(username):
    """Sign in as username. The result also carries the auto-submit form's action and every page
    login.php served on the way (login_page_html)."""
    browser = new_browser()
    page_url, page = open_login_page(browser)
    status, body = submit_username(browser, page_url, page, username)
    form = FormParser(body)
    if "SAMLResponse" not in form.fields:
        raise AssertionError(f"POST {LOGIN_PAGE} answered {status} without a SAMLResponse form: {excerpt(body)}")
    r = decode_response(form.fields["SAMLResponse"])
    r.form_action = form.action
    r.login_page_html = page + body
    return r


def idp_login_raw(username):
    """Post username at the login page and return the page that comes back."""
    browser = new_browser()
    page_url, page = open_login_page(browser)
    return submit_username(browser, page_url, page, username)[1]


def case_admin_asserted():
    r = idp_login("admin")
    assert r.form_action == CONTAINER_SP_ACS
    assert r.issuer == "https://saml.test/idp"
    assert r.name_id == "admin"
    assert r.name_id_format == "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified"
    assert r.attributes == {"username": ["admin"]}
    assert r.response_signed or r.assertion_signed


def case_odd_username_asserted_verbatim():
    odd = "  <b>o'neil</b> x  "
    r = idp_login(odd)
    assert r.name_id == "<b>o'neil</b> x"
    assert "<b>o'neil</b>" not in r.login_page_html   # login page never echoes input as HTML


def case_empty_username_refused():
    page = idp_login_raw("   ")
    assert "Enter a username" in page and "SAMLResponse" not in page


def post_to_sp(browser, status, body):
    """Post the IdP's auto-submit SAMLResponse form on to its action, the container SP's ACS, and
    follow the redirects. Returns the result page."""
    form = FormParser(body)
    if "SAMLResponse" not in form.fields:
        raise AssertionError(f"the IdP answered {status} without a SAMLResponse form: {excerpt(body)}")
    url, status, page = follow(browser, form.action, form.fields)
    if status != 200 or url != RESULT_PAGE:
        raise AssertionError(
            f"POST {form.action} ended with {status} at {url}, expected 200 at {RESULT_PAGE}: {excerpt(page)}")
    return page


def start_sp_login(username):
    """SP-initiated: start at the SP page's ?idp= login for the container IdP and sign in as
    username. Returns (browser, status, body), body being the IdP's auto-submit form, not yet
    posted."""
    browser = new_browser()
    page_url, page = open_login_page(browser, SP_PAGE + "?idp=" + urllib.parse.quote(CONTAINER_IDP, safe=""))
    return (browser, *submit_username(browser, page_url, page, username))


def sp_login(username):
    """SP-initiated round trip at the container IdP, posted on to the container SP. Returns the
    result page."""
    return post_to_sp(*start_sp_login(username))


def idp_initiated_to_sp(username):
    """IdP-initiated: start at the container IdP's SSO for the container SP, sign in as username,
    and post the unsolicited response to the SP. Returns the result page."""
    browser = new_browser()
    page_url, page = open_login_page(browser)
    return post_to_sp(browser, *submit_username(browser, page_url, page, username))


def case_sp_initiated_self():
    page = sp_login(username="alice")   # starts at /sp/?idp=https://saml.test/idp
    assert "Flow: SP-initiated" in page
    assert "Issuer: https://saml.test/idp" in page
    assert "NameID: alice" in page and "username: alice" in page
    assert "Signed: yes" in page
    assert "Assertions: 1 (encrypted: no)" in page


def case_idp_initiated_self():
    page = idp_initiated_to_sp(username="bob")   # singleSignOnService?spentityid=https://saml.test/sp, then on to the ACS
    assert "Flow: IdP-initiated" in page and "NameID: bob" in page
    assert "Assertions: 1 (encrypted: no)" in page


def case_sp_initiated_response_without_its_request():
    _, status, body = start_sp_login("carol")
    page = post_to_sp(new_browser(), status, body)   # a browser that holds no pending request
    sent = decode_response(FormParser(body).fields["SAMLResponse"])
    assert sent.in_response_to, "the SP-initiated response carries no InResponseTo"
    want = f"Flow: InResponseTo {sent.in_response_to} matched no pending request (accepted as unsolicited)"
    assert want in page, f"the result page lacks '{want}': {excerpt(page)}"
    assert "NameID: carol" in page


def refused_response():
    """A base64 samlp:Response from the container IdP with no Assertion, which the container SP
    refuses. Returns (response ID, base64 XML)."""
    response_id = "_selftest" + os.urandom(16).hex()
    xml = (
        '<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol"'
        ' xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion"'
        f' ID="{response_id}" Version="2.0" IssueInstant="{time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}"'
        f' Destination="{CONTAINER_SP_ACS}">'
        f"<saml:Issuer>{CONTAINER_IDP}</saml:Issuer>"
        '<samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>'
        "</samlp:Response>"
    )
    return response_id, base64.b64encode(xml.encode()).decode()


def case_result_page_keeps_the_login_after_a_refused_response():
    browser, status, body = start_sp_login("dave")
    post_to_sp(browser, status, body)
    _, refused = refused_response()
    url, status, page = follow(browser, CONTAINER_SP_ACS, {"SAMLResponse": refused})
    assert url != RESULT_PAGE, "the SP accepted a response with no Assertion"
    _, status, page = follow(browser, RESULT_PAGE)
    assert status == 200 and "NameID: dave" in page, f"GET {RESULT_PAGE} answered {status}: {excerpt(page)}"
    assert "Signed: yes" in page, f"Signed is not the login's: {excerpt(page)}"
    assert "Assertions: 1 (encrypted: no)" in page, f"Assertions is not the login's: {excerpt(page)}"


def case_odd_username_escaped_on_result_page():
    odd = "<b>o'neil</b>"
    page = sp_login(username=odd)
    escaped = "&lt;b&gt;o&#039;neil&lt;/b&gt;"
    assert f"NameID: {escaped}" in page and f"username: {escaped}" in page, excerpt(page)
    assert odd not in page


def case_unknown_idp_refused():
    start = SP_PAGE + "?idp=" + urllib.parse.quote("https://evil.example/idp", safe="")
    status, location, _ = fetch(new_browser(), start)
    assert status == 400 and location == "", f"GET {start} answered {status} {location}, expected 400"


def tree_registration(tree):
    """The tree's trees/<tree>.json, as `ohrm saml link <tree>` wrote it."""
    if not re.fullmatch(r"[a-z0-9]+", tree):
        raise AssertionError(f"tree {tree!r} must match ^[a-z0-9]+$")
    path = os.path.normpath(os.path.join(TREES_DIR, tree + ".json"))
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        raise AssertionError(f"no {path}; run `ohrm saml link {tree}` first") from None


def tree_idp_initiated(browser, tree, username):
    """IdP-initiated: start at the container IdP's SSO for the tree's SP with the RelayState the tree
    expects, sign in as username, post the unsolicited response to the tree's ACS and follow the
    redirects, all in browser. Returns (final URL, final status, final page)."""
    reg = tree_registration(tree)
    start = (IDP_SSO + "?spentityid=" + urllib.parse.quote(reg["spEntityId"], safe="")
             + "&RelayState=" + urllib.parse.quote(reg["spRelayState"], safe=""))
    page_url, page = open_login_page(browser, start)
    status, body = submit_username(browser, page_url, page, username)
    form = FormParser(body)
    if "SAMLResponse" not in form.fields:
        raise AssertionError(f"POST {LOGIN_PAGE} answered {status} without a SAMLResponse form: {excerpt(body)}")
    if form.action != reg["spAcsUrl"]:
        raise AssertionError(f"the IdP posts to {form.action}, expected the tree's ACS {reg['spAcsUrl']}")
    return follow(browser, form.action, form.fields)


# A tree serves this page for a secure URL to a visitor who is not logged in; a browser runs it and
# lands on the login form, which /auth/seamlessLogin serves.
TREE_ANONYMOUS_SHELL = 'window.location = "/auth/seamlessLogin"'
TREE_LOGIN_FORM = 'name="txtPassword"'


def tree_signed_in(browser, tree):
    """Sign in to tree as admin through tree_idp_initiated and check that it landed logged in.
    Returns the URL it landed on."""
    final_url, status, html = tree_idp_initiated(browser, tree, username="admin")
    assert status == 200, f"the sign-in ended with {status} at {final_url}: {excerpt(html)}"
    assert urlparse(final_url).hostname == f"{tree}.test-webubuntu83.orangehrmdev.com"
    assert "auth/login" not in final_url
    assert TREE_ANONYMOUS_SHELL not in html and TREE_LOGIN_FORM not in html, \
        f"the sign-in ended at {final_url} on a page for a visitor who is not logged in"
    assert "SimpleSAMLphp" not in html or "error" not in html.lower()
    return final_url


def case_tree_idp_initiated(tree):
    tree_signed_in(new_browser(), tree)


def case_tree_logout_ends_on_tree_login(tree):
    browser = new_browser()
    landed = tree_signed_in(browser, tree)
    host = f"{tree}.test-webubuntu83.orangehrmdev.com"
    url, status, html = follow(browser, f"https://{host}/auth/logout")
    assert urlparse(url).hostname == host and "auth/login" in url and status == 200 and TREE_LOGIN_FORM in html, \
        f"the logout ended with {status} at {url}, expected 200 at {host}'s login page: {excerpt(html)}"
    url, status, html = follow(browser, landed)
    if TREE_ANONYMOUS_SHELL in html:
        url, status, html = follow(browser, f"https://{host}/auth/seamlessLogin")
    assert status == 200 and TREE_LOGIN_FORM in html, \
        f"reopening {landed} after the logout ended with {status} at {url}, not on the login form: {excerpt(html)}"


CASES = {
    "idp": [case_admin_asserted, case_odd_username_asserted_verbatim, case_empty_username_refused],
    "sp": [case_sp_initiated_self, case_idp_initiated_self, case_unknown_idp_refused,
           case_sp_initiated_response_without_its_request,
           case_result_page_keeps_the_login_after_a_refused_response,
           case_odd_username_escaped_on_result_page],
    "tree": [case_tree_idp_initiated, case_tree_logout_ends_on_tree_login],
}


def describe(e):
    if str(e):
        return str(e)
    frame = traceback.extract_tb(e.__traceback__)[-1]
    return f"{type(e).__name__} at line {frame.lineno}: {frame.line}"


def main():
    global CAFILE
    parser = argparse.ArgumentParser(description="Live round trips against https://saml.test.")
    parser.add_argument("--cafile", required=True, help="the CA that signed saml.test's certificate")
    parser.add_argument("mode", choices=sorted(CASES))
    parser.add_argument("tree", nargs="?", help="the linked tree, for the tree mode only")
    args = parser.parse_args()
    if (args.mode == "tree") != (args.tree is not None):
        parser.error("a tree is given with, and only with, the tree mode")
    CAFILE = args.cafile
    case_args = (args.tree,) if args.mode == "tree" else ()

    failed = 0
    for case in CASES[args.mode]:
        name = case.__name__[len("case_"):].replace("_", " ")
        try:
            case(*case_args)
            print(f"ok   {name}")
        except Exception as e:
            failed += 1
            print(f"FAIL {name}: {describe(e)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
