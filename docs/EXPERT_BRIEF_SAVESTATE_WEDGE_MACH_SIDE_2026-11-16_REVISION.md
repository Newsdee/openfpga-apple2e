# REVISION — Savestate save-#N wedge: consolidated expert recommendations (2026-11-16)

**Supersedes §4 ranking, §5 (F1–F4) and §6 of
`EXPERT_BRIEF_SAVESTATE_WEDGE_MACH_SIDE_2026-11-16.md`.** Two independent
expert reviews of that brief converged; every load-bearing claim below was
verified against RTL (file/line references inline). The original brief's
hardware captures (§1), build matrix (§2) and shipping discipline (§7) remain
valid; its "proven invariants" §3 needs the corrections in §C below.

---

## A. Root cause: stale-acknowledgment race (PROVEN IN CODE — new L0)

The width fix (build 12:02) widened **only the first command after power-on**.
Every subsequent command is still a ~27 ns pulse — narrower than one mach
clock — and is missed phase-dependently. Mechanism, verified:

1. `core_bridge_cmd.v` 00A0 handler (~line 415-458): in the **same clocked
   edge** it does `savestate_start <= 1` AND samples `savestate_start_ack`:
   ```verilog
   if(host_20[0]) begin
       savestate_start <= 1;
       // stay in this state until ack'd
       if(savestate_start_ack) begin
           hstate <= ST_DONE_CODE;   // <-- exits on STALE ack
       end
   end
   ```
2. `savestate_slot.v` ack register (~line 533-537) **self-holds high after
   the previous op** and clears only on the *next* `start_rise`:
   ```verilog
   if (start_rise)                start_ack_r <= 1'b0;
   else if (start_ack_r | start_pend_74_c1) start_ack_r <= 1'b1;
   ```
3. `start_rise` is detected one 74a cycle AFTER the level appears
   (`start_d1`, ~line 455-459) — i.e. one cycle after the host already saw
   the stale ack and exited.

| Edge | Host FSM (74a) | Slot |
|---|---|---|
| T0 | asserts start; samples **stale ack=1**; exits to ST_DONE_CODE | level not yet visible |
| T1 | leaving; start high | `start_rise` fires; clears ack — **too late** |
| T2 | start back to 0 (ST_IDLE clear) | level ~2 cycles = **27 ns < 69.8 ns mach period** |

⇒ `synch_3 s_start` misses with ~25-60% probability per command; the 74a side
still sets `start_inflight_r` (busy=1 forever), the manager never accepts —
exactly the canonical capture signature (`SS 0202803E`, `SSD 00000:00000`,
`SSX 0807 0000`: port IDLE, mgr IDLE, zero traffic).

**Explains every datum:** save #1 always works (cold `ack_r=0` ⇒ host waits
for the real pend-crossing ack ⇒ wide level); later saves wedge
phase-dependently; persists after the width fix.

**Consequence for the original brief's §4:** L0 = this race (proven). L1
(synch_3 miss on wide level) stays low. **L2 (rst_mach glitch) and L4 (mach
clock stop) demote to fallback hypotheses** — only relevant if the Step-1
repro plus Steps 2-4 below fail to cure the field wedge. Do NOT do PLL/reset
work (old F4) speculatively.

## B. Verified defects in the proposed fixes (F1/F2/F3 as drafted)

**B.1 — F2 (level re-arm) as drafted replays commands.**
`start_pend <= start_lev_m | start_pend & ~start_go;` keeps pend set through
the whole op (the `& ~start_go` term re-latches it while busy), so when the
manager completes and returns to IDLE, `start_go` fires again: **an
uncommanded second save after every successful save.** (Both reviews found
this independently.) Required semantics: *capture once per request
assertion; clear on handoff; no re-capture until the request returns low*
(Step 3 below).

> **Adjudication of a rebuttal (2026-11-16):** it was objected that with the
> verified host contract (level dropped ~3–5 × 74a cycles after ack) and
> "pend clears on the handoff cycle", `start_lev_m` can never re-latch pend
> after handoff, so no replay occurs. The cycle-accurate retrace refutes
> this: at the handoff cycle the expression evaluates
> `lev | (pend & ~go)` = `1 | (1 & 0)` = **1** — pend does NOT clear, because
> `lev` is still high (ack is downstream of pend, which is downstream of
> nothing that drops the level; the host cannot have seen ack yet at
> handoff). The subsequent level drop is then irrelevant: the
> `pend & ~go` term self-holds pend through the entire busy window (~2–3 s),
> and on manager completion `go = pend & ~mgr_busy_m` refires → phantom
> save → its completion → another, i.e. an **infinite save loop** for any
> host that holds the level ≥1 mach cycle past pend-set (both the old and
> new host contracts do). The only safe host contract for the drafted
> expression is one that drops the level before mach sync propagation
> (~280 ns) — a pulse narrower than the synchronizer can catch, i.e.
> exactly the narrow-level class the width fix eliminated. B.1 stands;
> Step 3's captured-token semantics are adopted regardless (they are safe
> under both contracts, which is precisely why they are the right choice).
> The rebuttal targets B.1's mechanism, not Step 3 — Step 3 is unchanged.

**B.2 — F1 heartbeat saturates falsely.** An 8-bit counter "+1 per 100 mach
cycles, saturating" reaches 255 after 25,500 cycles ≈ **1.78 ms** and then
reads "frozen" forever on a *healthy* clock — it would fabricate L4
evidence. Replace with a free-running mach toggler + 74a-side age counter
(Step 5).

**B.3 — F1 rst counter polarity/erasure.** `rst_mach` is active-low: the
**falling** edge is assertion (the brief implies rising). And a mach-clocked
event counter is erased by the very reset it should count; it must live in
74a, fed by a synced toggle of `rst_mach`.

**B.4 — F3 error_code 4 truncates.** The manager's `error_code` is **2 bits**
(`savestate_manager.sv` ~line 158-180, `error_code <= 2'd1`). Code 4 lands as
0. Use a distinct slot-level transport err flag (or deliberately widen the
interface); do not overload the manager's field.

**B.5 — F3 "transparent recovery" is not safe.** Clearing `start_inflight_r`
does not cancel a mach-side pend that may still be alive; the op could
execute AFTER the host received ERR (ghost op), and a partially-applied load
abort must not resume the machine with half-restored RAM. Watchdog ⇒
**latched error + recovery-required**, not auto-retry.

**B.6 — 74a command block has no reset.** `savestate_slot.v` ~455-505:
`start_d1`, ok/err, `start_inflight_r`, `op_is_load_r` (and the ack block)
never see `rst_74a` — power-up defaults only. Add explicit reset.

**B.7 — snapshot machinery misdescribed (diagnostics-only).** Producer tick
13,183 ctrl cycles ≈ 10.1 kHz (not 10.1 Hz), receiver reacts to rising
toggles only, no producer-side ack: it is a periodically-held snapshot, not a
full handshake. Add a freshness/sequence nibble and fix the comments when
next touching this code. (Not independently re-derived here — verify the
divisor during Step 5.)

## C. Corrections to §3 "proven invariants" of the original brief

1. Invariant 1 wording is wrong: `start_rise` **sets** `start_inflight_r`;
   it never clears it (clear is `start_ok_r | start_err_r` only). The wedge
   does NOT resolve on a next command that is itself lost; a next command
   that *completes* does resolve it.
2. Invariant 2 needs qualification: the SSD counters reset on `ss_busy_any`
   (the wrapper aggregate, which includes `start_inflight_r`), **not** on
   manager acceptance. Zero counters + IDLE state prove *no current op and
   no observed traffic*, not that the manager never accepted at some earlier
   point (a later mach reset could have re-IDLed it). Practically the
   distinction doesn't change the cure, but the brief must not claim more
   than the data shows.
3. The §1 `SS` bit-layout line contradicts the layout used to decode
   `0202803E` earlier (bit17=busy, bit25=rd_hw[0]). Copy the table verbatim
   from the `savestate_status` assembly in `apf_stream_video_top.v` into ONE
   place and reference it from both briefs, so future captures can't be
   decoded two ways.

## D. Consolidated action sequence

**Step 0 — Build identity (no RTL, first).** Reboot the hash-verified 12:02
card image; re-run the two-save sequence once. `SS ST` multiplicity is NOT
build evidence. Prediction: save #1 OK, save #2 wedges (L0). Either outcome
is informative; a clean #2 would reopen §2.3 attribution instead.

**Step 1 — Sim repro of L0 before fixing (minutes, decisive).** Small TB
with the REAL `core_bridge_cmd` 00A0 FSM + REAL slot command front-end
(synch_3 + pender + ack), mach clock phase-swept: issue two sequential
commands, count mach-side acceptances. Expected: cmd #1 always accepted;
cmd #2 accepted phase-dependently. This TB becomes the regression gate for
Step 2 and belongs under `verilog/tb/` with a `run_tb_*.sh` wrapper.

**Step 2 — The actual fix: per-command req/ack lifecycle.** BOTH ends, and
the load path identically (same code shape, same bug):
- **Slot:** `start_ack_r` must return low when the command level returns low
  (re-arm), and assert only on the pend-crossing. Minimal form: add the
  clear `if (!savestate_start) start_ack_r <= 1'b0;` with priority over the
  self-hold — ack can then never be stale-high when a new command arrives.
- **Bridge:** sample ack only after the request has been high for ≥1 cycle:
  register `savestate_start` (`start_held_q`) and gate the exit:
  `if (start_held_q && savestate_start_ack) hstate <= ST_DONE_CODE;`.
  (Either end alone closes the observed race; both = belt-and-braces and
  protects against future host-firmware timing.)
- **Slot:** add `rst_74a` to the 74a command/ack/ok/err/inflight blocks
  (B.6).
- Keep the host contract unchanged otherwise: busy/ok/err polling at 00A0/
  00A4 untouched.

**Step 3 — Pender hardening (corrected F2), captured-token semantics:**
```verilog
// capture once per request assertion; clear on handoff;
// no re-capture until the request returns low.
if (start_go)                    start_pend <= 1'b0;
else if (!start_req_seen_m && start_lev_m)
                                 start_pend <= 1'b1;
if (!start_lev_m)                start_req_seen_m <= 1'b0;
else if (start_pend)             start_req_seen_m <= 1'b1;
```
`start_lev_m` = `synch_3 s_start` `.o()` output (currently unconnected —
wire it). Robust to L1/L2-class losses while un-captured; structurally
cannot replay after handoff. `load_pend` likewise.

**Step 4 — Containment watchdog (corrected F3), latched-error semantics:**
- Gate: count only while `inflight && !mgr_busy_74` (handoff window);
  timeout ~100 ms (handoff normally <1 µs). Optional separate long timeout
  for accepted-but-stalled ops.
- On expiry: set a **slot-level** err flag (NOT the manager's 2-bit
  `error_code`, B.4), clear inflight, and set a sticky `recovery_required`
  that blocks new commands until host re-init/reset (B.5: a mach-side pend
  may still execute later; partial loads must not resume).
- Host sees resultcode 3 + a distinct reason on the SS line; documented as
  "reboot required", not auto-retry.

**Step 5 — Corrected F1 diagnostics ONLY if Steps 2-4 leave residue:**
- Heartbeat: free-running mach toggler (toggle every ~2^12 mach cycles ≈
  0.6 Hz half-period), 2FF into 74a, **74a-side age counter** since last
  observed transition. Growing age = dead clock; never saturates falsely.
- rst counter: 74a-domain, fed by a synced TOGGLE of `rst_mach` (falling =
  assertion, B.3); cannot be erased by the reset it counts.
- Fields (32-bit SSY word): heartbeat age[7:0], rst count[15:8], raw
  `savestate_start` level[16], captured-token[17], `start_pend`[18],
  `start_go`[19], `mgr_busy_m`[20], `ack_r`[21], `inflight`[22],
  `pll_core_locked`[23], `cpu_frozen`[24], snapshot seq[27:25], spare.
- Emission: **stall-alert only** — when `busy && wr_req==0 && rd_req==0`
  persists >1 s, SSY replaces the repeating SS line. Keep the 20 Hz SS poll
  (it caught the live mid-walk word `0x7863` in capture 3); do NOT dilute to
  5 Hz phases.
- Add snapshot freshness/sequence nibble and fix the 10.1 kHz divisor
  documentation (B.7).

**Step 6 — Brief hygiene:** apply §C corrections to the original brief (or
keep this revision as the authoritative decode reference alongside it).

**Explicitly deferred:** old F4 (PLL-unlock/reset interaction) — only if
Step-5 fingerprints implicate it. `hdv_ram` M10K conversion stays parked per
`RECOMMENDATION_HDV_RAM_M10K_2026-11-16.md` (own sequencing constraints).

## E. Shipping discipline (updates §7 of the original brief)

KEEP candidates (real fixes, not diagnostics), pending Step-1/2 validation:
- Step 2 req/ack lifecycle fix (slot + bridge, save AND load paths).
- Step 3 captured-token pender.
- Step 4 watchdog with latched error + recovery-required (evaluate whether
  the sticky-block is shippable or dev-only; the ERR reporting itself ships).
- `rst_74a` on the 74a command blocks.

REVERT for shipping (unchanged plus):
- SSY line, heartbeat/age + rst counters, snapshot seq (Step 5) — all
  diagnostic.
- Everything already listed: SSD/SSX, LED_TX=1, OVL_SS_DIAG,
  cartridge_adapter=0, DUT taps, IDLE_PERIOD stays.

## F. One-paragraph summary

The persisting save-#N wedge is a **stale-acknowledgment race**: the bridge
FSM samples `savestate_start_ack` on the same edge it asserts the command,
and the slot's ack self-holds from the previous op — so every command after
the first is released after ~27 ns, narrower than one 14.318 MHz mach cycle,
and the mach-side pulse catcher misses it phase-dependently while the 74a
side latches busy forever. The fix is a per-command request/ack lifecycle
(ack re-arms when the command level drops; bridge only honors ack one cycle
after asserting the request), plus a captured-token pender and a
handoff-gated watchdog that reports a latched, recovery-required error
instead of wedging. Diagnostics (SSY) are corrected to use a non-saturating
heartbeat and reset-surviving counters, and are only built if the fix leaves
residue. PLL/reset work is deferred; build-identity check and a small
host-FSM+slot sim repro come first.

---

## Follow-through (2026-11-16, implementing side)

The adjudication was implemented exactly as revised:
- F2-as-drafted was NOT used. The captured-token pender (§9 Step 3) is in:
  level latches the pend; the token latches on the first held pend under the
  level (handoff fired); the token suppresses re-latching while the level
  stays high; a level fall releases both. This is immune to the §10
  handoff-precedes-drop ordering (the still-high level at the go cycle no
  longer holds a stale pend — the token branch holds pend at 0).
- The replay regression the adjudication required is in `tb_ss_cmdrace`
  (manager IDLE->active transition counter): two commands + two full op
  completions assert exactly two acceptances. Result on the fixed RTL:
  6/6 phases `acc=2 replay_ok=1`.
- Ack is per-command (level-gated, token-2FF based, explicit rst_74a reset),
  the bridge gates its ack-based exit on the registered request, and the
  ~100 ms containment watchdog (slot-level sticky error, NOT the manager's
  2-bit error_code) closes the "stuck busy forever" tail: on expiry the host
  gets a fast ERR and the slot blocks new ops until rst_74a.
- Unfixed-RTL baseline from the same TB: 3/6 phases LOST (phase-dependent
  command-#2 loss) — the L0 race reproduced before the fix was applied.
