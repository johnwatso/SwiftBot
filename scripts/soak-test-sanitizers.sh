#!/bin/bash
set -euo pipefail

# SwiftBot Sanitizer Soak Test
# Usage: ./scripts/soak-test-sanitizers.sh [address|thread] [duration_minutes]
#
# Runs SwiftBot built with sanitizers for an extended period to catch
# the CFNetwork EXC_BAD_ACCESS that occurs under sustained standby->primary
# request churn.
#
# Prerequisites:
#   - macOS with Xcode installed
#   - A healthy SwiftBot primary running (so the standby has something to poll)
#   - This script should be run from the project root or via ./scripts/

SANITIZER=${1:-address}
DURATION_MINUTES=${2:-20}
DURATION_SECONDS=$((DURATION_MINUTES * 60))

if [[ "$SANITIZER" != "address" && "$SANITIZER" != "thread" ]]; then
    echo "Usage: $0 [address|thread] [duration_minutes]"
    echo ""
    echo "  address  - Address Sanitizer + Undefined Behavior Sanitizer (recommended first)"
    echo "  thread   - Thread Sanitizer + Guard Malloc"
    echo ""
    echo "Note: Address Sanitizer and Thread Sanitizer are run separately because"
    echo "they are incompatible in the same binary."
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="SwiftBot-Sanitized"
if [ "$SANITIZER" == "thread" ]; then
    SCHEME="SwiftBot-ThreadSanitizer"
fi

echo "========================================"
echo "SwiftBot Sanitizer Soak Test"
echo "========================================"
echo "Sanitizer:      $SANITIZER"
echo "Duration:       ${DURATION_MINUTES} minutes"
echo "Scheme:         $SCHEME"
echo "Project dir:    $PROJECT_DIR"
echo "Start time:     $(date)"
echo ""

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
echo ">>> Building with $SCHEME scheme..."
cd "$PROJECT_DIR"

# Use a dedicated DerivedData path so we don't pollute the normal build
DERIVED_DATA="$PROJECT_DIR/.deriveddata-soak"
rm -rf "$DERIVED_DATA"

xcodebuild \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build \
    | tee /tmp/swiftbot-soak-build.log \
    | grep -E '(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)' || true

if grep -q "BUILD FAILED" /tmp/swiftbot-soak-build.log 2>/dev/null; then
    echo ""
    echo "ERROR: Build failed. See /tmp/swiftbot-soak-build.log"
    exit 1
fi

# Find the built app
APP_PATH=$(find "$DERIVED_DATA" -name "SwiftBot.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find built SwiftBot.app in $DERIVED_DATA"
    exit 1
fi

BINARY_PATH="$APP_PATH/Contents/MacOS/SwiftBot"

echo ""
echo "Built app:      $APP_PATH"
echo "Binary:         $BINARY_PATH"
echo ""

# ---------------------------------------------------------------------------
# Environment variables for diagnostics
# ---------------------------------------------------------------------------
export NSZombieEnabled=YES
export MallocScribble=YES
export MallocGuardEdges=YES

# Guard Malloc is incompatible with AddressSanitizer (both intercept malloc).
# We enable it only for the ThreadSanitizer run.
if [ "$SANITIZER" == "thread" ]; then
    export DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib
    echo ">>> Guard Malloc: ENABLED (TSan compatible)"
else
    echo ">>> Guard Malloc: SKIPPED (incompatible with AddressSanitizer)"
fi

echo ">>> NSZombieEnabled: YES"
echo ">>> MallocScribble: YES"
echo ">>> MallocGuardEdges: YES"
echo ""

# ---------------------------------------------------------------------------
# Log file
# ---------------------------------------------------------------------------
LOG_DIR="$PROJECT_DIR/soak-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/soak-${SANITIZER}-$(date +%Y%m%d-%H%M%S).log"

echo "Log file:       $LOG_FILE"
echo ""

# ---------------------------------------------------------------------------
# Launch app
# ---------------------------------------------------------------------------
echo ">>> Launching SwiftBot (standby mode)..."
echo "    Make sure your primary SwiftBot is running so the standby"
echo "    has a leader to register with and poll."
echo ""

# Launch the app in background, capturing all stdout/stderr
"$BINARY_PATH" > "$LOG_FILE" 2>&1 &
APP_PID=$!

echo "App PID:        $APP_PID"
echo ""

# Give the app a moment to start and potentially crash on launch
sleep 3
if ! kill -0 $APP_PID 2>/dev/null; then
    echo "!!! APP EXITED IMMEDIATELY !!!"
    echo "Check log: $LOG_FILE"
    echo "End time: $(date)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Monitor loop
# ---------------------------------------------------------------------------
echo ">>> Monitoring for ${DURATION_MINUTES} minutes..."
echo "    Press Ctrl+C to stop early"
echo ""

START_EPOCH=$(date +%s)
while true; do
    CURRENT_EPOCH=$(date +%s)
    ELAPSED=$((CURRENT_EPOCH - START_EPOCH))
    REMAINING=$((DURATION_SECONDS - ELAPSED))

    if [ $REMAINING -le 0 ]; then
        break
    fi

    # Check every 60 seconds
    SLEEP_TIME=60
    if [ $REMAINING -lt 60 ]; then
        SLEEP_TIME=$REMAINING
    fi

    sleep $SLEEP_TIME

    if ! kill -0 $APP_PID 2>/dev/null; then
        echo ""
        echo "========================================"
        echo "!!! APP CRASHED OR EXITED EARLY !!!"
        echo "========================================"
        echo "Elapsed time:   $((ELAPSED / 60)) minutes"
        echo "Log file:       $LOG_FILE"
        echo "End time:       $(date)"
        echo ""
        echo ">>> Last 50 lines of log:"
        tail -n 50 "$LOG_FILE" || true
        echo ""
        echo "Full log: $LOG_FILE"
        exit 1
    fi

    REMAINING_MIN=$((REMAINING / 60))
    ELAPSED_MIN=$((ELAPSED / 60))
    echo "$(date '+%H:%M:%S') - ${ELAPSED_MIN}m elapsed, ~${REMAINING_MIN}m remaining (PID $APP_PID alive)"
done

# ---------------------------------------------------------------------------
# Clean shutdown
# ---------------------------------------------------------------------------
echo ""
echo ">>> Soak test complete. Stopping app..."
kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true

echo ""
echo "========================================"
echo "Soak test PASSED"
echo "========================================"
echo "Duration:       ${DURATION_MINUTES} minutes"
echo "Sanitizer:      $SANITIZER"
echo "Log file:       $LOG_FILE"
echo "End time:       $(date)"
echo ""
echo "No crash detected. If you want to verify behavior, review the log:"
echo "  tail -f '$LOG_FILE'"
