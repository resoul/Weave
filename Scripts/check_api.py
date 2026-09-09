#!/usr/bin/env python3
"""Extract and compare Weave's public Swift symbol surface."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "weave-public-api.json"
TARGET = "arm64-apple-macosx14.0"


def run(command: list[str], env: dict[str, str]) -> str:
    result = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    return result.stdout


def normalized_symbol(symbol: dict) -> dict:
    return {
        "accessLevel": symbol.get("accessLevel"),
        "availability": symbol.get("availability", []),
        "declaration": "".join(item.get("spelling", "") for item in symbol["declarationFragments"]),
        "identifier": symbol["identifier"]["precise"],
        "kind": symbol["kind"]["identifier"],
        "pathComponents": symbol["pathComponents"],
    }


def extract() -> dict:
    pins = json.loads((ROOT / "toolchain.json").read_text())
    cache = ROOT / ".build/api-module-cache"
    cache.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = str(cache)
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(cache)
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env).strip()
    modules = ROOT / ".build/arm64-apple-macosx/debug/Modules"
    if not (modules / "Weave.swiftmodule").exists():
        raise SystemExit("Build Weave first (Scripts/check_all.py does this before API extraction).")
    with tempfile.TemporaryDirectory(prefix="weave-symbols-", dir=ROOT / ".build") as directory:
        run(
            [
                "xcrun", "swift-symbolgraph-extract", "-module-name", "Weave",
                "-I", str(modules), "-target", TARGET, "-sdk", sdk,
                "-output-dir", directory,
            ],
            env,
        )
        graph = json.loads((Path(directory) / "Weave.symbols.json").read_text())
    symbols = sorted((normalized_symbol(item) for item in graph["symbols"]), key=lambda item: item["identifier"])
    return {
        "module": "Weave",
        "platform": TARGET,
        "schemaVersion": 1,
        "symbols": symbols,
        "toolchain": {"sdk": pins["sdkVersion"], "swift": pins["swiftCompilerVersion"]},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--review-note", type=Path, help="tracked ADR or review note for a baseline update")
    args = parser.parse_args()
    baseline = json.loads(BASELINE.read_text())
    current = extract()
    if current == baseline:
        print(f"PASS public API ({len(current['symbols'])} symbols)")
        return 0

    old = {item["identifier"]: item for item in baseline["symbols"]}
    new = {item["identifier"]: item for item in current["symbols"]}
    removed = sorted(old.keys() - new.keys())
    added = sorted(new.keys() - old.keys())
    changed = sorted(identifier for identifier in old.keys() & new.keys() if old[identifier] != new[identifier])
    print(json.dumps({"added": added, "changed": changed, "removed": removed}, indent=2))
    if not args.update:
        print("FAIL public API differs; review it and update the baseline explicitly")
        return 1
    if args.review_note is None or not args.review_note.is_file():
        print("FAIL --update requires --review-note pointing to an existing ADR or migration note")
        return 1
    if (removed or changed) and "adr" not in args.review_note.name.lower():
        print("FAIL breaking API updates require an ADR file as --review-note")
        return 1
    BASELINE.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
    print(f"UPDATED public API after review in {args.review_note}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
