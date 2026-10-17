#!/bin/sh
# Install windows unattended, start it, and check it came up healthy.
#
# The whole installation runs without anyone at the keyboard: windows setup looks for
# autounattend.xml on removable media before it draws its first dialog, and the floppy built here
# holds one that answers every question - the licence, the product key, what to do with the disk,
# which account to make, and whether to ask about privacy afterwards.
#
# What counts as healthy is deliberately not a screenshot. The answer file ends with a command run
# from the first logged in session that writes a marker to the serial port, and the harness watches
# for it. Hearing it means setup finished, the machine rebooted on its own, windows booted from the
# disk rather than the installer, a session logged in, and a program ran inside it. A picture of a
# desktop establishes none of that on its own.
#
# The product key comes from WINDOWS_PRODUCT_KEY in the environment. It is written only into the
# floppy image under build/, which is not tracked, and never into the log.
#
# Usage: WINDOWS_PRODUCT_KEY=... ./tests/manual/install-windows.sh path/to/windows.iso [seconds]
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
iso=${1:-$HOME/Downloads/Win10_22H2_EnglishInternational_x64v1.iso}
budget=${2:-200000}
work=$root/build/e2e
out=$root/build/install-windows
marker=V86-DESKTOP-IS-UP

[ -f "$iso" ] || { echo "no iso at $iso" >&2; exit 2; }
[ -n "${WINDOWS_PRODUCT_KEY:-}" ] || {
    echo "WINDOWS_PRODUCT_KEY is not set." >&2
    echo "It lives in ~/.zshrc, which only an interactive shell reads, so run this as:" >&2
    echo "  zsh -ic '$0 $*'" >&2
    exit 2
}

mkdir -p "$work"
umask 077

echo "building the answer file and the floppy it travels on"
sed -e "s|@PRODUCTKEY@|$WINDOWS_PRODUCT_KEY|" -e "s|@MARKER@|$marker|" \
    "$here/autounattend.xml.in" > "$work/autounattend.xml"
"$here/make-floppy.mjs" "$work/unattend.img" autounattend.xml < "$work/autounattend.xml"

# A fresh disk every time: an installation onto a disk that already has one is a different test,
# and not the one this is.
rm -f "$work/windows.img"

echo "installing - this is hours, not minutes, and ends as soon as the guest says it is up"
HDA="$work/windows.img" HDA_GB=24 FDA="$work/unattend.img" \
    SERIAL_EXPECT="$marker" STOP_ON_SERIAL=1 \
    DETERMINISTIC=1 SHOT_MS=15000 OUT="$out" \
    "$here/boot-windows.mjs" "$iso" "$budget" && status=0 || status=$?

echo
if [ "$status" -eq 0 ]
then
    echo "PASS - windows installed, booted from its own disk, logged in and ran a program."
    echo "Screenshots and the log are in $out."
else
    echo "FAIL - see $out/boot.log and the screenshots beside it."
fi
exit $status
