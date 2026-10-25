#!/usr/bin/env python3
"""Builds the AuthCore .deb — the package that actually installs the component.

A .deb is an `ar` archive holding three members in this exact order:

    debian-binary     b"2.0\\n"
    control.tar.gz    ./control ./postinst ./prerm ./md5sums
    data.tar.gz       the filesystem payload

`ar` ships with macOS, but Apple's ar and GNU ar do not agree on when a symbol
table gets written, and dpkg refuses an archive carrying a `__.SYMDEF` member.
Writing the archive here removes that variable and makes the step reproducible
(and verifiable) on any machine with Python.

The payload is the *same* AuthCore.dylib the app bundle embeds. One binary, two
hosts: the app loads it from Frameworks/ for the integrity checks, SpringBoard
loads it from /usr/lib because the filter plist points at com.apple.springboard.

Two packages come out of one dylib:

    cc.ouovo.authcore_<ver>_iphoneos-arm.deb      rootful   (/usr/lib, /Library)
    cc.ouovo.authcore_<ver>_iphoneos-arm64.deb    rootless  (/var/jb/usr/lib, ...)

The split is baked into the paths rather than relocated in `postinst`: a rootless
device has a sealed system volume, so a package carrying rootful paths cannot
even unpack there. Emitting both means one of them always installs cleanly, and
which one is obvious from the filename.

Usage:
    python3 make_deb.py --dylib ../../authcore/AuthCore.dylib [--out build/debs]
                        [--version 1.1.0]
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import os
import sys
import tarfile
import time

PACKAGE = "cc.ouovo.authcore"
DISPLAY_NAME = "AuthCore (YOLO Person component)"
LOADER_NAME = "AuthCore"
DESCRIPTION = [
    "Authorization core and SpringBoard overlay component for YOLO Person.",
    ".",
    "The same binary serves two hosts. Inside the app it performs the integrity",
    "checks the app calls. Installed here it is loaded into SpringBoard, where it",
    "captures the display, runs the YOLO Core ML model, draws the floating window",
    "and injects the aim drag.",
    ".",
    "SpringBoard is the point: a window owned by an app is composited inside that",
    "app's process, so it disappears when the app is backgrounded. SpringBoard's",
    "windows stay above every app, and SpringBoard is never suspended.",
    ".",
    "The filter targets com.apple.springboard only - nothing is injected into any",
    "game. Requires a jailbreak (Dopamine, palera1n, unc0ver, checkra1n).",
    "TrollStore alone cannot inject into SpringBoard, so this package does nothing",
    "there.",
    ".",
    "After installing, check: ls -la /var/mobile/Library/Preferences/cc.ouovo.authcore.alive",
]

VARIANTS = [
    # (architecture field, payload prefix, human label)
    ("iphoneos-arm", "", "rootful"),
    ("iphoneos-arm64", "var/jb", "rootless"),
]


# --------------------------------------------------------------------------- #
# ar writer
# --------------------------------------------------------------------------- #

def _field(text: str, width: int) -> str:
    if len(text) > width:
        raise ValueError(f"ar field {text!r} does not fit in {width} bytes")
    return text.ljust(width)


def _ar_member(name: str, data: bytes, mode: int = 0o100644) -> bytes:
    """One ar member: a 60-byte ASCII header followed by the data, even-padded."""
    if len(name) > 16:
        raise ValueError(f"ar member name too long: {name}")
    # BSD/GNU layout: name, mtime, uid, gid, mode, size, then the magic.
    # Built from an explicit list rather than adjacent f-strings: implicit
    # concatenation would let a trailing .ljust() swallow the earlier fields.
    header = "".join([
        _field(name, 16),
        _field(str(int(time.time())), 12),
        _field("0", 6),                 # uid
        _field("0", 6),                 # gid
        _field(format(mode, "o"), 8),
        _field(str(len(data)), 10),
        "`\n",
    ]).encode("ascii")
    if len(header) != 60:
        raise ValueError(f"ar header is {len(header)} bytes, expected 60")
    padding = b"\n" if len(data) % 2 else b""
    return header + data + padding


def write_ar(path: str, members) -> None:
    with open(path, "wb") as handle:
        handle.write(b"!<arch>\n")
        for name, data in members:
            handle.write(_ar_member(name, data))


# --------------------------------------------------------------------------- #
# tar helpers
# --------------------------------------------------------------------------- #

def tar_gz(entries) -> bytes:
    """entries: list of (arcname, bytes, mode). Deterministic: no mtime, uid 0."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for arcname, data, mode in entries:
            info = tarfile.TarInfo(arcname)
            info.size = len(data)
            info.mtime = 0
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "wheel"
            info.mode = mode
            info.type = tarfile.REGTYPE
            tar.addfile(info, io.BytesIO(data))
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0) as gz:
        gz.write(raw.getvalue())
    return out.getvalue()


# --------------------------------------------------------------------------- #
# Maintainer scripts
# --------------------------------------------------------------------------- #

def postinst_script(root_prefix: str) -> bytes:
    root = f"/{root_prefix}" if root_prefix else ""
    loader_dir = f"{root}/Library/MobileSubstrate/DynamicLibraries"
    return f"""#!/bin/sh
# Runs after the files are unpacked. Never fails the install: a package stuck in
# half-configured is much harder for a user to recover from than a missing
# respring.
ROOT="{root}"
LOADER_DIR="{loader_dir}"

# A stale heartbeat would make the post-install check pass on an old timestamp,
# so it is removed before SpringBoard restarts. The app's Documents mirror is
# removed too - SpringBoard recreates both within five seconds.
rm -f /var/mobile/Library/Preferences/cc.ouovo.authcore.alive 2>/dev/null || true
rm -f /var/mobile/Library/Preferences/cc.ouovo.yolooverlay.alive 2>/dev/null || true
rm -f /var/mobile/Library/Preferences/cc.ouovo.authcore.log 2>/dev/null || true
for DOCS in /var/mobile/Containers/Data/Application/*/Documents; do
  rm -f "$DOCS/cc.ouovo.authcore.alive" 2>/dev/null || true
done

chmod 755 "$LOADER_DIR/{LOADER_NAME}.dylib" 2>/dev/null || true
chmod 644 "$LOADER_DIR/{LOADER_NAME}.plist" 2>/dev/null || true

# Reload SpringBoard so the dylib loader sees the new filter.
PATH="${{ROOT}}/usr/bin:${{ROOT}}/bin:${{ROOT}}/usr/sbin:$PATH"
export PATH

if command -v sbreload >/dev/null 2>&1; then
  sbreload >/dev/null 2>&1 || true
elif command -v killall >/dev/null 2>&1; then
  killall -9 SpringBoard >/dev/null 2>&1 || true
elif [ -x "${{ROOT}}/usr/bin/killall" ]; then
  "${{ROOT}}/usr/bin/killall" -9 SpringBoard >/dev/null 2>&1 || true
fi

exit 0
""".encode("utf-8")


def prerm_script(root_prefix: str) -> bytes:
    root = f"/{root_prefix}" if root_prefix else ""
    return f"""#!/bin/sh
# Stop SpringBoard reloading an already-deleted dylib during removal.
ROOT="{root}"
PATH="${{ROOT}}/usr/bin:${{ROOT}}/bin:$PATH"
export PATH
if command -v killall >/dev/null 2>&1; then
  killall -9 SpringBoard >/dev/null 2>&1 || true
elif [ -x "${{ROOT}}/usr/bin/killall" ]; then
  "${{ROOT}}/usr/bin/killall" -9 SpringBoard >/dev/null 2>&1 || true
fi
exit 0
""".encode("utf-8")


# --------------------------------------------------------------------------- #
# Package assembly
# --------------------------------------------------------------------------- #

def control_file(version: str, arch: str, installed_kb: int) -> bytes:
    lines = [
        f"Package: {PACKAGE}",
        f"Name: {DISPLAY_NAME}",
        f"Version: {version}",
        f"Architecture: {arch}",
        "Section: Tweaks",
        "Priority: optional",
        "Maintainer: WhyJ1ng <whyj1ng@ouovo.cc>",
        "Author: WhyJ1ng <whyj1ng@ouovo.cc>",
        # Only the firmware floor is declared. The injection loader
        # (ElleKit / Substitute / Substrate) is deliberately NOT a dependency:
        # its virtual package name differs between bootstraps, and an unmet
        # dependency turns "installs but does nothing" into "refuses to install",
        # which is strictly harder for a user to diagnose.
        "Depends: firmware (>= 15.0)",
        f"Installed-Size: {installed_kb}",
        "Description: " + DESCRIPTION[0],
    ]
    # Continuation lines must be indented by one space; an empty line is " .".
    for extra in DESCRIPTION[1:]:
        lines.append(" " + extra)
    return ("\n".join(lines) + "\n").encode("utf-8")


def build_variant(dylib: bytes, plist: bytes, version: str, arch: str,
                  prefix: str, out_dir: str) -> str:
    base = prefix + "/" if prefix else ""

    data_entries = [
        (f"./{base}usr/lib/{LOADER_NAME}.dylib", dylib, 0o755),
        (f"./{base}Library/MobileSubstrate/DynamicLibraries/{LOADER_NAME}.dylib", dylib, 0o755),
        (f"./{base}Library/MobileSubstrate/DynamicLibraries/{LOADER_NAME}.plist", plist, 0o644),
    ]

    md5_lines = []
    for name, payload, _mode in data_entries:
        md5_lines.append(f"{hashlib.md5(payload).hexdigest()}  {name[2:]}")
    md5sums = ("\n".join(md5_lines) + "\n").encode("utf-8")

    installed_kb = max(1, sum(len(p) for _n, p, _m in data_entries) // 1024)

    control_entries = [
        ("./control", control_file(version, arch, installed_kb), 0o644),
        ("./postinst", postinst_script(prefix), 0o755),
        ("./prerm", prerm_script(prefix), 0o755),
        ("./md5sums", md5sums, 0o644),
    ]

    deb_path = os.path.join(out_dir, f"{PACKAGE}_{version}_{arch}.deb")
    write_ar(deb_path, [
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", tar_gz(control_entries)),
        ("data.tar.gz", tar_gz(data_entries)),
    ])
    return deb_path


# --------------------------------------------------------------------------- #
# Verification
# --------------------------------------------------------------------------- #

def verify(deb_path: str) -> None:
    """Re-reads the package the way dpkg would. Raises on anything unexpected."""
    with open(deb_path, "rb") as handle:
        blob = handle.read()
    if not blob.startswith(b"!<arch>\n"):
        raise ValueError(f"{deb_path}: missing ar magic")

    members = []
    offset = 8
    while offset + 60 <= len(blob):
        header = blob[offset:offset + 60]
        if header[58:60] != b"`\n":
            raise ValueError(f"{deb_path}: bad member terminator at {offset}")
        name = header[0:16].decode("ascii").strip()
        try:
            size = int(header[48:58].decode("ascii").strip())
        except ValueError as exc:
            raise ValueError(f"{deb_path}: bad size field for {name}") from exc
        data = blob[offset + 60:offset + 60 + size]
        members.append((name, data))
        offset += 60 + size + (size % 2)

    names = [name for name, _ in members]
    if names != ["debian-binary", "control.tar.gz", "data.tar.gz"]:
        raise ValueError(f"{deb_path}: unexpected ar members {names}")
    if members[0][1] != b"2.0\n":
        raise ValueError(f"{deb_path}: debian-binary is {members[0][1]!r}")

    for member_name, payload in members[1:]:
        with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as tar:
            if not tar.getnames():
                raise ValueError(f"{deb_path}: {member_name} is empty")
            for info in tar.getmembers():
                if info.name.startswith("/") or ".." in info.name.split("/"):
                    raise ValueError(f"{deb_path}: unsafe path {info.name}")

    with tarfile.open(fileobj=io.BytesIO(members[1][1]), mode="r:gz") as tar:
        handle = tar.extractfile("./control")
        text = (handle.read() if handle else b"").decode("utf-8")
    for required in ("Package:", "Version:", "Architecture:", "Description:"):
        if required not in text:
            raise ValueError(f"{deb_path}: control is missing {required}")

    # The payload must contain the loader pair; without both the component never
    # loads, and the failure looks like a broken dylib rather than a bad package.
    with tarfile.open(fileobj=io.BytesIO(members[2][1]), mode="r:gz") as tar:
        payload_names = tar.getnames()
    if not any(name.endswith(f"DynamicLibraries/{LOADER_NAME}.plist")
               for name in payload_names):
        raise ValueError(f"{deb_path}: payload has no {LOADER_NAME}.plist filter")
    if not any(name.endswith(f"usr/lib/{LOADER_NAME}.dylib")
               for name in payload_names):
        raise ValueError(f"{deb_path}: payload has no /usr/lib/{LOADER_NAME}.dylib")


# --------------------------------------------------------------------------- #

def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description="Build the AuthCore .deb")
    parser.add_argument("--dylib", default=os.path.join(here, "..", "..", "authcore",
                                                        "AuthCore.dylib"))
    parser.add_argument("--plist", default=os.path.join(here, f"{LOADER_NAME}.plist"))
    parser.add_argument("--out", default=os.path.join(here, "build", "debs"))
    parser.add_argument("--version", default="1.1.0")
    args = parser.parse_args()

    if not os.path.isfile(args.dylib):
        print(f"error: dylib not found: {args.dylib}", file=sys.stderr)
        return 1
    with open(args.dylib, "rb") as handle:
        dylib = handle.read()
    # Accept thin arm64 (0xcffaedfe), thin arm64e (same magic) and fat (0xcafebabe).
    if len(dylib) < 4096 or dylib[:4] not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
        print("error: the input does not look like a Mach-O binary", file=sys.stderr)
        return 1
    with open(args.plist, "rb") as handle:
        plist = handle.read()
    if b"com.apple.springboard" not in plist:
        print("error: the filter plist does not target com.apple.springboard",
              file=sys.stderr)
        return 1

    os.makedirs(args.out, exist_ok=True)
    built = []
    for arch, prefix, label in VARIANTS:
        path = build_variant(dylib, plist, args.version, arch, prefix, args.out)
        verify(path)
        print(f"{label:<9} {os.path.basename(path)}  "
              f"{os.path.getsize(path)} bytes  "
              f"({'/' + prefix if prefix else '/'} layout)")
        built.append(path)

    print(f"\nOK  {len(built)} package(s) in {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
