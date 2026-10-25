#!/usr/bin/env python3
"""Two-stage build support for AuthCore.dylib's __TEXT self-check.

WHAT IS HASHED
--------------
The __TEXT,__text SECTION - not the whole __TEXT segment and not the file. __text
holds every function in the dylib, including the four probes, so patching a probe
body changes the value that body's own range is compared against. __TEXT's other
sections are excluded for a concrete reason: on arm64e with chained fixups dyld
rebases the pointer slots in __auth_stubs at load time, so a hash of the segment
taken from the file would never match the same hash taken from memory.

WHY A TWO-STAGE LINK
--------------------
AuthCore hashes its own __text and compares the result with expected values
compiled into the same image. Those values cannot live in __text (the comparison
would be circular) and must not live in __LINKEDIT (re-signing rewrites the
signature block, so the expected value would go stale on every codesign). They
therefore live in a custom section:

    -Wl,-sectcreate,__DATA,__guard,<payload file>

__DATA is writable and is not hashed, so filling the expected values in does not
change the value they are compared against.

That forces two links:

  stage 1  link with a ZERO-FILLED payload. The section exists at its final
           size, so __text and the load commands are already final.
  stage 2  hash the stage-1 __text per slice, write the digests into the
           payload, link again.

The second link produces a different file with byte-identical __text, because the
only change is the content of a __DATA section. `verify` asserts that rather than
assuming it: if the two links ever disagree, the binary would report itself as
tampered on device, which is worse than a failed build.

A ZERO-FILLED PAYLOAD IS A LEGITIMATE END STATE
-----------------------------------------------
If the stage-2 link cannot be made to work, shipping the zero-filled payload is
better than shipping nothing: the section and the runtime code are both present,
the magic is absent, and AuthCore reports "unarmed" (a pass) with a live
text_digest. The server then has the digest to compare, which is the layer that
actually matters. See SUBAGENT_BRIEF_7B.md: L1 is a decoy.

FAT SLICES
----------
The dylib is linked for arm64 and arm64e, so the output is a fat file whose two
slices contain different code. Each slice therefore needs its own expected
values, and the payload holds one slot per CPU. The runtime picks the slot that
matches the slice it is executing in.

The *version fingerprint* is deliberately slice-independent: it is derived from
every slot's digests, so an arm64 device and an arm64e device report the same
string and the server registers one value per (version, build).

PAYLOAD LAYOUT (256 bytes, constant at both stages)
---------------------------------------------------
    offset  size  field
    0       4     magic "AUG2"          (zero at stage 1: that is "unarmed")
    4       4     slot count actually used
    8       8     reserved, zero
    16      56*4  slots, zero-padded; slot = cputype(4) cpusubtype(4)
                                              digestA..D (8 each)
                                              fingerprint (16)
    240     16    sha256(bytes[0:240])[0:16]

USAGE
-----
    python3 scripts/authcore_integrity.py stage1 --out authcore/guard.zero
    <link authcore/AuthCore.stage1.dylib with -sectcreate ... guard.zero>
    python3 scripts/authcore_integrity.py stage2 authcore/AuthCore.stage1.dylib \\
        --out authcore/guard.bin --meta authcore/AuthCore.meta.json \\
        --version 1.1.0 --build 20
    <link authcore/AuthCore.dylib with -sectcreate ... guard.bin>
    python3 scripts/authcore_integrity.py verify authcore/AuthCore.dylib \\
        --meta authcore/AuthCore.meta.json --payload authcore/guard.bin
    python3 scripts/authcore_integrity.py tamper authcore/AuthCore.dylib \\
        --meta authcore/AuthCore.meta.json --probe A

Exit codes: 0 ok, 1 assertion failed, 2 tool error.
"""
import argparse
import hashlib
import hmac
import json
import os
import struct
import sys

# ---- names ------------------------------------------------------------------
GUARD_SEG = "__DATA"
GUARD_SEC = "__guard"

# ---- Mach-O constants -------------------------------------------------------
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_SYMTAB = 0x2
DYLIB_COMMANDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB,
                  LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB)

MH_PIE = 0x200000
CPU_ARCH_ABI64 = 0x01000000
CPU_ARCH_ABI64_32 = 0x02000000
CPU_SUBTYPE_MASK = 0xFF000000
CPU_TYPE_ARM64 = CPU_ARCH_ABI64 | 12

# Must match kIntegrityTextLimit in YOLOiOSApp/AuthCore.m. 2 MiB is far beyond
# this dylib's size, so in practice the whole section is covered; the cap only
# stops a runaway hash if it ever grows absurdly.
TEXT_HASH_LIMIT = 2 * 1024 * 1024

# The hashed region is the __TEXT,__text SECTION, not the whole __TEXT segment.
#
# __TEXT also holds __stubs / __auth_stubs / __cstring / __const, and on arm64e
# with chained fixups the pointed-to slot inside __auth_stubs is rebased by dyld
# at load time. Hashing the segment would then compare live memory against the
# file and report tampering on every clean install. __text is pure code: the
# linker never emits a rebase or a bind into it, so file bytes and runtime bytes
# are identical by construction. Every function in this dylib lives there,
# including the four probes, which is what makes the partition meaningful.
TEXT_SEG = "__TEXT"
TEXT_SEC = "__text"


# ---- Mach-O reader ----------------------------------------------------------
class Slice(object):
    """One thin 64-bit slice."""

    def __init__(self, data, offset):
        self.data = data
        self.base = offset
        (magic, cputype, cpusubtype, _filetype, ncmds, _sizeofcmds,
         flags, _res) = struct.unpack_from("<IiiIIIII", data, offset)
        if magic != MH_MAGIC_64:
            raise ValueError("slice at 0x%x is not a 64-bit Mach-O "
                             "(magic 0x%08x)" % (offset, magic))
        self.cputype = cputype
        # The ABI64 capability bit and the ptrauth feature bits above it are not
        # part of the subtype identity; only the low 24 bits name the CPU variant.
        #
        # The mask is applied as `& 0x00FFFFFF`, not `& ~CPU_SUBTYPE_MASK`: Python
        # integers are unbounded, so `~0xFF000000` is a negative value whose high
        # bits are all ones, and ANDing a sign-extended cpusubtype with it yields a
        # ~2^33-wide negative number instead of 2. That value then keys the
        # __guard slot, where it would never match the int32 the runtime computes
        # and every device would report "unarmed".
        self.cpusubtype = cpusubtype & 0x00FFFFFF
        self.is_pie = bool(flags & MH_PIE)

        self.segments = {}
        self.dylibs = []
        self.symtab = None

        cursor = offset + 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, cursor)
            if cmdsize < 8:
                raise ValueError("load command with cmdsize %d" % cmdsize)
            if cmd == LC_SEGMENT_64:
                (segname, vmaddr, vmsize, fileoff, filesize, _maxprot,
                 _initprot, nsects, _sflags) = struct.unpack_from(
                     "<16sQQQQiiII", data, cursor + 8)
                name = segname.split(b"\0", 1)[0].decode("ascii", "replace")
                seg = {"name": name, "vmaddr": vmaddr, "vmsize": vmsize,
                       "fileoff": fileoff, "filesize": filesize,
                       "sections": {}}
                sc = cursor + 72
                for _s in range(nsects):
                    (sectname, _sg, addr, size, s_off, _align, _reloff,
                     _nreloc, _sflags2) = struct.unpack_from(
                         "<16s16sQQIIIII", data, sc)
                    seg["sections"][sectname.split(b"\0", 1)[0]] = {
                        "addr": addr, "size": size, "offset": s_off}
                    sc += 80
                self.segments[name] = seg
            elif cmd == LC_SYMTAB:
                symoff, nsyms, stroff, strsize = struct.unpack_from(
                    "<IIII", data, cursor + 8)
                self.symtab = {"symoff": symoff, "nsyms": nsyms,
                               "stroff": stroff, "strsize": strsize}
            elif cmd in DYLIB_COMMANDS:
                nameoff = struct.unpack_from("<I", data, cursor + 8)[0]
                raw = data[cursor + nameoff:cursor + cmdsize]
                self.dylibs.append(raw.split(b"\0", 1)[0].decode("utf-8", "replace"))
            cursor += cmdsize

    # -- accessors ------------------------------------------------------------
    @property
    def arch(self):
        if self.cputype == CPU_TYPE_ARM64:
            return "arm64e" if self.cpusubtype else "arm64"
        return "cpu0x%x" % self.cputype

    def section(self, seg_name, sec_name):
        seg = self.segments.get(seg_name)
        if seg is None:
            return None
        meta = seg["sections"].get(sec_name.encode("ascii"))
        if meta is None:
            return None
        start = self.base + meta["offset"]
        return self.data[start:start + meta["size"]], meta

    def section_or_raise(self, seg_name, sec_name):
        """(bytes, segment, section meta) for a section that must exist."""
        got = self.section(seg_name, sec_name)
        if got is None:
            raise ValueError("no %s,%s section in the %s slice"
                             % (seg_name, sec_name, self.arch))
        body, meta = got
        if len(body) != meta["size"]:
            raise ValueError("%s,%s in the %s slice is truncated: %d of %d bytes"
                             % (seg_name, sec_name, self.arch,
                                len(body), meta["size"]))
        return body, self.segments[seg_name], meta

    def symbols(self):
        """{name: vmaddr} for every defined symbol in this slice."""
        if self.symtab is None:
            return {}
        out = {}
        symoff = self.base + self.symtab["symoff"]
        stroff = self.base + self.symtab["stroff"]
        for i in range(self.symtab["nsyms"]):
            strx, ntype, _sect, _desc, value = struct.unpack_from(
                "<IBBhQ", self.data, symoff + i * 16)
            if ntype & 0xE0 or strx == 0:
                continue
            end = self.data.find(b"\0", stroff + strx)
            name = self.data[stroff + strx:end].decode("ascii", "replace")
            if name and not name.startswith("ltmp"):
                out[name] = value
        return out


def read_slices(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) < 8:
        raise ValueError("%s is too small to be a Mach-O" % path)
    magic_be = struct.unpack_from(">I", data, 0)[0]
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack_from(">I", data, 4)[0]
        if nfat == 0 or nfat > 8:
            raise ValueError("fat header reports %d slices" % nfat)
        entry_size = 32 if magic_be == FAT_MAGIC_64 else 20
        slices = []
        for i in range(nfat):
            base = 8 + i * entry_size
            if magic_be == FAT_MAGIC_64:
                _cpu, _sub, off, size, _align, _r = struct.unpack_from(
                    ">iiQQII", data, base)
            else:
                _cpu, _sub, off, size, _align = struct.unpack_from(
                    ">iiIII", data, base)
            slices.append(Slice(data, off))
        return slices
    return [Slice(data, 0)]


# ---- probe definitions ------------------------------------------------------
# These mirror YOIntegrityProbeA..D in AuthCore.m. The four variants differ in
# algorithm, not merely in the bytes they read, so neutralising the check means
# defeating four different comparisons.

def probe_a(buf):
    """SHA-256, leading 8 bytes."""
    return hashlib.sha256(buf).digest()[:8]


def probe_b(buf):
    """SHA-256, trailing 8 bytes."""
    return hashlib.sha256(buf).digest()[-8:]


def probe_c(buf):
    """SHA-512, leading 8 bytes - a different digest function entirely."""
    return hashlib.sha512(buf).digest()[:8]


def probe_d(buf):
    """SHA-256 xor-folded to 8 bytes: every byte of the digest participates."""
    folded = bytearray(8)
    for i, byte in enumerate(hashlib.sha256(buf).digest()):
        folded[i % 8] ^= byte
    return bytes(folded)


PROBES = [("A", probe_a), ("B", probe_b), ("C", probe_c), ("D", probe_d)]

PROBE_SYMBOLS = [
    ("_YOIntegrityProbeA", 0),
    ("_YOIntegrityProbeB", 1),
    ("_YOIntegrityProbeC", 2),
    ("_YOIntegrityProbeD", 3),
]


def probe_ranges(sl):
    """([(probe index, lo, hi)], hashed bytes) - offsets into __TEXT,__text.

    The four probes PARTITION the section. Boundaries are the four probe entry
    addresses plus 0 and the section end; the probe with the lowest address also
    owns everything before it.

    Starting the lowest range at 0 rather than at that probe's own entry is not
    cosmetic: __text begins with code defined earlier in the translation unit
    (AuthCoreInit, the host check, the entry points themselves), and a range that
    began at the first probe would leave all of it unhashed - a free patch site in
    the same section the check claims to cover.

    AuthCore.m computes the same ranges at runtime with dladdr(), so any
    disagreement between the two is a false positive on every device - which is
    why the boundaries are derived from symbols on both sides instead of
    hardcoded, and why `verify` asserts that the ranges tile without a gap.
    """
    text, seg, secmeta = sl.section_or_raise(TEXT_SEG, TEXT_SEC)
    syms = sl.symbols()
    missing = [sym for sym, _ in PROBE_SYMBOLS if sym not in syms]
    if missing:
        raise ValueError(
            "probe functions missing from the symbol table of the %s slice (%s). "
            "They are non-static and visibility(default) in AuthCore.m for exactly "
            "this reason: the build needs their addresses to compute the values "
            "the runtime will compute." % (sl.arch, ", ".join(missing)))

    # The section occupies one contiguous run of __TEXT, so a symbol's index is
    # its vmaddr minus the section's vmaddr.
    sec_lo = secmeta["addr"]
    sec_hi = sec_lo + len(text)
    starts = []
    for sym, idx in PROBE_SYMBOLS:
        addr = syms[sym]
        if not (sec_lo <= addr < sec_hi):
            raise ValueError("%s (0x%x) is outside __TEXT,__text (0x%x..0x%x) in "
                             "the %s slice" % (sym, addr, sec_lo, sec_hi, sl.arch))
        starts.append((addr - sec_lo, idx))

    starts.sort()
    out = []
    for slot, (lo, idx) in enumerate(starts):
        if slot == 0:
            lo = 0
        hi = starts[slot + 1][0] if slot + 1 < len(starts) else len(text)
        if hi <= lo:
            raise ValueError("probe %s has an empty range in the %s slice"
                             % (PROBES[idx][0], sl.arch))
        out.append((idx, lo, hi))
    return out, text


def slice_digests(sl):
    """([dA, dB, dC, dD], __TEXT byte count) for one slice."""
    ranges, text = probe_ranges(sl)
    digests = [None] * 4
    for idx, lo, hi in ranges:
        digests[idx] = PROBES[idx][1](text[lo:hi])
    if any(d is None for d in digests):
        raise ValueError("not every probe produced a digest in the %s slice" % sl.arch)
    return digests, len(text)


# ---- version fingerprint ----------------------------------------------------
# HMAC_SHA256("version|build|textDigest", secret)[0:16], hex.
#
# The secret is a compiled constant in AuthCore.m, XOR-masked with 0x6B. This
# copy exists so CI and the binary cannot drift. Per SUBAGENT_BRIEF_7B.md this
# is a cost-raising detection measure, not a security boundary: the boundary is
# whatever the server decides to do with a mismatch.
FINGERPRINT_KEY = b"yhXk9QmZt3LpRw7VbNcFj2GsDaEuHoT5"


def version_fingerprint(version, build, slices):
    """Slice-independent: derived from every slice, so arm64 and arm64e devices
    report the same string and the server registers one value per build."""
    parts = []
    for sl, digests in slices:
        parts.append("%s:%s" % (sl.arch, b"".join(digests).hex()))
    parts.sort()
    message = "%s|%s|%s" % (version, build, ",".join(parts))
    return hmac.new(FINGERPRINT_KEY, message.encode("utf-8"),
                    hashlib.sha256).hexdigest()[:32], message


# ---- payload ----------------------------------------------------------------
GUARD_MAGIC = b"AUG2"
MAX_SLOTS = 4
SLOT_LEN = 56
GUARD_LEN = 16 + SLOT_LEN * MAX_SLOTS + 16  # 256


def build_payload(entries):
    """entries: [(cputype, cpusubtype, digests[4], fingerprint_hex)]."""
    # 16-byte header: magic(4) count(4) reserved(8). Spelled out field by field:
    # AuthCore.m indexes slots from offset 16, so a header of any other length
    # shifts every slot and no probe would ever match.
    body = GUARD_MAGIC + struct.pack("<I", len(entries)) + bytes(8)
    for i in range(MAX_SLOTS):
        if i < len(entries):
            cpu, sub, digests, fp_hex = entries[i]
            slot = struct.pack("<ii", cpu, sub)
            for d in digests:
                if len(d) != 8:
                    raise ValueError("digest length %d != 8" % len(d))
                slot += d
            slot += bytes.fromhex(fp_hex)
        else:
            slot = bytes(SLOT_LEN)
        if len(slot) != SLOT_LEN:
            raise ValueError("slot length %d != %d" % (len(slot), SLOT_LEN))
        body += slot
    if len(body) != GUARD_LEN - 16:
        raise ValueError("payload body %d bytes" % len(body))
    body += hashlib.sha256(body).digest()[:16]
    if len(body) != GUARD_LEN:
        raise ValueError("payload %d != %d bytes" % (len(body), GUARD_LEN))
    return body


def parse_payload(payload):
    if len(payload) < GUARD_LEN:
        raise ValueError("payload is %d bytes, expected %d" % (len(payload), GUARD_LEN))
    body = payload[:GUARD_LEN]
    if body[:4] != GUARD_MAGIC:
        raise ValueError("__guard magic missing - the payload was never filled "
                         "(this is the stage-1 state)")
    want = hashlib.sha256(body[:GUARD_LEN - 16]).digest()[:16]
    if want != body[GUARD_LEN - 16:]:
        raise ValueError("__guard trailer checksum mismatch")
    count = struct.unpack_from("<I", body, 4)[0]
    if count < 1 or count > MAX_SLOTS:
        raise ValueError("__guard declares %d slots" % count)
    entries = []
    for i in range(count):
        off = 16 + i * SLOT_LEN
        cpu, sub = struct.unpack_from("<ii", body, off)
        digests = [body[off + 8 + j * 8:off + 16 + j * 8] for j in range(4)]
        fingerprint = body[off + 40:off + 56].hex()
        entries.append((cpu, sub, digests, fingerprint))
    return entries


# ---- commands ---------------------------------------------------------------
def cmd_stage1(args):
    payload = bytes(GUARD_LEN)
    with open(args.out, "wb") as fh:
        fh.write(payload)
    print("stage1 payload: %s (%d zero bytes)" % (args.out, GUARD_LEN))
    print("  the section must already be at its final size, so __TEXT and the "
          "load commands are final after this link")
    return 0


def cmd_stage2(args):
    slices = read_slices(args.binary)
    per_slice = []
    for sl in slices:
        digests, hashed = slice_digests(sl)
        per_slice.append((sl, digests, hashed))

    fingerprint, message = version_fingerprint(args.version, str(args.build),
                                               [(sl, d) for sl, d, _h in per_slice])
    entries = [(sl.cputype, sl.cpusubtype, d, fingerprint)
               for sl, d, _h in per_slice]
    payload = build_payload(entries)

    with open(args.out, "wb") as fh:
        fh.write(payload)

    meta = {
        "binary": os.path.basename(args.binary),
        "version": args.version,
        "build": str(args.build),
        "hashed_section": "%s,%s" % (TEXT_SEG, TEXT_SEC),
        "text_limit": TEXT_HASH_LIMIT,
        "fingerprint": fingerprint,
        "fingerprint_message": message,
        "guard_payload_sha256": hashlib.sha256(payload).hexdigest(),
        # The digest AuthCoreIntegrityDigest() reports at runtime: four 8-byte
        # probe digests in probe order, hex. This is the value to register in
        # lic_versions.text_digest for the release.
        "text_digest": "".join(d.hex() for d in per_slice[0][1]) if per_slice else "",
        "slices": [
            {
                "arch": sl.arch,
                "cputype": sl.cputype,
                "cpusubtype": sl.cpusubtype,
                "text_hashed": hashed,
                "probes": {name: d.hex()
                           for (name, _fn), d in zip(PROBES, dgs)},
                "ranges": [{"probe": PROBES[idx][0], "lo": lo, "hi": hi}
                           for idx, lo, hi in probe_ranges(sl)[0]],
            }
            for sl, dgs, hashed in per_slice
        ],
    }
    with open(args.meta, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2, sort_keys=True)
        fh.write("\n")

    print("stage2: %d slice(s)" % len(per_slice))
    for sl, dgs, hashed in per_slice:
        print("  %-7s %s,%s %6d bytes" % (sl.arch, TEXT_SEG, TEXT_SEC, hashed))
        for (name, _fn), d in zip(PROBES, dgs):
            print("           probe %s = %s" % (name, d.hex()))
    print("  fingerprint = %s" % fingerprint)
    print("  text_digest = %s  (register this in lic_versions.text_digest)"
          % meta["text_digest"])
    print("  payload -> %s (%d bytes)" % (args.out, len(payload)))
    print("  meta    -> %s" % args.meta)
    return 0


def cmd_verify(args):
    failures = []

    slices = read_slices(args.binary)
    with open(args.meta, "r", encoding="utf-8") as fh:
        meta = json.load(fh)
    with open(args.payload, "rb") as fh:
        expected_payload = fh.read()

    print("verify: %d slice(s), payload %d bytes" % (len(slices), len(expected_payload)))

    # 1. __DATA,__guard must exist in every slice and hold the payload we linked.
    for sl in slices:
        got = sl.section(GUARD_SEG, GUARD_SEC)
        if got is None:
            failures.append("%s: no __DATA,__guard - -sectcreate did not take"
                            % sl.arch)
            continue
        blob, secmeta = got
        print("%-7s __DATA,__guard: %d bytes at offset %d"
              % (sl.arch, len(blob), secmeta["offset"]))
        if len(blob) != GUARD_LEN:
            failures.append("%s: __guard is %d bytes, expected %d"
                            % (sl.arch, len(blob), GUARD_LEN))
        if blob[:GUARD_LEN] != expected_payload:
            failures.append("%s: __guard content differs from %s"
                            % (sl.arch, args.payload))

    # 2. The payload must parse and its trailer must check out.
    try:
        entries = parse_payload(expected_payload)
    except ValueError as exc:
        print("::error::%s" % exc)
        return 1
    print("payload ok: %d slot(s), checksum valid" % len(entries))

    # 3. Every slice must hash to what stage 2 recorded, and to what its own
    #    __guard slot says. This is the assertion that makes the two-stage link
    #    honest: the second link must not have moved a byte of __TEXT.
    registered_fingerprints = set()
    for sl in slices:
        row = next((r for r in meta["slices"] if r["arch"] == sl.arch), None)
        if row is None:
            failures.append("%s: no stage2 record for this slice" % sl.arch)
            continue
        try:
            digests, hashed = slice_digests(sl)
            ranges = probe_ranges(sl)[0]
        except ValueError as exc:
            print("::error::%s" % exc)
            return 1

        for (name, _fn), d in zip(PROBES, digests):
            want = row["probes"][name]
            if d.hex() != want:
                failures.append("%s probe %s: final file %s != stage2 %s"
                                % (sl.arch, name, d.hex(), want))
            else:
                print("%-7s probe %s ok  %s" % (sl.arch, name, d.hex()))

        # The four ranges must tile the hashed section exactly. A gap would be a
        # stretch of code no probe covers - i.e. a free patch site - and an
        # overlap would mean the ranges disagree with the runtime's view.
        ordered = sorted(ranges)
        cursor = 0
        for _idx, lo, hi in ordered:
            if lo != cursor:
                failures.append("%s: probe ranges do not tile the section "
                                "(expected %d, got %d)" % (sl.arch, cursor, lo))
            cursor = hi
        if cursor != hashed:
            failures.append("%s: probe ranges cover %d of %d hashed bytes"
                            % (sl.arch, cursor, hashed))
        else:
            print("%-7s ranges tile %d bytes across %d probe(s)"
                  % (sl.arch, hashed, len(ordered)))

        slot = next((e for e in entries
                     if e[0] == sl.cputype and e[1] == sl.cpusubtype), None)
        if slot is None:
            failures.append("%s: no __guard slot for cputype 0x%x subtype %d"
                            % (sl.arch, sl.cputype, sl.cpusubtype))
        else:
            for i, ((name, _fn), d) in enumerate(zip(PROBES, digests)):
                if slot[2][i] != d:
                    failures.append("%s slot probe %s = %s but the binary hashes "
                                    "to %s" % (sl.arch, name,
                                               slot[2][i].hex(), d.hex()))
            if slot[3] != meta["fingerprint"]:
                failures.append("%s slot fingerprint %s != %s"
                                % (sl.arch, slot[3], meta["fingerprint"]))
            registered_fingerprints.add(slot[3])

    # 4. The fingerprint must be the same in every slot, otherwise the server
    #    would need one registration per CPU variant.
    if len(registered_fingerprints) > 1:
        failures.append("slots disagree on the fingerprint: %s"
                        % ", ".join(sorted(registered_fingerprints)))
    recomputed, _msg = version_fingerprint(
        meta["version"], meta["build"],
        [(sl, slice_digests(sl)[0]) for sl in slices])
    if recomputed != meta["fingerprint"]:
        failures.append("fingerprint %s != registered %s"
                        % (recomputed, meta["fingerprint"]))
    else:
        print("fingerprint ok  %s (identical in %d slot(s))"
              % (recomputed, len(registered_fingerprints)))

    # 5. Entry points and probe symbols the runtime needs.
    for sl in slices:
        syms = sl.symbols()
        missing = [s for s, _ in PROBE_SYMBOLS if s not in syms]
        missing += [s for s in ("_AuthCoreIntegrityVerified",
                                "_AuthCoreVersionFingerprint",
                                "_AuthCoreIntegrityDigest",
                                "_AuthCoreIntegrityState")
                    if s not in syms]
        if missing:
            failures.append("%s: missing symbol(s) %s" % (sl.arch, ", ".join(missing)))
        else:
            print("%-7s symbols ok (4 probes + 4 entry points)" % sl.arch)

        # A dylib is position-independent by nature; it is not required to carry
        # MH_PIE (that flag applies to executables). Asserting it here treated
        # every valid dynamic library as broken, so the check was wrong and is
        # removed rather than papered over with a weaker flag.

    # 6. Unchanged structural expectations.
    for needle in ("/usr/lib/libSystem.B.dylib", "Foundation.framework",
                   "UIKit.framework", "Security.framework"):
        if not any(needle in d for d in slices[0].dylibs):
            failures.append("dylib dependency %r missing" % needle)
    if not failures:
        print("dylib deps ok")

    if failures:
        print("")
        for f in failures:
            print("::error::%s" % f)
        return 1

    print("")
    print("INTEGRITY OK: __guard %d bytes, fingerprint %s"
          % (GUARD_LEN, meta["fingerprint"]))
    return 0


def cmd_tamper(args):
    """MUTATION TEST: flip one byte inside a probe's range and prove the digest
    moves.

    CI cannot execute an iOS dylib, so the runtime comparison cannot be exercised
    there. What can be established mechanically is the property the comparison
    rests on: every hashed byte is load-bearing. This copies the binary, flips one
    bit of one byte inside probe `--probe`'s range, re-hashes, and asserts that at
    least one probe digest differs from stage 2's record.

    A pass here means "a one-byte patch cannot go unnoticed". It does not mean the
    runtime comparison is wired up correctly - that needs a device.
    """
    with open(args.meta, "r", encoding="utf-8") as fh:
        meta = json.load(fh)

    with open(args.binary, "rb") as fh:
        original = fh.read()

    slices = read_slices(args.binary)
    target_arch = args.arch or slices[0].arch
    target = next((s for s in slices if s.arch == target_arch), None)
    if target is None:
        print("::error::no %s slice in %s" % (target_arch, args.binary))
        return 2

    row = next((r for r in meta["slices"] if r["arch"] == target_arch), None)
    if row is None:
        print("::error::no stage2 record for the %s slice" % target_arch)
        return 2

    try:
        ranges = probe_ranges(target)[0]
    except ValueError as exc:
        print("::error::%s" % exc)
        return 2

    probe_index = {"A": 0, "B": 1, "C": 2, "D": 3}[args.probe]
    match = [r for r in ranges if r[0] == probe_index]
    if not match:
        print("::error::probe %s has no range in the %s slice"
              % (args.probe, target_arch))
        return 2
    _idx, lo, hi = match[0]

    # Pick a byte a patcher would plausibly touch: `--offset` when given, else the
    # middle of the range (an instruction, not padding).
    if args.offset is not None:
        offset = args.offset
        if not (lo <= offset < hi):
            print("::error::offset %d is outside probe %s's range (%d..%d)"
                  % (offset, args.probe, lo, hi))
            return 2
    else:
        offset = (lo + hi) // 2

    text, _seg, secmeta = target.section_or_raise(TEXT_SEG, TEXT_SEC)
    absolute = target.base + secmeta["offset"] + offset

    mutated = bytearray(original)
    before = mutated[absolute]
    mutated[absolute] ^= 0x01
    after = mutated[absolute]
    if before == after:
        print("::error::flipping bit 0 of byte 0x%02x changed nothing" % before)
        return 2

    tmp = args.out or os.path.join(os.path.dirname(args.binary) or ".",
                                   "_tamper_probe.dylib")
    with open(tmp, "wb") as fh:
        fh.write(bytes(mutated))

    print("tamper: %s slice, probe %s range %d..%d" % (target_arch, args.probe, lo, hi))
    print("  flipped 0x%02x -> 0x%02x at section offset %d (file offset %d)"
          % (before, after, offset, absolute))

    try:
        mutated_slice = next(s for s in read_slices(tmp) if s.arch == target_arch)
        digests, hashed = slice_digests(mutated_slice)
    finally:
        if args.out is None:
            try:
                os.remove(tmp)
            except OSError:
                pass

    changed = []
    for (name, _fn), d in zip(PROBES, digests):
        if d.hex() != row["probes"][name]:
            changed.append(name)

    for (name, _fn), d in zip(PROBES, digests):
        mark = "CHANGED" if name in changed else "same"
        print("  probe %s: %s  %s" % (name, d.hex(), mark))
    print("  hashed bytes: %d (unchanged: a one-byte edit must not resize the "
          "section)" % hashed)

    if hashed != row["text_hashed"]:
        print("::error::the edit changed the section size, %d -> %d; the byte was "
              "not inside the hashed section" % (row["text_hashed"], hashed))
        return 1

    if not changed:
        print("::error::no probe digest changed after a one-byte edit - the hashed "
              "ranges do not cover offset %d" % offset)
        return 1

    # The edited probe's own range must be one of those that moved; if only a
    # neighbouring probe reacted, the range map is off by a function and the
    # runtime would disagree with the build.
    if args.probe not in changed:
        print("::error::probe %s's digest did not change, but %s did - its range "
              "does not contain offset %d"
              % (args.probe, ", ".join(changed), offset))
        return 1

    print("")
    print("TAMPER OK: one byte at offset %d moved probe(s) %s"
          % (offset, ", ".join(changed)))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        description="two-stage build support for AuthCore's __TEXT self-check")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("stage1", help="write the zero-filled __guard payload")
    p1.add_argument("--out", required=True)
    p1.set_defaults(func=cmd_stage1)

    p2 = sub.add_parser("stage2", help="hash the __text section and fill the payload")
    p2.add_argument("binary")
    p2.add_argument("--out", required=True)
    p2.add_argument("--meta", required=True)
    p2.add_argument("--version", required=True)
    p2.add_argument("--build", required=True)
    p2.set_defaults(func=cmd_stage2)

    p3 = sub.add_parser("verify", help="assert the shipped binary is consistent")
    p3.add_argument("binary")
    p3.add_argument("--meta", required=True)
    p3.add_argument("--payload", required=True)
    p3.set_defaults(func=cmd_verify)

    p4 = sub.add_parser("tamper",
                        help="mutation test: one byte edit must change a digest")
    p4.add_argument("binary")
    p4.add_argument("--meta", required=True)
    p4.add_argument("--probe", required=True, choices=["A", "B", "C", "D"])
    p4.add_argument("--arch", default=None,
                    help="slice to edit (default: the first one)")
    p4.add_argument("--offset", type=int, default=None,
                    help="section offset to flip (default: middle of the range)")
    p4.add_argument("--out", default=None,
                    help="keep the mutated copy at this path")
    p4.set_defaults(func=cmd_tamper)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (ValueError, KeyError, struct.error, OSError) as exc:
        print("::error::%s" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
