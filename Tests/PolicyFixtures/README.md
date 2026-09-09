# Policy fixtures

Each child directory is an intentionally invalid repository fragment. `Scripts/test_policy.py`
copies `policy.json` into one fragment and verifies that the named rule fails. Fixture files use
an extra `.fixture` suffix so SwiftPM and documentation tooling do not treat them as source.
