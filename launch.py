#!/usr/bin/env python3
from __future__ import annotations

"""Start the BilalReloaded Nathan Drake Collection runtime on this Mac.

The dump stays where the user put it. Saves and probe-*.ini live under
~/Library/Application Support/NathanDrakeCollection/user.
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

ROOT = Path(__file__).resolve().parent
SUPPORT = Path.home() / "Library/Application Support/NathanDrakeCollection"
USER = SUPPORT / "user"

GAMES = (
    ("u1", "Drake's Fortune", "eboot.bin", "u1data"),
    ("u2", "Among Thieves", "big2-ps4_Shipping.elf", "u2data"),
    ("u3", "Drake's Deception", "big3-ps4_Shipping.elf", "u3data"),
)
GAME_TABLE = {key: (title, filename) for key, title, filename, _data in GAMES}

INI_DEFAULTS = {
    "display_mode": "windowed",
    "vsync": "1",
    "fps_limit": "60",
    "frames_queued": "1",
    "async_shaders": "1",
    "fsr1": "0",
    "rcas": "1",
    "rcas_strength": "75",
    "show_fps": "0",
    "upscaler": "off",
    "preset": "0",
}
TEMPORAL = ("fsr3", "fsr4", "fsr411")
UPSCALE_SCALES = {"quality": 1.5, "balanced": 1.7, "performance": 2.0, "ultra": 3.0}
UPSCALE_PRESET = {"off": "0", "quality": "1", "balanced": "2", "performance": "3", "ultra": "4"}
ASPECT_WIDTHS = {"16:10": 16 / 10, "16:9": 16 / 9, "21:9": 64 / 27, "32:9": 32 / 9}
UPDATE_SUFFIXES = ("-patch", "-update", "_patch", "_update")


def is_native(path: Path) -> bool:
    return (path / "gow3_pc/out/gow3-probe").is_file() and (path / "tools/probe_uncharted.py").is_file()


def native_root() -> Path | None:
    env = os.environ.get("UNCHARTED_NATIVE", "").strip()
    candidates = []
    if env:
        candidates.append(Path(env).expanduser())
    if ROOT.name == "engine":
        candidates.append(ROOT.parent / "native")
    here = ROOT
    for _ in range(8):
        candidates.append(here / "native")
        candidates.append(here / "uncharted-bilal-work/bilal")
        here = here.parent
    seen: set[Path] = set()
    for path in candidates:
        try:
            path = path.expanduser().resolve()
        except OSError:
            continue
        if path in seen:
            continue
        seen.add(path)
        if is_native(path):
            return path
    return None


def play_root() -> Path:
    """Writable copy of the bundled runtime so boot files do not break the app signature."""
    source = native_root()
    if source is None:
        raise FileNotFoundError("The native BilalReloaded runtime is not installed in this app.")
    stamp_file = source / ".bundle-stamp"
    try:
        stamp = stamp_file.read_text(encoding="utf-8").strip()
    except OSError:
        stamp = str(source)
    dest = SUPPORT / "runtime"
    marker = dest / ".bundle-stamp"
    if is_native(dest):
        try:
            if marker.read_text(encoding="utf-8").strip() == stamp:
                return dest
        except OSError:
            pass
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(source, dest, symlinks=True, ignore=shutil.ignore_patterns("analysis", "*.dSYM", "*.log"))
    marker.write_text(stamp + "\n", encoding="utf-8")
    return dest


def sfo_value(folder: Path, key: str) -> str | None:
    path = folder / "sce_sys/param.sfo"
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if data[:4] != b"\x00PSF":
        return None
    _magic, _version, key_table, data_table, count = struct.unpack_from("<4sIIII", data, 0)
    for index in range(count):
        name_off, fmt, length, _max_len, data_off = struct.unpack_from("<HHIII", data, 20 + index * 16)
        name = data[key_table + name_off:].split(b"\x00", 1)[0].decode("ascii", "replace")
        if name != key:
            continue
        raw = data[data_table + data_off:data_table + data_off + length]
        if fmt == 0x0204:
            return raw.split(b"\x00", 1)[0].decode("utf-8", "replace")
        if fmt == 0x0404:
            return str(struct.unpack_from("<I", raw)[0])
        return raw.split(b"\x00", 1)[0].decode("utf-8", "replace")
    return None


def resolve_dump(path: Path) -> Path:
    if (path / "eboot.bin").is_file():
        return path
    try:
        children = [child for child in path.iterdir() if (child / "eboot.bin").is_file()]
    except OSError:
        children = []
    return children[0] if len(children) == 1 else path


def resolve_update(path: Path | None) -> Path | None:
    if path is None:
        return None
    if (path / "eboot.bin").is_file() and (path / "sce_sys/param.sfo").is_file():
        return path
    nested = path / "uroot"
    if (nested / "eboot.bin").is_file() and (nested / "sce_sys/param.sfo").is_file():
        return nested
    return None


def find_sibling_update(game: Path) -> Path | None:
    title = game.parent if game.name.lower() == "uroot" else game
    names = {title.name.lower() + suffix for suffix in UPDATE_SUFFIXES}
    try:
        siblings = [entry for entry in title.parent.iterdir() if entry.name.lower() in names]
    except OSError:
        return None
    for entry in siblings:
        found = resolve_update(entry / "uroot") or resolve_update(entry)
        if found:
            return found
    return None


def game_version(game: Path) -> str:
    return sfo_value(game, "APP_VER") or ""


def inspect(dump: Path, update: Path | None) -> int:
    dump = resolve_dump(dump)
    native = native_root()
    print(f"native\t{native}" if native else "native\t")
    print(f"game\t{dump}")
    if not (dump / "eboot.bin").is_file():
        print("error\tThat folder has no eboot.bin.")
        return 1
    chosen = resolve_update(update) if update else find_sibling_update(dump)
    if chosen:
        print(f"update\t{chosen}")
        print(f"version\t{game_version(chosen) or game_version(dump) or '?'}")
    else:
        print("update\t")
        print(f"version\t{game_version(dump) or '?'}")
    print(f"title\t{sfo_value(dump, 'TITLE_ID') or ''}")
    for key, title, filename, data in GAMES:
        missing = []
        if not (dump / filename).is_file():
            missing.append(filename)
        if not (dump / data).is_dir():
            missing.append(data)
        print(f"{key}\t{title}\t{'yes' if not missing else 'no'}\t{', '.join(missing)}")
    return 0


def load_settings(path: Path | None) -> dict:
    values = {
        "display_mode": "windowed",
        "vsync": "1",
        "fps_limit": "60",
        "frames_queued": "1",
        "async_shaders": "1",
        "upscaler": "off",
        "upscale": "off",
        "aa": "off",
        "rcas": "1",
        "rcas_strength": "75",
        "show_fps": "0",
        "resolution": "1920x1080",
        "aspect": "16:9",
        "multithreaded": False,
        "job_sleep": "on",
        "language": "1",
        "unlock": False,
        "metal_hud": False,
        "cheats": [],
    }
    if path is None or not path.is_file():
        return values
    try:
        stored = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return values
    if isinstance(stored, dict):
        values.update(stored)
    return values


def aspect_resolution(resolution: str, aspect: str) -> str:
    width, height = (int(part) for part in resolution.split("x"))
    if aspect not in ASPECT_WIDTHS or aspect == "16:9":
        return resolution
    if ASPECT_WIDTHS[aspect] < 16 / 9:
        height = int(round(width / ASPECT_WIDTHS[aspect] / 4)) * 4
    elif aspect == "21:9" and height in (1080, 1440, 1600):
        width = {1080: 2560, 1440: 3440, 1600: 3840}[height]
    else:
        width = int(round(height * ASPECT_WIDTHS[aspect] / 16)) * 16
    return f"{width}x{height}"


def game_sizes(settings: dict) -> tuple[str, str | None]:
    output = aspect_resolution(settings.get("resolution", "1920x1080"), settings.get("aspect", "16:9"))
    upscaling = settings.get("upscaler", "off")
    scale = UPSCALE_SCALES.get(settings.get("upscale", "off"))
    if not scale or (upscaling not in TEMPORAL and upscaling != "fsr1"):
        return output, None
    width, height = (int(part) for part in output.split("x"))
    render = f"{max(16, round(width / scale / 16) * 16)}x{max(4, round(height / scale / 4) * 4)}"
    return render, output


def ini_updates(settings: dict) -> dict[str, str]:
    upscaling = settings.get("upscaler", "off")
    aa = settings.get("aa", "off")
    if aa not in ("off", "taa"):
        aa = "off"
    if upscaling in TEMPORAL:
        upscaler = upscaling
        fsr1 = "0"
    elif upscaling == "fsr1":
        upscaler = aa
        fsr1 = "1"
    else:
        upscaler = aa
        fsr1 = "0"
    render, output = game_sizes(settings)
    display = settings.get("display_mode", "windowed")
    if display not in ("windowed", "borderless", "fullscreen"):
        display = "windowed"
    strength = str(settings.get("rcas_strength", "75"))
    rcas = "0" if settings.get("rcas", "1") in (0, "0", False, "off") or strength == "off" else "1"
    if strength == "off":
        strength = "75"
    fps = str(settings.get("fps_limit", "60"))
    if fps not in {"30", "40", "45", "50", "55", "60", "75", "90", "100", "120"}:
        fps = "60"
    queued = str(settings.get("frames_queued", "1"))
    if queued not in {"0", "1", "2"}:
        queued = "1"
    updates = dict(INI_DEFAULTS)
    updates.update({
        "display_mode": display,
        "vsync": "1" if settings.get("vsync", "1") not in (0, "0", False) else "0",
        "fps_limit": fps,
        "frames_queued": queued,
        "async_shaders": "1" if settings.get("async_shaders", "1") not in (0, "0", False) else "0",
        "fsr1": fsr1,
        "rcas": rcas,
        "rcas_strength": strength,
        "show_fps": "1" if settings.get("show_fps", "0") in (1, "1", True) else "0",
        "upscaler": upscaler,
        "preset": UPSCALE_PRESET.get(settings.get("upscale", "off"), "0"),
        "output_res": output or render,
    })
    return updates


def write_ini(game: str, updates: dict[str, str]) -> Path:
    USER.mkdir(parents=True, exist_ok=True)
    path = USER / f"probe-{game}.ini"
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        lines = ["# Uncharted settings (launcher and in-game menu: Insert / R3+L2)"]
    done: set[str] = set()
    for index, line in enumerate(lines):
        if "=" in line and not line.lstrip().startswith("#"):
            key = line.split("=", 1)[0].strip()
            if key in updates:
                lines[index] = f"{key}={updates[key]}"
                done.add(key)
    lines += [f"{key}={value}" for key, value in updates.items() if key not in done]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def launch(dump: Path, update: Path | None, exe: str, settings: dict) -> int:
    native = play_root()
    dump = resolve_dump(dump)
    _title, filename = GAME_TABLE[exe]
    if not (dump / "eboot.bin").is_file():
        raise FileNotFoundError(f"No eboot.bin in {dump}")
    if not (dump / filename).is_file():
        raise FileNotFoundError(f"No {filename} in {dump}")
    USER.mkdir(parents=True, exist_ok=True)
    SUPPORT.mkdir(parents=True, exist_ok=True)
    log = SUPPORT / "native-boot.log"
    updates = ini_updates(settings)
    for key, _title, _filename, _data in GAMES:
        write_ini(key, updates)
    env = os.environ.copy()
    env.setdefault("ROSETTA_ADVERTISE_AVX", "1")
    env["UNCHARTED_USER_DIR"] = str(USER)
    env["UNCHARTED_DIAGNOSTICS"] = "0" if settings.get("log_level") == "errors" else "1"
    env["UNCHARTED_JOB_SLEEP"] = "0" if settings.get("job_sleep") == "off" else "1"
    env["UNCHARTED_LANGUAGE"] = str(settings.get("language", "1"))
    env["UNCHARTED_UNLOCK"] = "1" if settings.get("unlock") in (True, 1, "1") else "0"
    cheats = settings.get("cheats") or []
    if isinstance(cheats, str):
        cheats = [part for part in cheats.split(",") if part]
    env["UNCHARTED_CHEATS"] = ",".join(cheats)
    chosen = resolve_update(update) if update else None
    if chosen:
        env["UNCHARTED_UPDATE"] = str(chosen)
    elif settings.get("no_update") in (True, 1, "1"):
        env["UNCHARTED_UPDATE"] = "0"
    env.pop("GOW3_VBLANK_HZ", None)
    render, output = game_sizes(settings)
    multithreaded = "1" if settings.get("multithreaded") in (True, 1, "1") else "0"
    for key, _title, _filename, _data in GAMES:
        env[f"UNCHARTED_RESOLUTION_{key.upper()}"] = render
        if output:
            env[f"UNCHARTED_OUTPUT_RES_{key.upper()}"] = output
        else:
            env.pop(f"UNCHARTED_OUTPUT_RES_{key.upper()}", None)
        env[f"UNCHARTED_MULTITHREADED_{key.upper()}"] = multithreaded
    if settings.get("metal_hud") in (True, 1, "1"):
        env["MTL_HUD_ENABLED"] = "1"
    icd = native / "gow3_pc/out/kosmickrisp_mesa_icd.json"
    if icd.is_file():
        env.setdefault("VK_DRIVER_FILES", str(icd))
    command = [
        sys.executable, "-u", str(native / "tools/probe_uncharted.py"),
        "--boot", "--seconds", "0", "--game", str(dump), "--executable", filename,
    ]
    print(f"Engine: native {native / 'gow3_pc/out/gow3-probe'}", flush=True)
    print(f"Game: {dump} ({exe})", flush=True)
    if chosen:
        print(f"Update: {chosen}", flush=True)
    print(f"Log: {log}", flush=True)
    with log.open("wb") as output_file:
        process = subprocess.Popen(command, cwd=str(native), env=env,
                                   stdout=output_file, stderr=subprocess.STDOUT)

        def stop(_signum, _frame):
            process.terminate()
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
            sys.exit(0)

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        return process.wait()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dump", type=Path, help="Game folder with eboot.bin and sce_sys")
    parser.add_argument("--update", type=Path, default=None, help="Optional extracted 1.02 folder")
    parser.add_argument("--exe", default="u1", choices=tuple(GAME_TABLE))
    parser.add_argument("--settings", type=Path, default=None, help="JSON settings from the Mac launcher")
    parser.add_argument("--inspect", action="store_true", help="Print dump, update, and native status")
    parser.add_argument("--native-status", action="store_true", help="Print whether the native probe is present")
    parser.add_argument("--no-update", action="store_true", help="Do not overlay a 1.02 folder")
    args = parser.parse_args()
    try:
        if args.native_status:
            native = native_root()
            print(f"native\t{native}" if native else "missing")
            return 0 if native else 1
        if args.dump is None:
            raise SystemExit("Choose the game folder.")
        dump = args.dump.expanduser().resolve()
        update = args.update.expanduser().resolve() if args.update else None
        if args.inspect:
            return inspect(dump, update)
        settings = load_settings(args.settings)
        if args.no_update:
            settings["no_update"] = True
            update = None
        return launch(dump, update, args.exe, settings)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Cannot launch: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
