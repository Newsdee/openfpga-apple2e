# Apple IIe for Analogue Pocket — 0.3.6

The first release with **savestate save and load**. You can now save a
running Apple IIe from the Pocket's host menu and load it back later —
the machine resumes exactly where it was.

## Savestates

- **Save** from the host's Save States menu: the core snapshots the
  machine (main + auxiliary RAM and the core's shadow registers) into
  the Pocket's SDRAM, and the host writes it to the core's *Save States*
  folder on your SD card (one `.sta` file per state).
- **Load** from the same menu: the host writes the state back, the core
  checks the header (magic, size, version, CPU) and restores the machine.
  A corrupt, empty, or incompatible file is **refused** — it cannot
  clobber a running machine or a good state.
- Save and load both work while the core is paused by the host (the
  standard Pocket flow); repeated save/load cycles are stable.
- What a state holds: the machine's RAM and internal register state —
  so the screen, the programs in memory, and the keyboard state come
  back intact. Media (floppy/HDD images) is untouched by savestates;
  it is whatever was mounted when you load.

## Nothing else changes

Video, audio, keyboard, floppy, and hard-disk behavior are as in 0.3.5.
The development serial console and on-screen debug lines that were used
to bring up savestates are compiled out of this build; they stay
available in the development tree for future diagnostics.

## Known limitations

- Savestates are per-host-slot: use the host's menu for naming,
  duplicates, and deletion (the core handles whatever slot file the
  host points it at).
- A state saved on this core is for this core (the header carries a
  core magic) — it does not port to other Apple II cores.

---

*Technical bring-up record (diagnostic builds, root causes, hardware
captures): the EXPERT_BRIEF_SAVESTATE_* docs and `builds/2026-11-17_*`
/ `builds/2026-11-18_*` manifests in the repository.*
