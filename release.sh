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
#  release.sh - copy the built core to releases/JupiterACE_YYYYMMDD.rbf
#
#  Builds first (./build.sh) when output_files/JupiterACE.rbf is missing or
#  older than any source file. A release made earlier the same day is
#  replaced.
#============================================================================

PROJECT=JupiterACE
RBF=output_files/$PROJECT.rbf

cd "$(dirname "$(readlink -f "$0")")" || exit 1

# sources: anything newer than the rbf means it must be rebuilt
newer=
if [ -f "$RBF" ]; then
	newer=$(find "$PROJECT.sv" "$PROJECT.qsf" "$PROJECT.qpf" files.qip rtl sys -type f -newer "$RBF" -print -quit)
fi

if [ ! -f "$RBF" ] || [ -n "$newer" ]; then
	if [ -f "$RBF" ]; then echo "Sources changed since the last build ($newer): rebuilding."
	else echo "No $RBF yet: building."; fi
	./build.sh || exit 1
fi

out=releases/${PROJECT}_$(date +%Y%m%d).rbf
mkdir -p releases
[ -f "$out" ] && echo "Replacing today's release $out"
cp "$RBF" "$out" || exit 1
echo "Release: $out ($(stat -c %s "$out") bytes)"
