#!/bin/zsh
# Builds the app's sources together with the tests and runs them.
# Usage: Tests/run.sh [--intel] [filter]   (e.g. Tests/run.sh Errors)
#   --intel  builds the tests for x86_64 and runs them under Rosetta, as on an Intel Mac.
set -euo pipefail
cd "${0:A:h}/.."
arch=$(uname -m)
runner=()
if [[ ${1:-} == --intel ]]; then
  shift
  arch=x86_64
  [[ $(uname -m) == arm64 ]] && runner=(arch -x86_64)
fi
mkdir -p build
# The security suite audits the real app binary, so rebuild it when any source is newer.
app=build/Split.app/Contents/MacOS/Split
if [[ ! -x $app || -n "$(find Sources Resources -newer $app -type f | head -1)" ]]; then
  # One slice is enough to test; make-dmg.sh builds the universal app.
  ARCHS="${ARCHS:-$(uname -m)}" ./build.sh
fi
# The messages the tests read are the English source texts.
export SPLIT_LANGUAGE=en
sources=(Sources/**/*.swift)
sources=(${sources:#Sources/App/main.swift})
swiftc -O -target "$arch-apple-macos13.0" -sdk "$(xcrun --show-sdk-path)" -module-name Split \
  "${sources[@]}" Tests/*.swift -o build/SplitTests-$arch
exec $runner build/SplitTests-$arch "$@"
