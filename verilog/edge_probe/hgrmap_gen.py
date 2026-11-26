# One-shot: HGR probe fixture - markers at addresses computed from
# addr(L) = $2000 + $1000*((L-1)>>6) + $80*((L-1)&7) + $28*(((L-1)>>3)&7)
# byte 10 = $7F. If mapping right: line_cnt 66 shows marker; if standard
# formula: line 93 shows it.
import sys
sys.path.insert(0, '.')
from fixture_gen import Asm, prologue, soft, COL80OFF, ALTCHAROFF, STORE80OFF, AN3OFF, PAGE1, TEXTCLR, MIXCLR, HIRES, store_pair

def addr(L):
    Lm = L - 1
    return 0x2000 + 0x1000*(Lm>>6) + 0x80*(Lm & 7) + 0x28*((Lm>>3) & 7)

a = Asm()
prologue(a)
soft(a, COL80OFF, ALTCHAROFF, STORE80OFF, AN3OFF, PAGE1, TEXTCLR, MIXCLR, HIRES)
# zero both pages quickly: only the lines that matter for confusion; do full
# clear of $2000-$3FFF via indirect loop (same as hgr fixture)
a.lda_imm(0x00); a.sta_zp(0x02); a.lda_imm(0x20); a.sta_zp(0x03)
a.ldx_imm(0x20); a.ldy_imm(0x00); a.label("clrh")
a.emit(0x92, 0x02); a.iny(); a.bne("clrh"); a.emit(0xE6, 0x03)
a.emit(0xCA); a.bne("clrh")
for L in (66, 70):
    store_pair(a, addr(L) + 10, 0x7F)
    print(f"line {L}: addr ${addr(L)+10:04X}", file=sys.stderr)
a.label("done"); a.jmp_self()
a.resolve()
with open("fixture_hgrmap.hex", "w", newline="\n") as f:
    for b in a.code:
        f.write(f"{b:02X}\n")
print(f"wrote fixture_hgrmap.hex ({len(a.code)} bytes)", file=sys.stderr)
