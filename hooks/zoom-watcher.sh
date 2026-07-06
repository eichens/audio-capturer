#!/bin/bash
# zoom-watcher.sh — starts/stops meetingrec around Zoom meetings.
#
#   meeting joined -> launch meetingrec in the background
#   meeting ended  -> SIGINT meetingrec (finalizes the WAV, runs post-processor)
#
# Meeting detection: Zoom spawns its CptHost helper (us.zoom.CptHost) for the
# lifetime of every meeting, so "CptHost is running" is a reliable in-meeting
# signal and its exit marks the end of the meeting. We also require the main
# zoom.us process so a stray helper can never trigger a recording.
#
# Designed to run under launchd (see com.meetingrec.zoom-watcher.plist), but
# works standalone in a terminal too. All knobs below can be overridden in the
# config file, which is also where launchd runs pick up MEETINGREC_S3_BUCKET /
# AWS_REGION (launchd does not read your shell profile).

set -u

CONFIG_FILE="${MEETINGREC_ZOOM_CONFIG:-$HOME/.config/meetingrec/zoom-watcher.env}"
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# launchd starts agents with a minimal PATH; the post-processor needs ffmpeg
# (homebrew) and the dev-mode fallback in main.swift needs uv (~/.local/bin).
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

MEETINGREC_BIN="${MEETINGREC_BIN:-meetingrec}"
MEETINGREC_ZOOM_ARGS="${MEETINGREC_ZOOM_ARGS:-}"   # e.g. "-s" for speaker-only
POLL_SECONDS="${POLL_SECONDS:-5}"
END_GRACE_POLLS="${END_GRACE_POLLS:-3}"            # consecutive meeting-free polls before stopping
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/meetingrec}"

mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

in_meeting() {
    pgrep -xq zoom.us && pgrep -xq CptHost
}

rec_pid=""
absent_polls=0
failed_starts=0

start_recording() {
    local logfile
    logfile="$LOG_DIR/recording-$(date '+%Y-%m-%d-%H%M%S').log"
    # shellcheck disable=SC2086  # word-splitting of the extra args is intentional
    "$MEETINGREC_BIN" $MEETINGREC_ZOOM_ARGS </dev/null >>"$logfile" 2>&1 &
    rec_pid=$!
    log "meeting detected -> started meetingrec (pid $rec_pid, log $logfile)"
}

stop_recording() {
    if [ -n "$rec_pid" ] && kill -0 "$rec_pid" 2>/dev/null; then
        log "meeting ended -> sending SIGINT to meetingrec (pid $rec_pid)"
        kill -INT "$rec_pid"
        # Deliberately no wait: post-processing can run for many minutes and
        # we must keep polling in case another meeting starts.
    fi
    rec_pid=""
}

# Unloading the agent mid-meeting still finalizes the recording.
trap 'stop_recording; exit 0' INT TERM

log "zoom-watcher started (poll ${POLL_SECONDS}s, end grace $((END_GRACE_POLLS * POLL_SECONDS))s)"

while :; do
    if in_meeting; then
        absent_polls=0
        if [ -n "$rec_pid" ] && ! kill -0 "$rec_pid" 2>/dev/null; then
            # meetingrec died mid-meeting (e.g. missing TCC permission).
            # Retry a couple of times, then hold off until the next meeting
            # so we don't spawn a failing process every poll.
            rec_pid=""
            failed_starts=$((failed_starts + 1))
            if [ "$failed_starts" -eq 3 ]; then
                log "meetingrec exited $failed_starts times this meeting; giving up until next meeting (check the recording log)"
            fi
        fi
        if [ -z "$rec_pid" ] && [ "$failed_starts" -lt 3 ]; then
            start_recording
        fi
    else
        failed_starts=0
        if [ -n "$rec_pid" ]; then
            absent_polls=$((absent_polls + 1))
            if [ "$absent_polls" -ge "$END_GRACE_POLLS" ]; then
                stop_recording
                absent_polls=0
            fi
        fi
    fi
    sleep "$POLL_SECONDS"
done
