#!/usr/bin/env python3
"""
Verify that docs/appcast.xml is internally consistent and that every update it
advertises is correctly signed for THIS app's public key.

For each <enclosure> in the appcast it checks:
  * the required attributes are present (url, length, sparkle:edSignature)
  * the file's byte length matches the advertised `length`
  * the EdDSA (Ed25519) signature verifies against SUPublicEDKey from Info.plist

This proves the whole trust chain is consistent:
    Info.plist public key  ↔  appcast signature  ↔  the actual binary
If any link is wrong, users couldn't install the update — so this fails the build.

The binary is read from a local `sparkle-updates/<file>` when present (fast,
offline — handy before you push), otherwise it's downloaded from its URL. A
missing *remote* asset (e.g. before the first publish) is reported as a warning,
not a failure; a present-but-wrong asset is a hard error.

Usage:
    python3 scripts/verify_appcast.py
Exit code 0 = OK, 1 = verification failed, 2 = missing dependency.
"""
import base64
import os
import plistlib
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

try:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
except ImportError:
    sys.stderr.write("This script needs the 'cryptography' package:\n    pip install cryptography\n")
    sys.exit(2)

ROOT = Path(__file__).resolve().parent.parent
INFO_PLIST = ROOT / "Info.plist"
APPCAST = ROOT / "docs" / "appcast.xml"
LOCAL_ARCHIVES = ROOT / "sparkle-updates"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ED_SIG_ATTR = f"{{{SPARKLE_NS}}}edSignature"
VERSION_ATTR = f"{{{SPARKLE_NS}}}version"
IN_CI = os.environ.get("GITHUB_ACTIONS") == "true"

_errors = 0
_warnings = 0


def err(msg: str) -> None:
    global _errors
    _errors += 1
    print(f"  \u2717 {msg}")
    if IN_CI:
        print(f"::error::{msg}")


def warn(msg: str) -> None:
    global _warnings
    _warnings += 1
    print(f"  ! {msg}")
    if IN_CI:
        print(f"::warning::{msg}")


def ok(msg: str) -> None:
    print(f"  \u2713 {msg}")


def load_public_key():
    if not INFO_PLIST.exists():
        err(f"{INFO_PLIST.name} not found")
        return None
    with INFO_PLIST.open("rb") as f:
        info = plistlib.load(f)
    key_b64 = info.get("SUPublicEDKey", "")
    if not key_b64 or "REPLACE" in key_b64:
        err("SUPublicEDKey is missing or still a placeholder in Info.plist")
        return None
    try:
        raw = base64.b64decode(key_b64)
    except Exception:
        err("SUPublicEDKey is not valid base64")
        return None
    if len(raw) != 32:
        err(f"SUPublicEDKey decodes to {len(raw)} bytes, expected 32")
        return None
    ok(f"Public key loaded: {key_b64}")
    return Ed25519PublicKey.from_public_bytes(raw)


def fetch_bytes(url: str):
    """Return (data, source). Prefers a local archive; otherwise downloads.
    Returns (None, None) and warns if a remote asset can't be retrieved."""
    name = url.rsplit("/", 1)[-1]
    local = LOCAL_ARCHIVES / name
    if local.exists():
        return local.read_bytes(), f"local:{local.relative_to(ROOT)}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "verify-appcast"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.read(), "downloaded"
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
        warn(f"could not download {url} ({e}) \u2014 skipping signature check for this item")
        return None, None


def main() -> int:
    print(f"Verifying {APPCAST.relative_to(ROOT)}\n")
    if not APPCAST.exists():
        err(f"{APPCAST} not found \u2014 run ./make-appcast.sh first")
        return 1

    pub = load_public_key()

    try:
        tree = ET.parse(APPCAST)
    except ET.ParseError as e:
        err(f"appcast is not valid XML: {e}")
        return 1

    enclosures = tree.findall(".//enclosure")
    if not enclosures:
        err("no <enclosure> entries found in appcast")
        return 1

    items = tree.findall(".//item")
    print(f"\nFound {len(enclosures)} update(s):")
    for item in items:
        enc = item.find("enclosure")
        if enc is None:
            continue
        url = enc.get("url", "")
        length = enc.get("length")
        sig_b64 = enc.get(ED_SIG_ATTR)
        # generate_appcast writes the version as a child element; older feeds put
        # it on the enclosure. Accept either.
        ver_el = item.find(VERSION_ATTR)
        ver = (ver_el.text if ver_el is not None else None) or enc.get(VERSION_ATTR) or "?"
        name = url.rsplit("/", 1)[-1] or "(no url)"
        print(f"\n- {name}  (version {ver})")

        if not url:
            err("enclosure has no url")
            continue
        if not sig_b64:
            err(f"{name}: missing sparkle:edSignature")
            continue
        if not length or not length.isdigit():
            err(f"{name}: missing or non-numeric length attribute")
            continue

        data, source = fetch_bytes(url)
        if data is None:
            continue
        if len(data) != int(length):
            err(f"{name}: length mismatch \u2014 appcast says {length}, file is {len(data)} bytes")
            continue
        if pub is None:
            continue

        try:
            pub.verify(base64.b64decode(sig_b64), data)
            ok(f"signature valid, length {length} ({source})")
        except InvalidSignature:
            err(f"{name}: EdDSA signature does NOT match the app's public key")
        except Exception as e:
            err(f"{name}: signature check error: {e}")

    print()
    if _errors:
        print(f"FAILED: {_errors} error(s), {_warnings} warning(s).")
        return 1
    print(f"OK: appcast verified ({_warnings} warning(s)).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
