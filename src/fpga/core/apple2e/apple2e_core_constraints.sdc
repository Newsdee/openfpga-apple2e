#
# apple2e core constraints
#
# Declares the asynchronous clock groups for the Apple IIe core. The four
# apple2e_pll outputs (14.318 / 12.288 / 12.288-90 / 3.072 MHz) are treated
# as separate clock groups (the core pipelines across them with synchronizers),
# as are the two 74.25 MHz main clocks and the bridge SPI clock.
#
# Net names MUST be the internal PLL divclk nets (as Quartus names them in the
# STA report), NOT the core_top wire names - the wire names do not match and
# the async-clock groups silently fail to apply (leaving false cross-domain
# setup/recovery paths on the video domain). Matches the template's SDC
# pattern (ic|mp1|...|general[N].gpll~PLL_OUTPUT_COUNTER|divclk). The 4 PLL
# outputs are general[0]=14.318, [1]=12.288, [2]=12.288-90, [3]=3.072 MHz.
#

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk }
