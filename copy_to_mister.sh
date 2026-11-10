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

# Copy the core and the helper script to the MiSTer.
# One SSH connection is opened first and shared by both copies,
# so the password is asked only once.

HOST=${MISTER:-root@mister}
SSH_OPT=(-o ControlMaster=auto -o "ControlPath=/tmp/copy_to_mister-%C" -o ControlPersist=30)

cd "$(dirname "$(readlink -f "$0")")" || exit 1

ssh "${SSH_OPT[@]}" -fN "$HOST" || { echo "Cannot connect to $HOST"; exit 1; }
trap 'ssh "${SSH_OPT[@]}" -O exit "$HOST" 2>/dev/null' EXIT

scp "${SSH_OPT[@]}" output_files/JupiterACE.rbf "$HOST":/media/fat/_Computer/ &&
scp "${SSH_OPT[@]}" scripts/JupiterACE.sh "$HOST":/media/fat/Scripts/ &&
echo "Copied to $HOST"
