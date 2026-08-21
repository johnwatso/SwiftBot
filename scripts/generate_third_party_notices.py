#!/usr/bin/env python3
"""Regenerate THIRD-PARTY-NOTICES.md from the resolved Swift packages.

SwiftBot ships a signed, notarized app containing every one of these packages,
so their license and notice texts have to travel with it. Rather than hand-maintain
that file, this reads the pinned versions out of Package.resolved and the license
texts out of the SwiftPM checkouts, so a version bump is a re-run rather than a
copy-paste job.

The output is also bundled into the app and shown verbatim in the Acknowledgements
window, so it deliberately avoids HTML: it has to read as plain text, not just render
on GitHub.

Usage:
    python3 scripts/generate_third_party_notices.py [--checkouts PATH] [--check]

    --checkouts  SwiftPM checkouts directory. Defaults to the DerivedData location
                 for this project; resolve packages in Xcode at least once first.
    --check      Exit non-zero if the committed file is out of date, without
                 rewriting it. Intended for CI.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from datetime import date

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOLVED = os.path.join(
    REPO_ROOT, "SwiftBot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)
OUTPUT = os.path.join(REPO_ROOT, "THIRD-PARTY-NOTICES.md")

# identity -> (display name, checkout directory, what SwiftBot uses it for)
PACKAGES = {
    "sparkle": ("Sparkle", "Sparkle", "Signed automatic app updates."),
    "swiftsoup": ("SwiftSoup", "SwiftSoup", "HTML parsing for Patchy and WikiBridge."),
    "swift-opus": ("swift-opus", "swift-opus", "Opus encode/decode for Discord voice."),
    "swift-nio": ("SwiftNIO", "swift-nio", "Networking for SwiftMesh cluster transport."),
    "swift-nio-ssl": ("SwiftNIO SSL", "swift-nio-ssl", "TLS for SwiftMesh cluster transport."),
    "swift-crypto": ("Swift Crypto", "swift-crypto", "Cryptographic primitives for mesh auth."),
    "swift-certificates": ("Swift Certificates", "swift-certificates", "X.509 handling for mesh TLS."),
    "swift-asn1": ("Swift ASN.1", "swift-asn1", "ASN.1 encoding beneath Swift Certificates."),
    "swift-markdown": ("Swift Markdown", "swift-markdown", "Release-note rendering."),
    "swift-cmark": ("swift-cmark", "swift-cmark", "CommonMark parser beneath Swift Markdown."),
    "swift-atomics": ("Swift Atomics", "swift-atomics", "Transitive dependency of SwiftNIO."),
    "swift-collections": ("Swift Collections", "swift-collections", "Transitive dependency of SwiftNIO."),
    "swift-system": ("Swift System", "swift-system", "Transitive dependency of SwiftNIO."),
    "libdave-swift": ("libdave-swift", "libdave-swift", "Discord DAVE end-to-end encrypted voice."),
}

LICENSE_FILENAMES = ("LICENSE.txt", "LICENSE", "LICENSE.md", "COPYING", "COPYING.txt")
NOTICE_FILENAMES = ("NOTICE.txt", "NOTICE", "NOTICE.md")

APACHE_MARKER = "Apache License"

HEADER = """# Third-Party Notices

SwiftBot is distributed as a signed macOS application that statically or dynamically
includes the third-party packages listed below. Their license and notice texts are
reproduced here to satisfy the attribution terms those licenses require.

This file is generated — edit `scripts/generate_third_party_notices.py` and re-run it
rather than editing this file by hand. Package versions reflect the pins in
`SwiftBot.xcodeproj/.../Package.resolved` as of {generated}.

SwiftBot's own license is in [LICENSE](LICENSE).

## Contents

{toc}
"""

LIBDAVE_NOTE = """`libdave-swift` is maintained alongside SwiftBot and ships a prebuilt
`Dave.xcframework` compiled from Discord's libdave, mlspp, and OpenSSL/libcrypto.

**Its license status is unresolved.** The repository carries no license file of its
own, and its `THIRD_PARTY_NOTICES.md` records that the exact source revisions and
license texts of the bundled native components were not captured at build time.
That inventory explicitly warns against inferring a component's version or license
from it, so no license is asserted for those components here.

Resolving this requires capturing the upstream revisions and license texts during the
next framework rebuild, per the workflow in that repository's `THIRD_PARTY_NOTICES.md`,
and adding a license file to `libdave-swift` itself.

* Bundled native components: Discord libdave, mlspp, OpenSSL/libcrypto
* Component inventory: https://github.com/johnwatso/libdave-swift/blob/main/THIRD_PARTY_NOTICES.md
"""


def read_first(directory: str, names: tuple[str, ...]) -> tuple[str, str] | None:
    """Returns (filename, contents) for the first of `names` that exists."""
    for name in names:
        path = os.path.join(directory, name)
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as handle:
                return name, handle.read().strip()
    return None


def default_checkouts() -> str | None:
    pattern = os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/SwiftBot-*/SourcePackages/checkouts"
    )
    matches = sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True)
    return matches[0] if matches else None


def load_pins() -> dict[str, dict]:
    with open(RESOLVED, encoding="utf-8") as handle:
        data = json.load(handle)
    pins = data.get("pins") or data.get("object", {}).get("pins", [])
    result = {}
    for pin in pins:
        identity = pin.get("identity") or pin.get("package", "").lower()
        state = pin.get("state", {})
        result[identity] = {
            "version": state.get("version") or state.get("revision", "")[:8],
            "url": pin.get("location") or pin.get("repositoryURL", ""),
        }
    return result


def anchor(name: str) -> str:
    return name.lower().replace(" ", "-").replace(".", "")


def build(checkouts: str) -> str:
    pins = load_pins()
    missing = [identity for identity in pins if identity not in PACKAGES]
    if missing:
        raise SystemExit(
            "Package.resolved has packages this script does not know about: "
            + ", ".join(sorted(missing))
            + "\nAdd them to PACKAGES in scripts/generate_third_party_notices.py."
        )

    ordered = [i for i in PACKAGES if i in pins]
    sections: list[str] = []
    apache_users: list[str] = []

    toc = "\n".join(
        f"* [{PACKAGES[i][0]}](#{anchor(PACKAGES[i][0])})" for i in ordered
    ) + "\n* [Appendix A: Apache License 2.0](#appendix-a-apache-license-20)"

    for identity in ordered:
        display, folder, purpose = PACKAGES[identity]
        pin = pins[identity]
        directory = os.path.join(checkouts, folder)

        lines = [f"## {display}", ""]
        lines.append(f"* Version: `{pin['version']}`")
        lines.append(f"* Upstream: {pin['url'].removesuffix('.git')}")
        lines.append(f"* Used for: {purpose}")
        lines.append("")

        if identity == "libdave-swift":
            lines.append(LIBDAVE_NOTE)
            sections.append("\n".join(lines))
            continue

        license_file = read_first(directory, LICENSE_FILENAMES)
        if license_file is None:
            raise SystemExit(f"No license file found for {display} in {directory}")
        filename, text = license_file

        if APACHE_MARKER in text.split("\n")[0] or text.lstrip().startswith(APACHE_MARKER):
            apache_users.append(display)
            lines.append(
                "Licensed under the Apache License, Version 2.0 — full text in "
                "[Appendix A](#appendix-a-apache-license-20)."
            )
            lines.append("")
        else:
            lines.append(f"License text (`{filename}`):")
            lines.append("")
            lines.append("```")
            lines.append(text)
            lines.append("```")
            lines.append("")

        notice_file = read_first(directory, NOTICE_FILENAMES)
        if notice_file is not None:
            notice_name, notice_text = notice_file
            lines.append(f"Notice (`{notice_name}`):")
            lines.append("")
            lines.append("```")
            lines.append(notice_text)
            lines.append("```")
            lines.append("")

        sections.append("\n".join(lines).rstrip() + "\n")

    apache_source = None
    for identity in ordered:
        directory = os.path.join(checkouts, PACKAGES[identity][1])
        found = read_first(directory, LICENSE_FILENAMES)
        if found and (found[1].lstrip().startswith(APACHE_MARKER)):
            apache_source = found[1]
            break

    appendix = ["## Appendix A: Apache License 2.0", ""]
    if apache_users:
        appendix.append("Applies to: " + ", ".join(apache_users) + ".")
        appendix.append("")
    if apache_source:
        appendix.append("```")
        appendix.append(apache_source)
        appendix.append("```")
    sections.append("\n".join(appendix) + "\n")

    header = HEADER.format(generated=date.today().isoformat(), toc=toc)
    return header + "\n" + "\n---\n\n".join(sections)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkouts", default=None)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    checkouts = args.checkouts or default_checkouts()
    if not checkouts or not os.path.isdir(checkouts):
        print(
            "Could not find the SwiftPM checkouts directory. Open the project in Xcode "
            "(or run a build) so packages resolve, or pass --checkouts.",
            file=sys.stderr,
        )
        return 2

    generated = build(checkouts)

    if args.check:
        if not os.path.isfile(OUTPUT):
            print("THIRD-PARTY-NOTICES.md is missing.", file=sys.stderr)
            return 1
        with open(OUTPUT, encoding="utf-8") as handle:
            current = handle.read()
        # The generated-on date changes every day; compare everything else.
        if strip_date(current) != strip_date(generated):
            print("THIRD-PARTY-NOTICES.md is out of date — re-run this script.", file=sys.stderr)
            return 1
        return 0

    with open(OUTPUT, "w", encoding="utf-8") as handle:
        handle.write(generated)
    print(f"Wrote {os.path.relpath(OUTPUT, REPO_ROOT)}")
    return 0


def strip_date(text: str) -> str:
    return "\n".join(line for line in text.split("\n") if "as of " not in line)


if __name__ == "__main__":
    sys.exit(main())
