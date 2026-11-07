#!/usr/bin/env python3
"""Live round trips against the SAML test container at https://saml.test.

Usage: python3 -I utils/tests/saml-selftest.py --cafile "$(mkcert -CAROOT)/rootCA.pem" MODE

  idp  IdP-initiated sign-ins at the container IdP for the container's own SP
       (https://saml.test/sp). Each case decodes the SAMLResponse in the IdP's auto-submit form
       and never posts it on.
  sp   Full round trips between the container SP and the container IdP, SP- and IdP-initiated,
       posted on to the SP's ACS and checked on its result page.

Each case uses its own cookie jar, so no IdP or SP session carries over between cases.
Needs `ohrm saml up` and a running dev_saml. Touches no tree. Prints one `ok <case>` or
`FAIL <case>: <reason>` line per case and exits 0 only when every case passed.
Stdlib only: the host has Python 3.9 without lxml.
"""
import argparse
import base64
import html.parser
import http.cookiejar
import re
import ssl
import sys
import traceback
import types
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ORIGIN = "https://saml.test"
CONTAINER_SP = ORIGIN + "/sp"
IDP_SSO = ORIGIN + "/simplesaml/module.php/saml/idp/singleSignOnService"
LOGIN_PAGE = ORIGIN + "/login.php"
SP_PAGE = ORIGIN + "/sp/"
RESULT_PAGE = ORIGIN + "/sp/result.php"
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
    assert r.form_action == "https://saml.test/simplesaml/module.php/saml/sp/saml2-acs.php/container-sp"
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


def sp_login(idp, username):
    """SP-initiated: start at the SP page's ?idp= login, sign in as username, and post the response
    to the container SP. Returns the result page. idp must be the container IdP, since the sign-in
    step drives its login.php."""
    browser = new_browser()
    page_url, page = open_login_page(browser, SP_PAGE + "?idp=" + urllib.parse.quote(idp, safe=""))
    return post_to_sp(browser, *submit_username(browser, page_url, page, username))


def idp_initiated_to_sp(username):
    """IdP-initiated: start at the container IdP's SSO for the container SP, sign in as username,
    and post the unsolicited response to the SP. Returns the result page."""
    browser = new_browser()
    page_url, page = open_login_page(browser)
    return post_to_sp(browser, *submit_username(browser, page_url, page, username))


def case_sp_initiated_self():
    page = sp_login(idp="https://saml.test/idp", username="alice")   # starts at /sp/?idp=…
    assert "Flow: SP-initiated" in page
    assert "Issuer: https://saml.test/idp" in page
    assert "NameID: alice" in page and "username: alice" in page
    assert "Signed: yes" in page
    assert "Assertions: 1 (encrypted: no)" in page


def case_idp_initiated_self():
    page = idp_initiated_to_sp(username="bob")   # singleSignOnService?spentityid=https://saml.test/sp, then on to the ACS
    assert "Flow: IdP-initiated" in page and "NameID: bob" in page
    assert "Assertions: 1 (encrypted: no)" in page


def case_unknown_idp_refused():
    start = SP_PAGE + "?idp=" + urllib.parse.quote("https://evil.example/idp", safe="")
    status, location, _ = fetch(new_browser(), start)
    assert status == 400 and location == "", f"GET {start} answered {status} {location}, expected 400"


CASES = {
    "idp": [case_admin_asserted, case_odd_username_asserted_verbatim, case_empty_username_refused],
    "sp": [case_sp_initiated_self, case_idp_initiated_self, case_unknown_idp_refused],
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
    args = parser.parse_args()
    CAFILE = args.cafile

    failed = 0
    for case in CASES[args.mode]:
        name = case.__name__[len("case_"):].replace("_", " ")
        try:
            case()
            print(f"ok   {name}")
        except Exception as e:
            failed += 1
            print(f"FAIL {name}: {describe(e)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
