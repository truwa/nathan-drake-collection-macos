#!/usr/bin/env python3
from __future__ import annotations

"""Start the Uncharted Windows port with Wine and KosmicKrisp.

The dump stays where the user put it. Prepared images, saves, and the Wine
prefix live under ~/Library/Application Support/Nathan Drake Collection. The
first launch downloads the latest WineHQ macOS build from Gcenx and creates
the prefix. A bundled engine is used when this file sits in the app. Otherwise
the x86-64 KosmicKrisp cache under dist/upstream is used.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

import patch_probe

ROOT = Path(__file__).resolve().parent
_PREVIOUS_SUPPORT = Path.home() / "Library/Application Support/Uncharted MacOS"
SUPPORT = Path.home() / "Library/Application Support/Nathan Drake Collection"


def adopt_support_folder() -> None:
    if _PREVIOUS_SUPPORT.exists() and not SUPPORT.exists():
        SUPPORT.parent.mkdir(parents=True, exist_ok=True)
        _PREVIOUS_SUPPORT.rename(SUPPORT)


adopt_support_folder()
DLL_NAME = "uncharted-crossover-tls.dll"
UPSTREAM = ROOT / "dist/upstream"
WINE_DIST = UPSTREAM / "wine-extract/Wine Devel.app/Contents/Resources/wine"
WINE_RELEASE_API = "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/latest"
INSTALLED_WINE = SUPPORT / "wine"
KOSMIC_DIST = UPSTREAM / "kosmickrisp-x86_64"
FALLBACK_PORT = Path("/Volumes/S990PRO/uncharted-windows")
INSTALLED_PORT = SUPPORT / "port"
PORT_RELEASE_API = "https://api.github.com/repos/Supermedo/uncharted_pc/releases/latest"
PORT_ASSET = "uncharted-windows.zip"

GAMES = (
    ("u1", "Drake's Fortune", "eboot.bin"),
    ("u2", "Among Thieves", "big2-ps4_Shipping.elf"),
    ("u3", "Drake's Deception", "big3-ps4_Shipping.elf"),
)
# NVIDIA's DLSS runtime is left out of the app. The Mac path uses TAA and FSR.
SKIP_RUNTIME = {
    "bbport_dlss.dll",
    "nvngx_dlss.dll",
    "nvngx_dlssg.dll",
    "bb-probe.exe",
    "bb-probe-macos.exe",
    "bb-probe-macos.exe.pre-bigbind",
    "bb-probe-macos.exe.pre-shadowblock",
    DLL_NAME,
}


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


def game_table():
    return {key: (title, filename) for key, title, filename in GAMES}


def resources_root() -> Path | None:
    chosen = os.environ.get("UNCHARTED_RESOURCES")
    if chosen:
        return Path(chosen)
    candidate = ROOT.parent
    if (candidate / "port/bin/bb-probe.exe").is_file():
        return candidate
    return None


def installed_wine() -> Path | None:
    if (INSTALLED_WINE / "bin/wine").is_file() and (INSTALLED_WINE / "bin/wineserver").is_file():
        return INSTALLED_WINE
    return None


def engine_parts(port_override: Path | None):
    resources = resources_root()
    if resources is not None:
        icd = resources / "vulkan/icd.d/kosmickrisp_icd.json"
        frameworks = resources.parent / "Frameworks"
        port = port_override or installed_port() or (resources / "port")
        kosmic = frameworks / "libvulkan_kosmickrisp.dylib"
    else:
        icd = KOSMIC_DIST / "kosmickrisp_icd.json"
        frameworks = KOSMIC_DIST
        port = port_override or installed_port() or FALLBACK_PORT
        kosmic = frameworks / "libvulkan_kosmickrisp.dylib"
    return icd, frameworks, kosmic, port


def resolve_engine(port_override: Path | None):
    wine_root = installed_wine()
    if wine_root is None:
        resources = resources_root()
        if resources is not None and (resources / "wine/bin/wine").is_file():
            wine_root = resources / "wine"
        elif resources is None and (WINE_DIST / "bin/wine").is_file():
            wine_root = WINE_DIST
        else:
            wine_root = download_wine()
    icd, frameworks, kosmic, port = engine_parts(port_override)
    wine = wine_root / "bin/wine"
    missing = [path for path in (wine, wine_root / "bin/wineserver", icd, kosmic, port / "bin/bb-probe.exe")
               if not path.is_file()]
    if missing:
        raise FileNotFoundError("Engine is incomplete: " + ", ".join(str(path) for path in missing))
    return wine_root, icd, frameworks, kosmic, port


def wine_environment(prefix: Path, icd: Path, frameworks: Path, kosmic: Path, wine_root: Path,
                     metal_hud: bool = False) -> dict:
    environment = os.environ.copy()
    for inherited in ("WINEPREFIX", "WINEDEBUG", "WINEDLLOVERRIDES", "WINEDLLPATH",
                      "WINEMSYNC", "SikarugirAppWine11", "CX_FWD_COMPAT_GL_CTX"):
        environment.pop(inherited, None)
    environment["WINEPREFIX"] = str(prefix)
    environment["WINEBOOT_HIDE_DIALOG"] = "1"
    # Rosetta hides AVX unless asked. The game's x86-64 code can use it.
    environment["ROSETTA_ADVERTISE_AVX"] = "1"
    # Gecko and Mono are not shipped. These overrides stop Wine from asking for them.
    environment["WINEDLLOVERRIDES"] = "mscoree,mshtml="
    spec = json.loads(icd.read_text(encoding="utf-8"))
    spec["ICD"]["library_path"] = str(kosmic)
    driver = SUPPORT / "kosmickrisp_icd.json"
    driver.write_text(json.dumps(spec), encoding="utf-8")
    environment["VK_DRIVER_FILES"] = str(driver)
    environment["VK_ICD_FILENAMES"] = str(driver)
    environment["DYLD_FALLBACK_LIBRARY_PATH"] = ":".join((
        str(wine_root / "lib"), str(frameworks), "/usr/lib", "/usr/libexec", "/usr/lib/system"))
    environment["PATH"] = str(wine_root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin"
    environment.pop("MTL_HUD_ENABLED", None)
    environment.pop("METAL_HUD", None)
    if metal_hud:
        environment["MTL_HUD_ENABLED"] = "1"
        environment["METAL_HUD"] = "1"
    return environment


def ensure_prefix(wine: Path, environment: dict) -> None:
    prefix = Path(environment["WINEPREFIX"])
    prefix.mkdir(parents=True, exist_ok=True)
    system32 = prefix / "drive_c/windows/system32"
    if (prefix / "system.reg").is_file() and system32.is_dir() and any(system32.iterdir()):
        return
    subprocess.run([str(wine), "wineboot", "--init"], env=environment, check=True)


def ensure_tls(runtime: Path) -> None:
    destination = runtime / DLL_NAME
    source = ROOT / DLL_NAME
    adapter = ROOT / "tls_adapter.c"
    if adapter.is_file() and (not source.is_file() or source.stat().st_mtime < adapter.stat().st_mtime):
        compiler = shutil.which("x86_64-w64-mingw32-gcc")
        if compiler:
            subprocess.run(
                [compiler, "-shared", "-nostdlib", "-O2", str(adapter),
                 "-lkernel32", "-Wl,--entry,DllMain", "-o", str(source)],
                check=True)
    if not source.is_file():
        raise FileNotFoundError(f"Missing {DLL_NAME}. Build it with x86_64-w64-mingw32-gcc.")
    if not destination.is_file() or destination.read_bytes() != source.read_bytes():
        shutil.copy2(source, destination)


def ensure_runtime(port: Path) -> Path:
    runtime = SUPPORT / "runtime"
    runtime.mkdir(parents=True, exist_ok=True)
    source_bin = port / "bin"
    wanted = set()
    for entry in source_bin.iterdir():
        if not entry.is_file() or entry.name in SKIP_RUNTIME:
            continue
        wanted.add(entry.name)
        link = runtime / entry.name
        target = entry.resolve()
        try:
            current = link.resolve() if link.is_symlink() else None
        except OSError:
            current = None
        if current == target:
            continue
        if link.exists() or link.is_symlink():
            link.unlink()
        link.symlink_to(target)
    shaders = port / "fsr4_shaders"
    if shaders.is_dir():
        link = runtime / "fsr4_shaders"
        if not link.is_symlink() or link.resolve() != shaders.resolve():
            if link.exists() or link.is_symlink():
                link.unlink()
            link.symlink_to(shaders.resolve())
        wanted.add("fsr4_shaders")
    for entry in runtime.iterdir():
        if entry.name in wanted or entry.name in (DLL_NAME, "bb-probe-macos.exe"):
            continue
        if entry.is_symlink():
            entry.unlink()
    ensure_tls(runtime)
    patched = runtime / "bb-probe-macos.exe"
    patch_probe.patch(source_bin / "bb-probe.exe", patched)
    return patched


def seed_settings(port: Path) -> tuple[Path, Path]:
    SUPPORT.mkdir(parents=True, exist_ok=True)
    config = SUPPORT / "bbport.ini"
    controls = SUPPORT / "input.ini"
    if not config.is_file() and (port / "bbport.ini").is_file():
        shutil.copy2(port / "bbport.ini", config)
    if not controls.is_file() and (port / "input.ini").is_file():
        shutil.copy2(port / "input.ini", controls)
    return config, controls


def prepare_image(port: Path, game: Path, filename: str) -> Path:
    out = SUPPORT / "out" / Path(filename).stem.split("-")[0]
    out.mkdir(parents=True, exist_ok=True)
    linked = out / "boot-linked.bin"
    scripts = port / "scripts"
    sources = [game / filename, *scripts.glob("*.py"), *(game / "sce_module").glob("*.prx")]
    fresh = linked.is_file() and all(linked.stat().st_mtime >= source.stat().st_mtime for source in sources)
    if not fresh:
        for script in ("prepare.py", "link_modules.py"):
            subprocess.run(
                [sys.executable, str(scripts / script), str(game), "--out", str(out), "--exe", filename],
                check=True)
    subprocess.run(
        [sys.executable, str(scripts / "content_profile.py"), str(game), "--out", str(out), "--sku", "full"],
        check=True)
    prepare_guest(linked)
    return out


def write_bat(prefix: Path, game: Path, filename: str, probe: Path, image: Path,
              config: Path, controls: Path, guest_argv: Path | None, fullscreen: bool) -> None:
    user = SUPPORT / "user"
    user.mkdir(parents=True, exist_ok=True)
    drive = prefix / "drive_c"
    drive.mkdir(parents=True, exist_ok=True)
    guest = f' --guest-argv "{windows_path(guest_argv)}"' if guest_argv else ""
    lines = [
        "@echo off",
        "echo bat-start > C:\\uncharted-out.txt",
        f"set BB_PROBE={windows_path(probe)}",
        f"set BB_GAME_DIR={windows_path(game)}",
        f"set BB_EXE={filename}",
        f"set BB_DATA_DIR={windows_path(SUPPORT)}",
        f"set BB_USER_DIR={windows_path(user)}",
        f"set BB_GPU_USER_DIR={windows_path(user)}",
        f"set BB_CONFIG={windows_path(config)}",
        f"set BB_INPUT_CONFIG={windows_path(controls)}",
        f"set BB_LOADEXEC_FILE={windows_path(SUPPORT / 'out' / 'loadexec.txt')}",
        "set BB_VBLANK_HZ=60",
        # The texture cache otherwise grows to the GPU heap budget, about
        # 15 GB here, and then spends every frame evicting images.
        "set BB_GC_BUDGET_MB=6144",
        # Leave depth copies synced. Skipping that wait removed the chapter
        # hitch, and it also left depth of field focused on the wrong plane.
        "set BB_VELOCITY_PS=f4b18264",
        "set BB_UPSCALE_BEFORE_CS=aec539f0",
        "set BB_HUDLESS_PS=484cdbf5",
        "set BB_TIMEOUT=0",
        "set BB_FULLSCREEN=1" if fullscreen else "set BB_FULLSCREEN=0",
        (f"\"{windows_path(probe)}\" \"{windows_path(image / 'boot-linked.bin')}\" "
         f"--content-profile \"{windows_path(image / 'content.bin')}\" "
         f"--app0 \"{windows_path(game)}\" --user \"{windows_path(user)}\" --timeout 0"
         f"{guest} >> C:\\uncharted-out.txt 2>&1"),
        "echo exit %ERRORLEVEL% >> C:\\uncharted-out.txt",
    ]
    (drive / "uncharted-launch.bat").write_bytes(("\r\n".join(lines) + "\r\n").encode("ascii"))


def available_games(dump: Path) -> list[tuple[str, str, bool]]:
    return [(key, title, (dump / filename).is_file()) for key, title, filename in GAMES]


def installed_port() -> Path | None:
    if (INSTALLED_PORT / "bin/bb-probe.exe").is_file() and (INSTALLED_PORT / "scripts/prepare.py").is_file():
        return INSTALLED_PORT
    return None


def port_version(port: Path) -> str:
    stamp = port / "PORT_VERSION"
    if stamp.is_file():
        text = stamp.read_text(encoding="utf-8", errors="replace").strip()
        if text:
            return text
    return "unknown"


def version_key(text: str) -> tuple:
    numbers = []
    for part in text.lstrip("vV").split("."):
        digits = ""
        for char in part:
            if char.isdigit():
                digits += char
            else:
                break
        if not digits:
            return ()
        numbers.append(int(digits))
    return tuple(numbers)


def active_port(port_override: Path | None) -> Path:
    _wine, _icd, _frameworks, _kosmic, port = resolve_engine(port_override)
    return port


def fetch_latest_port() -> tuple[str, str, str]:
    request = urllib.request.Request(PORT_RELEASE_API, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "uncharted-macos",
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)
    tag = str(payload.get("tag_name") or "").strip()
    assets = payload.get("assets") or []
    match = next((asset for asset in assets if asset.get("name") == PORT_ASSET), None)
    if match is None or not tag or not match.get("browser_download_url"):
        raise ValueError(f"The latest port release has no {PORT_ASSET}")
    digest = str(match.get("digest") or "")
    return tag, str(match["browser_download_url"]), digest


def _zip_prefix(archive: zipfile.ZipFile) -> str:
    names = [name.replace("\\", "/") for name in archive.namelist()]
    prefixes = []
    for name in names:
        if name.endswith("/"):
            continue
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"The zip has an unsafe path: {name}")
        if name.endswith("bin/bb-probe.exe"):
            prefixes.append(name[: -len("bin/bb-probe.exe")])
    if len(prefixes) != 1:
        raise ValueError("The zip is not an Uncharted Windows port build")
    prefix = prefixes[0]
    if prefix + "scripts/prepare.py" not in names:
        raise ValueError("The zip has no scripts/prepare.py")
    return prefix


def _copy_zip_tree(archive: zipfile.ZipFile, prefix: str, source: str, destination: Path,
                   skip: set[str] | None = None) -> None:
    skip = skip or set()
    source_prefix = prefix + source.strip("/") + "/"
    for info in archive.infolist():
        name = info.filename.replace("\\", "/")
        if info.is_dir() or not name.startswith(source_prefix):
            continue
        relative = Path(name[len(source_prefix):])
        if not relative.parts or ".." in relative.parts or relative.name in skip:
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with archive.open(info) as incoming, target.open("wb") as outgoing:
            shutil.copyfileobj(incoming, outgoing)


def install_port_zip(zip_path: Path, version: str | None = None, destination: Path | None = None) -> str:
    destination = destination or INSTALLED_PORT
    stamp = version.strip() if version else "custom"
    staging = destination.with_name(destination.name + ".new")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    try:
        with zipfile.ZipFile(zip_path) as archive:
            prefix = _zip_prefix(archive)
            names = {name.replace("\\", "/") for name in archive.namelist()}
            _copy_zip_tree(archive, prefix, "bin", staging / "bin", {
                "bbport_dlss.dll", "nvngx_dlss.dll", "nvngx_dlssg.dll",
            })
            _copy_zip_tree(archive, prefix, "scripts", staging / "scripts")
            if any(name.startswith(prefix + "fsr4_shaders/") for name in names):
                _copy_zip_tree(archive, prefix, "fsr4_shaders", staging / "fsr4_shaders")
            _copy_zip_tree(archive, prefix, "licenses", staging / "licenses", {"NVIDIA-DLSS-LICENSE.txt"})
            for filename in ("LICENSE", "README.txt", "bbport.ini", "input.ini"):
                member = prefix + filename
                if member in names:
                    target = staging / filename
                    with archive.open(member) as incoming, target.open("wb") as outgoing:
                        shutil.copyfileobj(incoming, outgoing)
            covers = staging / "covers"
            for game in ("u1.jpg", "u2.jpg", "u3.jpg"):
                member = prefix + "_internal/covers/" + game
                if member not in names:
                    continue
                covers.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as incoming, (covers / game).open("wb") as outgoing:
                    shutil.copyfileobj(incoming, outgoing)
        (staging / "PORT_VERSION").write_text(stamp.lstrip("vV") + "\n", encoding="utf-8")
        previous = destination.with_name(destination.name + ".old")
        if previous.exists():
            shutil.rmtree(previous)
        if destination.exists():
            destination.rename(previous)
        staging.rename(destination)
        if previous.exists():
            shutil.rmtree(previous)
    except Exception:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        raise
    return stamp.lstrip("vV")


def fetch_latest_wine() -> tuple[str, str]:
    request = urllib.request.Request(WINE_RELEASE_API, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "uncharted-macos",
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)
    tag = str(payload.get("tag_name") or "").strip().lstrip("vV")
    assets = payload.get("assets") or []
    match = next((asset for asset in assets
                  if str(asset.get("name") or "").startswith("wine-devel-")
                  and str(asset.get("name") or "").endswith("-osx64.tar.xz")), None)
    if match is None or not tag or not match.get("browser_download_url"):
        raise ValueError("The latest Wine release has no wine-devel macOS build")
    return tag, str(match["browser_download_url"])


def _wine_payload_skipped(relative: str) -> bool:
    path = relative.replace("\\", "/").strip("/")
    return (path == "share/wine/gecko" or path.startswith("share/wine/gecko/")
            or path == "share/wine/mono" or path.startswith("share/wine/mono/")
            or path.endswith("libMoltenVK.dylib")
            or path == "lib/wine/x86_64-unix/vulkan" or path.startswith("lib/wine/x86_64-unix/vulkan/"))


def _link_stays_inside(root: Path, link_path: Path, linkname: str) -> bool:
    if linkname.startswith("/"):
        return False
    normalized = os.path.normpath(str(link_path.parent / linkname))
    root_path = os.path.normpath(str(root))
    return normalized == root_path or normalized.startswith(root_path + os.sep)


def install_wine_archive(archive_path: Path, version: str, destination: Path | None = None) -> Path:
    destination = destination or INSTALLED_WINE
    staging = destination.with_name(destination.name + ".new")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    try:
        with tarfile.open(archive_path, "r:xz") as archive:
            root = ""
            for member in archive.getmembers():
                name = member.name.replace("\\", "/")
                if name.endswith("/bin/wine") or name.endswith("bin/wine"):
                    root = name[: -len("bin/wine")]
                    break
            if not root:
                raise ValueError("The Wine archive has no bin/wine")
            for member in archive.getmembers():
                name = member.name.replace("\\", "/")
                if not name.startswith(root):
                    continue
                relative = name[len(root):]
                if not relative or ".." in Path(relative).parts or _wine_payload_skipped(relative):
                    continue
                target = staging / relative
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.is_symlink() or target.exists():
                    target.unlink()
                if member.issym():
                    if _link_stays_inside(staging, target, member.linkname):
                        os.symlink(member.linkname, target)
                    continue
                if not member.isfile():
                    continue
                source = archive.extractfile(member)
                if source is None:
                    continue
                with source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
                os.chmod(target, member.mode & 0o777)
        if not (staging / "bin/wine").is_file() or not (staging / "bin/wineserver").is_file():
            raise ValueError("The Wine archive did not contain a usable build")
        previous = destination.with_name(destination.name + ".old")
        if previous.exists():
            shutil.rmtree(previous)
        if destination.exists():
            destination.rename(previous)
        staging.rename(destination)
        if previous.exists():
            shutil.rmtree(previous)
    except Exception:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        raise
    (destination.parent / "WINE_VERSION").write_text(version.lstrip("vV") + "\n", encoding="utf-8")
    return destination


def wine_version_text() -> str:
    stamp = SUPPORT / "WINE_VERSION"
    if stamp.is_file():
        text = stamp.read_text(encoding="utf-8", errors="replace").strip()
        if text:
            return text
    return "unknown"


def download_wine(destination: Path | None = None) -> Path:
    tag, url = fetch_latest_wine()
    print(f"status Downloading Wine {tag}", flush=True)
    request = urllib.request.Request(url, headers={"User-Agent": "uncharted-macos"})
    with tempfile.TemporaryDirectory(prefix="uncharted-wine-") as folder:
        archive = Path(folder) / f"wine-devel-{tag}-osx64.tar.xz"
        with urllib.request.urlopen(request, timeout=60) as response, archive.open("wb") as output:
            total = int(response.headers.get("Content-Length") or 0)
            received = 0
            reported = -1
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                output.write(chunk)
                received += len(chunk)
                if total:
                    percent = received * 100 // total
                    if percent != reported:
                        reported = percent
                        print(f"progress {percent}", flush=True)
        print("status Installing Wine", flush=True)
        installed = install_wine_archive(archive, tag, destination)
    print(f"installed wine {tag}", flush=True)
    return installed


def kill_wine() -> None:
    wine_root = installed_wine()
    if wine_root is None:
        resources = resources_root()
        if resources is not None and (resources / "wine/bin/wine").is_file():
            wine_root = resources / "wine"
        elif (WINE_DIST / "bin/wine").is_file():
            wine_root = WINE_DIST
    if wine_root is None:
        print("status Wine is not installed", flush=True)
        return
    environment = os.environ.copy()
    environment["WINEPREFIX"] = str(SUPPORT / "prefix")
    environment["PATH"] = str(wine_root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin"
    subprocess.run([str(wine_root / "bin/wineserver"), "-k"], env=environment, check=False)
    print("status Wine processes stopped", flush=True)


def setup_wine(force: bool = False) -> str:
    wine_root = None if force else installed_wine()
    if wine_root is None:
        wine_root = download_wine()
    version = wine_version_text()
    icd, frameworks, kosmic, _port = engine_parts(None)
    prefix = SUPPORT / "prefix"
    environment = wine_environment(prefix, icd, frameworks, kosmic, wine_root)
    system32 = prefix / "drive_c/windows/system32"
    if not ((prefix / "system.reg").is_file() and system32.is_dir() and any(system32.iterdir())):
        print("status Creating the Wine environment", flush=True)
        ensure_prefix(wine_root / "bin/wine", environment)
    print(f"ready {version}", flush=True)
    return version


def download_port(destination: Path | None = None) -> str:
    tag, url, _digest = fetch_latest_port()
    print(f"status Downloading Windows port {tag}", flush=True)
    request = urllib.request.Request(url, headers={"User-Agent": "uncharted-macos"})
    with tempfile.TemporaryDirectory(prefix="uncharted-port-") as folder:
        archive = Path(folder) / PORT_ASSET
        with urllib.request.urlopen(request, timeout=60) as response, archive.open("wb") as output:
            total = int(response.headers.get("Content-Length") or 0)
            received = 0
            reported = -1
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                output.write(chunk)
                received += len(chunk)
                if total:
                    percent = received * 100 // total
                    if percent != reported:
                        reported = percent
                        print(f"progress {percent}", flush=True)
        print("status Installing the Windows port", flush=True)
        installed = install_port_zip(archive, tag, destination)
    print(f"installed {installed}", flush=True)
    return installed


def recorded_exit(prefix: Path, process_code: int) -> int:
    log = prefix / "drive_c/uncharted-out.txt"
    if not log.is_file():
        return process_code
    for line in reversed(log.read_text(encoding="utf-8", errors="replace").splitlines()):
        if line.startswith("exit "):
            try:
                return int(line.split()[1])
            except (IndexError, ValueError):
                return process_code
    return process_code


def launch(dump: Path, exe: str, port_override: Path | None, fullscreen: bool, metal_hud: bool) -> int:
    _title, filename = game_table()[exe]
    if not (dump / "eboot.bin").is_file():
        raise FileNotFoundError(f"No eboot.bin in {dump}")
    if not (dump / filename).is_file():
        raise FileNotFoundError(f"No {filename} in {dump}")
    wine_root, icd, frameworks, kosmic, port = resolve_engine(port_override)
    if not (port / "scripts/prepare.py").is_file():
        raise FileNotFoundError(f"No prepare.py in {port / 'scripts'}")
    SUPPORT.mkdir(parents=True, exist_ok=True)
    prefix = SUPPORT / "prefix"
    environment = wine_environment(prefix, icd, frameworks, kosmic, wine_root, metal_hud)
    wine = wine_root / "bin/wine"
    wineserver = wine_root / "bin/wineserver"

    def stop(_signum, _frame):
        subprocess.run([str(wineserver), "-k"], env=environment, check=False)
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    ensure_prefix(wine, environment)
    probe = ensure_runtime(port)
    config, controls = seed_settings(port)
    print(f"Engine: {wine_root}", flush=True)
    print(f"Game: {dump} ({exe})", flush=True)
    print(f"Log: {prefix / 'drive_c' / 'uncharted-out.txt'}", flush=True)
    guest_argv = None
    # 101 is the port's sceSystemServiceLoadExec: the collection asked for another executable.
    while True:
        if not (dump / filename).is_file():
            raise FileNotFoundError(f"No {filename} in {dump}")
        image = prepare_image(port, dump, filename)
        loadexec = SUPPORT / "out" / "loadexec.txt"
        loadexec.unlink(missing_ok=True)
        write_bat(prefix, dump, filename, probe, image, config, controls, guest_argv, fullscreen)
        subprocess.run([str(wineserver), "-k"], env=environment, check=False)
        completed = subprocess.run([str(wine), "cmd", "/c", r"C:\uncharted-launch.bat"], env=environment)
        code = recorded_exit(prefix, completed.returncode)
        if code != 101 or not loadexec.is_file():
            return code
        lines = loadexec.read_text(encoding="utf-8", errors="replace").splitlines()
        target = Path(lines[0].replace("\\", "/")).name if lines else ""
        if not target:
            raise ValueError("The game asked for another executable without a name.")
        print(f"Switching to {target}", flush=True)
        filename = target
        guest_argv = SUPPORT / "out" / "guest-argv.txt"
        guest_argv.write_text("\n".join(lines) + "\n", encoding="utf-8")


def check_engine(port_override: Path | None) -> int:
    wine_root, icd, frameworks, kosmic, port = resolve_engine(port_override)
    SUPPORT.mkdir(parents=True, exist_ok=True)
    prefix = SUPPORT / "prefix"
    environment = wine_environment(prefix, icd, frameworks, kosmic, wine_root)
    ensure_prefix(wine_root / "bin/wine", environment)
    print(f"Engine: {wine_root}")
    print(f"Port: {port}")
    print(f"KosmicKrisp: {kosmic}")
    print(f"Prefix: {prefix}")
    subprocess.run([str(wine_root / "bin/wine"), "--version"], env=environment, check=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dump", type=Path, default=None,
                        help="Folder with eboot.bin, big2-ps4_Shipping.elf, and big3-ps4_Shipping.elf")
    parser.add_argument("--port", type=Path, default=None,
                        help="Port runtime folder (default: the copy inside the app)")
    parser.add_argument("--exe", default="u1", choices=tuple(key for key, _title, _name in GAMES),
                        help="Which game to start")
    parser.add_argument("--display", default="window", choices=("window", "fullscreen"),
                        help="Start in a window or full screen")
    parser.add_argument("--metal-hud", action="store_true", help="Show the Metal performance HUD")
    parser.add_argument("--list", action="store_true", help="Print which games are in the dump")
    parser.add_argument("--check", action="store_true", help="Create the Wine prefix and print the engine")
    parser.add_argument("--setup-wine", action="store_true",
                        help="Download Wine if needed and create the prefix")
    parser.add_argument("--update-wine", action="store_true",
                        help="Download the latest Wine again and keep the prefix")
    parser.add_argument("--kill-wine", action="store_true",
                        help="Stop the Wine processes for this launcher")
    parser.add_argument("--check-port", action="store_true",
                        help="Print the installed Windows port and the latest release")
    parser.add_argument("--download-port", action="store_true",
                        help="Download the latest Windows port and install it")
    parser.add_argument("--install-port", type=Path, default=None,
                        help="Install a downloaded uncharted-windows.zip")
    parser.add_argument("--port-version", default=None,
                        help="Version stamp to write when installing a zip")
    args = parser.parse_args()
    try:
        if args.kill_wine:
            kill_wine()
            return 0
        if args.setup_wine or args.update_wine:
            setup_wine(force=args.update_wine)
            return 0
        if args.check:
            return check_engine(args.port.expanduser().resolve() if args.port else None)
        if args.check_port or args.download_port or args.install_port:
            override = args.port.expanduser().resolve() if args.port else None
            if args.download_port:
                download_port()
                return 0
            if args.install_port:
                installed = install_port_zip(args.install_port.expanduser().resolve(), args.port_version)
                print(f"installed {installed}")
                return 0
            current = port_version(active_port(override))
            tag, url, _digest = fetch_latest_port()
            latest = tag.lstrip("vV")
            newer = version_key(latest) > version_key(current)
            print(f"{current}\t{latest}\t{url if newer else ''}")
            return 0
        if args.dump is None:
            args.dump = FALLBACK_PORT / "CUSA02343"
        dump = args.dump.expanduser().resolve()
        if args.list:
            for key, title, present in available_games(dump):
                print(f"{key}\t{title}\t{'yes' if present else 'no'}")
            return 0
        port = args.port.expanduser().resolve() if args.port else None
        return launch(dump, args.exe, port, args.display == "fullscreen", args.metal_hud)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Cannot launch: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
