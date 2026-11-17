#!/bin/zsh
# Runs all three native Steam check suites and asserts their JSON results.
#
# Used by .github/workflows/checks.yml, but it is a plain script on purpose so
# the same commands can be run locally:
#
#   zsh .github/run_native_checks.sh
#
# Requires arm64 + macOS 14 and the Command Line Tools (xcrun swiftc). The
# suites compile a fake libsteam_api.dylib per run: no Steam login, no real
# account, nothing written to the user's Steam data.
set -euo pipefail

repo="${0:A:h:h}"
cd "$repo/synchronizer/Tests"

suites=(
    run_steam_subscription_native_checks.sh
    run_steam_favorite_native_checks.sh
    run_steam_user_vote_native_checks.sh
    run_saved_workshop_reclaim_checks.sh
)

total=0
failed=0
for suite in "${suites[@]}"; do
    print "=== $suite"
    if output=$(zsh "./$suite" 2>&1); then
        print -r -- "$output"
        # run_steam_user_vote_native_checks.sh -> steam-user-vote-native-checks
        name="${${suite#run_}%.sh}"
        name="${name//_/-}"
        if python3 assert_suite_json.py "$name" "$output"; then
            checks=$(print -r -- "$output" | /usr/bin/grep -o '"checks":[0-9]*' | tail -1 | cut -d: -f2)
            total=$(( total + ${checks:-0} ))
        else
            failed=$(( failed + 1 ))
        fi
    else
        print -r -- "$output"
        print -u2 -- "FAILED to run $suite"
        failed=$(( failed + 1 ))
    fi
done

if (( failed )); then
    print -u2 -- "$failed suite(s) failed"
    exit 1
fi
print -- "all suites passed, $total checks total"
