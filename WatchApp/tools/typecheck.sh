#!/bin/bash
# Type-checks the watch app on a Mac that has only the Swift command-line tools.
#
#   WatchApp/tools/typecheck.sh            build the four shared modules, then run every pass
#   WatchApp/tools/typecheck.sh --no-build reuse the modules already in the scratch path
#
# Pass 1 (strict)    every source file, compiled for macOS exactly as written. Code inside
#                    `#if os(watchOS)` is skipped, so this covers the platform-neutral code:
#                    model, logic, and all SwiftUI views. Must produce no diagnostics.
# Pass 2 (advisory)  the same files with `os(watchOS)` forced on, against the macOS SDK's
#                    CoreMotion / HealthKit / SwiftUI and a hand-written WatchKit stand-in
#                    (tools/stubs/WatchKit.swift). The only errors allowed are "is unavailable
#                    in macOS", which just says the API is watch-only. Argument labels, types,
#                    delegate signatures and imports are all checked.
# Pass 3 (advisory)  as pass 2 with `targetEnvironment(simulator)` forced on as well, to cover
#                    the simulator-only branch.
# Pass 4             builds and runs tools/logic_tests.swift against the neutral logic.
set -uo pipefail

TOOLS="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$TOOLS/.." && pwd)"
ROOT="$(cd "$APP/.." && pwd)"
SCRATCH="${GAUNTLET_SCRATCH:-.build-watch}"
TARGET="arm64-apple-macos15.0"      # macOS 15 is the same SwiftUI generation as watchOS 11
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gauntlet-typecheck.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
status=0

cd "$ROOT" || exit 2
if [ "${1:-}" != "--no-build" ]; then
    # Only the modules the watch app links, so unrelated targets cannot break this check.
    for module in GauntletWatchCore GauntletEngine; do
        echo "== building $module and its dependencies ($SCRATCH)"
        swift build --scratch-path "$SCRATCH" --target "$module" 2>&1 | grep -v "ld: warning" | tail -n 1
    done
fi
BIN="$(swift build --scratch-path "$SCRATCH" --show-bin-path 2>/dev/null)"
# Where SwiftPM put the .swiftmodule files varies by version (bin path, Modules/, ...): look.
FOUND="$(find "$BIN" -maxdepth 3 -name 'GauntletWatchCore.swiftmodule' 2>/dev/null | head -n 1)"
if [ -z "$FOUND" ]; then
    echo "shared modules not found under $BIN; found these instead:"
    find "$ROOT/$SCRATCH" -maxdepth 6 -name '*.swiftmodule' 2>/dev/null | head -n 10
    exit 2
fi
MODS="$(dirname "$FOUND")"

FILES=()
while IFS= read -r file; do FILES+=("$file"); done < <(cd "$APP" && find GauntletWatch -name '*.swift' | sort)
COMMON=(-typecheck -wmo -swift-version 5 -target "$TARGET" -parse-as-library -diagnostic-style llvm -I "$MODS")

echo "== pass 1: strict, ${#FILES[@]} files as written (target $TARGET, Swift 5 mode)"
(cd "$APP" && swiftc "${COMMON[@]}" "${FILES[@]}") > "$WORK/pass1.log" 2>&1
grep -v "ld: warning" "$WORK/pass1.log" | grep -E "(error|warning):" > "$WORK/pass1.diag"
if [ -s "$WORK/pass1.diag" ]; then
    cat "$WORK/pass1.diag"; echo "pass 1 FAILED"; status=1
else
    echo "pass 1 clean: 0 errors, 0 warnings"
fi

echo "== building WatchKit stand-in"
mkdir -p "$WORK/stubs"
swiftc -emit-module -module-name WatchKit -parse-as-library -swift-version 5 -target "$TARGET" \
    -emit-module-path "$WORK/stubs/WatchKit.swiftmodule" "$TOOLS/stubs/WatchKit.swift" 2>&1 | grep -E "error" && status=1

advisory() {    # $1 = pass name, $2... = sed expressions
    local name="$1"; shift
    local dir="$WORK/$name"
    mkdir -p "$dir"
    local file
    for file in "${FILES[@]}"; do
        mkdir -p "$dir/$(dirname "$file")"
        sed "$@" "$APP/$file" > "$dir/$file"
    done
    (cd "$dir" && swiftc "${COMMON[@]}" -I "$WORK/stubs" "${FILES[@]}") > "$dir.log" 2>&1
    grep -E "(error|warning):" "$dir.log" | grep -v "ld: warning" > "$dir.diag"
    local expected unexpected
    expected=$(grep -c "is unavailable in macOS" "$dir.diag")
    grep -v "is unavailable in macOS" "$dir.diag" > "$dir.unexpected"
    unexpected=$(wc -l < "$dir.unexpected" | tr -d ' ')
    echo "$name: $expected expected \"unavailable in macOS\" diagnostics, $unexpected others"
    grep "is unavailable in macOS" "$dir.diag" | sed -E "s/.*(error|warning): //" | sort | uniq -c | sed 's/^/    /'
    if [ "$unexpected" != "0" ]; then cat "$dir.unexpected"; echo "$name FAILED"; status=1; fi
}

echo "== pass 2: advisory, watch-only code forced on"
advisory pass2 -e 's/os(watchOS)/true/g'
echo "== pass 3: advisory, watch-only + simulator branch forced on"
advisory pass3 -e 's/os(watchOS)/true/g' -e 's/targetEnvironment(simulator)/true/g'

if [ -f "$TOOLS/logic_tests.swift" ]; then
    echo "== pass 4: logic tests"
    LOGIC=()
    while IFS= read -r file; do LOGIC+=("$file"); done < <(cd "$APP" && find GauntletWatch/Core -name '*.swift' | sort)
    # SwiftPM does not emit static libraries for these targets; link their object files directly.
    OBJECTS=()
    for module in GauntletProtocol GauntletLink GauntletWatchCore GauntletEngine; do
        while IFS= read -r obj; do OBJECTS+=("$obj"); done < <(find "$BIN/$module.build" -name '*.o' 2>/dev/null | sort)
    done
    if (cd "$APP" && swiftc -swift-version 5 -target "$TARGET" -parse-as-library -I "$MODS" \
            -o "$WORK/logic_tests" "${LOGIC[@]}" tools/logic_tests.swift "${OBJECTS[@]}") > "$WORK/pass4.log" 2>&1; then
        "$WORK/logic_tests" || status=1
    else
        grep -v "ld: warning" "$WORK/pass4.log"; echo "pass 4 FAILED to build"; status=1
    fi
fi

[ "$status" = "0" ] && echo "ALL PASSES OK" || echo "SOME PASSES FAILED"
exit "$status"
