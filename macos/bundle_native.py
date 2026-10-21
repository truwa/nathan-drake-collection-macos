"""Copy gow3-probe, KosmicKrisp, and their libraries into a self-contained app runtime."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def output(*command: str) -> str:
    return subprocess.check_output(command, text=True)


def run(*command: str) -> None:
    subprocess.check_call(command)


def resolve_library(name: str, loader: Path, prefix: Path) -> Path | None:
    if name.startswith(("/usr/lib/", "/System/Library/")):
        return None
    prefix = prefix.resolve()
    if name.startswith("@rpath/"):
        candidates = [prefix / "lib" / name.removeprefix("@rpath/")]
    elif name.startswith("@loader_path/"):
        candidates = [Path(loader).parent / name.removeprefix("@loader_path/")]
    else:
        candidates = [Path(name)]
    for candidate in candidates:
        try:
            candidate = candidate.resolve()
        except OSError:
            continue
        if candidate.is_file() and str(candidate).startswith(str(prefix) + os.sep):
            return candidate
    raise ValueError(f"Missing or external dependency: {name} (loaded by {loader})")


def unsigned(path: Path) -> None:
    subprocess.run(["codesign", "--remove-signature", str(path)], check=False, capture_output=True)


def set_rpaths(path: Path, desired: list[str]) -> None:
    lines = output("otool", "-l", str(path)).splitlines()
    rpaths: list[str] = []
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH" and index + 2 < len(lines):
            rpaths.append(lines[index + 2].strip().removeprefix("path ").split(" (offset", 1)[0])
    for rpath in set(rpaths):
        subprocess.run(["install_name_tool", "-delete_rpath", rpath, str(path)], check=False)
    for rpath in desired:
        run("install_name_tool", "-add_rpath", rpath, str(path))


def relocate(out: Path, prefix: Path) -> None:
    lib = out / "lib"
    lib.mkdir(parents=True, exist_ok=True)
    gpu = out / "gpu" / "libgow3gpu.dylib"
    probe = out / "gow3-probe"
    krisp = out / "vulkan" / "libvulkan_kosmickrisp.dylib"
    queue = [probe, gpu, krisp]
    fingerprints: dict[str, bytes] = {}
    originals: dict[Path, Path] = {}
    for file in queue:
        if not file.is_file():
            raise FileNotFoundError(file)
        if "x86_64" not in output("lipo", "-archs", str(file)).split():
            raise ValueError(f"Runtime library is not x86-64: {file}")
        unsigned(file)
        own_id = [line.strip() for line in output("otool", "-D", str(file)).splitlines()[1:]]
        for line in output("otool", "-L", str(file)).splitlines()[1:]:
            name = line.strip().split(" (", 1)[0]
            if name in own_id:
                continue
            if name.endswith("/libgow3gpu.dylib") or name.endswith("@rpath/libgow3gpu.dylib"):
                replacement = "@rpath/libgow3gpu.dylib"
            else:
                source = resolve_library(name, originals.get(file, file), prefix)
                if source is None:
                    continue
                digest = hashlib.sha256(source.read_bytes()).digest()
                previous = fingerprints.get(source.name)
                if previous is not None and previous != digest:
                    raise ValueError(f"Conflicting libraries named {source.name}")
                if previous is None:
                    target = lib / source.name
                    shutil.copy2(source, target)
                    target.chmod(0o755)
                    unsigned(target)
                    fingerprints[source.name] = digest
                    originals[target] = source
                    queue.append(target)
                replacement = "@rpath/" + source.name
            run("install_name_tool", "-change", name, replacement, str(file))
        if file.suffix == ".dylib":
            run("install_name_tool", "-id", "@rpath/" + file.name, str(file))
        if file.parent == lib:
            desired = ["@loader_path"]
        elif file.suffix == ".dylib":
            desired = ["@loader_path/../lib"]
        else:
            desired = ["@executable_path/lib", "@executable_path/gpu"]
        set_rpaths(file, desired)


def configure_vulkan(out: Path) -> None:
    loaders = list((out / "lib").glob("libvulkan.1.*.dylib"))
    driver = out / "vulkan" / "libvulkan_kosmickrisp.dylib"
    if len(loaders) != 1 or not loaders[0].is_file() or not driver.is_file():
        raise ValueError("Vulkan package requires one versioned loader and the KosmicKrisp driver")
    for name in ("libvulkan.dylib", "libvulkan.1.dylib"):
        link = out / "lib" / name
        if link.exists() or link.is_symlink():
            link.unlink()
        link.symlink_to(loaders[0].name)
    manifest = {
        "file_format_version": "1.0.0",
        "ICD": {"library_path": "./" + driver.name, "api_version": "1.3.0"},
    }
    text = json.dumps(manifest) + "\n"
    (driver.parent / "kosmickrisp_mesa_icd.json").write_text(text, encoding="utf-8")
    alias = {
        "file_format_version": "1.0.0",
        "ICD": {"library_path": "./vulkan/" + driver.name, "api_version": "1.3.0"},
    }
    (out / "kosmickrisp_mesa_icd.json").write_text(json.dumps(alias) + "\n", encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: bundle_native.py <gow3_pc/out> <deps-prefix>", file=sys.stderr)
        return 2
    out = Path(sys.argv[1])
    prefix = Path(sys.argv[2])
    relocate(out, prefix)
    configure_vulkan(out)
    print(f"Bundled native runtime in {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
