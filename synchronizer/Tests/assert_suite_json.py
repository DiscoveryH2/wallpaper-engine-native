#!/usr/bin/env python3
"""Assert one native-check suite's JSON result line.

The three suites in this directory print a single JSON object as their last
line. For CI we only care about three invariants: every check passed, no real
Steam account was touched, and nothing was written under the user's data
directories.

Usage: assert_suite_json.py <suite-name> <raw-output>
"""

import json
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: assert_suite_json.py <suite-name> <raw-output>", file=sys.stderr)
        return 2
    suite, raw = sys.argv[1], sys.argv[2]
    lines = [line for line in raw.splitlines() if line.strip().startswith("{")]
    if not lines:
        print(f"{suite}: no JSON result line in output", file=sys.stderr)
        return 1
    try:
        result = json.loads(lines[-1])
    except json.JSONDecodeError as error:
        print(f"{suite}: unparsable result line: {error}", file=sys.stderr)
        return 1

    checks = result.get("checks")
    passed = result.get("passed")
    if not isinstance(checks, int) or not isinstance(passed, int) or checks <= 0:
        print(f"{suite}: missing checks/passed counts in {result!r}", file=sys.stderr)
        return 1
    if passed != checks:
        print(f"{suite}: {passed}/{checks} checks passed", file=sys.stderr)
        return 1
    if result.get("realSteamAccountUsed") is not False:
        print(f"{suite}: suite touched a real Steam account", file=sys.stderr)
        return 1
    if result.get("userSteamDataWritten") is not False:
        print(f"{suite}: suite wrote user data", file=sys.stderr)
        return 1
    if result.get("suite") != suite:
        print(f"{suite}: result came from suite {result.get('suite')!r}", file=sys.stderr)
        return 1

    print(f"{suite}: {passed} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
