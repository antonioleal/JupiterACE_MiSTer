## Jupiter Ace for MiSTer FPGA

### Features:
- RAM 51KB
- Turbo x2, x4, and Tape Fast Load / Fast Save (8x while the tape runs)
- Scandoubler with HQ2x
- Loads and saves *.ACE snapshots
- Supports *.TAP and *.TZX tapes (up to 128KB)

### Install
1. Copy `JupiterACE.rbf` to the root of the SD card (or to `_Computer/`).
2. Put your .ace, .tap and .tzx files in `games/JupiterACE/`; subfolders are
   fine.

Loading works with just these two steps. Saving to tape and saving snapshots
also need the helper script, installed once:

3. Copy `scripts/JupiterACE.sh` to `/media/fat/Scripts/`.
4. On the MiSTer, open the OSD **Scripts** menu and run `JupiterACE`.
   It:
   - creates `games/JupiterACE/boot1.vhd` (257.5 KB, fixed size), the file
     the core writes snapshots, tape saves and delete requests into;
   - adds itself to `/media/fat/linux/user-startup.sh`, so it starts at
     every boot;
   - starts watching for saves. It should report "Started".
5. Load the JupiterACE core again, so the MiSTer mounts `boot1.vhd`. Until
   then, **Save Snapshot** shows "Snapshot: run JupiterACE.sh" and tape
   saves show "Save failed: run JupiterACE.sh".

"Tape saved" and "Snapshot saved" appear once the script has written the
file. If the script is not running, the OSD shows "JupiterACE.sh not running"
after about 8 seconds instead; the save is kept in `boot1.vhd` and written
when the script starts, as long as nothing else is saved in between.

To update the script, copy the new version over the old one and run
`JupiterACE` from the OSD **Scripts** menu again (or reboot the MiSTer).

To remove the script, run `bash /media/fat/Scripts/JupiterACE.sh stop`, delete
its line from `/media/fat/linux/user-startup.sh`, then delete the script and
`games/JupiterACE/boot1.vhd`.

The script's log is `/tmp/jupiterace_saved.log`.

### Tapes
1. OSD → **Insert Tape** and pick a `.tap` or `.tzx` file. The tape is rewound.
2. Type `LOAD name` (dictionary) or `0 0 BLOAD name` (bytes) on the Ace.
3. Start the tape with **Tape Play/Pause**, or turn on **Tape Autoplay**
   (off by default): the tape then plays by itself while the ROM is loading
   and pauses when it stops. **Tape Rewind** goes back to the start.

**Tape Auto Rewind** (off by default): once loading ends (the program
loaded, or you pressed BREAK, or there was an error) the tape rewinds to the
start, so the next `LOAD` finds any program on it. If the tape reaches its end
while the Ace is still searching for a name, it rewinds and keeps searching,
like a tape loop, until the program is found or you press BREAK. A `LOAD` with
a blank name is left where it is, as it means "the next file".

To eject the tape, use OSD → **Eject Tape** (or press **Backspace** in the
**Insert Tape** file browser).

**Tape Fast Load** (off by default): while the tape plays, the CPU and the
tape both run 8 times faster, so a program loads in an eighth of the time.
It works for every kind of tape, including TZX turbo loaders, because the
whole machine speeds up together.

**Tape Fast Save** (off by default) does the same while the Ace saves to tape.

The disk LED is lit while the tape plays. **Tape Sound** lets you hear it.

Tapes load correctly at every **CPU Speed** setting.

TZX support: standard/turbo/pure data, pure tone, pulse sequences, direct
recordings, pauses, loops and signal level blocks. A "stop the tape" block
pauses manual playback. Other blocks (text, info, CSW, generalized data,
jumps/calls) are skipped.

### Saving to tape
Use `SAVE name` / `BSAVE name` on the Ace as usual. The OSD shows "Tape saved" when done.

**Onto an inserted tape:** the saved program replaces the program with the
same name on the tape, or is added at the end. The old tape file is kept in
`games/JupiterACE/previous/` (same subfolder, with a timestamp).

**With no tape inserted, `SAVE` starts a new tape** (the OSD shows "New tape
created"). It becomes `games/JupiterACE/<name>.tap`, named
after the program you saved; if that file already exists it becomes
`<name>_2.tap`, `<name>_3.tap`, ... so no tape is ever overwritten. Later
saves go onto the same new tape until you insert or eject a tape. Characters
that cannot be in a file name become `_`.

**New Tape Format** (OSD, default TAP) chooses whether a new tape is a `.tap`
or a `.tzx` file. A tape you insert keeps its own format.

Programs saved onto a `.tzx` tape are stored as TZX "turbo data" (0x11)
blocks holding the Ace ROM's own tape timings, so any TZX player reproduces
them exactly as the Ace wrote them.

After a save the tape is positioned at the saved program, so `VERIFY name`
works straight away.

This needs the helper script (see Install).

How it works: the core writes the saved programs into
`games/JupiterACE/boot1.vhd`; the script finds the inserted tape file (the
MiSTer keeps it open, so its exact path is known, subfolder included), or
creates the new tape, and merges them in. Log: `/tmp/jupiterace_saved.log`.

### Saving snapshots
OSD → **Save Snapshot** stops the Ace for a moment and saves the whole machine
(RAM 2000-FFFF, character set and CPU registers) as
`games/JupiterACE/SNAPnnn.ace`: SNAP001.ace, SNAP002.ace, ... numbered after
the highest SNAPnnn.ace in `games/JupiterACE` and its subfolders. Load it back
with **Load Snapshot**. The OSD shows "Snapshot saved" when done.

This needs the helper script (see Install). How it works: the core writes
each snapshot into `games/JupiterACE/boot1.vhd`, reusing the same space every
time, so the file never grows; the script copies each new snapshot out as the
next SNAPnnn.ace.

### Deleting files
OSD → **Delete File** opens a file browser for `.tap`, `.tzx` and `.ace` files.
The file you pick is moved to `games/JupiterACE/previous/deleted/` (same
subfolder; a timestamp is added if a file with that name is already there), so
a wrong pick can be undone by moving it back. The OSD shows "File deleted".
Deleting the inserted tape also ejects it. There is no confirmation step:
picking the file deletes it.

This needs the helper script (see Install). Files already in `previous/`
are never deleted. If the OSD shows "JupiterACE.sh not running", start the
script; "Delete failed: see log" means the script could not find or move
the file (`/tmp/jupiterace_saved.log` says why).
