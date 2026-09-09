#!/usr/bin/env python3
"""Deterministic Weave policy linter; uses only the Python standard library."""

import argparse
import fnmatch
import json
from pathlib import Path
import re
import sys

LINTER_VERSION = "1.0.0"
DEFAULT_ROOT = Path(__file__).resolve().parents[1]
IGNORED_PARTS = {".build", ".git", ".swiftpm", "DerivedData", "PolicyFixtures", "xcuserdata"}


def relative_files(root: Path):
    for path in root.rglob("*"):
        if path.is_file() and not IGNORED_PARTS.intersection(path.parts):
            yield path, path.relative_to(root).as_posix()


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--expect", help="succeed only when this rule is violated")
    parser.add_argument("--version", action="store_true")
    args = parser.parse_args()
    if args.version:
        print(LINTER_VERSION)
        return 0

    root = args.root.resolve()
    policy_path = root / "policy.json"
    if not policy_path.is_file():
        print("POLICY_CONFIG: policy.json is missing", file=sys.stderr)
        return 1
    policy = json.loads(policy_path.read_text())
    violations: list[tuple[str, str, int, str]] = []

    if policy.get("policyVersion") != LINTER_VERSION:
        violations.append(("POLICY_VERSION", "policy.json", 1, "policy and linter versions differ"))

    exceptions = policy.get("allowedExceptions", [])
    for exception in exceptions:
        if not exception.get("path") or not exception.get("rules") or not exception.get("reason"):
            violations.append(("ALLOWLIST_REASON", "policy.json", 1, "exception needs path, rules and reason"))

    def is_allowed(rule: str, relative: str) -> bool:
        return any(
            rule in item.get("rules", []) and fnmatch.fnmatch(relative, item.get("path", ""))
            for item in exceptions
        )

    platform_prefixes = tuple(policy.get("platformImplementationPrefixes", []))
    swift_patterns = {
        "PLATFORM_IMPORT": re.compile(r"(?m)^\s*(?:@\w+\s+)?import\s+(?:UIKit|AppKit|Cocoa|SwiftUI|Metal)\b"),
        "PLATFORM_CONDITION": re.compile(r"#if\s+os\s*\("),
        "COCOA_LIFECYCLE": re.compile(
            r"\b(?:viewDidLoad|loadView|viewWillAppear|viewDidAppear|applicationDidFinishLaunching|sceneDidBecomeActive)\b"
        ),
        "UNSAFE_CONCURRENCY": re.compile(r"@unchecked\s+Sendable|nonisolated\s*\(\s*unsafe\s*\)|@preconcurrency"),
        "FORCE_OPERATION": re.compile(r"\btry!|\bfatalError\s*\(|(?<=[A-Za-z0-9_\]\)])!(?!=)"),
    }
    public_declaration = re.compile(
        r"^\s*(?:public|open)\s+(?:(?:final|indirect)\s+)?(?:class|struct|enum|protocol|actor|func|init|typealias)\b"
    )
    secret_patterns = {
        "SECRET_PRIVATE_KEY": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
        "SECRET_GITHUB_TOKEN": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"),
        "SECRET_SLACK_TOKEN": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{16,}\b"),
        "SECRET_AWS_KEY": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    }

    for path, relative in relative_files(root):
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for rule, pattern in secret_patterns.items():
            for match in pattern.finditer(text):
                if not is_allowed(rule, relative):
                    violations.append((rule, relative, line_number(text, match.start()), "possible credential"))

        is_swift = relative.endswith((".swift", ".swift.fixture"))
        if is_swift and relative.startswith("Sources/"):
            for rule, pattern in swift_patterns.items():
                if rule in {"PLATFORM_IMPORT", "PLATFORM_CONDITION", "COCOA_LIFECYCLE"} and relative.startswith(platform_prefixes):
                    continue
                for match in pattern.finditer(text):
                    if not is_allowed(rule, relative):
                        violations.append((rule, relative, line_number(text, match.start()), match.group(0).strip()))
            lines = text.splitlines()
            for index, line in enumerate(lines):
                if not public_declaration.match(line):
                    continue
                cursor = index - 1
                while cursor >= 0 and lines[cursor].lstrip().startswith("@"):
                    cursor -= 1
                documentation = []
                while cursor >= 0 and lines[cursor].lstrip().startswith("///"):
                    documentation.append(lines[cursor])
                    cursor -= 1
                joined = "\n".join(reversed(documentation))
                required = ("Ownership:", "Isolation:", "Errors:", "Cancellation:")
                if not all(section in joined for section in required) and not is_allowed("PUBLIC_DOCUMENTATION", relative):
                    violations.append(
                        ("PUBLIC_DOCUMENTATION", relative, index + 1, "missing ownership/isolation/errors/cancellation sections")
                    )

        if relative.endswith((".md", ".md.fixture")):
            for match in re.finditer(r"(?<!!)\[[^]]+\]\(([^)]+)\)", text):
                target = match.group(1).strip().split("#", 1)[0]
                if not target or "://" in target or target.startswith(("mailto:", "/")):
                    continue
                if not (path.parent / target).resolve().exists() and not is_allowed("MARKDOWN_LINK", relative):
                    violations.append(("MARKDOWN_LINK", relative, line_number(text, match.start()), target))

    violations.sort()
    for rule, relative, line, detail in violations:
        print(f"{relative}:{line}: {rule}: {detail}")

    if args.expect:
        found = any(item[0] == args.expect for item in violations)
        print(f"{'PASS' if found else 'FAIL'} expected violation {args.expect}")
        return 0 if found else 1
    if violations:
        print(f"FAIL policy ({len(violations)} violations)")
        return 1
    print(f"PASS policy {LINTER_VERSION}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
