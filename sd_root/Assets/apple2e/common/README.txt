Data slot files for platform "apple2e" (platform-common location).

The host loads EXACTLY:  disk.woz   ("filename": "disk", ext "woz").
Other .woz files here are swap-in spares (rename one to disk.woz to use it).

Reference CRC32s (the on-screen overlay shows the CRC of what the
SDRAM actually holds after load + readback; N is always 39000 hex
= 234,496 bytes for these fixtures):

  disk.woz              = DOS 3.3 System Master   crc32=74ea1324
  My BASIC programs.woz = scratch/BASIC disk      crc32=9d392af6

Note: "My BASIC programs", "Test Scratch Disk 2" and "# Blank Disk
(made from dos3.3 master)" in ..\..\..\..\apple2saves are byte-
identical copies of the same image (9d392af6).

If disk.woz is missing, the core boots normally and shows "NO FILE".

Joy2key .a2k profiles (core 0.2.7+; per-slot "Custom" from 0.4.4):
  Format: 16 bytes - slots 0-3 = right/left/down/up dpad, 4-9 = A/B/L/R/
  X/Y face, 10-15 = the same with Select held. A byte is an Apple key
  code; 0 = no key (button does nothing), >127 stored as no key.
  Activation (0.4.4+): a loaded profile is only USED when the matching
  option says so - DPad Keys = "Custom (.a2k profile)" feeds slots 0-3,
  Fire Keys = "Custom (.a2k profile)" feeds slots 4-15 (either can mix
  with a preset on the other option). Set an option to Off or any preset
  to stop using the profile for those slots - that is the off-switch.
  On 0.4.3 and earlier a present file overrode everything and could not
  be switched off; there, load off.a2k as the off-profile instead.
  disk.a2k          the default profile - the .a2k data slot's filename is
                    cloned from the disk slot (fixed name "disk"), so this
                    file is loaded at boot and is what the Custom options
                    read. Shipped default = IJKL_layout (L/J/K/I + U/O +
                    Space/Return).
  off.a2k           all-zero profile: every button does nothing (the
                    explicit "off" profile).
  Joy2key\          spare profiles, organized as:
    IJKL_layout, QAOP_layout, cursor_space_enter - generic layouts
    Game Specific\ - per-game maps (Alien Typhoon, Castle
                    Wolfenstein, Karateka, Snake Byte, Thunderbirds GX)
    Others\ - tester.a2k: label test (each button types its own
                    slot letter; use it to verify a mapping)
  If you re-pick the disk by name in the interact browser instead of
  renaming, the profile name follows the picked base name
  (JungleHunt.woz -> JungleHunt.a2k) - keep spares named to match.
  The "joy2key profile" media option in the core UI loads any .a2k from
  this folder for the current session (the choice does not persist;
  next boot returns to disk.a2k).

Hard disk slot (core 0.3.5, HDV writable; the Boot Media option controls
  the HD's read/write state, and writes default OFF until you pick a
  "write" Boot Media value):
  RAW .hdv ONLY - no .2mg (64-byte container header; the bridge reads
  sector*512 with no skip, so every block lands 64 bytes off) and no
  .po (a floppy format in the wrong slot).
  NoxArchaist.HDV          1.4 MB  small bootable image - first test target
  Total Replay v6.1.hdv   32 MB   ProDOS MLI target (the C700 ROM is a full
                                  ProDOS driver; Total Replay drives the HD
                                  via $C70D)
  Pick one in the core's "hard disk" media option (deferload slot; the
  choice is for the session). "Boot Media" selects what the ROM sees,
  plus the HD's write state (one combined option):
  Both, read-only (default) = HD card + floppy, HD read-only;
  Both, write = HD card + floppy, HD writable;
  Floppy (no HD) = HD off the bus (guaranteed floppy boot - use this to
    recover if a .hdv selection is blocking the floppy);
  HDD, read-only = floppy off, HD read-only;
  HDD, write = floppy off, HD writable.
  Before any HD boot test: release all
  joystick buttons and make sure the OSK Open-Apple latch is CLEAR - a
  held Open Apple after a successful block-0 read routes boot to the
  floppy (ROM $C77F, driver GH#370). Trigger the HD boot explicitly
  (C700G / PR#7); do not rely on the state-dependent cold-reset scan.
  The OSK Reset key is now a true COLD boot (build 2026-10-30_0937):
  it runs the ROM slot-scan, so Reset is also a way to re-enter the
  HD boot path.
