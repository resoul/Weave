#!/usr/bin/env python3
"""Prove that every T-68 policy guard rejects its negative fixture."""

from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CASES = {
    "platform-import": "PLATFORM_IMPORT",
    "platform-condition": "PLATFORM_CONDITION",
    "unsafe-concurrency": "UNSAFE_CONCURRENCY",
    "cocoa-lifecycle": "COCOA_LIFECYCLE",
    "secret": "SECRET_GITHUB_TOKEN",
    "markdown-link": "MARKDOWN_LINK",
    "public-documentation": "PUBLIC_DOCUMENTATION",
    "force-operation": "FORCE_OPERATION",
}


with tempfile.TemporaryDirectory(prefix="weave-policy-") as temporary:
    temporary_root = Path(temporary)
    for fixture, rule in CASES.items():
        case_root = temporary_root / fixture
        shutil.copytree(ROOT / "Tests/PolicyFixtures" / fixture, case_root)
        shutil.copy2(ROOT / "policy.json", case_root / "policy.json")
        result = subprocess.run(
            ["python3", str(ROOT / "Scripts/check_policy.py"), "--root", str(case_root), "--expect", rule],
            text=True,
            capture_output=True,
        )
        if result.returncode:
            raise SystemExit(result.stdout + result.stderr)
        print(f"PASS fixture {fixture}: {rule}")
