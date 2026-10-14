#!/usr/bin/env python3
"""Report required step outcomes and fail if any did not succeed."""

import json
import os
import sys

if len(sys.argv) < 2:
    sys.exit("At least one required phase must be specified")

steps = json.loads(os.environ["STEP_RESULTS"])
# conclusion hides failures when continue-on-error is used; outcome preserves them.
outcomes = {name: steps.get(name, {}).get("outcome", "not run") for name in sys.argv[1:]}
with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
    summary.write("| Required phase | Original outcome |\n| --- | --- |\n")
    for name, outcome in outcomes.items():
        summary.write(f"| {name} | {outcome} |\n")

failed = [name for name, outcome in outcomes.items() if outcome != "success"]
if failed:
    sys.exit("Required phases did not succeed: " + ", ".join(failed))
