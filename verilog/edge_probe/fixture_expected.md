# Fixture marker expectations (scoreboard source)

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
