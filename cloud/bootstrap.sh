#!/bin/bash
# Paste this as the setup script of a claude.ai/code cloud environment. It fetches
# cloud/setup.sh from this (public) repo and runs it. It never fails, because a failing setup
# script stops the session from starting.
base=https://raw.githubusercontent.com/lago-morph/ai-sandbox/main
if curl -fsSL --retry 3 -o /tmp/ai-sandbox-cloud-setup.sh "$base/cloud/setup.sh"; then
  AI_SANDBOX_CLOUD_BASE=$base bash /tmp/ai-sandbox-cloud-setup.sh || echo "ai-sandbox cloud setup failed; continuing"
else
  echo "ai-sandbox cloud setup: download failed; continuing"
fi
exit 0
