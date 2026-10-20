#!/usr/bin/env python3
# Build src/fpga/core/apple2e/io_sdram_pocket.v from the pinned io_sdram.v
# with a minimal, documented diff (expert M0 review, Unit 1).
import hashlib, sys

ROOT = 'E:/MiSTer/Apple-II_FPGAdev/apple2e-pocket'
src_path = f'{ROOT}/src/fpga/core/apple2e/io_sdram.v'
dst_path = f'{ROOT}/src/fpga/core/apple2e/io_sdram_pocket.v'

d = open(src_path, 'rb').read()
orig_sha = hashlib.sha256(d).hexdigest()
ref_sha = '0c53ad4d83b24b8b1772730c9daf8b73f6ccd8868876fd43c90d906c5b7d5738'
assert orig_sha == ref_sha, f'stock io_sdram.v changed: {orig_sha}'

CRLF = b'\r\n'

def rep1(d, old, new, label):
    n = d.count(old)
    assert n == 1, f'{label}: expected 1 occurrence, got {n}'
    return d.replace(old, new)

# 1. header
old = (b'//\r\n// io_sdram\r\n//\r\n// 2019-2022 Analogue\r\n//\r\n')
new = (
    b'//\r\n'
    b'// io_sdram_pocket - Pocket-local variant of io_sdram\r\n'
    b'//\r\n'
    b'// Base: pinned open-fpga core-example-basicassets (e5f9c0a) io_sdram.v,\r\n'
    b'// SHA-256 0c53ad4d83b24b8b1772730c9daf8b73f6ccd8868876fd43c90d906c5b7d5738\r\n'
    b'// (refs/basicassets/ - kept immutable). 2019-2022 Analogue; Pocket diff\r\n'
    b'// 2026-10-19 per M0_STORAGE_REVIEW_HANDOVER_2026-10-19.md.\r\n'
    b'//\r\n'
    b'// POCKET DIFF (the only changes from the base, each marked in-line):\r\n'
    b'//   1. module renamed io_sdram -> io_sdram_pocket\r\n'
    b'//   2. new port word_done     - 1-cycle pulse when a word WRITE op completes\r\n'
    b'//   3. new port word_rd_valid - 1-cycle pulse when word_q (32-bit) is complete\r\n'
    b'//                                (the base had this as a commented-out line)\r\n'
    b'//   4. new port boot_done     - init sequence complete, stable afterwards\r\n'
    b'//   5. word_busy now asserted for the duration of an op (base only cleared it)\r\n'
    b'// No other line differs. Verify: diff io_sdram.v io_sdram_pocket.v\r\n'
    b'//\r\n'
)
d = rep1(d, old, new, 'header')

# 2. module name
d = rep1(d, b'module io_sdram (', b'module io_sdram_pocket (', 'module name')

# 3. new ports
old = (b'output  reg     [31:0]  word_q,\r\n'
       b'output  reg             word_busy\r\n'
       b');')
new = (b'output  reg     [31:0]  word_q,\r\n'
       b'output  reg             word_busy,   // POCKET-DIFF: now actually asserted\r\n'
       b'output  reg             word_done,      // POCKET-DIFF: write op complete\r\n'
       b'output  reg             word_rd_valid,  // POCKET-DIFF: word_q complete\r\n'
       b'output  reg             boot_done       // POCKET-DIFF: init complete\r\n'
       b');')
d = rep1(d, old, new, 'ports')

# 4. pulse defaults in the main always block
old = (b'    burst_data_valid <= 0;\r\n'
       b'    burstwr_ready <= 0;\r\n')
new = (b'    burst_data_valid <= 0;\r\n'
       b'    burstwr_ready <= 0;\r\n'
       b'    word_done <= 0;      // POCKET-DIFF: 1-cycle pulses\r\n'
       b'    word_rd_valid <= 0;\r\n')
d = rep1(d, old, new, 'pulse defaults')

# 5. ST_RESET: clear boot_done
old = (b'        cmd <= CMD_NOP;\r\n'
       b'        delay_boot <= 0;\r\n')
new = (b'        cmd <= CMD_NOP;\r\n'
       b'        delay_boot <= 0;\r\n'
       b'        boot_done <= 0; // POCKET-DIFF\r\n')
d = rep1(d, old, new, 'ST_RESET clear')

# 6. ST_BOOT_5: set boot_done
old = (b'            phy_dqm <= 2\'b00;\r\n'
       b'            \r\n'
       b'            state <= ST_IDLE;\r\n'
       b'        end\r\n'
       b'    end\r\n'
       b'\r\n'
       b'    \r\n'
       b'    ST_IDLE: begin')
new = (b'            phy_dqm <= 2\'b00;\r\n'
       b'            boot_done <= 1; // POCKET-DIFF: init sequence complete\r\n'
       b'            \r\n'
       b'            state <= ST_IDLE;\r\n'
       b'        end\r\n'
       b'    end\r\n'
       b'\r\n'
       b'    \r\n'
       b'    ST_IDLE: begin')
d = rep1(d, old, new, 'ST_BOOT_5 set')

# 7. ST_IDLE: word_busy on acceptance (two branches)
old = (b'        if(word_rd_queue) begin\r\n'
       b'            word_rd_queue <= 0;\r\n'
       b'            word_op <= 1;\r\n')
new = (b'        if(word_rd_queue) begin\r\n'
       b'            word_rd_queue <= 0;\r\n'
       b'            word_op <= 1;\r\n'
       b'            word_busy <= 1; // POCKET-DIFF\r\n')
d = rep1(d, old, new, 'word_busy rd')

old = (b'        if(word_wr_queue) begin\r\n'
       b'            word_wr_queue <= 0;\r\n'
       b'            word_op <= 1;\r\n')
new = (b'        if(word_wr_queue) begin\r\n'
       b'            word_wr_queue <= 0;\r\n'
       b'            word_op <= 1;\r\n'
       b'            word_busy <= 1; // POCKET-DIFF\r\n')
d = rep1(d, old, new, 'word_busy wr')

# 8. ST_WRITE_5: word_done pulse
old = (b"        if(dc == TIMING_PRECHARGE-1) begin // was -3\r\n"
       b"            state <= ST_IDLE;\r\n")
new = (b"        if(dc == TIMING_PRECHARGE-1) begin // was -3\r\n"
       b"            word_done <= 1; // POCKET-DIFF: write op complete\r\n"
       b"            state <= ST_IDLE;\r\n")
d = rep1(d, old, new, 'word_done')

# 9. odd-cycle capture: word_rd_valid (replaces the commented-out line)
old = (b'                word_q[15:0] <= phy_dq;\r\n'
       b'                //word_q_valid <= 1;\r\n')
new = (b'                word_q[15:0] <= phy_dq;\r\n'
       b'                word_rd_valid <= 1; // POCKET-DIFF: word_q (32b) complete\r\n')
d = rep1(d, old, new, 'word_rd_valid')

# 10. reset branch: clear boot_done
old = (b'        state <= ST_RESET;\r\n'
       b'        refresh_count <= 0;\r\n')
new = (b'        state <= ST_RESET;\r\n'
       b'        refresh_count <= 0;\r\n'
       b'        boot_done <= 0; // POCKET-DIFF\r\n')
d = rep1(d, old, new, 'reset branch clear')

open(dst_path, 'wb').write(d)
print('wrote', dst_path, len(d), 'bytes')
print('new sha256', hashlib.sha256(d).hexdigest())
