#!/bin/sh
# Install windows unattended in two processes: one that runs the installation part way and saves
# the whole machine, and a second, started cold, that restores it and has to finish the job.
#
# This is install-windows.sh with a save and a restore in the middle, and its verdict is the same
# one - the marker the answer file has the first logged in session write to the serial port. That
# makes the test strict about resuming in a way a quick check cannot be: the restored machine has to
# keep a 64-bit kernel running, finish copying files onto a disk the first process wrote half of,
# reboot itself from that disk and log in. A register lost in the save, a device that comes back in
# the wrong state, or a disk that does not match what the guest believes it wrote, each ends in a
# bugcheck or a hang rather than the marker.
#
# What is carried from one process to the other is exactly what a real resume would carry: the
# state file, the harness's clock beside it (so that guest time carries on rather than restarting
# from zero), and a clone of the disk taken at the same instant. The first process stops as soon
# as it has saved, so nothing it does afterwards can leak into the second.
#
# The product key comes from WINDOWS_PRODUCT_KEY, which lives in ~/.zshrc, so run this as:
#   zsh -ic './tests/manual/resume-windows.sh path/to/windows.iso [save_at] [seconds]'
#
# save_at is the guest time to save at (default 1800, with the 64-bit kernel and its drivers
# running); seconds is the guest time the whole installation may take, both halves together.
# REUSE_STATE=1 skips the first half and restores the state an earlier run left behind, which is
# how to repeat the expensive half of the test without paying for the cheap one again.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
iso=${1:-$HOME/Downloads/Win10_22H2_EnglishInternational_x64v1.iso}
save_at=${2:-1800}
budget=${3:-200000}
work=$root/build/e2e
out=$root/build/resume-windows
marker=V86-DESKTOP-IS-UP

[ -f "$iso" ] || { echo "no iso at $iso" >&2; exit 2; }
[ -n "${WINDOWS_PRODUCT_KEY:-}" ] || {
    echo "WINDOWS_PRODUCT_KEY is not set." >&2
    echo "It lives in ~/.zshrc, which only an interactive shell reads, so run this as:" >&2
    echo "  zsh -ic '$0 $*'" >&2
    exit 2
}

mkdir -p "$work" "$out"
umask 077

echo "building the answer file and the floppy it travels on"
sed -e "s|@PRODUCTKEY@|$WINDOWS_PRODUCT_KEY|" -e "s|@MARKER@|$marker|" \
    "$here/autounattend.xml.in" > "$work/autounattend.xml"
"$here/make-floppy.mjs" "$work/unattend.img" autounattend.xml < "$work/autounattend.xml"

# Both halves see the same machine: the same medium, floppy, memory and clock. Anything that
# differed between them would be a different machine being restored into, which is not the test.
export FDA="$work/unattend.img" HDA_GB=24 DETERMINISTIC=1 SHOT_MS=15000

if [ "${REUSE_STATE:-}" != 1 ]
then
    rm -rf "$out/before"
    rm -f "$work/resume.img"
    echo "installing up to ${save_at}s of guest time, then saving and stopping"
    HDA="$work/resume.img" SAVE_AT="$save_at" STOP_AFTER_SAVE=1 OUT="$out/before" \
        "$here/boot-windows.mjs" "$iso" "$budget" || {
        echo "FAIL - the first half did not reach ${save_at}s; see $out/before/boot.log"
        exit 1
    }
fi

for f in state.bin state.json state-disk.img
do
    [ -f "$out/before/$f" ] || { echo "FAIL - the first half left no $out/before/$f"; exit 1; }
done

# A clone of the saved disk rather than the saved disk itself, so that the state stays reusable:
# the second half writes all over the disk it is given.
rm -f "$work/resume.img"
cp -c "$out/before/state-disk.img" "$work/resume.img"

echo "restoring in a new process and running until the guest says it is up"
rm -rf "$out/after"
HDA="$work/resume.img" RESTORE="$out/before/state.bin" OUT="$out/after" \
    SERIAL_EXPECT="$marker" STOP_ON_SERIAL=1 \
    "$here/boot-windows.mjs" "$iso" "$budget" && status=0 || status=$?

echo
if [ "$status" -eq 0 ]
then
    echo "PASS - saved at ${save_at}s, restored in a new process, and the restored machine"
    echo "finished installing, booted from its own disk, logged in and ran a program."
else
    echo "FAIL - see $out/after/boot.log and the screenshots beside it."
fi
exit $status
