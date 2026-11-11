## Jupiter Ace for MiSTer FPGA

### Features
- Memory 3K, 19K, 35K, 51K (default) or 99K with Edwin Blink's 96K RAM pack
- CPU speed Normal, x2 and x4
- Scandoubler with HQ2x
- Loads and saves `.ace` snapshots (SNAP001.ace, SNAP002.ace, ...)
- Loads `.tap` and `.tzx` tapes (up to 128KB), with optional auto play,
  auto rewind and 8x fast load
- Saves to tape with `SAVE` / `BSAVE`: onto the inserted tape (replacing a
  program with the same name, with backups of the old version), or onto a new
  `.tap` or `.tzx` tape named after the program; optional 8x fast save
- Spools Forth source files (`.fth`) into the Ace, typed 8x
  faster than by hand
- Saves the dictionary as a Forth source file (DICT001.fth, ...) that spools
  back
- Deletes `.tap`, `.tzx`, `.ace` and `.fth` files from the OSD (recoverable for 30 days)

### Install
1. Copy `JupiterACE.rbf` to the root of the SD card (or to `_Computer/`).
2. Put your .ace, .tap and .tzx files in `games/JupiterACE/`; subfolders are
   fine.

Loading and spooling work with just these two steps. Saving to tape, saving
snapshots, saving the dictionary and deleting files also need the helper
script, installed once:

3. Copy `scripts/JupiterACE.sh` to `/media/fat/Scripts/`.
4. On the MiSTer, open the OSD **Scripts** menu and run `JupiterACE`.
   It:
   - creates `games/JupiterACE/boot1.vhd` (339.5 KB, fixed size), the file
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

**Uninstalling.** When installed, the script adds this line to
`/media/fat/linux/user-startup.sh`, which starts its watcher at every boot:

    [ -f "/media/fat/Scripts/JupiterACE.sh" ] && bash "/media/fat/Scripts/JupiterACE.sh" start

When you remove the core, remove the script too:

1. Stop the watcher: `bash /media/fat/Scripts/JupiterACE.sh stop`
2. Delete that line from `/media/fat/linux/user-startup.sh` (with a text editor,
   or `sed -i '/JupiterACE\.sh/d' /media/fat/linux/user-startup.sh`).
3. Delete `/media/fat/Scripts/JupiterACE.sh` and `games/JupiterACE/boot1.vhd`.

The line does nothing once the script is gone (it checks that the file is
there), but it is best removed so `user-startup.sh` stays clean.

The script's log is `/tmp/jupiterace_saved.log`. It is cleared at every
reboot.

### Saving your OSD settings
The tape and display options (Tape Auto Play, Tape Auto Rewind, Tape Sound,
Tape Fast Load, Tape Fast Save, New Tape Format, Aspect ratio, Scandoubler Fx,
Scale, CPU Speed and Memory) are in OSD → **Options**.

OSD options are kept only once you save them: set them, press **Right** on
the OSD to go to its second page, and choose **Save settings**. They are
stored in `/media/fat/config/JupiterACE.CFG` and loaded every time the core
starts. **Reset settings** on the same page goes back to the defaults.

### Memory
OSD → **Options** → **Memory** chooses how much RAM the Ace has:

| Memory | RAM pack | RAM ends at (RAMTOP) |
|---|---|---|
| 3K | none: the Ace's own 1K video, 1K character set and 1K program RAM | `4000` |
| 19K | 16K | `8000` |
| 35K | 32K | `C000` |
| 51K (default) | 48K | `0000` (top of memory) |
| 99K | 96K: two 48K pages | `0000` (top of memory) |

Changing it restarts the Ace. Missing RAM ignores writes and reads `FF`, so the
ROM's RAM test at power-on finds the size, as on the real machine.

**The 96K RAM pack** is Edwin Blink's design
([jupiter-ace.co.uk](https://jupiter-ace.co.uk/hardware_96kram_pack.html)), as
in [xAce-baremetal](https://github.com/antonioleal/xAce-baremetal): two 48K
pages, both at `4000-FFFF`; the Ace's own 3K is never paged. It starts on page
0 and works as a 48K pack (the ROM finds 51K). Bit 7 of the Z80's R register
selects the page: the pack latches it in every refresh cycle, and only `LD R,A`
changes it, so `LD A,128 : LD R,A` gives page 1 and `XOR A : LD R,A` page 0.
The new page takes over at the refresh after the next opcode fetch (that opcode
still comes from the old page) or at an interrupt, so code that switches pages
should run below `4000`. A reset goes back to page 0.

**Snapshots and memory:** a snapshot records the memory size at `2080` and
holds memory up to RAMTOP, as other emulators expect. With the 96K pack the
page in use is saved as usual and the other page follows the end marker
(`XACE96K`, as xAce does); other emulators stop at the end marker and load it
as a 51K snapshot. Loading a snapshot that needs more memory than is set (by
its RAMTOP, its size, or a 96K page) enlarges the memory for it: the OSD shows
"Memory raised for snapshot", and **Memory** in the OSD keeps your setting
until you change it.

### Tapes
1. OSD → **Insert Tape** and pick a `.tap` or `.tzx` file. The tape is rewound.
2. Type `LOAD name` (dictionary) or `0 0 BLOAD name` (bytes) on the Ace.
3. Start the tape with **Tape Play/Pause**, or turn on **Tape Auto Play**
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

### Spooling Forth source
OSD → **Spool Forth File** and pick a `.fth` file: it is typed
into the Ace line by line, as if from the keyboard, and each line is run or
compiled before the next one. The Ace runs 8 times faster while spooling, so
it takes about 12 seconds per 1000 characters. Close the OSD to watch it.

- `( ... )` comments outside definitions are left out (the Ace would answer
  them with ERROR 4); comments inside definitions are kept, so `LIST` shows
  them. Text in `." ..."` and the character after `ASCII` are typed as they are.
- Empty lines are skipped, tabs become spaces, and `£` and `©` are typed as the
  Ace's own characters. Other characters the Ace does not have are skipped.
- Caps lock, graphics and inverse mode are switched off first.
- An `ERROR n` does not stop spooling. A line the Ace does not accept does: it
  is left in the editor, so you can see what is wrong.
- The keyboard is ignored while spooling, except **Esc**, which stops it
  (as does OSD → **Stop Spool**).

At the end the OSD shows "Spool done", "Spool done with errors", "Spool
stopped: line not OK" or "Spool stopped".

### Saving the dictionary
OSD → **Save Dictionary** closes the OSD and saves the words you have defined
as Forth source in `games/JupiterACE/DICTnnn.fth`: DICT001.fth, DICT002.fth,
... numbered after the highest DICTnnn.fth in `games/JupiterACE` and its
subfolders. Spool the file back to get the words again. The OSD shows
"Dictionary saved" when done.

- Words defined with `:`, `DEFINER` and `COMPILER` are written exactly as `LIST`
  shows them.
- Variables and constants are written with their current value, other words
  (`CREATE`, machine code, data) as `create` with their bytes.
- If a word uses a newer word (after `REDEFINE`), it is written after it.
- The file starts with `decimal` and ends with a few lines that restore what
  re-spooling alone would not (links and flags of the words).

How it works: the core stops the Ace for a moment and writes all of memory
into `games/JupiterACE/boot1.vhd`; the script turns the words into Forth
source. The Ace itself is not changed.

### Deleting files
OSD → **Delete \*.TAP,TZX,ACE,FTH** opens a file browser for `.tap`, `.tzx`,
`.ace` and `.fth` files.
The file you pick is moved to `games/JupiterACE/deleted/` (same subfolder; a
timestamp is added if a file with that name is already there), so a wrong pick
can be undone by moving it back within 30 days; after that it is erased.
Picking a file that is already in `deleted/` erases it for good. The OSD shows
"File deleted" once you close the OSD.
Deleting the inserted tape also ejects it. There is no confirmation step:
picking the file deletes it. Files in `backup/` are never deleted.

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
| Snapshot: run JupiterACE.sh | `boot1.vhd` is missing: install the script, then load the core again (also for **Save Dictionary**). |
| Snapshot failed: CPU busy | The Ace could not be stopped (for example, during a reset). Try again. |
| Snapshot failed: see log | The script could not write the snapshot file. |
| Snapshot failed: too big | A 99K snapshot did not fit in `boot1.vhd` (only with memory that packs badly). |
| Memory raised for snapshot | The snapshot needed more memory than set; it was enlarged for it. |
| File deleted | The file was moved to `deleted/`, or erased if it was already there. |
| Delete failed: see log | The script could not find or move the file. |
| Delete: run JupiterACE.sh | `boot1.vhd` is missing: install the script, then load the core again. |
| Spool done | The whole file was typed. |
| Spool done with errors | The whole file was typed, but some lines gave an `ERROR n`. |
| Spool stopped: line not OK | The Ace did not accept a line; it is left in the editor. |
| Spool stopped | Stopped with **Esc** or **Stop Spool**. |
| Dictionary saved | The words were saved as the next DICTnnn.fth. |
| Dictionary failed: see log | There were no words to save, or the script could not write the file. |
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
