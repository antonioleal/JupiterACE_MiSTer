#!/bin/bash
#============================================================================
#  build.sh - rebuild output_files/JupiterACE.rbf with Quartus Prime Lite 17.0
#
#  Usage:
#    ./build.sh          build (incremental where Quartus can)
#    ./build.sh clean    delete the Quartus working folders first, then build
#
#  QUARTUS_BIN overrides the Quartus bin folder.
#  The full Quartus output goes to build.log.
#============================================================================

QUARTUS_BIN=${QUARTUS_BIN:-/mnt/data/antonio_local/Quartus-bin/intelFPGA_lite/17.0/quartus/bin}
PROJECT=JupiterACE

cd "$(dirname "$(readlink -f "$0")")" || exit 1

if [ ! -x "$QUARTUS_BIN/quartus_sh" ]; then
	echo "quartus_sh not found in $QUARTUS_BIN (set QUARTUS_BIN)"
	exit 1
fi
export PATH=$QUARTUS_BIN:$PATH

case "$1" in
	"") ;;
	clean)
		echo "Removing db/, incremental_db/ and output_files/"
		rm -rf db incremental_db output_files
		;;
	*)
		echo "usage: $0 [clean]"
		exit 1
		;;
esac

echo "Building $PROJECT.rbf (about 5 minutes; output in build.log) ..."
start=$(date +%s)
quartus_sh --flow compile "$PROJECT" > build.log 2>&1
rc=$?
secs=$(( $(date +%s) - start ))

if [ $rc -ne 0 ] || [ ! -f "output_files/$PROJECT.rbf" ]; then
	echo "Build FAILED after ${secs}s:"
	grep -E "^Error" build.log | head -20
	exit 1
fi

echo "Build OK in $((secs / 60))m$((secs % 60))s"
grep -E "Logic utilization|Total block memory bits" "output_files/$PROJECT.fit.summary" | sed 's/^/  /'

# worst setup and hold slack over all clocks (negative = timing not met)
for kind in Setup Hold; do
	slack=$(awk -F';' -v t="; $kind Summary" '
		index($0, t) == 1 { on = 1; next }
		on && !/^[;+]/    { exit }
		on && $3 ~ /[0-9]/ { gsub(/ /, "", $3); print $3 }' "output_files/$PROJECT.sta.rpt" | sort -g | head -1)
	echo "  Worst $kind slack: ${slack:-?} ns"
	case $slack in -*) echo "  WARNING: timing not met" ;; esac
done

ls -l "output_files/$PROJECT.rbf" | awk '{ print "  " $NF " (" $5 " bytes)" }'
