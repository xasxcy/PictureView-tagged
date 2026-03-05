#!/usr/bin/env python3
"""
inject_macho.py  –  Add LC_LOAD_WEAK_DYLIB to a (possibly fat) Mach-O binary.

Usage:
    python3 inject_macho.py <binary> <dylib_path>

Works by writing the new load command into the padding that already exists
between the end of the load-command list and the first section content.
The binary is modified in-place; make a backup first if needed.
"""

import struct
import sys
import os

# ── Mach-O constants ──────────────────────────────────────────────────────────
FAT_MAGIC          = 0xCAFEBABE
MH_MAGIC_64        = 0xFEEDFACF   # little-endian
LC_LOAD_WEAK_DYLIB = 0x80000018
MACHO_HEADER_SIZE  = 32            # mach_header_64


def align8(n):
    return (n + 7) & ~7


def make_lc_load_weak_dylib(dylib_path: str) -> bytes:
    """Build the LC_LOAD_WEAK_DYLIB command bytes."""
    path_bytes  = dylib_path.encode() + b'\x00'
    name_offset = 24                        # fixed offset: sizeof(dylib_command header)
    padded_len  = align8(len(path_bytes))
    cmdsize     = name_offset + padded_len
    path_padded = path_bytes.ljust(padded_len, b'\x00')

    header = struct.pack('<IIIIII',
        LC_LOAD_WEAK_DYLIB,  # cmd
        cmdsize,             # cmdsize
        name_offset,         # dylib.name.offset
        0,                   # dylib.timestamp
        0,                   # dylib.current_version
        0,                   # dylib.compatibility_version
    )
    return header + path_padded


def patch_slice(data: bytearray, slice_offset: int, dylib_path: str) -> None:
    """Inject the load command into one Mach-O slice."""
    magic = struct.unpack_from('<I', data, slice_offset)[0]
    if magic != MH_MAGIC_64:
        raise ValueError(f"Not a 64-bit little-endian Mach-O at offset {slice_offset:#x} "
                         f"(got {magic:#010x})")

    # Read header fields
    _, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags = \
        struct.unpack_from('<IIIIIII', data, slice_offset)

    lc_start = slice_offset + MACHO_HEADER_SIZE
    lc_end   = lc_start + sizeofcmds

    # Scan load commands to:
    #  a) check we haven't already injected this dylib
    #  b) find the offset of the first section to compute available padding
    first_section_offset = None
    pos = lc_start
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', data, pos)
        if cmdsize < 8:
            raise ValueError(f"Corrupt load command (cmdsize={cmdsize}) at {pos:#x}")

        if cmd == 0x19:  # LC_SEGMENT_64
            # segment_command_64 is 72 bytes; sections follow immediately after.
            # section_64.offset (at +48 within each section) is slice-relative.
            nsects = struct.unpack_from('<I', data, pos + 64)[0]
            for s in range(nsects):
                sec_off  = pos + 72 + s * 80        # sections start at cmd+72
                sec_foff = struct.unpack_from('<I', data, sec_off + 48)[0]
                if sec_foff > 0:
                    abs_foff = slice_offset + sec_foff   # slice-relative → absolute
                    if first_section_offset is None or abs_foff < first_section_offset:
                        first_section_offset = abs_foff

        elif cmd == LC_LOAD_WEAK_DYLIB:
            # Check if it's already our dylib
            name_offset_field = struct.unpack_from('<I', data, pos + 8)[0]
            existing_path = data[pos + name_offset_field:pos + cmdsize].rstrip(b'\x00').decode(errors='replace')
            if existing_path == dylib_path:
                print(f"  Already injected ({dylib_path}), skipping slice.")
                return

        pos += cmdsize

    if first_section_offset is None:
        raise ValueError("Could not find any section with a file offset.")

    padding_available = first_section_offset - lc_end
    new_lc = make_lc_load_weak_dylib(dylib_path)

    if len(new_lc) > padding_available:
        raise ValueError(
            f"Not enough padding: need {len(new_lc)} bytes, have {padding_available}. "
            "Cannot inject without growing the binary."
        )

    # Write new load command right after the existing ones
    data[lc_end: lc_end + len(new_lc)] = new_lc

    # Update ncmds and sizeofcmds in the Mach-O header
    new_ncmds      = ncmds + 1
    new_sizeofcmds = sizeofcmds + len(new_lc)
    struct.pack_into('<I', data, slice_offset + 16, new_ncmds)
    struct.pack_into('<I', data, slice_offset + 20, new_sizeofcmds)

    arch_name = {0x01000007: 'x86_64', 0x0100000C: 'arm64'}.get(cputype, hex(cputype))
    print(f"  [{arch_name}] injected {len(new_lc)}B, padding left: {padding_available - len(new_lc)}B")


def inject(binary_path: str, dylib_path: str) -> None:
    print(f"Target : {binary_path}")
    print(f"Dylib  : {dylib_path}")

    with open(binary_path, 'rb') as f:
        data = bytearray(f.read())

    magic = struct.unpack_from('>I', data, 0)[0]

    if magic == FAT_MAGIC:
        nfat = struct.unpack_from('>I', data, 4)[0]
        print(f"Fat binary with {nfat} arch(s)")
        for i in range(nfat):
            off = 8 + i * 20
            # Fat arch entries are big-endian
            cputype, _, arch_offset, arch_size, _ = struct.unpack_from('>iiIII', data, off)
            arch_name = {0x01000007: 'x86_64', 0x0100000C: 'arm64'}.get(cputype, hex(cputype))
            print(f"  Patching arch {i} ({arch_name}) at offset {arch_offset:#x} ...")
            patch_slice(data, arch_offset, dylib_path)
    else:
        # Might be little-endian single arch
        le_magic = struct.unpack_from('<I', data, 0)[0]
        if le_magic == MH_MAGIC_64:
            print("Single-arch 64-bit Mach-O")
            patch_slice(data, 0, dylib_path)
        else:
            raise ValueError(f"Unknown binary format (magic={magic:#010x})")

    with open(binary_path, 'wb') as f:
        f.write(data)

    print("Done.")


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <binary> <dylib_path>")
        sys.exit(1)
    inject(sys.argv[1], sys.argv[2])
