#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bash "$root/ops/tests/test_runner_completeness.sh"
bash "$root/ops/tests/hddt_lite_behavior_harness.sh" --self-test
bash "$root/ops/tests/test_hddt_lite_behavior.sh" --self-test
bash "$root/ops/tests/test_hddt_lite_mutants.sh" --self-test
printf '%s\n' 'package-a: PASS acceptance=meta-oracle,harness-self-tests product-behavior=not-gated'
