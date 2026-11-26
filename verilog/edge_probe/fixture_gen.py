#!/usr/bin/env python3
# fixture_gen.py - 6502 fixture programs for the video edge probe
# (PLAN_VIDEO_40COL_ENCODER_EDGE_2026-11-25 section 1).
#
# Emits, into this directory:
#   fixture_<mode>.hex   program bytes at $6000, $readmemh format (one byte/line)
#   fixture_<mode>.lst   byte listing with addresses (for review)
#   fixture_expected.md  marker table the scoreboard checks against
#
# Modes: gr (page-1 mixed LORES 40col), t40 (TEXT40), t80 (TEXT80 control),
#        hgr (HGR control).
#
# All screen writes are done by the CPU through normal soft-switch-selected
# pages; nothing is deposited into screen RAM by the TB (the TB only deposits
# the program and patches the reset vector, then re-resets).
#
# Marker layout (40-col modes), columns 0..39, 14 samples per cell:
#   col 0        : white marker (edge cell - the symptom is here)
#   col 1        : black neighbour
#   col 19       : white interior marker (start half of the 2-cell marker)
#   col 20       : second interior cell, distinguishable pattern
#   col 21       : black neighbour
#   col 39       : white right-edge marker (right-edge control)
#   cols 10..13  : colour patch (gr only), row above the marker row
# Text rows: normal space ($A0) background, inverse space ($20) markers.
#   (IIe $20-$3F is the flashing range; FLASH_CLK phase may invert the
#    appearance on some frames - the probe captures after many stable frames
#    and the expected table notes both polarities.)
# TEXT80: aux byte $20 at even columns (white marker), main byte $A0 at odd
#   columns; markers at display columns 0, 39/40, 78, 79.

import sys, os

ORG = 0x6000

class Asm:
    def __init__(self):
        self.code = bytearray()
        self.labels = {}
        self.fixups = []   # (offset, label)
        self.lst = []

    @property
    def pc(self):
        return ORG + len(self.code)

    def label(self, name):
        self.labels[name] = self.pc

    def emit(self, *bs):
        for b in bs:
            self.code.append(b & 0xFF)

    # --- instructions used ---
    def sei(self):  self.emit(0x78)
    def cld(self):  self.emit(0xD8)
    def txa_(self): pass
    def ldx_imm(self, v): self.emit(0xA2, v)
    def txs(self):  self.emit(0x9A)
    def lda_imm(self, v): self.emit(0xA9, v)
    def ldy_imm(self, v): self.emit(0xA0, v)
    def bit_abs(self, a): self.emit(0x2C, a & 0xFF, a >> 8)
    def sta_abs(self, a): self.emit(0x8D, a & 0xFF, a >> 8)
    def sta_zp(self, a):  self.emit(0x85, a)
    def sta_absy(self, a): self.emit(0x99, a & 0xFF, a >> 8)
    def iny(self): self.emit(0xC8)
    def inx(self): self.emit(0xE8)
    def bne(self, label):
        self.fixups.append((len(self.code), label, self.pc + 2))
        self.emit(0xD0, 0)
    def jmp_self(self):
        a = self.pc
        self.emit(0x4C, a & 0xFF, a >> 8)

    def resolve(self):
        for off, label, after in self.fixups:
            target = self.labels[label]
            rel = target - after
            assert -128 <= rel <= 127, f"branch {label} out of range"
            self.code[off + 1] = rel & 0xFF

    def listing(self):
        lines = []
        a = ORG
        i = 0
        while i < len(self.code):
            lines.append(f"{a:04X}: {' '.join(f'{b:02X}' for b in self.code[i:i+8])}")
            i += 8
            a += 8
        return "\n".join(lines) + "\n"


def prologue(a):
    a.sei(); a.cld(); a.ldx_imm(0xFF); a.txs()

def soft(a, *sw):
    # $C00x keyboard soft switches latch on WRITE only (machine/apple2.v:540
    # gates on we); $C05x video switches respond to any access. Use STA for
    # $C000-$C00F, BIT for the rest.
    for s in sw:
        if (s & 0xFFF0) == 0xC000:
            a.sta_abs(s)
        else:
            a.bit_abs(s)

# Apple IIe soft switches
TEXTCLR, TEXTSET   = 0xC050, 0xC051
MIXCLR,  MIXSET    = 0xC052, 0xC053
PAGE1,   PAGE2     = 0xC054, 0xC055
LORES,   HIRES     = 0xC056, 0xC057
COL80OFF, COL80ON  = 0xC00C, 0xC00D
STORE80OFF, STORE80ON = 0xC000, 0xC001
ALTCHAROFF = 0xC00E
AN3OFF     = 0xC05E
RDMAINRAM, RDAUXRAM = 0xC002, 0xC003
WRMAIN_OFF, WRMAIN_ON = 0xC004, 0xC005   # $C004: writes->aux, $C005: writes->main

SCREEN = 0x0400
AUXSCR = 0x0400   # aux text page 1 same offsets

def row_addr(row):
    """Apple II text/lores screen row base offset within $0400 page."""
    return (row & 7) * 0x80 + (row >> 3) * 0x28

def clear_loop(a, extra_pages=0):
    # LDA #$00 / LDY #$00 / L: STA $0400,Y ... INY BNE L
    a.lda_imm(0x00)
    a.ldy_imm(0x00)
    a.label("clr")
    pages = [SCREEN + p * 0x100 for p in range(4 + extra_pages)]
    for p in pages[:4]:
        a.sta_absy(p)
    a.iny()
    a.bne("clr")

def clear_main_and_aux(a):
    # clear main $0400-$07FF then aux $0400-$07FF (80STORE off, WRMAIN off
    # writes aux on the IIe)
    a.sta_abs(STORE80OFF)
    a.lda_imm(0x00)
    a.ldy_imm(0x00)
    a.label("clrm")
    for p in (0x0400, 0x0500, 0x0600, 0x0700):
        a.sta_absy(p)
    a.iny()
    a.bne("clrm")
    a.sta_abs(WRMAIN_OFF)  # writes now go to aux
    a.ldy_imm(0x00)
    a.label("clra")
    for p in (0x0400, 0x0500, 0x0600, 0x0700):
        a.sta_absy(p)
    a.iny()
    a.bne("clra")
    a.sta_abs(WRMAIN_ON)   # back to main writes

def store_pair(a, addr, value):
    a.lda_imm(value)
    a.sta_abs(addr)

def finish(a):
    a.label("done")
    a.jmp_self()

def build_gr():
    """Page-1 mixed LORES: graphics rows 0..15, text rows 20..23."""
    a = Asm()
    prologue(a)
    soft(a, COL80OFF, ALTCHAROFF, STORE80OFF, AN3OFF, PAGE1,
         TEXTCLR, MIXSET, LORES)
    clear_loop(a)
    # colour patch: graphics row 6 (byte row 6), cols 10..13
    base6 = SCREEN + row_addr(6)
    for i, col in enumerate((0x11, 0x22, 0x55, 0x99)):
        store_pair(a, base6 + 10 + i, col)
    # marker row: graphics row 8 -> byte row 8 (upper nibble = row 8 white,
    # lower nibble = row 9 black for col19; col20 inverted nibbles)
    base8 = SCREEN + row_addr(8)
    store_pair(a, base8 + 0, 0xFF)    # col0 white both rows
    store_pair(a, base8 + 19, 0xF0)   # col19 white(row8)/black(row9)
    store_pair(a, base8 + 20, 0x0F)   # col20 black(row8)/white(row9)
    store_pair(a, base8 + 39, 0xFF)   # col39 white
    # text row 21 (mixed): inverse-space markers
    base21 = SCREEN + row_addr(21)
    for c in range(40):
        store_pair(a, base21 + c, 0x20 if c in (0, 19, 20, 39) else 0xA0)
    finish(a)
    a.resolve()
    return a

def build_t40():
    a = Asm()
    prologue(a)
    soft(a, COL80OFF, ALTCHAROFF, STORE80OFF, AN3OFF, PAGE1,
         TEXTSET, MIXCLR)
    clear_loop(a)
    # fill with normal spaces, markers inverse on row 10
    for row in range(24):
        base = SCREEN + row_addr(row)
        for c in range(40):
            v = 0x20 if (row == 10 and c in (0, 19, 20, 39)) else 0xA0
            store_pair(a, base + c, v)
    finish(a)
    a.resolve()
    return a

def build_t80():
    a = Asm()
    prologue(a)
    soft(a, COL80ON, ALTCHAROFF, AN3OFF, PAGE1, TEXTSET, MIXCLR)
    clear_main_and_aux(a)
    # row 10: aux = even display cols, main = odd display cols (80COL on)
    base = row_addr(10)
    # main: spaces everywhere, inverse at odd marker cols 39, 79
    for c in range(40):
        v = 0x20 if c in (39, 79 - 40) else 0xA0   # main col39 = display 79
        store_pair(a, SCREEN + base + c, v)
    # aux: inverse at even display cols 0, 38, 78 -> aux bytes 0, 19, 39
    a.sta_abs(WRMAIN_OFF)  # writes go aux
    for c in range(40):
        v = 0x20 if c in (0, 19, 39) else 0xA0
        store_pair(a, AUXSCR + base + c, v)
    a.sta_abs(WRMAIN_ON)   # restore main writes
    finish(a)
    a.resolve()
    return a

def build_hgr(dhgr=False):
    a = Asm()
    prologue(a)
    if dhgr:
        # DHGR quirk state: HIRES + DHIRES(AN3 on, $C05F) + ~TEXT + ~COL80
        soft(a, COL80OFF, ALTCHAROFF, STORE80OFF, PAGE1,
             TEXTCLR, MIXCLR, HIRES)
        a.bit_abs(0xC05F)   # DHIRES on
    else:
        soft(a, COL80OFF, ALTCHAROFF, STORE80OFF, AN3OFF, PAGE1,
             TEXTCLR, MIXCLR, HIRES)
    # clear HGR page 1 $2000-$3FFF via zero-page indirect indexed:
    # LDA #$00 / STA $02 / LDA #$20 / STA $03 / LDX #$20 / LDY #$00
    # loop: STA ($02),Y / INY / BNE loop / INC $03 / DEX / BNE loop
    a.lda_imm(0x00)
    a.sta_zp(0x02)
    a.lda_imm(0x20)
    a.sta_zp(0x03)
    a.ldx_imm(0x20)
    a.ldy_imm(0x00)
    a.label("clrh")
    a.emit(0x92, 0x02)          # STA ($02),Y
    a.iny()
    a.bne("clrh")
    a.emit(0xE6, 0x03)          # INC $03
    a.emit(0xCA)                # DEX
    a.bne("clrh")               # outer loop back to clrh (fixup-computed)
    # marker scanline row 80 (HGR line 80 = row 10 of screen mapping):
    # HGR line L -> offset ((L>>6)*0x28) + ((L>>3)&7)*0x400 + (L&7)*0x80
    def hgr_off(line):
        # HGR: $80*(L&7) + $400*((L>>3)&7) + $28*(L>>6)  (NOT the text-row form)
        return (line & 7) * 0x80 + ((line >> 3) & 7) * 0x400 + (line >> 6) * 0x28
    off = hgr_off(80)
    # white bars: each HGR byte = 7 pixels. Marker at display col 0 ->
    # HGR byte 0 (LSB-first). Use $7F (7 white pixels, half-pixel phase 0).
    # col0 marker: bytes 0,1 (14 px = one 40-col cell)
    store_pair(a, 0x2000 + off + 0, 0x7F)
    store_pair(a, 0x2000 + off + 1, 0x7F)
    # interior marker bytes 26,27 (~col 18.5) and right marker bytes 38,39
    store_pair(a, 0x2000 + off + 26, 0x7F)
    store_pair(a, 0x2000 + off + 27, 0x7F)
    store_pair(a, 0x2000 + off + 38, 0x7F)
    store_pair(a, 0x2000 + off + 39, 0x7F)
    finish(a)
    a.resolve()
    return a

def main():
    outdir = os.path.dirname(os.path.abspath(__file__))
    builds = {"gr": build_gr, "t40": build_t40, "t80": build_t80,
              "hgr": build_hgr, "dhgr": lambda: build_hgr(dhgr=True)}
    for name, fn in builds.items():
        a = fn()
        hexpath = os.path.join(outdir, f"fixture_{name}.hex")
        lstpath = os.path.join(outdir, f"fixture_{name}.lst")
        with open(hexpath, "w", newline="\n") as f:
            for b in a.code:
                f.write(f"{b:02X}\n")
        with open(lstpath, "w", newline="\n") as f:
            f.write(f"; fixture_{name} - {len(a.code)} bytes at ${ORG:04X}\n")
            f.write(a.listing())
        print(f"{name}: {len(a.code)} bytes -> {hexpath}")
    # expected-marker doc
    with open(os.path.join(outdir, "fixture_expected.md"), "w", newline="\n") as f:
        f.write("""# Fixture marker expectations (scoreboard source)

Screen row base: `(row&7)*$80 + (row>>3)*$28` within the $0400 page.
40-col cell = 14 samples of the 560-pixel active window.

| mode | marker row | markers (display columns) | notes |
|------|-----------|---------------------------|-------|
| gr   | graphics row 8 (scanline row*8+3 sampled) | 0, 19, 20, 39 | col19=$FF, col20=$0F (row8 black, row9 white); colour patch row 6 cols 10-13 ($11/$22/$55/$99); mixed text row 21 same columns as inverse spaces |
| t40  | text row 10 | 0, 19, 20, 39 | inverse space $20 (IIe flash range - polarity may alternate per 16-frame FLASH_CLK phase; expected table accepts both) |
| t80  | text row 10 | display cols 0, 38(aux), 39(main), 78(aux), 79(main) | aux=even cols, main=odd |
| hgr  | HGR line 80 | HGR bytes 0-1 (px 0-13), 26-27 (px 182-195), 38-39 (px 266-279) | $7F bars, control mode |

Expected left marker start (40-col): DE sample 0..13 (col 0).
Expected interior marker start: DE samples 19*14=266 .. 20*14+13=293.
Expected right marker end: DE sample 559 (col 39 spans 546..559).
""")
    print("fixture_expected.md written")

if __name__ == "__main__":
    main()
