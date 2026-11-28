# shellcheck shell=bash
# Test fixture step.
check() { [ -f "$AI_SANDBOX_STATE/alpha-done" ]; }
apply() { mkdir -p "$AI_SANDBOX_STATE"; touch "$AI_SANDBOX_STATE/alpha-done"; }
