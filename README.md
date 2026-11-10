## Jupiter Ace for MiSTer FPGA

### Features
- RAM 51KB
- CPU speed Normal, x2 and x4
- Scandoubler with HQ2x
- Loads and saves `.ace` snapshots (SNAP001.ace, SNAP002.ace, ...)
- Loads `.tap` and `.tzx` tapes (up to 128KB), with optional autoplay,
  auto rewind and 8x fast load
- Saves to tape with `SAVE` / `BSAVE`: onto the inserted tape (replacing a
  program with the same name, with backups of the old version), or onto a new
  `.tap` or `.tzx` tape named after the program; optional 8x fast save
- Deletes `.tap`, `.tzx` and `.ace` files from the OSD (recoverable for 30 days)

### Install
1. Copy `JupiterACE.rbf` to the root of the SD card (or to `_Computer/`).
2. Put your .ace, .tap and .tzx files in `games/JupiterACE/`; subfolders are
   fine.

Loading works with just these two steps. Saving to tape, saving snapshots
and deleting files also need the helper script, installed once:

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

The script's log is `/tmp/jupiterace_saved.log`. It is cleared at every
reboot.

### Saving your OSD settings
OSD options are kept only once you save them: set them, press **Right** on
the OSD to go to its second page, and choose **Save settings**. They are
stored in `/media/fat/config/JupiterACE.CFG` and loaded every time the core
starts. **Reset settings** on the same page goes back to the defaults.

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
like a tape loop, until the program is found or you press BREAK. After a
`LOAD` with a blank name the tape is not rewound.

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
Use `SAVE name` / `BSAVE name` on the Ace as usual. The OSD shows "Tape
saved" when done. A tape and everything saved onto it must fit in 128 KB.

**Onto an inserted tape:** the saved program replaces the program with the
same name on the tape, or is added at the end.

**Backups in `backup/`:** before every save onto an inserted `.tap` or
`.tzx` file, the tape as it was is copied to `games/JupiterACE/backup/`,
in the same subfolder, with the date and time added to its name:

    games/JupiterACE/arcade/game.tzx
    games/JupiterACE/backup/arcade/game_20261110_223521.tzx

Only the newest 3 copies of each tape are kept; older ones are removed. To go
back to an earlier version, copy the backup back under the tape's own name,
for example over ssh:

    cp /media/fat/games/JupiterACE/backup/arcade/game_20261110_223521.tzx /media/fat/games/JupiterACE/arcade/game.tzx

A new tape (see below) has no backup for its first save, as there was no file
before it.

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

How it works: the core writes the saved programs into
`games/JupiterACE/boot1.vhd`; the script finds the inserted tape file (the
MiSTer keeps it open, so its exact path is known, subfolder included), or
creates the new tape, and merges them in.

### Saving snapshots
OSD → **Save Snapshot** closes the OSD, stops the Ace for a moment and saves
the whole machine (RAM 2000-FFFF, character set and CPU registers) as
`games/JupiterACE/SNAPnnn.ace`: SNAP001.ace, SNAP002.ace, ... numbered after
the highest SNAPnnn.ace in `games/JupiterACE` and its subfolders. Load it back
with **Load Snapshot**; the Ace carries on exactly where it was. The OSD shows
"Snapshot saved" when done.

How it works: the core writes each snapshot into `games/JupiterACE/boot1.vhd`,
reusing the same space every time, so the file never grows; the script copies
each new snapshot out as the next SNAPnnn.ace.

### Deleting files
OSD → **Delete File** opens a file browser for `.tap`, `.tzx` and `.ace` files.
The file you pick is moved to `games/JupiterACE/backup/deleted/` (same
subfolder; a timestamp is added if a file with that name is already there), so
a wrong pick can be undone by moving it back within 30 days; after that it is
erased. The OSD shows "File deleted" once you close the OSD.
Deleting the inserted tape also ejects it. There is no confirmation step:
picking the file deletes it. Files already in `backup/` are never deleted.

### OSD messages
Messages appear while the OSD is closed.

| Message | Meaning |
|---|---|
| Tape saved | The program was saved and the tape file updated. |
| New tape created | `SAVE` with no tape inserted started a new tape. |
| Tape full: save discarded | The tape and its saves would exceed 128 KB. Insert another tape, or eject to start a new one. |
| Save failed: bad block | The saved data did not check out. Save again. |
| Save failed: run JupiterACE.sh | `boot1.vhd` is missing: install the script, then load the core again. |
| Tape save failed: see log | The script could not update the tape (for example, the tape file was moved). |
| Snapshot saved | The snapshot was saved as the next SNAPnnn.ace. |
| Snapshot: run JupiterACE.sh | `boot1.vhd` is missing: install the script, then load the core again. |
| Snapshot failed: CPU busy | The Ace could not be stopped (for example, during a reset). Try again. |
| Snapshot failed: see log | The script could not write the snapshot file. |
| File deleted | The file was moved to `backup/deleted/`. |
| Delete failed: see log | The script could not find or move the file. |
| Delete: run JupiterACE.sh | `boot1.vhd` is missing: install the script, then load the core again. |
| JupiterACE.sh not running | The script did not answer: run `JupiterACE` from the OSD **Scripts** menu. |

"See log" means `/tmp/jupiterace_saved.log` on the MiSTer says why.

### Building from source
Needs Quartus Prime Lite 17.0.2 on Linux.

- `./build.sh` builds `output_files/JupiterACE.rbf` (about 6 minutes) and
  prints the resources used and the timing slack. `./build.sh clean` starts
  from scratch. Set `QUARTUS_BIN` if Quartus is not in the default place.
- `./release.sh` copies the rbf to `releases/JupiterACE_YYYYMMDD.rbf` (today's
  date), rebuilding first if any source changed.
- `./copy_to_mister.sh` copies the rbf and the script to a MiSTer reachable as
  `root@mister`.

### Credits
Based on the [Jupiter Ace core for MiSTer](https://github.com/MiSTer-devel/Jupiter_MiSTer)
by Sorgelig, with the T80 Z80 CPU core and the MiSTer framework. Licensed
under the GNU General Public License, version 2 or later.
