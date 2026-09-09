#!/usr/bin/env python3
"""Reproduce T-01 package checks, with an optional Xcode compile matrix."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--matrix', action='store_true', help='also build generic Apple destinations')
parser.add_argument('--output', type=Path, default=ROOT / '.build/bootstrap-validation')
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
results = []

def record(name, command, code, passed):
    results.append(dict(name=name, command=command, exitCode=code, passed=passed))
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(('PASS ' if passed else 'FAIL ') + name, flush=True)

def run(name, command, cwd=ROOT):
    # Keep SwiftPM manifest/build SDK selection aligned with the pinned Xcode toolchain.
    if command[0] == 'swift':
        if command[1] == 'package':
            command = [*command[:2], '--disable-sandbox', *command[2:]]
        elif command[1] in {'build', 'test', 'run'}:
            command = [*command[:2], '--disable-sandbox', *command[2:]]
        command = ['xcrun', '--sdk', 'macosx', *command]
    environment = os.environ.copy()
    module_cache = output / 'module-cache'
    module_cache.mkdir(parents=True, exist_ok=True)
    environment['CLANG_MODULE_CACHE_PATH'] = str(module_cache)
    result = subprocess.run(
        command, cwd=cwd, env=environment, text=True, capture_output=True, timeout=300
    )
    log = result.stdout + result.stderr
    (output / (name + '.log')).write_text(log)
    record(name, command, result.returncode, result.returncode == 0)
    if result.returncode:
        raise SystemExit(log[-6000:])
    return result.stdout

def require(name, condition, detail):
    (output / (name + '.log')).write_text(detail + '\n')
    record(name, ['local-contract-check', detail], 0 if condition else 1, condition)
    if not condition:
        raise SystemExit(detail)

pin = json.loads((ROOT / 'toolchain.json').read_text())
swift = run('swift-version', ['swift', '--version'])
xcode = run('xcode-version', ['xcodebuild', '-version'])
formatter = run('format-version', ['xcrun', 'swift-format', '--version']).strip()
require('pinned-toolchain',
        f"Swift version {pin['swiftCompilerVersion']} " in swift
        and f"Xcode {pin['xcodeVersion']}\n" in xcode
        and f"Build version {pin['xcodeBuild']}" in xcode
        and formatter == pin['swiftFormatVersion'],
        'Use the repository-pinned toolchain.json; update it explicitly with validation.')
mac_sdk = run('macos-sdk-version', ['xcrun', '--sdk', 'macosx', '--show-sdk-version']).strip()
require('macos-sdk-pin', mac_sdk == pin['sdkVersion'], 'Expected SDK ' + pin['sdkVersion'])
run('format', ['xcrun', 'swift-format', 'lint', '--strict', '--configuration', '.swift-format',
               '--recursive', 'Package.swift', 'Sources', 'Tests'])
run('resolve', ['swift', 'package', 'resolve'])
manifest = json.loads(run('manifest', ['swift', 'package', 'dump-package']))
lock = json.loads((ROOT / 'Package.resolved').read_text())
flux = [item for item in lock['pins'] if item['identity'] == 'flux']
require('released-flux', len(flux) == 1 and flux[0]['kind'] == 'remoteSourceControl'
        and flux[0]['location'] == 'https://github.com/resoul/flux.git'
        and flux[0]['state']['version'] == '1.2.0'
        and flux[0]['state']['revision'] == '7e98033b26e793e36f3902fdc073f5d26969f6c6',
        'Flux 1.2.0 is the remote release at 7e98033b26e793e36f3902fdc073f5d26969f6c6.')
require('language-mode', manifest['swiftLanguageVersions'] == ['6'],
        'Weave must compile in Swift 6 language mode; complete concurrency is implicit in mode 6.')
platforms = {item['platformName']: item['version'] for item in manifest['platforms']}
require('deployment-targets', platforms == {'macos': '14.0', 'ios': '16.0', 'tvos': '16.0'},
        'Deployment baselines are macOS 14, iOS 16 and tvOS 16.')
require('bootstrap-targets', {t['name'] for t in manifest['targets']} == {
    'Weave', 'WeaveBootstrapTests', 'Logging', 'LoggingTests', 'UIKitAdapter', 'UIKitAdapterTests',
    'AppKitAdapter', 'AppKitAdapterTests', 'Networking', 'NetworkingTests', 'Storage', 'StorageTests',
    'NetworkingLogging', 'NetworkingLoggingTests', 'WeaveTesting', 'WeaveTestingTests',
    'Analytics', 'AnalyticsTests', 'Syntax', 'SyntaxTests',
    'WeaveUI', 'WeaveAdapters'
}, 'All declared library products and their test targets must be present.')
require('safe-package-flags', 'unsafeFlags' not in json.dumps(manifest),
        'No unsafe compiler flags in a library consumed by another Swift package.')
# This narrow bootstrap scan is not the complete boundary/API/secret tooling from T-68.
violations = []
for source in (
    list((ROOT / 'Sources').rglob('*.swift'))
):
    content = source.read_text()
    relative = str(source.relative_to(ROOT))
    if relative.startswith(('Sources/UIKitAdapter/', 'Sources/AppKitAdapter/', 'Sources/Weave/Platform/')):
        continue
    if re.search(r'(?m)^\s*(?:public |internal |private )?import (?:UIKit|AppKit|SwiftUI|WeaveCore)\b', content):
        violations.append(str(source.relative_to(ROOT)))
require('bootstrap-boundaries', not violations, 'Unexpected bootstrap imports: ' + repr(violations))
run('library-build', ['swift', 'build', '--target', 'Weave', '-Xswiftc', '-warnings-as-errors'])
run('tests', ['swift', 'test', '-Xswiftc', '-warnings-as-errors'])

if args.matrix:
    destinations = [
        ('macos-universal', 'generic/platform=macOS', 'macosx', ['ARCHS=arm64 x86_64']),
        ('ios-device', 'generic/platform=iOS', 'iphoneos', []),
        ('ios-simulator', 'generic/platform=iOS Simulator', 'iphonesimulator', []),
        ('tvos-device', 'generic/platform=tvOS', 'appletvos', []),
        ('tvos-simulator', 'generic/platform=tvOS Simulator', 'appletvsimulator', []),
    ]
    for name, destination, sdk, arch in destinations:
        version = run(name + '-sdk', ['xcrun', '--sdk', sdk, '--show-sdk-version']).strip()
        require(name + '-sdk-pin', version == pin['sdkVersion'], 'Expected SDK ' + pin['sdkVersion'])
        run(name, ['xcodebuild', '-scheme', 'Weave', '-destination', destination,
                   '-derivedDataPath', str(ROOT / '.build/xcode' / name),
                   '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
                   'CODE_SIGNING_ALLOWED=NO', 'ONLY_ACTIVE_ARCH=NO',
                   'SWIFT_VERSION=6.0', 'SWIFT_STRICT_CONCURRENCY=complete',
                   'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'SWIFT_SUPPRESS_WARNINGS=NO', *arch, 'build'])
print('Bootstrap checks complete; logs: ' + str(output))
