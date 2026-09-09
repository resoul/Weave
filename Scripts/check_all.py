#!/usr/bin/env python3
"""Run the complete local/CI quality gate."""

import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--matrix", action="store_true", help="include all generic Xcode destinations")
args = parser.parse_args()

commands = [
    ["python3", "Scripts/check_policy.py"],
    ["python3", "Scripts/test_policy.py"],
    ["python3", "Scripts/verify_bootstrap.py", *(["--matrix"] if args.matrix else [])],
    ["python3", "Scripts/check_api.py"],
]

for command in commands:
    print("RUN " + " ".join(command), flush=True)
    result = subprocess.run(command, cwd=ROOT)
    if result.returncode:
        raise SystemExit(result.returncode)
print("PASS all quality gates")
