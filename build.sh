#!/bin/bash
# Build both igrep and igrep-bench escripts
set -e

echo "==> Fetching dependencies..."
mix deps.get

echo "==> Compiling..."
mix compile

echo "==> Building igrep escript..."
mix escript.build

echo "==> Building igrep-bench escript..."
# Build the bench escript by temporarily switching the main_module
MIX_ENV=prod mix escript.build --name igrep-bench --main-module Igrep.Bench 2>/dev/null || \
  mix escript.build

echo ""
echo "Built:"
ls -la igrep igrep-bench 2>/dev/null || ls -la igrep
