#!/usr/bin/env python3
"""Start the Uncharted Windows port with the MyVulkan Sikarugir wrapper.

That wrapper already loads KosmicKrisp. Game files stay where they are.
"""
import argparse
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys

import patch_probe

ROOT = Path(__file__).resolve().parent
DEFAULT_PORT = Path("/Volumes/S990PRO/uncharted-windows")
SUPPORT = Path.home() / "Library/Application Support/Uncharted MacOS"
DLL_NAME = "uncharted-crossover-tls.dll"
WRAPPER = Path("/Volumes/S990PRO/Sikarugir/MyVulkan.app")


# The game's allocator starts at the PS4 user-space base. macOS guards that
# address, so the runtime can only satisfy the request at COMPAT_MIN. The game
# then asserts that the address it got is the one it asked for.
GUEST_BASE_OLD = 0x1000000000
GUEST_BASE_NEW = 0x7000000000
# FrameBegin compares the GPU end-of-pipe tick and aborts when it is still
# zero. The port's own patch misses these builds. Spin on the same compare.
EOP_SPIN = bytes.fromhex("f390ebf1")


def linked_image_offset(data: bytes) -> int:
    magic, size, _entry, segments, relocs, names, _flags = struct.unpack_from("<8s6Q", data, 0)
    if magic != b"BBPROBE5":
        raise ValueError("not a linked probe image")
    offset = 56 + 8 + 32
    modules = struct.unpack_from("<Q", data, offset)[0]
    offset += 8 + modules * 56
    bindings = struct.unpack_from("<Q", data, offset)[0]
    offset += 8 + bindings * 24 + segments * 24 + names * 128 + relocs * 32
    if offset + size != len(data):
        raise ValueError("linked image header does not match its size")
    return offset


def prepare_guest(image: Path) -> None:
    data = bytearray(image.read_bytes())
    base = linked_image_offset(data)
    blob = data[base:]
    changed = False
    old_base = struct.pack("<Q", GUEST_BASE_OLD)
    new_base = struct.pack("<Q", GUEST_BASE_NEW)

    bumps = _find_all(blob, bytes.fromhex("c0c62d0000000000"))
    if len(bumps) != 1:
        raise ValueError(f"{image.name} has {len(bumps)} allocator bases")
    slot = bumps[0] + 8
    current = struct.unpack_from("<Q", blob, slot)[0]
    if current == GUEST_BASE_OLD:
        blob[slot:slot + 8] = new_base
        changed = True
    elif current != GUEST_BASE_NEW:
        raise ValueError(f"allocator base is {current:#x}")

    eops = []
    cursor = 0
    while True:
        found = blob.find(bytes.fromhex("4883bc08"), cursor)
        if found < 0:
            break
        cursor = found + 1
        if blob[found + 5:found + 14] == bytes.fromhex("0a000000753b488b05"):
            eops.append(found)
        elif blob[found + 5:found + 11] == bytes.fromhex("0a000000753b") and blob[found + 11:found + 15] == EOP_SPIN:
            eops.append(found)
    if len(eops) != 1:
        raise ValueError(f"{image.name} has {len(eops)} frame waits")
    check = eops[0]
    if blob[check + 11:check + 15] != EOP_SPIN:
        blob[check + 11:check + 15] = EOP_SPIN
        changed = True

    # Drake's Fortune stores the window base in its offset table. The later
    # games add that base to a relative pointer and then align the address.
    tables = _find_all(blob, bytes.fromhex("48c74108ffffff7f48ba") + old_base)
    for at in tables:
        blob[at + 10:at + 18] = new_base
        changed = True
    for at in range(len(blob) - 12):
        if blob[at] not in (0x48, 0x49) or not 0xB8 <= blob[at + 1] <= 0xBF:
            continue
        if blob[at + 2:at + 10] != old_base:
            continue
        if bytes.fromhex("4883e0f0") not in blob[at + 10:at + 32]:
            continue
        blob[at + 2:at + 10] = new_base
        changed = True

    if changed:
        data[base:] = blob
        image.write_bytes(data)


def _find_all(blob: bytes, pattern: bytes) -> list:
    found = []
    cursor = 0
    while True:
        at = blob.find(pattern, cursor)
        if at < 0:
            return found
        found.append(at)
        cursor = at + 1


def windows_path(path: Path) -> str:
    return "Z:" + str(path.resolve()).replace("/", "\\")


def write_wrapper_bat(port: Path, game: Path, exe: str, probe: Path) -> Path:
    drive = WRAPPER / "Contents/SharedSupport/prefix/drive_c"
    if not drive.is_dir():
        raise FileNotFoundError(f"No Wine prefix in {WRAPPER}")
    names = {"u1": "eboot.bin", "u2": "big2-ps4_Shipping.elf", "u3": "big3-ps4_Shipping.elf"}
    guest = names[exe]
    out = port / "out" / Path(guest).stem.split("-")[0]
    user = port / "user"
    bat = drive / "uncharted-launch.bat"
    lines = [
        "@echo off",
        f"set BB_PROBE={windows_path(probe)}",
        f"set BB_GAME_DIR={windows_path(game)}",
        f"set BB_EXE={guest}",
        f"set BB_DATA_DIR={windows_path(port)}",
        f"set BB_USER_DIR={windows_path(user)}",
        f"set BB_GPU_USER_DIR={windows_path(user)}",
        f"set BB_CONFIG={windows_path(port / 'bbport.ini')}",
        f"set BB_INPUT_CONFIG={windows_path(port / 'input.ini')}",
        f"set BB_LOADEXEC_FILE={windows_path(port / 'out' / 'loadexec.txt')}",
        "set BB_VBLANK_HZ=60",
        # A multi-megabyte scalar copy otherwise flushes an image back to its
        # buffer first. On this Vulkan stack that flush is the chapter hitch.
        "set BB_DEPTH_COPY_SYNC=0",
        "set BB_VELOCITY_PS=f4b18264",
        "set BB_UPSCALE_BEFORE_CS=aec539f0",
        "set BB_HUDLESS_PS=484cdbf5",
        "set BB_TIMEOUT=0",
        f"\"{windows_path(probe)}\" \"{windows_path(out / 'boot-linked.bin')}\" --content-profile \"{windows_path(out / 'content.bin')}\" --app0 \"{windows_path(game)}\" --user \"{windows_path(user)}\" --timeout 0 >> C:\\uncharted-out.txt 2>&1",
        "echo exit %ERRORLEVEL% >> C:\\uncharted-out.txt",
    ]
    bat.write_bytes(("\r\n".join(lines) + "\r\n").encode("ascii"))
    return bat


def build_tls_dll(destination: Path) -> None:
    compiler = shutil.which("x86_64-w64-mingw32-gcc")
    if not compiler:
        raise FileNotFoundError("x86_64-w64-mingw32-gcc is not installed")
    source = ROOT / "tls_adapter.c"
    subprocess.run(
        [compiler, "-shared", "-nostdlib", "-O2", str(source),
         "-lkernel32", "-Wl,--entry,DllMain", "-o", str(destination)],
        check=True)


def launch(port: Path, game: Path, exe: str) -> int:
    if not WRAPPER.is_dir():
        raise FileNotFoundError(WRAPPER)
    if not (port / "Uncharted.exe").is_file():
        raise FileNotFoundError(f"No Uncharted.exe in {port}")
    if not (game / "eboot.bin").is_file():
        raise FileNotFoundError(f"No eboot.bin in {game}")
    probe = port / "bin/bb-probe.exe"
    if not probe.is_file():
        raise FileNotFoundError(probe)

    dll = port / "bin" / DLL_NAME
    source_dll = ROOT / DLL_NAME
    if not source_dll.is_file() or source_dll.stat().st_mtime < (ROOT / "tls_adapter.c").stat().st_mtime:
        build_tls_dll(source_dll)
    if not dll.is_file() or dll.read_bytes() != source_dll.read_bytes():
        shutil.copy2(source_dll, dll)

    linked = port / "out" / {"u1": "eboot", "u2": "big2", "u3": "big3"}[exe] / "boot-linked.bin"
    prepare_guest(linked)
    patched = port / "bin/bb-probe-macos.exe"
    patch_probe.patch(probe, patched)
    write_wrapper_bat(port, game, exe, patched)
    plist = WRAPPER / "Contents/Info.plist"
    subprocess.run(
        ["plutil", "-replace", "Program Name and Path", "-string", "/uncharted-launch.bat", str(plist)],
        check=True)
    wine = WRAPPER / "Contents/SharedSupport/wine/bin/wineserver"
    environment = os.environ.copy()
    environment["WINEPREFIX"] = str(WRAPPER / "Contents/SharedSupport/prefix")
    environment["DYLD_FALLBACK_LIBRARY_PATH"] = str(WRAPPER / "Contents/Frameworks")
    subprocess.run([str(wine), "-k"], env=environment, check=False)
    print(f"Wrapper: {WRAPPER}")
    print(f"Game: {game} ({exe})")
    print("Log:  Contents/SharedSupport/Logs/LastRunWine.log inside the wrapper")
    subprocess.run(["open", "-W", str(WRAPPER)], check=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=Path, default=DEFAULT_PORT,
                        help="Folder containing Uncharted.exe and the game dump")
    parser.add_argument("--game", type=Path, default=None,
                        help="Game folder with eboot.bin (default: <port>/CUSA02343)")
    parser.add_argument("--exe", default="u1", choices=("u1", "u2", "u3"),
                        help="Which game to start: u1 Drake's Fortune, u2 Among Thieves, u3 Drake's Deception")
    args = parser.parse_args()
    port = args.port.expanduser().resolve()
    game = (args.game.expanduser().resolve() if args.game else port / "CUSA02343")
    try:
        return launch(port, game, args.exe)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Cannot launch: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
