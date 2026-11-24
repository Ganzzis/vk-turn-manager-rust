"""Collect notices for the locked Rust crates in both iOS build graphs."""
import json
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
output = pathlib.Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
packages = {}
for target in ("aarch64-apple-ios", "aarch64-apple-ios-sim", "x86_64-apple-ios"):
    result = subprocess.check_output([
        "cargo", "metadata", "--locked", "--format-version", "1",
        "--manifest-path", str(root / "Core/Cargo.toml"), "--filter-platform", target,
    ])
    for package in json.loads(result)["packages"]:
        if package["source"]:
            packages[(package["name"], package["version"])] = package

with (output / "crates.txt").open("w", encoding="utf-8") as index:
    for (name, version), package in sorted(packages.items()):
        folder = pathlib.Path(package["manifest_path"]).parent
        licenses = [p for p in folder.iterdir() if p.is_file() and
                    p.name.upper().startswith(("LICEN", "COPYING", "NOTICE", "COPYRIGHT"))]
        if package["license_file"]:
            licenses.append(folder / package["license_file"])
        target = output / f"{name}-{version}"
        target.mkdir(exist_ok=True)
        for license_path in set(licenses):
            shutil.copyfile(license_path, target / license_path.name)
        if name == "boringtun":
            shutil.copyfile(root / "Licenses/BoringTun.BSD-3-Clause.txt", target / "LICENSE")
        source = package["repository"] or f"https://crates.io/crates/{name}/{version}"
        index.write(f"{name} {version}\t{package['license'] or 'see included notices'}\t{source}\n")
shutil.copyfile(root.parent / "LICENSE", output / "VKMobile-MIT.txt")
