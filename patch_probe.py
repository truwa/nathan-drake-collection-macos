#!/usr/bin/env python3
"""Patch Uncharted's bb-probe.exe so CrossOver on macOS can reserve its guest memory.

macOS keeps a guard over 0x1000000000, which is where this runtime asks Windows
for the PlayStation 4 address window. The prepared game image is relocatable,
so the window can start at 0x7000000000 instead. The same executable is also
hooked to a small DLL that accepts TLS slots Wine puts past the first 64.
"""
import argparse
import hashlib
import struct
from pathlib import Path

PROBE_SHA256 = "993357964b408a23a242fba47c14a3086b0ec25ee3ade30b9e2efca3774d9d8e"
TLS_SLOT_FILE = 0xCE9320
TLS_GUARD_FILE = 0x1DA34

USER_MIN = 0x1000000000
USER_MAX = 0xFC00000000
COMPAT_MIN = 0x7000000000
PATCH_TCB_RVA = 0x5480
IMAGE_GLOBAL_RVA = 0xCF3D08
DLL_NAME = b"uncharted-crossover-tls.dll\0"
EXPORT_NAME = b"\0\0patch_guest_tls\0"

# Immediate operand file offsets in this 0.3.3 bb-probe.exe. The two opcode
# bytes sit immediately before each immediate.
PATCHES = (
    (0xE92F, b"\x48\xbf", USER_MAX - USER_MIN, USER_MAX - COMPAT_MIN, "reservation size"),
    (0xE939, b"\x48\xbe", USER_MIN, COMPAT_MIN, "reservation base"),
    (0xF57B, b"\x49\xbe", USER_MIN + 1, COMPAT_MIN + 1, "low-map ceiling"),
    (0x10AE6, b"\x48\xb9", USER_MIN, COMPAT_MIN, "placement floor"),
    (0x34EDF, b"\x48\xb8", USER_MIN, COMPAT_MIN, "GPU address floor"),
)


def align(value, boundary):
    return (value + boundary - 1) // boundary * boundary


def patch(source: Path, destination: Path) -> None:
    data = bytearray(source.read_bytes())
    digest = hashlib.sha256(data).hexdigest()
    if digest != PROBE_SHA256:
        raise ValueError(f"This bb-probe.exe is not the 0.3.3 runtime ({digest})")
    if data[TLS_SLOT_FILE:TLS_SLOT_FILE + 4] != b"\xff" * 4:
        raise ValueError("Guest TLS slot is not the expected unset value")
    if data[TLS_GUARD_FILE:TLS_GUARD_FILE + 2] != b"\x73\x0d":
        raise ValueError("TLS slot guard is not the expected jump")
    # TlsSetValue accepts expansion slots. The adapter installs those loads.
    data[TLS_GUARD_FILE:TLS_GUARD_FILE + 2] = b"\x90\x90"
    for offset, opcode, old, new, label in PATCHES:
        expected = opcode + struct.pack("<Q", old)
        found = bytes(data[offset - 2:offset + 8])
        if found != expected:
            raise ValueError(f"{label} does not match this bb-probe.exe ({found.hex()})")
        data[offset:offset + 8] = struct.pack("<Q", new)
    _hook_tls(data)
    _enlarge_record_chunks(data)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(destination)


def _enlarge_record_chunks(data: bytearray) -> None:
    """One recorded GPU command during combat exceeds the 128 KB chunk.

    Commands live in the first 0x20000 bytes. The cursor and two neighboring
    qwords follow, and the allocation is 0x20040. ReserveRecordData aborts
    when one reservation cannot fit. The data area becomes 4 MB and those
    three qwords move with it.
    """
    old_cap, new_cap = 0x20000, 0x400000
    delta = new_cap - old_cap
    text_start, text_end = 0x400, 0x400 + 0x53A600
    text = bytes(data[text_start:text_end])
    changed = 0
    cursors = []

    def rewrite(at, new):
        nonlocal changed
        data[at:at + 4] = struct.pack("<I", new)
        changed += 1

    for field in (0x20000, 0x20008, 0x20010):
        raw = struct.pack("<I", field)
        index = 0
        while True:
            found = text.find(raw, index)
            if found < 0:
                break
            index = found + 1
            at = text_start + found
            if not _is_chunk_field(data, at):
                continue
            if field == old_cap:
                cursors.append(at)
            rewrite(at, field + delta)

    index = 0
    cap = struct.pack("<I", old_cap)
    while True:
        found = text.find(cap, index)
        if found < 0:
            break
        index = found + 1
        at = text_start + found
        near_cursor = any(at - 32 <= cursor < at for cursor in cursors)
        if near_cursor and _is_capacity_compare(data, at):
            rewrite(at, new_cap)
        elif data[at - 2:at] == b"\x41\xb8" and data[at + 4:at + 7] == b"\x4c\x2b\x80":
            rewrite(at, new_cap)

    allocs = 0
    alloc = struct.pack("<I", 0x20040)
    index = 0
    while True:
        found = text.find(alloc, index)
        if found < 0:
            break
        index = found + 1
        at = text_start + found
        if data[at - 1] in range(0xB8, 0xC0) or data[at - 2:at] == b"\x41\xb8":
            rewrite(at, 0x400040)
            allocs += 1
    limit_at = text.find(struct.pack("<I", 0x20001))
    if limit_at < 0 or data[text_start + limit_at - 3:text_start + limit_at] != b"\x48\x81\xfa":
        raise ValueError("record chunk limit was not the expected compare")
    rewrite(text_start + limit_at, 0x400001)
    if len(cursors) < 50 or allocs != 12:
        raise ValueError(f"record chunk patch saw {len(cursors)} cursors and {allocs} allocations")


def _is_chunk_field(data: bytearray, at: int) -> bool:
    opcodes = {0x8B, 0x89, 0x2B, 0x81, 0x83, 0xC7, 0x03, 0x01, 0x29, 0x39}
    rex, opcode, modrm = data[at - 3], data[at - 2], data[at - 1]
    if rex in range(0x40, 0x50) and opcode in opcodes and modrm >> 6 == 2 and (modrm & 7) != 4:
        if (modrm & 7) == 5 and (rex & 1) == 0:
            return False
        return True
    rex, opcode, modrm, sib = data[at - 4], data[at - 3], data[at - 2], data[at - 1]
    if rex in range(0x40, 0x50) and opcode in opcodes and modrm >> 6 == 2 and (modrm & 7) == 4:
        base = sib & 7
        if base == 4 and (rex & 1) == 0:
            return False
        if base == 5 and (rex & 1) == 0:
            return False
        return True
    # movaps [r13+cursor], xmm — the recorder clears the cursor this way.
    return data[at - 4:at] == b"\x41\x0f\x29\xb5"


def _is_capacity_compare(data: bytearray, at: int) -> bool:
    rex, opcode, modrm = data[at - 3], data[at - 2], data[at - 1]
    if rex in range(0x40, 0x50) and opcode == 0x81 and modrm >> 6 == 3 and (modrm >> 3) & 7 == 7:
        return True
    return data[at - 2:at] == b"\x48\x3d"


def _hook_tls(data: bytearray) -> None:
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe + 4
    section_count = struct.unpack_from("<H", data, coff + 2)[0]
    optional = coff + 20
    optional_size = struct.unpack_from("<H", data, coff + 16)[0]
    if struct.unpack_from("<H", data, optional)[0] != 0x20B:
        raise ValueError("bb-probe.exe is not a PE32+ image")
    section_alignment, file_alignment = struct.unpack_from("<II", data, optional + 32)
    header_table = optional + optional_size
    header_slot = header_table + section_count * 40
    size_of_headers = struct.unpack_from("<I", data, optional + 60)[0]
    if header_slot + 40 > size_of_headers or any(data[header_slot:header_slot + 40]):
        raise ValueError("No room for a TLS hook section")

    layouts = []
    for index in range(section_count):
        header = header_table + index * 40
        virtual_size, rva, raw_size, raw_offset = struct.unpack_from("<IIII", data, header + 8)
        layouts.append((rva, max(virtual_size, raw_size), raw_offset))

    def file_offset(rva):
        for start, size, raw in layouts:
            if start <= rva < start + size:
                return raw + rva - start
        raise ValueError(f"RVA {rva:#x} is outside the original sections")

    import_directory = optional + 112 + 8
    import_rva, _import_size = struct.unpack_from("<II", data, import_directory)
    cursor = file_offset(import_rva)
    descriptors = []
    while any(data[cursor:cursor + 20]):
        descriptors.append(bytes(data[cursor:cursor + 20]))
        cursor += 20

    section_rva = align(max(start + size for start, size, _raw in layouts), section_alignment)
    raw_offset = align(len(data), file_alignment)
    descriptor_size = (len(descriptors) + 2) * 20
    lookup_offset = align(descriptor_size, 8)
    iat_offset = lookup_offset + 16
    name_offset = iat_offset + 16
    symbol_offset = align(name_offset + len(DLL_NAME), 2)
    code_offset = align(symbol_offset + len(EXPORT_NAME), 16)

    section = bytearray(code_offset + 32)
    struct.pack_into(
        "<IIIII", section, 0,
        section_rva + lookup_offset, 0, 0,
        section_rva + name_offset, section_rva + iat_offset)
    for index, descriptor in enumerate(descriptors, start=1):
        section[index * 20:(index + 1) * 20] = descriptor
    struct.pack_into("<Q", section, lookup_offset, section_rva + symbol_offset)
    struct.pack_into("<Q", section, iat_offset, section_rva + symbol_offset)
    section[name_offset:name_offset + len(DLL_NAME)] = DLL_NAME
    section[symbol_offset:symbol_offset + len(EXPORT_NAME)] = EXPORT_NAME

    code_rva = section_rva + code_offset
    image_disp = IMAGE_GLOBAL_RVA - (code_rva + 11)
    iat_disp = (section_rva + iat_offset) - (code_rva + 20)
    code = (
        b"\x48\x83\xEC\x28"
        + b"\x48\x8B\x05" + struct.pack("<i", image_disp)
        + b"\x4C\x8B\xC0"
        + b"\xFF\x15" + struct.pack("<i", iat_disp)
        + b"\x48\x83\xC4\x28"
        + b"\xC3"
    )
    section[code_offset:code_offset + len(code)] = code

    prologue = file_offset(PATCH_TCB_RVA)
    if data[prologue:prologue + 5] != bytes.fromhex("5541565657"):
        raise ValueError("patch_tcb_loads prologue changed")
    data[prologue:prologue + 5] = b"\xE9" + struct.pack("<i", code_rva - (PATCH_TCB_RVA + 5))

    virtual_size = code_offset + len(code)
    raw_size = align(virtual_size, file_alignment)
    data[header_slot:header_slot + 40] = struct.pack(
        "<8sIIIIIIHHI", b".umac\0\0\0", virtual_size, section_rva,
        raw_size, raw_offset, 0, 0, 0, 0, 0xE0000060)
    struct.pack_into("<H", data, coff + 2, section_count + 1)
    struct.pack_into("<I", data, optional + 56, align(section_rva + virtual_size, section_alignment))
    struct.pack_into("<II", data, import_directory, section_rva, descriptor_size)
    struct.pack_into("<I", data, optional + 64, 0)
    data.extend(bytes(raw_offset - len(data)))
    data.extend(section)
    data.extend(bytes(raw_size - len(section)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    patch(args.source, args.destination)
    print(args.destination)
