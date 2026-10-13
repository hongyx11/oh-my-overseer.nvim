#!/bin/bash
set -e

mkdir -p ".testenv/config/nvim"
mkdir -p ".testenv/data/nvim"
mkdir -p ".testenv/state/nvim"
mkdir -p ".testenv/run/nvim"
mkdir -p ".testenv/cache/nvim"
TEST_ROOT="$(pwd)/.testenv"
PLUGINS="$TEST_ROOT/data/nvim/site/pack/plugins/start"

if [ ! -e "$PLUGINS/plenary.nvim" ]; then
  git clone --depth=1 https://github.com/nvim-lua/plenary.nvim.git "$PLUGINS/plenary.nvim"
fi

if [ ! -e "$PLUGINS/telescope.nvim" ]; then
  git clone --depth=1 https://github.com/nvim-telescope/telescope.nvim.git "$PLUGINS/telescope.nvim"
fi

XDG_CONFIG_HOME="$TEST_ROOT/config" \
  XDG_DATA_HOME="$TEST_ROOT/data" \
  XDG_STATE_HOME="$TEST_ROOT/state" \
  XDG_RUNTIME_DIR="$TEST_ROOT/run" \
  XDG_CACHE_HOME="$TEST_ROOT/cache" \
  nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory ${1-tests} { minimal_init = './tests/minimal_init.lua' }"
if [ "${1-tests}" = "tests" ]; then
  python3 -m unittest discover -s tests -p experiment_runner_test.py
fi
echo "Success"
