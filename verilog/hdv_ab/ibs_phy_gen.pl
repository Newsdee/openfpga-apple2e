#!/usr/bin/perl
# ibs_phy_gen.pl <src_io_bridge_peripheral.v> <out_ibs_phy_split.v>
#
# Generates the port-split wrapper used by tb_hdv_ab.sv:
# io_bridge_peripheral's three `inout` phy ports become explicit
# sample(in)/drive(out) pairs so a two-state simulator can model the
# one-wire/one-driver-at-a-time physical SPI bus without multi-driver
# nets. The module body is VERBATIM from the shipping source except the
# two sim-only restructures documented below.
#
#   1. port-list block: inout x3 -> input x3 + output wire x3 (phy_spiss
#      gains a comma); module renamed io_bridge_peripheral_phy.
#   2. RX references: `posedge phy_spiclk` -> `posedge phy_spiclk_in`,
#      and the four {phy_spimosi, phy_spimiso} latches -> _in.
#   3. SIM RESTRUCTURE (required - Verilator 5.050 --timing bug, proven
#      by tb_pmp_probe): the original drives the three phy lines from
#      FIVE NBA sites each (ST_SIDLE..ST_SEND_2 in the TX case). A
#      signal with >=4 NBA sites in one clocked process compiles into a
#      latched OR of "strong drivers" (no validity) - the TX line sticks
#      High after the first ST_SEND_N while the machine itself keeps
#      running, so any host read capture hangs. The fix: the line
#      values are computed combinationally (one per state) and written
#      with ONE NBA each. Cycle-identical: ST_SEND_1 and ST_SEND_3
#      assign no line values in the original (hold = current value).
#      (Signals with <=3 NBA sites, like pmp_rd/pmp_wr/pmp_addr_valid,
#      compile to last-NBA-wins and need no treatment.)
#
# run_hdv_ab.sh verifies the transformation: after stripping the
# scaffolding lines and the _in/_out/_q/_n suffixes, every remaining
# differing line must reference a phy_sp* port, a _q/_n line-driver
# token, or the module name.

use strict;
use warnings;

my ($in, $out) = @ARGV;
die "usage: ibs_phy_gen.pl <in.v> <out.v>\n" unless @ARGV == 2;
open my $fh, '<:raw', $in or die "open $in: $!";
my @lines = <$fh>;
close $fh;

my @o;
my $scaff_done = 0;
my $tx_ins_done = 0;
my $tx_nba_done = 0;

for my $l (@lines) {
    # 1. port list
    if ($l =~ /^inout\s+reg\s+phy_spimosi,\s*$/) {
        $l = "input   wire            phy_spimosi_in,\n";
    }
    elsif ($l =~ /^inout\s+reg\s+phy_spimiso,\s*$/) {
        $l = "input   wire            phy_spimiso_in,\n";
    }
    elsif ($l =~ /^inout\s+reg\s+phy_spiclk,\s*$/) {
        $l = "input   wire            phy_spiclk_in,\n";
    }
    elsif ($l =~ /^input\s+wire\s+phy_spiss\s*$/) {
        $l = "input   wire            phy_spiss,\n"
           . "output  wire            phy_spimosi_out,\n"
           . "output  wire            phy_spimiso_out,\n"
           . "output  wire            phy_spiclk_out\n";
    }
    elsif (!$scaff_done && $l =~ /^\s*\)\s*;?\s*$/) {
        # end of the port header; insert the driver scaffolding right
        # AFTER it (top of the module body).
        push @o, $l;
        push @o, "\n";
        push @o, "    // simulation scaffolding (see header comment): the\n";
        push @o, "    // phy lines are driven through internal _q regs (one\n";
        push @o, "    // continuous driver per port), fed by ONE NBA each\n";
        push @o, "    // from the combinational next-value block below -\n";
        push @o, "    // >=4 NBA sites per signal in a clocked process\n";
        push @o, "    // compile into a latched OR in Verilator 5.050\n";
        push @o, "    // --timing (proven by tb_pmp_probe).\n";
        push @o, "    reg phy_spiclk_q = 1'b0, phy_spimosi_q = 1'b0, phy_spimiso_q = 1'b0;\n";
        push @o, "    reg phy_spiclk_n = 1'b0, phy_spimosi_n = 1'b0, phy_spimiso_n = 1'b0;\n";
        push @o, "    assign phy_spiclk_out  = phy_spiclk_q;\n";
        push @o, "    assign phy_spimosi_out = phy_spimosi_q;\n";
        push @o, "    assign phy_spimiso_out = phy_spimiso_q;\n";
        $scaff_done = 1;
        next;
    }
    # module name
    $l =~ s/^module\s+io_bridge_peripheral\s*\(/module io_bridge_peripheral_phy (/;
    # 2. RX renames
    $l =~ s/posedge phy_spiclk or posedge/posedge phy_spiclk_in or posedge/;
    $l =~ s/\{phy_spimosi, phy_spimiso\}/{phy_spimosi_in, phy_spimiso_in}/g;
    $l =~ s/\{rx_dat\[7:2\], phy_spimosi, phy_spimiso\}/{rx_dat[7:2], phy_spimosi_in, phy_spimiso_in}/;
    # 3. remove the in-branch line-driving assignments (replaced by the
    #    combinational next-value block + single NBAs). Each of the five
    #    TX states drives the lines from its own NBA sites; the original
    #    lines are deleted here, and the _q rename below leaves nothing
    #    else to touch.
    $l =~ s/^\s*phy_spiclk\s*<=\s*1'bZ;\s*$//;
    $l =~ s/^\s*phy_spimosi\s*<=\s*1'bZ;\s*$//;
    $l =~ s/^\s*phy_spimiso\s*<=\s*1'bZ;\s*$//;
    $l =~ s/^\s*phy_spiclk\s*<=\s*1'b1;\s*$//;
    $l =~ s/^\s*phy_spimosi\s*<=\s*1'b1;\s*$//;
    $l =~ s/^\s*phy_spimiso\s*<=\s*1'b1;\s*$//;
    $l =~ s/^\s*phy_spiclk\s*<=\s*0;\s*$//;
    $l =~ s/^\s*phy_spiclk\s*<=\s*1;\s*$//;
    $l =~ s/^\s*phy_spimosi\s*<=\s*spis_word\[31\];\s*$//;
    $l =~ s/^\s*phy_spimiso\s*<=\s*spis_word\[30\];\s*$//;
    # insert the combinational next-value block OUTSIDE the clocked
    # block, right before the `always @(posedge clk)` that owns the FSM
    if ($l =~ /^always\s*@\(posedge clk\)\s+begin/ && !$tx_ins_done) {
        push @o, "    // SIM RESTRUCTURE: cycle-identical line driving (see\n";
        push @o, "    // header). ST_SEND_1/ST_SEND_3 held the lines in the\n";
        push @o, "    // original (no assignment) -> hold = current _q value.\n";
        push @o, "    always @(*) begin\n";
        push @o, "        phy_spiclk_n  = 1'b0;\n";
        push @o, "        phy_spimosi_n = 1'b0;\n";
        push @o, "        phy_spimiso_n = 1'b0;\n";
        push @o, "        case(spis)\n";
        push @o, "        ST_SEND_N: begin\n";
        push @o, "            phy_spiclk_n  = 1'b1; phy_spimosi_n = 1'b1; phy_spimiso_n = 1'b1;\n";
        push @o, "        end\n";
        push @o, "        ST_SEND_0: begin\n";
        push @o, "            phy_spiclk_n  = 1'b0;\n";
        push @o, "            phy_spimosi_n = spis_word[31];\n";
        push @o, "            phy_spimiso_n = spis_word[30];\n";
        push @o, "        end\n";
        push @o, "        ST_SEND_1: begin\n";
        push @o, "            phy_spiclk_n  = 1'b1;\n";
        push @o, "            phy_spimosi_n = phy_spimosi_q;\n";
        push @o, "            phy_spimiso_n = phy_spimiso_q;\n";
        push @o, "        end\n";
        push @o, "        ST_SEND_2: begin\n";
        push @o, "            phy_spiclk_n  = 1'b1; phy_spimosi_n = 1'b1; phy_spimiso_n = 1'b1;\n";
        push @o, "        end\n";
        push @o, "        ST_SEND_3: begin\n";
        push @o, "            phy_spiclk_n  = phy_spiclk_q;\n";
        push @o, "            phy_spimosi_n = phy_spimosi_q;\n";
        push @o, "            phy_spimiso_n = phy_spimiso_q;\n";
        push @o, "        end\n";
        push @o, "        endcase\n";
        push @o, "    end\n";
        $tx_ins_done = 1;
    }
    # the three single NBAs feeding the _q regs: insert once, right at
    # the TX `case(spis)` (only after the combinational block has landed)
    if (!$tx_nba_done && $l =~ /^\s*case\(spis\)\s*$/ && $tx_ins_done) {
        push @o, "    phy_spiclk_q  <= phy_spiclk_n;\n";
        push @o, "    phy_spimosi_q <= phy_spimosi_n;\n";
        push @o, "    phy_spimiso_q <= phy_spimiso_n;\n";
        $tx_nba_done = 1;
    }
    push @o, $l;
}

open my $ofh, '>:raw', $out or die "open $out: $!";
print $ofh @o;
close $ofh;
