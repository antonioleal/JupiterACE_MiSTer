#!/bin/bash

# Copyright 2026 Antonio Leal, Porto Salvo, Oeiras, Portugal
# All rights reserved.
#
# Redistribution and use of this script, with or without modification, is
# permitted provided that the following conditions are met:
#
# 1. Redistributions of this script must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#
#  THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
#  WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
#  MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO
#  EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
#  PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
#  OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
#  WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
#  OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
#  ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#============================================================================
#  JupiterACE.sh - tape saves and snapshots for the JupiterACE core
#
#  The core cannot create files, so this script creates a fixed-size file,
#  games/JupiterACE/boot1.vhd, that Main_MiSTer mounts when the core starts,
#  and watches it. The core writes snapshots into its first half and tape
#  saves into its second half.
#
#  Tapes: when the Ace SAVEs onto the inserted tape, this script merges each
#  saved program into the inserted tape file (games/JupiterACE/..., any
#  subfolder), replacing a program with the same name or appending it.
#  Before each update the tape file is copied to games/JupiterACE/backup/
#  (same subfolder, with a timestamp); the newest KEEP_BACKUPS (3) copies of
#  each tape are kept. With no tape inserted, SAVE starts a
#  new tape: it becomes games/JupiterACE/<program name>.tap (with _2, _3, ...
#  if that name is taken), and later saves in the session go into it.
#
#  Snapshots: each new snapshot is copied to games/JupiterACE/SNAPnnn.ace,
#  numbered after the highest SNAPnnn.ace found in any subfolder.
#
#  Save Dictionary: the core dumps all of memory into the snapshot area; the
#  user's words are written as Forth source to games/JupiterACE/DICTnnn.fth
#  (listed as the ROM's LIST would), ready to be spooled back.
#
#  Delete File: the file picked in the OSD is moved to
#  games/JupiterACE/backup/deleted/ (same subfolder) and erased from there
#  after DELETED_DAYS (30) days; the answer goes back to the core, which
#  shows it on the OSD.
#
#  Usage (bash + BusyBox only):
#    JupiterACE.sh            install into user-startup.sh and start
#    JupiterACE.sh start      start the watcher in the background
#    JupiterACE.sh stop       stop the watcher
#    JupiterACE.sh daemon     run the watcher in the foreground
#    JupiterACE.sh once       process boot1.vhd now (testing)
#
#  Log: /tmp/jupiterace_saved.log
#============================================================================

FAT=${JA_FAT:-/media/fat}
GAMES=$FAT/games/JupiterACE
PREV=$GAMES/backup
KEEP_BACKUPS=3             # backups kept per tape in backup/
DELETED_DAYS=30            # days a file stays in backup/deleted/
VHD=$GAMES/boot1.vhd       # written by the core (SD slot 1): sectors 0-256 snapshots,
VHD_SECTORS=515            #   257-513 tape saves, 514 delete requests
SAV_OFF=$((257 * 512))     # start of the tape save area
DEL_OFF=$((514 * 512))     # delete request sector
STARTUP=$FAT/linux/user-startup.sh
SELF=$(readlink -f "$0")
RUN=${JA_RUN:-/tmp}
LOG=$RUN/jupiterace_saved.log
MAP=$RUN/jupiterace_saved.map
PID=$RUN/jupiterace_saved.pid
WORK=$RUN/jupiterace_saved.work

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ---- binary helpers (little-endian, like the MiSTer's ARM CPU) ----
u8()   { local v; v=$(od -An -tu1 -j "$2" -N1 "$1" | tr -d ' \n'); echo "${v:-0}"; }
u16()  { echo $(( $(u8 "$1" "$2") + $(u8 "$1" $(($2 + 1))) * 256 )); }
u24()  { echo $(( $(u16 "$1" "$2") + $(u8 "$1" $(($2 + 2))) * 65536 )); }
u32()  { echo $(( $(u16 "$1" "$2") + $(u16 "$1" $(($2 + 2))) * 65536 )); }
hexs() { od -An -tx1 -v -j "$2" -N "$3" "$1" | tr -d ' \n'; }
# range FILE OFFSET LENGTH: copy LENGTH bytes starting at OFFSET to stdout
range() { [ "$3" -gt 0 ] && tail -c +$(($2 + 1)) "$1" | head -c "$3"; return 0; }
fsize() { stat -c %s "$1"; }

# ---- block lists ----
# blocks FILE FORMAT START: one line per block: "offset length kind name"
#   kind H = Ace header block (name = 10 name bytes in hex), D = data block, O = other
blocks() {
	local f=$1 fmt=$2 off=$3 size id len end dl fl
	size=$(fsize "$f")
	if [ "$fmt" = 0 ]; then
		# TAP: [len lo][len hi][block]; a 26-byte block is a header (no block-type byte)
		while [ $((off + 2)) -le "$size" ]; do
			len=$(u16 "$f" "$off")
			end=$((off + 2 + len))
			[ "$end" -gt "$size" ] && break
			if [ "$len" -eq 26 ]; then
				echo "$off $((end - off)) H $(hexs "$f" $((off + 3)) 10)"
			else
				echo "$off $((end - off)) D -"
			fi
			off=$end
		done
	else
		# TZX: walk the blocks by ID
		while [ "$off" -lt "$size" ]; do
			id=$(u8 "$f" "$off")
			dl=-1; fl=0
			case $id in
				16) dl=$(u16 "$f" $((off + 3))); len=$((5 + dl)); fl=5 ;;     # 0x10 standard data
				17) dl=$(u24 "$f" $((off + 16))); len=$((19 + dl)); fl=19 ;;  # 0x11 turbo data
				18) len=5 ;;
				19) len=$((2 + 2 * $(u8 "$f" $((off + 1))))) ;;
				20) dl=$(u24 "$f" $((off + 8))); len=$((11 + dl)); fl=11 ;;   # 0x14 pure data
				21) len=$((9 + $(u24 "$f" $((off + 6))))); dl=0 ;;            # 0x15 direct recording
				32|35|36) len=3 ;;
				34|37|39) len=1 ;;
				33|48) len=$((2 + $(u8 "$f" $((off + 1))))) ;;
				38) len=$((3 + 2 * $(u16 "$f" $((off + 1))))) ;;
				40|50) len=$((3 + $(u16 "$f" $((off + 1))))) ;;
				43) len=6 ;;
				49) len=$((3 + $(u8 "$f" $((off + 2))))) ;;
				51) len=$((2 + 3 * $(u8 "$f" $((off + 1))))) ;;
				52) len=9 ;;
				53) len=$((21 + $(u32 "$f" $((off + 17))))) ;;
				64) len=$((5 + $(u24 "$f" $((off + 2))))) ;;
				90) len=10 ;;
				*) len=$((5 + $(u32 "$f" $((off + 1))))) ;;
			esac
			[ $((off + len)) -gt "$size" ] && break
			if [ "$dl" -eq 27 ] && [ "$fl" -gt 0 ] && [ "$(u8 "$f" $((off + fl)))" -eq 0 ]; then
				echo "$off $len H $(hexs "$f" $((off + fl + 2)) 10)"
			elif [ "$dl" -ge 0 ]; then
				echo "$off $len D -"
			else
				echo "$off $len O -"
			fi
			off=$((off + len))
		done
	fi
}

# merge_pair TAPE FORMAT HEADER_FILE DATA_FILE NAMEHEX: replace by name, else append
merge_pair() {
	local w=$1 fmt=$2 hf=$3 df=$4 name=$5 start=0 size o l k n
	local hoff=-1 hend=0 doff=-1 dend=0
	[ "$fmt" = 1 ] && start=10
	size=$(fsize "$w")
	while read -r o l k n; do
		if [ "$hoff" -lt 0 ]; then
			[ "$k" = H ] && [ "$n" = "$name" ] && { hoff=$o; hend=$((o + l)); }
		elif [ "$k" = D ]; then
			doff=$o; dend=$((o + l)); break
		elif [ "$k" = H ]; then
			break
		fi
	done < <(blocks "$w" "$fmt" "$start")

	if [ "$hoff" -lt 0 ]; then
		cat "$w" "$hf" "$df" > "$w.new"
	elif [ "$doff" -lt 0 ]; then
		{ range "$w" 0 "$hoff"; cat "$hf" "$df"; range "$w" "$hend" $((size - hend)); } > "$w.new"
	else
		{ range "$w" 0 "$hoff"; cat "$hf"; range "$w" "$hend" $((doff - hend)); cat "$df"; range "$w" "$dend" $((size - dend)); } > "$w.new"
	fi
	mv "$w.new" "$w"
	[ "$hoff" -ge 0 ]
}

# is_tape CRC LEN FILE: FILE has the cksum of the tape the core loaded
is_tape() {
	local c s
	read -r c s _ < <(cksum "$3")
	[ "$c" = "$1" ] && [ "$s" = "$2" ]
}

# find_tape CRC LEN: the inserted tape file
find_tape() {
	local f pid
	# Main_MiSTer keeps the mounted tape open: use its path
	for pid in $(pidof MiSTer); do
		for f in /proc/"$pid"/fd/*; do
			f=$(readlink "$f")
			case $f in
				"$PREV"/*) ;;
				*.[tT][aA][pP]|*.[tT][zZ][xX]) [ -f "$f" ] && is_tape "$1" "$2" "$f" && { echo "$f"; return 0; } ;;
			esac
		done
	done
	# otherwise any tape in games/JupiterACE with the same contents
	while IFS= read -r f; do
		is_tape "$1" "$2" "$f" && { echo "$f"; return 0; }
	done < <(find "$GAMES" -path "$PREV" -prune -o -type f \( -iname '*.tap' -o -iname '*.tzx' \) -print)
	return 1
}

# done_mark OFFSET STATE: answer the core about the data whose header is at
# OFFSET in boot1.vhd: 3 = handled, 4 = failed (the core shows it on the OSD)
done_mark() { printf "\\00$2" | dd of="$VHD" bs=1 seek=$(($1 + 12)) count=1 conv=notrunc 2>/dev/null; }

# safe_name NAME: an Ace program name as a file name
safe_name() {
	local n
	n=$(printf '%s' "$1" | sed 's/ *$//; s/^ *//; s/[^A-Za-z0-9._-]/_/g')
	echo "${n:-tape}"
}

# merge_save: merge the programs saved in the tape save area of boot1.vhd into
# the inserted tape, or into a new <program name>.tap for a new tape
# (0 = done, 1 = failed, 2 = nothing to do)
merge_save() {
	local h=$WORK/sav_hdr ext fmt crc ilen plen newt token name target key rel dir fname ts o l k n hdr cnt=0 rep=0 created=
	[ -f "$VHD" ] || return 2
	[ "$(fsize "$VHD")" -ge $((SAV_OFF + 512)) ] || return 2
	mkdir -p "$WORK"
	range "$VHD" "$SAV_OFF" 512 > "$h"
	[ "$(head -c 8 "$h" | tr -d '\000')" = "JACESAV1" ] || return 2
	[ "$(u8 "$h" 12)" -eq 2 ] || return 2
	fmt=$(u8 "$h" 13); newt=$(u8 "$h" 14); crc=$(u32 "$h" 16); ilen=$(u32 "$h" 20); plen=$(u32 "$h" 24)
	token=$(u32 "$h" 40); name=$(range "$h" 28 10 | tr -d '\000' | sed 's/ *$//')
	if [ "$(fsize "$VHD")" -lt $((SAV_OFF + 512 + plen)) ]; then
		log "boot1.vhd: bad tape save length $plen"; return 1
	fi

	if [ "$newt" = 1 ]; then key="new $token"; else key="$crc $ilen"; fi
	target=$([ -f "$MAP" ] && awk -F'|' -v k="$key" '$1 == k { p = substr($0, length(k) + 2) } END { print p }' "$MAP")
	if [ -z "$target" ] || [ ! -f "$target" ]; then
		if [ "$newt" = 1 ]; then
			# a new tape: named after the program saved on it, never over another file;
			# .tap or .tzx as chosen in the OSD "New Tape Format"
			ext=tap; [ "$fmt" = 1 ] && ext=tzx
			o="$GAMES/$(safe_name "$name")"; target="$o.$ext"; n=1
			while [ -e "$target" ]; do n=$((n + 1)); target="${o}_$n.$ext"; done
			mkdir -p "$GAMES" || { log "cannot create $GAMES"; return 1; }
			if [ "$fmt" = 1 ]; then
				# TZX file header: "ZXTape!", 0x1A, version 1.20
				printf 'ZXTape!\032\001\024' > "$target" || { log "cannot create $target"; return 1; }
			else
				: > "$target" || { log "cannot create $target"; return 1; }
			fi
			created=1
		elif ! target=$(find_tape "$crc" "$ilen"); then
			log "cannot find the inserted tape (it was changed or moved); not saved"
			return 1
		fi
		echo "$key|$target" >> "$MAP"
	fi

	case $target in
		"$GAMES"/*)
			rel=${target#"$GAMES"/}
			dir=$PREV/$(dirname "$rel"); [ "$(dirname "$rel")" = . ] && dir=$PREV ;;
		*)	rel=$target; dir=$(dirname "$target")/backup ;;
	esac
	# archive the current version (a tape created just now has none)
	if [ -z "$created" ]; then
		fname=$(basename "$target")
		ts=$(date +%Y%m%d_%H%M%S)
		mkdir -p "$dir" || { log "cannot create $dir"; return 1; }
		o="$dir/${fname%.*}_$ts"; n=1
		while [ -e "$o.${fname##*.}" ]; do n=$((n + 1)); o="$dir/${fname%.*}_${ts}_$n"; done
		cp "$target" "$o.${fname##*.}" || { log "cannot archive $target"; return 1; }
		prune_backups "$dir" "${fname%.*}" "${fname##*.}"
	fi

	# merge every program saved since the tape was inserted, in order
	range "$VHD" $((SAV_OFF + 512)) "$plen" > "$WORK/payload"
	cp "$target" "$WORK/tape"
	hdr=
	while read -r o l k n; do
		if [ "$k" = H ]; then
			range "$WORK/payload" "$o" "$l" > "$WORK/hdr"; hdr=$n
		elif [ "$k" = D ] && [ -n "$hdr" ]; then
			range "$WORK/payload" "$o" "$l" > "$WORK/data"
			merge_pair "$WORK/tape" "$fmt" "$WORK/hdr" "$WORK/data" "$hdr" && rep=$((rep + 1))
			cnt=$((cnt + 1)); hdr=
		fi
	done < <(blocks "$WORK/payload" "$fmt" 0)

	if [ "$cnt" -eq 0 ]; then
		log "no complete program in the tape save"
		[ -n "$created" ] && rm -f "$target"
		return 1
	fi
	cat "$WORK/tape" > "$target.tmp" && mv "$target.tmp" "$target" || { log "cannot write $target"; return 1; }
	if [ -n "$created" ]; then
		log "$rel: new tape, saved \"$name\""
	else
		log "$rel: saved $cnt program(s) ($rep replaced, $((cnt - rep)) added), last \"$name\"; old version in ${dir#"$GAMES"/}"
	fi
	return 0
}

# process: handle a tape save and answer the core
process() {
	merge_save
	case $? in
		0) done_mark "$SAV_OFF" 3 ;;
		1) done_mark "$SAV_OFF" 4 ;;
	esac
}

# make_vhd: create boot1.vhd, or bring it to its full size (0 = changed now)
make_vhd() {
	local have=0
	[ -f "$VHD" ] && have=$(( $(fsize "$VHD") / 512 ))
	[ "$have" -ge "$VHD_SECTORS" ] && return 1
	mkdir -p "$GAMES" && dd if=/dev/zero of="$VHD" bs=512 seek="$have" count=$((VHD_SECTORS - have)) conv=notrunc 2>/dev/null
	log "made $VHD $((VHD_SECTORS * 512)) bytes"
	return 0
}

# ---- backups in backup/ ----
# prune_backups DIR BASE EXT: keep only the newest $KEEP_BACKUPS backups of a tape
# (backups are BASE_YYYYMMDD_HHMMSS[_n].EXT, so name order is age order)
prune_backups() {
	local d=$1 b=$2 e=$3 n f
	n=$(ls "$d/$b"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]*."$e" 2>/dev/null | wc -l)
	[ "$n" -gt "$KEEP_BACKUPS" ] || return 0
	ls "$d/$b"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]*."$e" | sort | head -n $((n - KEEP_BACKUPS)) |
	while IFS= read -r f; do rm -f "$f" && log "removed old backup ${f#"$GAMES"/}"; done
}

# purge_deleted: empty backup/deleted/ of files deleted more than $DELETED_DAYS days ago
purge_deleted() {
	local f
	[ -d "$PREV/deleted" ] || return 0
	find "$PREV/deleted" -type f -mtime +"$DELETED_DAYS" | while IFS= read -r f; do
		rm -f "$f" && log "removed ${f#"$GAMES"/} (deleted over $DELETED_DAYS days ago)"
	done
	find "$PREV/deleted" -depth -type d | while IFS= read -r f; do
		[ "$f" = "$PREV/deleted" ] || rmdir "$f" 2>/dev/null   # only empty folders go
	done
}

# ---- Delete File ----
# answer N: tell the core how the delete request went (3 = deleted, 4 = not)
answer() { done_mark "$DEL_OFF" "$1"; }

# delete_req: move the file picked in the OSD "Delete File" to backup/deleted/
delete_req() {
	local h=$WORK/del_hdr crc len f pid target rel dest base ext ts
	[ -f "$VHD" ] && [ "$(fsize "$VHD")" -ge $((DEL_OFF + 512)) ] || return 0
	mkdir -p "$WORK"
	range "$VHD" "$DEL_OFF" 512 > "$h"
	[ "$(head -c 8 "$h" | tr -d '\000')" = "JACEDEL1" ] || return 0
	[ "$(u8 "$h" 12)" -eq 2 ] || return 0
	crc=$(u32 "$h" 16); len=$(u32 "$h" 20)

	# the picked file is open in Main_MiSTer: find it by its checksum
	target=
	for pid in $(pidof MiSTer); do
		for f in /proc/"$pid"/fd/*; do
			f=$(readlink "$f")
			case $f in
				"$PREV"/*) ;;
				*.[tT][aA][pP]|*.[tT][zZ][xX]|*.[aA][cC][eE])
					[ -f "$f" ] && is_tape "$crc" "$len" "$f" && { target=$f; break 2; } ;;
			esac
		done
	done
	if [ -z "$target" ]; then
		log "Delete File: the picked file was not found (only .tap/.tzx/.ace outside backup/ are deleted)"
		answer 4; return 0
	fi

	case $target in
		"$GAMES"/*) rel=${target#"$GAMES"/}; dest=$PREV/deleted/$rel ;;
		*)          rel=$target; dest=$(dirname "$target")/backup/deleted/$(basename "$target") ;;
	esac
	if [ -e "$dest" ]; then
		ts=$(date +%Y%m%d_%H%M%S); base=${dest%.*}; ext=${dest##*.}
		dest="${base}_$ts.$ext"
	fi
	if mkdir -p "$(dirname "$dest")" && mv "$target" "$dest"; then
		touch "$dest"   # the 30 days count from the deletion, not from the file's own date
		log "Delete File: moved $rel to ${dest#"$GAMES"/}"
		answer 3
	else
		log "Delete File: cannot move $rel"
		answer 4
	fi
}

# ---- dictionary as Forth source ----
# DICT_AWK reads all of memory (0000-FFFF, ROM included, as "od -tu1" numbers)
# and writes the user dictionary as Forth source that spools back, like xAce's
# F7. Words are found from 3C51h (after the FORTH vocabulary word) to STKBOT
# by their length fields. Colon, DEFINER and COMPILER words are listed exactly
# as the ROM's LIST would (this copies LIST's code: L1672-L17FB in the ROM);
# variables and constants are written with their value, other words as
# CREATE with their bytes. Words that use newer ones come after them, and
# links, flags and the newest word's length field that re-spooling would not
# reproduce are set at the end. Exit status 3: no words.
# (BusyBox awk reads "name (" as a function call: never follow a variable by a bracket)
DICT_AWK='
function w(a) { return mem[a % 65536] + 256 * mem[(a + 1) % 65536] }
function s16(v) { return v >= 32768 ? v - 65536 : v }

# ---- LIST: printing ----
function emit(c,   t) {
	if (c == 13) { LN[nl++] = cur; cur = "" }
	else { t = (c >= 32 && c < 127) ? CH[c] : " "; cur = cur t }
}
function emits(s) { cur = cur s }
function prstr(p,   c, n) {                 # pr_string_sp: up to the bit-7 character, then a space
	for (n = 0; n < 80; n++) {
		c = mem[p]; emit(c % 128)
		if (c >= 128) break
		p = (p + 1) % 65536
	}
	emit(32)
}
function prname(de,   h, a, len, p, n) {    # L17E4: the name of the word whose code field is at de
	h = (de + 65535) % 65536; a = mem[h]
	if (a < 128) {                         # a header: name before the link (and length field in RAM)
		len = a % 64; if (h >= 15360) len += 2
		p = (h - 2 - len + 65536) % 65536
	} else {                               # compiled by a COMPILER word: skip its inline bytes
		n = mem[(h + 65534) % 65536]
		if (n == 255) { n = w(bc); bc += 2 }
		bc += n
		p = (w((h + 65535) % 65536) + h) % 65536
	}
	prstr(p)
}
function indent(   i) {                     # L17C1: new line and indentation for a line'"'"'s first word
	if (ind3 >= 128) return
	emit(13); for (i = 0; i < ind3; i++) emit(32)
	ind3 = 255
}
function printfloat(v1, v2,   e, m0, m1, m2, s, E, a, z, d) {   # F. (L0AB1)
	m2 = v1 % 256; m1 = int(v1 / 256); m0 = v2 % 256; e = int(v2 / 256)
	s = ""; if (e >= 128) { s = "-"; e -= 128 }
	E = 0; a = (e + 255) % 256
	if (a >= 73 || a < 60) { e = 65; E = (a + 1) % 256 }
	if (e <= 64) { s = s "."; for (z = 0; z < 64 - e; z++) s = s "0" }
	for (z = 0; z < 40; z++) {
		if (e <= 64 && m0 == 0 && m1 == 0 && m2 == 0) break
		d = int(m0 / 16)
		m0 = (m0 % 16) * 16 + int(m1 / 16); m1 = (m1 % 16) * 16 + int(m2 / 16); m2 = (m2 % 16) * 16
		e--; s = s d
		if (e == 64) s = s "."
	}
	if (E == 0) s = s " "; else s = s "E" (E - 65) " "
	emits(s)
}
function line(   de, k, v1, v2, sb, n, i, ch) {   # L1708: one line, up to 5 words
	ind3 = ind2; cnt = 5
	while (1) {
		if (++guard > 20000) { bad = 1; return 1 }
		de = w(bc); bc += 2
		k = KIND[de]
		if (k == "in")       { ind3 = ind2; ind2 = (ind2 + 1) % 256; cnt = 1 }
		else if (k == "mid") { ind3 = (ind2 + 255) % 256; cnt = 1 }
		else if (k == "out") { ind2 = (ind2 + 255) % 256; ind3 = ind2; cnt = 1 }
		if (k == "lit")  { v1 = w(bc); bc += 2; indent(); emits(s16(v1) " ") }
		else if (k == "flit") { v1 = w(bc); bc += 2; v2 = w(bc); bc += 2; indent(); printfloat(v1, v2) }
		else if (k == "ascii") { ch = mem[bc % 65536]; indent(); prname(de); emit(ch); emit(32) }
		else if (k == "paren" || k == "dotq") {
			sb = bc; indent(); prname(de)
			n = w(sb); for (i = 0; i < n && i < 4096; i++) emit(mem[(sb + 2 + i) % 65536])
			emit(k == "paren" ? 41 : 34)
			return 0
		}
		else if (k == "exit") { emit(13); emit(59); emit(13); emit(32); return 1 }
		else { indent(); prname(de) }
		if (--cnt == 0) return 0
	}
}
function listword(i,   cfa, cf, a, b, j, s) {     # LIST (L1672)
	cur = ""; nl = 0; guard = 0; bad = 0
	cfa = WN[i] + 1; cf = w(cfa)
	emit(13)
	if (cf == 4360) { a = w(cfa + 2); b = mem[(a + 65533) % 65536]; emits((b >= 128 ? b - 256 : b) " ") }
	bc = cfa; prname(cf)
	bc = cfa + (cf == 3779 ? 2 : 4); prname(cfa)
	ind2 = 1
	while (1) if (line()) break
	emit(13)
	if (bad || bc > WE[i]) return 0
	for (j = 0; j < nl; j++) { s = LN[j]; sub(/ +$/, "", s); if (s != "") print s }
	return 1
}

# ---- the words ----
function holding(a,   i) { for (i = 0; i < nw; i++) if (a >= WS[i] && a < WE[i]) return i; return -1 }
function address(a,   o, off) {               # an address relative to the word holding it
	o = a >= 15441 ? holding(a) : -1
	if (o < 0) return s16(a) ""
	off = a - (WN[o] + 1)
	return off == 0 ? "find " NAME[o] : "find " NAME[o] " " off " +"
}
function as_bytes(i,   a, n, s, cf) {
	print "create " NAME[i]
	n = 0; s = ""
	a = WN[i] + 3
	while (a < WE[i]) {
		if (a + 1 < WE[i]) { s = s s16(w(a)) " , "; a += 2 }
		else { s = s mem[a] " c, "; a++ }
		n++
		if (n == 4) { print s; s = ""; n = 0 }
	}
	if (n > 0) print s
	cf = w(WN[i] + 1)
	if (cf != 4076) print address(cf) " find " NAME[i] " !"
	asbytes++
}

BEGIN {
	for (i = 32; i < 127; i++) CH[i] = sprintf("%c", i)
	# LIST'"'"'s table at L171B: control words change the indentation; others have inline data
	KIND[4739] = "in";  KIND[4767] = "in";  KIND[4899] = "in"              # IF BEGIN DO
	KIND[4721] = "mid"; KIND[4744] = "mid"; KIND[4328] = "mid"; KIND[4416] = "mid"   # ELSE WHILE DOES> RUNS>
	KIND[4772] = "out"; KIND[4749] = "out"; KIND[4726] = "out"; KIND[4914] = "out"; KIND[4924] = "out"  # THEN UNTIL REPEAT LOOP +LOOP
	KIND[4113] = "lit"; KIND[4196] = "flit"; KIND[4171] = "ascii"
	KIND[4985] = "paren"; KIND[5014] = "dotq"; KIND[1206] = "exit"
	n = 0
}
{ for (i = 1; i <= NF; i++) mem[n++] = $i + 0 }
END {
	stkbot = w(15415)
	nw = 0; st = 15441
	while (st < stkbot && nw < 2048) {
		last = st
		while (last < stkbot && mem[last] < 128 && last - st < 63) last++
		nlen = last - st + 1; nlf = last + 5
		if (last >= stkbot || mem[last] < 128 || nlf + 3 > stkbot || mem[nlf] % 64 != nlen) break
		s = ""
		for (i = 0; i < nlen; i++) { c = mem[st + i] % 128; t = (c >= 32 && c < 127) ? CH[c] : "?"; s = s t }
		NAME[nw] = s; WS[nw] = st; WN[nw] = nlf
		WL[nw] = w(last + 1); WK[nw] = w(last + 3); WF[nw] = mem[nlf]
		e = st + WL[nw] + nlen
		WE[nw] = (WL[nw] != 0 && e > nlf + 2 && e <= stkbot) ? e : stkbot
		CFAIDX[nlf + 1] = nw + 1
		st = WE[nw]; nw++
	}
	if (nw == 0) exit 3

	# words a word uses: code field addresses in its parameter field, and the word holding its code field
	nd = 0
	for (i = 0; i < nw; i++) {
		DF[i] = nd; DN[i] = 0; DONE[i] = 0
		cf = w(WN[i] + 1); o = cf >= 15441 ? holding(cf) : -1
		if (o >= 0 && o != i) { DEP[nd++] = o; DN[i]++ }
		for (a = WN[i] + 3; a + 1 < WE[i] && nd < 8192; a++) {
			u = CFAIDX[w(a)] - 1
			if (u >= 0 && u != i) { DEP[nd++] = u; DN[i]++ }
		}
	}
	reordered = 0
	for (n = 0; n < nw; n++) {
		ch = -1; old = -1
		for (i = 0; i < nw && ch < 0; i++) {
			if (DONE[i]) continue
			if (old < 0) old = i
			ok = 1
			for (d = 0; d < DN[i] && ok; d++) ok = DONE[DEP[DF[i] + d]]
			if (ok) ch = i
		}
		if (ch < 0) ch = old
		DONE[ch] = 1; ORD[n] = ch
		if (ch != n) reordered = 1
	}

	print "decimal"
	for (n = 0; n < nw; n++) {
		i = ORD[n]; cf = w(WN[i] + 1); par = WN[i] + 3; one = (WE[i] == par + 2)
		if (cf == 3779 || cf == 4229 || cf == 4360) { if (listword(i)) listed++; else as_bytes(i) }
		else if (cf == 4080 && one) print s16(w(par)) " variable " NAME[i]
		else if (cf == 4085 && one) print s16(w(par)) " constant " NAME[i]
		else as_bytes(i)
	}

	# what re-spooling would not reproduce
	if (WL[nw - 1] != 0 && !reordered) print s16(WL[nw - 1]) " find " NAME[nw - 1] " 5 - !"
	for (n = 0; n < nw; n++) {
		i = ORD[n]; want = (i == 0) ? 15433 : WN[i - 1]
		if (WK[i] != want) {
			t = CFAIDX[WK[i] + 1] - 1
			if (WK[i] == 0 || WK[i] == 15433 || t < 0) lk = s16(WK[i]) ""
			else lk = "find " NAME[t] " 1-"
			print lk " find " NAME[i] " 3 - !"
		}
		if (int(WF[i] / 64) != 0) print WF[i] " find " NAME[i] " 1- c!"
	}
	extra = ""
	if (reordered) extra = ", reordered"
	summary = nw " words (" (listed + 0) " listed, " (asbytes + 0) " as bytes" extra ")"
	print summary > "/dev/stderr"
}'

# next_name PREFIX EXT: the next free PREFIXnnn.EXT (searching all subfolders but backup/)
next_name() {
	local f n max=0 p=$1 e=$2
	while IFS= read -r f; do
		n=$(basename "$f"); n=${n:${#p}}; n=${n%.*}
		case $n in ''|*[!0-9]*) continue ;; esac
		n=$((10#$n))
		[ "$n" -gt "$max" ] && max=$n
	done < <(find "$GAMES" -path "$PREV" -prune -o -type f -iname "$p*.$e" -print)
	printf '%s/%s%03d.%s' "$GAMES" "$p" $((max + 1)) "$e"
}

# dict: write the dictionary dump in the snapshot area as DICTnnn.fth
dict() {
	local len out info rc
	len=$(u32 "$VHD" 16)
	if [ "$len" -ne 65536 ] || [ $((512 + len)) -gt "$(fsize "$VHD")" ]; then
		log "boot1.vhd: bad dictionary dump length $len"
		done_mark 0 4; return 0
	fi
	mkdir -p "$WORK"
	out=$(next_name DICT fth)
	range "$VHD" 512 65536 | od -An -v -tu1 | awk "$DICT_AWK" > "$out.tmp" 2> "$WORK/dict_info"
	rc=$?
	info=$(cat "$WORK/dict_info")
	if [ "$rc" -eq 3 ]; then
		rm -f "$out.tmp"; log "Save Dictionary: there are no words to save"
		done_mark 0 4; return 0
	fi
	if [ "$rc" -ne 0 ]; then
		rm -f "$out.tmp"; log "Save Dictionary failed (awk exit $rc): $(head -c 300 "$WORK/dict_info" | tr '\n' ' ')"
		done_mark 0 4; return 0
	fi
	if ! mv "$out.tmp" "$out"; then
		rm -f "$out.tmp"; log "Save Dictionary: cannot write $out"
		done_mark 0 4; return 0
	fi
	done_mark 0 3
	log "dictionary saved as ${out#"$GAMES"/}: $info"
}

# ---- snapshots ----

# snap: copy a complete, not yet copied snapshot out of boot1.vhd and answer the core
snap() {
	local len out
	[ -f "$VHD" ] || return 0
	[ "$(head -c 8 "$VHD" | tr -d '\000')" = "JACESNP1" ] || return 0
	[ "$(u8 "$VHD" 12)" -eq 2 ] || return 0
	[ "$(u8 "$VHD" 13)" -eq 1 ] && { dict; return 0; }
	len=$(u32 "$VHD" 16)
	if [ "$len" -lt 1 ] || [ $((512 + len)) -gt "$(fsize "$VHD")" ]; then
		log "boot1.vhd: bad snapshot length $len"
		done_mark 0 4; return 0
	fi
	out=$(next_name SNAP ace)
	range "$VHD" 512 "$len" > "$out.tmp" && mv "$out.tmp" "$out" || { log "cannot write $out"; done_mark 0 4; return 0; }
	done_mark 0 3
	log "snapshot saved as ${out#"$GAMES"/} ($len bytes)"
}

daemon() {
	local m vm= day=
	echo $$ > "$PID"
	log "watching $VHD"
	make_vhd && log "load the JupiterACE core again so it uses the new boot1.vhd"
	while true; do
		if [ -f "$VHD" ]; then
			m=$(stat -c '%Y %s' "$VHD")
			[ "$vm" != "$m" ] && { snap; process; delete_req; vm=$(stat -c '%Y %s' "$VHD"); }
		fi
		# once a day (and at start): empty old files out of backup/deleted/
		[ "$day" != "$(date +%Y%m%d)" ] && { purge_deleted; day=$(date +%Y%m%d); }
		sleep 2
	done
}

running() { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }

start() {
	if running; then echo "Already running."; return; fi
	if command -v setsid >/dev/null; then
		setsid bash "$SELF" daemon < /dev/null > /dev/null 2>&1 &
	else
		nohup bash "$SELF" daemon < /dev/null > /dev/null 2>&1 &
	fi
	sleep 1
	if running; then echo "Started. Log: $LOG"; else echo "Failed to start."; fi
}

case "$1" in
	daemon) daemon ;;
	start)  start ;;
	stop)   running && kill "$(cat "$PID")" && rm -f "$PID" && echo "Stopped." ;;
	once)   process; snap; delete_req; purge_deleted ;;
	"")
		make_vhd && echo "Made $VHD: load the JupiterACE core again before saving."
		# restart, so an updated script takes over from the running watcher
		running && kill "$(cat "$PID")" && rm -f "$PID" && sleep 1
		line="[ -f \"$SELF\" ] && bash \"$SELF\" start"
		if ! grep -qF "$SELF" "$STARTUP" 2>/dev/null; then
			mkdir -p "$(dirname "$STARTUP")"
			[ -f "$STARTUP" ] || echo "#!/bin/sh" > "$STARTUP"
			echo "$line" >> "$STARTUP"
			echo "Added to $STARTUP"
		fi
		start
		;;
	*) echo "usage: $0 [start|stop|daemon|once]"; exit 1 ;;
esac
