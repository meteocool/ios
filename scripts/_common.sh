# Shared helpers for the scripts in this directory. Not executable on its own.

set -euo pipefail

PROJECT="meteocool.xcodeproj"
SCHEME="${MC_SCHEME:-meteocool}"
APP_NAME="meteocool"
BUILD_DIR="build"

# Preferred simulator. Override with e.g. MC_SIMULATOR='iPhone 15 Pro'.
# If unset, the newest available iPhone is used.
SIMULATOR="${MC_SIMULATOR:-}"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

step() { printf "\n\033[1;36m▸ %s\033[0m\n" "$*"; }
info() { printf "  %s\n" "$*"; }
fail() { printf "\n\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }
ok()   { printf "\n\033[1;32m✓ %s\033[0m\n" "$*"; }

preflight() {
    command -v xcodegen >/dev/null || fail "xcodegen not installed - run: brew install xcodegen"
    [ "$(xcode-select -p)" = "/Applications/Xcode.app/Contents/Developer" ] || \
        info "note: xcode-select points at $(xcode-select -p)"
}

# XcodeGen resolves `sources:` by walking the directories, so a file that was
# merely added or deleted changes the project too. Regenerating is well under a
# second, so it is unconditional rather than guarded by a staleness check that
# would silently miss exactly that case.
regenerate() {
    step "Regenerating project"
    xcodegen generate
    restore_package_pins
}

# The generated workspace carries SwiftPM's Package.resolved, which is thrown
# away on every regeneration — so the pins are kept at the repo root and copied
# back in. Update them with ./scripts/update-packages.sh.
restore_package_pins() {
    local dest="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    [ -f Package.resolved ] || return 0
    mkdir -p "$(dirname "$dest")"
    cmp -s Package.resolved "$dest" || cp Package.resolved "$dest"
}

# UDID of a booted simulator, booting one first if none is running.
booted_simulator() {
    local udid
    udid="$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)"
    if [ -z "$udid" ]; then
        if [ -n "$SIMULATOR" ]; then
            udid="$(xcrun simctl list devices available | grep -F "$SIMULATOR (" | grep -oE '[0-9A-F-]{36}' | head -1)"
            [ -n "$udid" ] || fail "no simulator named '$SIMULATOR' - see: xcrun simctl list devices available"
        else
            udid="$(xcrun simctl list devices available | grep -E '^ +iPhone' | tail -1 | grep -oE '[0-9A-F-]{36}' | head -1)"
            [ -n "$udid" ] || fail "no iPhone simulator available - see: xcrun simctl list devices available"
        fi
        xcrun simctl boot "$udid" >/dev/null
        open -a Simulator
    fi
    printf '%s' "$udid"
}
