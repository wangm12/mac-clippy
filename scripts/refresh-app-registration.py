#!/usr/bin/env python3
"""Keep only the installed MacClippy registered, without resetting other apps."""

import argparse
import plistlib
import re
import subprocess
from pathlib import Path

LSREGISTER = Path(
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    "LaunchServices.framework/Support/lsregister"
)
BUNDLE_IDS = {
    "com.macallyouneed.macclippy",
    "com.macallyouneed.macclippy.e2e",
    "com.macallyouneed.macclippy.uitests.xctrunner",
}


def registered_paths(dump):
    paths = set()
    for record in re.split(r"(?m)^-{20,}\s*$", dump):
        identifier = re.search(r"(?m)^identifier:\s+(\S+)\s*$", record)
        path = re.search(r"(?m)^path:\s+(.+?)\s+\(0x[0-9a-fA-F]+\)\s*$", record)
        if identifier and identifier.group(1) in BUNDLE_IDS and path:
            candidate = Path(path.group(1))
            if not candidate.is_absolute() or candidate.suffix != ".app":
                raise ValueError(f"Unexpected registered app path: {candidate}")
            paths.add(candidate)
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Apply the printed registration changes")
    args = parser.parse_args()
    installed = Path("/Applications/MacClippy.app")
    with (installed / "Contents/Info.plist").open("rb") as handle:
        if plistlib.load(handle).get("CFBundleIdentifier") != "com.macallyouneed.macclippy":
            raise ValueError("The installed app has an unexpected bundle identifier")
    dump = subprocess.check_output([str(LSREGISTER), "-dump"], text=True)
    obsolete = sorted(registered_paths(dump) - {installed})
    for path in obsolete:
        print(f"Unregister: {path}")
        if args.apply:
            subprocess.run([str(LSREGISTER), "-u", str(path)], check=True)
    print(f"Register: {installed}")
    if args.apply:
        subprocess.run([str(LSREGISTER), "-f", str(installed)], check=True)
        remaining = registered_paths(subprocess.check_output([str(LSREGISTER), "-dump"], text=True))
        if remaining != {installed}:
            raise RuntimeError(f"Unexpected remaining registrations: {sorted(remaining)}")
        print("Verified: only /Applications/MacClippy.app is registered.")


if __name__ == "__main__":
    main()
