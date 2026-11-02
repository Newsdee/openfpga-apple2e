// ============================================================================
// verilog/pocket_boot/pocket_main.cpp
//
// SDL2 front-end for tb_pocket_boot: renders the exact frame the Pocket core
// outputs (video_rgb), logs the diagnostic overlay values to the console,
// and drives the host bridge model (load/reload/reset cycles) from the
// keyboard - so the WOZ no-boot race can be watched and poked in simulation.
//
// Usage:
//   Vpocket_boot [--woz FILE.woz] [--seq around|after|before|none] [--smoke]
//
// Keys (windowed mode):
//   F8  host reset pulse (Enter -> 50us -> Exit)
//   F9  re-run the load cycle in the current seq mode (data reload)
//   F10 cycle seq mode: around -> after -> before -> none
//   F7  save a PPM screenshot of the current frame
//   Esc quit
//
// --smoke: headless. Runs the auto-boot, waits up to 20 s of sim time,
// dumps the last 3 frames to ./pocket_boot_shots/, prints the diagnostic
// table, exits 0 only if frames arrived AND the WOZ engine issued reads.
// ============================================================================
#include <SDL.h>
#include <cstdio>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <string>
#include <fstream>
#include <vector>
#include <cstdint>
#include <filesystem>

#include "Vtb_pocket_boot.h"
#include "Vtb_pocket_boot___024root.h"
#include "Vtb_pocket_boot_tb_pocket_boot.h"
#include "verilated.h"

// Verilator 5: top-level module signals live in the root instance's module
// class (undecorated names); the /* verilator public */ attribute in the TB
// keeps C-only signals from being pruned.
#define P(sig) (top->rootp->tb_pocket_boot->sig)


// Verilator --timing links against this even though we are not SystemC.
double sc_time_stamp() { return 0.0; }

static const char *seqNames[4] = { "around", "after", "before", "none" };

// ----------------------------------------------------------------------------
static uint32_t crc32_buf(const uint8_t *p, size_t n);

// .woz -> hex conversion (4 bytes/token = one 32-bit word, 8 hex digits,
// MSB first, uppercase). $readmemh truncates any token wider than the
// memory word to its low bits - 128-bit tokens silently drop 12 of
// every 16 bytes (found 2026-10-22).
static bool wozaToHex(const std::string &wozaPath, const std::string &hexPath,
                      size_t *outBytes, uint32_t *outCrc, bool le = false)
{
    std::ifstream f(wozaPath, std::ios::binary);
    if (!f) {
        fprintf(stderr, "cannot open %s\n", wozaPath.c_str());
        return false;
    }
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)),
                             std::istreambuf_iterator<char>());
    if (buf.empty()) {
        fprintf(stderr, "empty WOZ file %s\n", wozaPath.c_str());
        return false;
    }
    static const char *hx = "0123456789ABCDEF";
    std::ofstream o(hexPath, std::ios::binary);
    if (!o) {
        fprintf(stderr, "cannot write %s\n", hexPath.c_str());
        return false;
    }
    for (size_t i = 0; i < buf.size(); i += 4) {
        for (int k = 0; k < 4; k++) {
            // le: emit the 4-byte group in reverse so the FIRST file byte
            // lands in the word's LOW byte ([7:0]) - little-endian.
            // !le (default): file order, so the FIRST file byte lands in the
            // HIGH byte ([31:24]) - big-endian.
            //
            // The HDV path uses !le (big-endian): the core drives
            // bridge_endian_little = 0, so the real host writes each DMA word
            // with the first file byte in [31:24], and hdv_bridge.sv unpacks
            // big-endian to match (review 2026-11-02). The WOZ storage path
            // also consumes the big-endian (file-order) orientation, so both
            // use !le. (le=true is retained only as a parameter for the WOZ
            // orientation if a LE host is ever modelled.)
            int idx = le ? (3 - k) : k;
            uint8_t b = (i + idx < buf.size()) ? buf[i + idx] : 0;
            o << hx[b >> 4] << hx[b & 0xF];
        }
        o << '\n';
    }
    *outBytes = buf.size();
    if (outCrc) *outCrc = crc32_buf(buf.data(), buf.size());
    return true;
}

// Standard reflected IEEE CRC-32 (poly 0xEDB88320, init/final 0xFFFFFFFF)
// - must match disk_verifier.v (review 2026-10-22: the expected CRC must
// come from the original binary, not the hex representation).
static uint32_t crc32_buf(const uint8_t *p, size_t n) {
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) {
        c ^= p[i];
        for (int k = 0; k < 8; k++)
            c = (c >> 1) ^ (0xEDB88320u & (uint32_t)(-(int32_t)(c & 1)));
    }
    return c ^ 0xFFFFFFFFu;
}

static void dumpPpm(const char *path, const uint32_t *fb, int w, int h,
                    int stride)
{
    std::ofstream o(path, std::ios::binary);
    o << "P6\n" << w << " " << h << "\n255\n";
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            uint32_t c = fb[y * stride + x];
            o << char((c >> 16) & 0xFF) << char((c >> 8) & 0xFF)
              << char(c & 0xFF);
        }
    o.close();
}

int main(int argc, char **argv)
{
    std::string wozaPath = "disk.woz";
    std::string hdvPath;
    int seqMode = 0;
    bool smoke = false;
    bool hdvMode = false;
    bool hdvDt = false;        // +HDV_DT: also write the datatable entry
    bool hdvNo008A = false;    // +HDV_NO008A: datatable-only mount variant
    bool hdvNomount = false;   // +HDV_NOMOUNT: never mount (ROM must fall back)
    long hdvMountMs = 0;       // 0 = mount at reset release + 50 us settle
    long hdvFailAt = 0, hdvStallAt = 0, hdvStallMs = 200, hdvGap = 0;
    bool budgetSet = false;
    bool dramTrace = false;
    bool wzBoundNF = false;
    bool smokePass = false;
    uint32_t wozaCrc = 0;
    size_t hdvBytes = 0;
        // Context time is in the timeprecision() units (PS for this design:
        // `timescale 1ns/1ps`). VerilatedContext::time() returns ps
        // (verilated.h: "Returns current simulation time in units of
        // timeprecision()"; confirmed by the 2026-11-01 e74a ratio =
        // 1000.000). The pre-fix comment claimed NS - that wrong assumption
        // made every C++ time value 1000x too large (see
        // REVIEW_BRIEF_HDV_SIMHOST_TIMING_2026-11-01.md). Convert at the
        // read site (t = tps/1000.0); all constants below are NS.
    // The host WOZ load cycle holds machine reset for ~60 ms of machine time
    // in this harness (load_pace; the pre-fix "~60 s" was the 1000x unit bug).
    // The smoke milestone (below) fires at 100 ms, so 70 s leaves ample
    // margin (early-exit on the gate makes the ceiling moot in practice).
    // (1 s = 1e9 ns. The .bat's --budget-ms path (x1e6, ms->ns) is correct.)
    double budgetNs = 70e9;   // 70 s of sim time (ceiling; gate early-exits)

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--woz" && i + 1 < argc) wozaPath = argv[++i];
        else if (a == "--hdv" && i + 1 < argc) { hdvPath = argv[++i]; hdvMode = true; }
        else if (a == "--hdv-dt") hdvDt = true;
        else if (a == "--hdv-no008a") hdvNo008A = true;
        else if (a == "--hdv-nomount") hdvNomount = true;
        else if (a == "--mount-ms" && i + 1 < argc) hdvMountMs = atol(argv[++i]);
        else if (a == "--fail-at" && i + 1 < argc) hdvFailAt = atol(argv[++i]);
        else if (a == "--stall-at" && i + 1 < argc) hdvStallAt = atol(argv[++i]);
        else if (a == "--stall-ms" && i + 1 < argc) hdvStallMs = atol(argv[++i]);
        else if (a == "--gap" && i + 1 < argc) hdvGap = atol(argv[++i]);
        else if (a == "--smoke") smoke = true;
        else if (a == "--dramtrace") dramTrace = true;
        else if (a == "--wzbound-nf") wzBoundNF = true;
        else if (a == "--budget-ms" && i + 1 < argc) {
            budgetNs = atof(argv[++i]) * 1e6;
            budgetSet = true;
        }
        else if (a == "--seq" && i + 1 < argc) {
            std::string s = argv[++i];
            for (int m = 0; m < 4; m++)
                if (s == seqNames[m]) seqMode = m;
        } else if (a == "--help") {
            fprintf(stderr,
                "Usage: %s [--woz FILE.woz] [--hdv FILE.hdv] [--seq around|after|before|none] [--smoke] [--budget-ms N]\n",
                argv[0]);
            return 0;
        }
    }
    if (hdvMode) {   // headless boot-observation run
        smoke = true;
        if (!budgetSet) budgetNs = 3e9;    // 3 s ceiling: HDV fast path boots in ms of machine time
    }

    // WOZ -> hex for the TB's $readmemh
    size_t wozaBytes = 0;
    if (!wozaToHex(wozaPath, "pocket_boot.woz.hex", &wozaBytes, &wozaCrc)) return 2;
    char plusSize[64];
    snprintf(plusSize, sizeof plusSize, "+WOZSIZE=%zu", wozaBytes);
    char *sizeArg = plusSize;
    // HDV -> hex (full image, 4-bytes/line LE words, same layout as WOZ).
    // NOTE: each plusarg is a SEPARATE argv element (Verilator does not
    // split one element on spaces).
    static char hdvArgBuf[10][40];
    char *hdvArgList[10];
    int nHdvArg = 0;
    static char nfArg[16];
    if (wzBoundNF) snprintf(nfArg, sizeof nfArg, "+WZBOUND_NF=1");
    if (hdvMode) {
        if (!wozaToHex(hdvPath, "pocket_boot.hdv.hex", &hdvBytes, nullptr,
                       /*le=*/false))
            return 2;
        snprintf(hdvArgBuf[nHdvArg], 40, "+HDV_EN=1");          hdvArgList[nHdvArg++] = hdvArgBuf[0];
        snprintf(hdvArgBuf[nHdvArg], 40, "+HDV_SIZE=%zu", hdvBytes); hdvArgList[nHdvArg++] = hdvArgBuf[1];
        snprintf(hdvArgBuf[nHdvArg], 40, "+HDV_MOUNT_MS=%ld", hdvMountMs); hdvArgList[nHdvArg++] = hdvArgBuf[2];
        snprintf(hdvArgBuf[nHdvArg], 40, "+HDV_FAIL_AT=%ld", hdvFailAt); hdvArgList[nHdvArg++] = hdvArgBuf[3];
        snprintf(hdvArgBuf[nHdvArg], 40, "+HDV_STALL_AT=%ld", hdvStallAt); hdvArgList[nHdvArg++] = hdvArgBuf[4];
        snprintf(hdvArgBuf[nHdvArg], 40, "+HDV_STALL_MS=%ld", hdvStallMs); hdvArgList[nHdvArg++] = hdvArgBuf[5];
        snprintf(hdvArgBuf[nHdvArg], 40, "+HDV_GAP=%ld", hdvGap); hdvArgList[nHdvArg++] = hdvArgBuf[6];
        if (hdvDt) { snprintf(hdvArgBuf[nHdvArg], 40, "+HDV_DT=1"); hdvArgList[nHdvArg++] = hdvArgBuf[7]; }
        if (hdvNo008A) { snprintf(hdvArgBuf[nHdvArg], 40, "+HDV_NO008A=1"); hdvArgList[nHdvArg++] = hdvArgBuf[8]; }
        if (hdvNomount) { snprintf(hdvArgBuf[nHdvArg], 40, "+HDV_NOMOUNT=1"); hdvArgList[nHdvArg++] = hdvArgBuf[9]; }
    }
    int nargv = argc + 1 + (dramTrace ? 1 : 0) + (wzBoundNF ? 1 : 0) + nHdvArg;
    char **nargv2 = new char *[nargv + 1];
    for (int i = 0; i < argc; i++) nargv2[i] = argv[i];
    nargv2[argc] = sizeArg;
    int extra = argc + 1;
    if (dramTrace) nargv2[extra++] = "+DRAM_TRACE=1";
    if (wzBoundNF) nargv2[extra++] = nfArg;
    for (int i = 0; i < nHdvArg; i++) nargv2[extra++] = hdvArgList[i];
    nargv2[nargv] = nullptr;
    Verilated::commandArgs(nargv, nargv2);
    std::filesystem::create_directories("pocket_boot_shots");
    fprintf(stderr, "pocket_boot: WOZ %s (%zu bytes) seq=%s smoke=%d hdv=%s\n",
            wozaPath.c_str(), wozaBytes, seqNames[seqMode], smoke,
            hdvMode ? hdvPath.c_str() : "off");

    // ---- sim model ------------------------------------------------------
    Vtb_pocket_boot *top = new Vtb_pocket_boot;
    P(seq_mode_req) = seqMode;
    P(action_go) = 0;   // auto-boot fires at t=2ms inside the TB
    P(do_quit) = 0;
    P(trace_req) = dramTrace ? 1 : 0;

    // ---- SDL ------------------------------------------------------------
    SDL_Window *win = nullptr;
    SDL_Renderer *ren = nullptr;
    SDL_Texture *tex = nullptr;
    uint32_t *texPix = nullptr;
    int texW = 0, texH = 0;
    const int SCALE = 4;

    if (!smoke) {
        if (SDL_Init(SDL_INIT_VIDEO) != 0) {
            fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
            return 3;
        }
        win = SDL_CreateWindow("Apple IIe on Pocket - boot debug",
                               SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                               1120, 768, 0);
        if (!win) {
            fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError());
            return 3;
        }
        ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
        if (!ren) ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0"); // nearest
        if (!ren) {
            fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError());
            return 3;
        }
    }

    bool quit = false;
    long stallCount = 0;
    double lastLog = -1e6;
    int shotCount = 0;
    VerilatedContext *ctx = top->contextp();
    int jumpDbg = 0;

    // time-axis self-check (2026-11-01 review Q1): validate the ps->ns axis
    // against e74a, the free-running 74.25 MHz edge counter - ground truth
    // independent of any display. If Verilator's precision ever changes the
    // harness must fail loudly, not silently mistime a matrix again.
    double   tcT0 = -1.0, tcT1 = -1.0;
    uint32_t tcE0 = 0, tcE1 = 0;
    bool     tcDone = false, tcFail = false;
    double   hdvTm = -1.0;     // t at which both HDV milestones were set
    bool     hdvHardFail = false;   // budget exit without milestones
    fprintf(stderr, "TIMEAX: ctx->timeprecision()=%d (reference only; e74a is the check)\n",
            (int)ctx->timeprecision());

    // Verilator 5 --timing main loop (matches the generated --binary main):
    // eval() processes events at the current time; when events are pending
    // the context time must be advanced to the next time slot explicitly.
    while (!quit && !ctx->gotFinish()) {
        // batch of time slots per UI/log pass
        int slots = 0;
        for (int i = 0; i < 2000 && !quit && !ctx->gotFinish(); i++) {
            top->eval();
            if (!top->eventsPending()) {
                // Empty queue: nothing is scheduled for the future
                // (--timing delays are enqueued when scheduled, so an
                // empty queue means there is no later time slot to
                // advance to). nextTimeSlot() aborts when
                // !eventsPending() (generated-header contract), so do NOT
                // call it here; stop. Defensive branch: the TB's
                // forever #delay clocks keep the queue non-empty in
                // practice (review 2026-10-22: latent-UB call removed).
                break;
            }
            slots++;
            ctx->time(top->nextTimeSlot());
        }
        if (ctx->gotFinish()) break;
        if (!top->eventsPending()) quit = true;   // true stop: nothing left

        uint64_t tps = top->contextp()->time();   // ps (timeprecision units)
        // 2026-11-01 review: ctx->time() is in timeprecision() units (ps for
        // this design's `timescale 1ns/1ps`); the pre-fix code used the raw
        // ps value as ns, making every C++ time (display, budget, gates)
        // 1000x too large. Work in ns everywhere below.
        double t = (double)tps / 1000.0;          // ns

        if (slots == 0 && stallCount++ < 5)
            fprintf(stderr, "STALL: t=%.3fms pending=%d\n",
                    t / 1e6, (int)top->eventsPending());

        // ---- time-axis self-check (once, over a known 50 ms window) ----
        if (!tcDone && !tcFail) {
            if (tcT0 < 0 && t >= 1e6) {
                tcT0 = t; tcE0 = (uint32_t)P(e74a);
            } else if (tcT0 >= 0 && t >= tcT0 + 50e6) {
                tcT1 = t; tcE1 = (uint32_t)P(e74a); tcDone = true;
                double mhz = (double)(tcE1 - tcE0) / (tcT1 - tcT0) * 1e3;
                fprintf(stderr, "TIMECHECK: e74a rate=%.3f MHz over %.1f ms (expect 74.25 +/-2%%)\n",
                        mhz, (tcT1 - tcT0) / 1e6);
                if (mhz < 72.8 || mhz > 75.7) {
                    tcFail = true;
                    fprintf(stderr,
                            "TIMECHECK FAIL: ps->ns axis wrong (ratio off). "
                            "Aborting before burning wall time.\n");
                    break;
                }
            }
        }

        // ---- sim-rate line (budget must be chosen from data, not stale notes)
        {
            static auto wallPrev = std::chrono::steady_clock::now();
            static double simPrev = 0.0;
            auto wallNow = std::chrono::steady_clock::now();
            double wallS = std::chrono::duration<double>(wallNow - wallPrev).count();
            if (wallS >= 5.0) {
                fprintf(stderr, "SIMRATE: sim=%.1f ms wall=%.1f s rate=%.3f ms-sim/s-wall (%.0fx slower than realtime)\n",
                        t / 1e6, wallS, (t - simPrev) / 1e6 / wallS,
                        wallS / ((t - simPrev) / 1e9));
                wallPrev = wallNow; simPrev = t;
            }
        }

        // ---- console diagnostics (every 1 ms of sim time) ---------------
        if (t - lastLog > 1e6) {
            lastLog = t;
            stallCount = 0;
            fprintf(stderr,
                "t=%8.3fms frames=%-4d host=%s st=%d res82=%04X res8f=%04X | "
                "mrs=%d rstn=%d pll=%d init=%d | MT=%d AC=%d MO=%d ST=%d A=%d F=%d RD=%u CRC=%08X(%s) | e74a=%u\n",
                t / 1e6, (int)P(frame_cnt),
                P(host_busy) ? "busy" : "idle", (int)P(host_state),
                (int)P(load_res82), (int)P(load_res8f),
                (int)P(d_machine_reset), (int)P(d_reset_n),
                (int)P(d_pll_lock), (int)P(d_init_done),
                (int)P(d_mt), (int)P(d_ac), (int)P(d_mo),
                (int)P(d_st), (int)P(d_ack), (int)P(d_tf),
                (unsigned)P(d_reads), (unsigned)P(d_crc),
                ((unsigned)P(d_crc) == wozaCrc) ? "OK" : "??", (unsigned)P(e74a));
        }

        // ---- frame render ------------------------------------------------
        if (P(frame_new)) {
            P(frame_new) = 0;
            int w = (int)P(fb_w), h = (int)P(fb_h);
            if (w > 0 && h > 0) {
                if (smoke) {
                    // keep the last 3 frames as PPMs + one long_ shot
                    // every 200 frames for boot-sequence review
                    // stride 20: a 10 s run is ~600 frames; per-frame PPM
                    // writes would be ~600 MB of disk I/O (review 2026-11-01)
                    if (P(frame_cnt) % 20 == 0) {
                        char path[64];
                        snprintf(path, sizeof path,
                                 "pocket_boot_shots/f%03d_%06d.ppm",
                                 shotCount % 3, (int)P(frame_cnt));
                        dumpPpm(path, P(fb).data(), w, h, 720);
                        shotCount++;
                    }
                    if (P(frame_cnt) % 200 == 0) {
                        char path[64];
                        snprintf(path, sizeof path,
                                 "pocket_boot_shots/long_%04d.ppm",
                                 (int)(P(frame_cnt) / 200));
                        dumpPpm(path, P(fb).data(), w, h, 720);
                    }
                } else {
                    if (w * SCALE != texW || h * SCALE != texH) {
                        if (tex) SDL_DestroyTexture(tex);
                        SDL_DestroyWindow(win);
                        SDL_DestroyRenderer(ren);
                        tex = nullptr;
                        win = SDL_CreateWindow(
                            "Apple IIe on Pocket - boot debug",
                            SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                            w * SCALE, h * SCALE, 0);
                        ren = SDL_CreateRenderer(win, -1,
                                                 SDL_RENDERER_ACCELERATED);
                        if (!ren)
                            ren = SDL_CreateRenderer(win, -1,
                                                     SDL_RENDERER_SOFTWARE);
                        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
                        tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888,
                                                SDL_TEXTUREACCESS_STREAMING,
                                                w * SCALE, h * SCALE);
                        SDL_SetTextureScaleMode(tex, SDL_ScaleModeNearest);
                        SDL_RenderSetViewport(ren, nullptr);
                    }
                    if (tex) {
                        void *p;
                        int pitch;
                        if (SDL_LockTexture(tex, nullptr, &p, &pitch) == 0) {
                            uint8_t *row = (uint8_t *)p;
                            for (int y = 0; y < h; y++) {
                                uint32_t *dst = (uint32_t *)(row + y * pitch);
                                const uint32_t *src =
                                    P(fb).data() + (size_t)y * 720;
                                for (int x = 0; x < w; x++)
                                    for (int s = 0; s < SCALE; s++)
                                        dst[x * SCALE + s] =
                                            0xFF000000 | src[x];
                            }
                            SDL_UnlockTexture(tex);
                            SDL_RenderClear(ren);
                            SDL_RenderCopy(ren, tex, nullptr, nullptr);
                            SDL_RenderPresent(ren);
                        }
                    }
                }
            }
        }

        // ---- hdv observation exit (2026-11-01, review 2026-11-01) --------
        // The budget is a ceiling, not the runtime: as soon as both boot
        // milestones (launcher block 41904 + catalog block 41907 fetched)
        // are set, give the launcher 2 s to reach its verdict screen, then
        // stop. A budget exit WITHOUT both milestones is a hard fail
        // ("verdict not reached") - not a content verdict.
        if (hdvMode) {
            if (P(hdv_mile_launcher) && P(hdv_mile_catalog)) {
                if (hdvTm < 0) {
                    hdvTm = t;
                    fprintf(stderr,
                            "HDV MILESTONES: launcher+catalog fetched at t=%.3fms; +200 ms settle for verdict screen\n",
                            t / 1e6);
                } else if (t > hdvTm + 200e6) {
                    fprintf(stderr, "HDV EARLY EXIT: verdict window elapsed (milestones + 200 ms settle)\n");
                    dumpPpm("pocket_boot_shots/final.ppm", P(fb).data(),
                            (int)P(fb_w), (int)P(fb_h), 720);
                    fprintf(stderr,
                            "HDV RUN END (early): frames=%d fetches=%d errfetches=%d mt=%d tf=%d "
                            "mile_launcher=%d mile_catalog=%d t=%.3fms fb=%ux%u\n",
                            (int)P(frame_cnt), (int)P(hdv_fetch_cnt),
                            (int)P(hdv_err_cnt), (int)P(d_mt), (int)P(d_tf),
                            (int)P(hdv_mile_launcher), (int)P(hdv_mile_catalog),
                            t / 1e6, (unsigned)P(fb_w), (unsigned)P(fb_h));
                    fprintf(stderr,
                            "HDV VERDICT REACHED: milestones set - inspect final.ppm + HDVFETCH trace.\n");
                    quit = true;
                }
            }
            if (t > budgetNs && !quit) {
                dumpPpm("pocket_boot_shots/final.ppm", P(fb).data(),
                        (int)P(fb_w), (int)P(fb_h), 720);
                fprintf(stderr,
                        "HDV RUN END (budget ceiling): frames=%d fetches=%d errfetches=%d mt=%d tf=%d "
                        "mile_launcher=%d mile_catalog=%d t=%.3fms fb=%ux%u\n",
                        (int)P(frame_cnt), (int)P(hdv_fetch_cnt),
                        (int)P(hdv_err_cnt), (int)P(d_mt), (int)P(d_tf),
                        (int)P(hdv_mile_launcher), (int)P(hdv_mile_catalog),
                        t / 1e6, (unsigned)P(fb_w), (unsigned)P(fb_h));
                if (P(hdv_mile_launcher) && P(hdv_mile_catalog)) {
                    fprintf(stderr,
                            "HDV VERDICT REACHED: milestones set - inspect final.ppm + HDVFETCH trace.\n");
                } else {
                    fprintf(stderr,
                            "HDV VERDICT NOT REACHED: milestones missing (launcher=%d catalog=%d). "
                            "Harness/transport/boot failure - NOT a content verdict.\n",
                            (int)P(hdv_mile_launcher), (int)P(hdv_mile_catalog));
                    hdvHardFail = true;
                }
                quit = true;
            }
        }

        // ---- smoke exit ---------------------------------------------------
        // Milestone (review 2026-10-22): mounted, no transport fault, CRC of
        // the SDRAM image matches the original file, video alive. Read
        // counts alone are NOT boot proof.
        // t > 100 ms: the WOZ load takes ~60 ms of machine time in this
        // harness, so 100 ms keeps boot margin. With the 2026-11-01 ps->ns
        // fix this gate finally means 100 ms (pre-fix it was 100 us, which
        // is why the smoke "failed" with mt=0 - the open finding). The
        // milestone early-exits; the 70 s budget is only a ceiling.
        if (smoke && !hdvMode) {
            bool crcOk  = ((unsigned)P(d_crc) == wozaCrc) && P(load_res8f) == 0;
            bool mountOk = P(d_mt) && !P(d_tf);
            if (crcOk && mountOk && P(frame_cnt) >= 3 && t > 100e6) {
                fprintf(stderr,
                        "SMOKE BOOT OK: frames=%d reads=%u crc=%08X mt=%d tf=%d res8f=%04X t=%.3fms fb=%ux%u\n",
                        (int)P(frame_cnt), (unsigned)P(d_reads),
                        (unsigned)P(d_crc), (int)P(d_mt), (int)P(d_tf),
                        (int)P(load_res8f), t / 1e6,
                        (unsigned)P(fb_w), (unsigned)P(fb_h));
                // ---- direct chroma measurement (does not depend on dumpPpm) ----
                // The framebuffer holds the last captured frame. Count pixels
                // whose channel spread (max-min) exceeds a small threshold:
                // monochrome video has R==G==B everywhere, so ANY chromatic
                // pixel proves the NTSC decoder produced real chroma rather
                // than an expanded 1-bit image.
                {
                    int w = (int)P(fb_w), h = (int)P(fb_h);
                    long chromatic = 0, total = 0, maxSpread = 0;
                    unsigned firstChroma = 0; bool gotFirst = false;
                    if (w > 0 && h > 0) {
                        for (int y = 0; y < h; y++)
                            for (int x = 0; x < w; x++) {
                                uint32_t c = P(fb)[y * 720 + x];
                                int r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF,
                                    b = c & 0xFF;
                                int mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
                                int mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
                                int sp = mx - mn;
                                total++;
                                if (sp > maxSpread) maxSpread = sp;
                                if (sp > 8) {
                                    chromatic++;
                                    if (!gotFirst) { firstChroma = c; gotFirst = true; }
                                }
                            }
                    }
                    // grayscale sanity: is this a real screen or a dead capture?
                    long nBlack = 0, nWhite = 0, nMid = 0, distinct = 0;
                    {
                        bool seen[256] = {false};
                        for (int y = 0; y < h; y++)
                            for (int x = 0; x < w; x++) {
                                uint32_t c = P(fb)[y * 720 + x];
                                int r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF,
                                    b = c & 0xFF;
                                if (r == g && g == b) {
                                    seen[r] = true;
                                    if (r == 0) nBlack++;
                                    else if (r == 255) nWhite++;
                                    else nMid++;
                                }
                            }
                        for (int i = 0; i < 256; i++) if (seen[i]) distinct++;
                    }
                    fprintf(stderr,
                            "GRAY: distinct_gray_levels=%ld black=%ld white=%ld mid=%ld\n",
                            distinct, nBlack, nWhite, nMid);
                    fprintf(stderr,
                            "CHROMA: fb=%dx%d pixels=%ld chromatic(spread>8)=%ld "
                            "(%.2f%%) max_spread=%ld first_chroma=%06X\n",
                            w, h, total, chromatic,
                            total ? 100.0 * (double)chromatic / (double)total : 0.0,
                            maxSpread, firstChroma);
                }
                smokePass = true;
                break;
            }
            if (t > budgetNs) {
                fprintf(stderr,
                        "SMOKE END: frames=%d reads=%u crc=%08X(exp %08X) mt=%d tf=%d res8f=%04X (t>%.0fms) fb=%ux%u\n",
                        (int)P(frame_cnt), (unsigned)P(d_reads),
                        (unsigned)P(d_crc), wozaCrc,
                        (int)P(d_mt), (int)P(d_tf), (int)P(load_res8f),
                        budgetNs / 1e6,
                        (unsigned)P(fb_w), (unsigned)P(fb_h));
                break;
            }
        }

        // ---- SDL events ---------------------------------------------------
        if (!smoke) {
            SDL_Event ev;
            while (SDL_PollEvent(&ev)) {
                if (ev.type == SDL_QUIT) quit = true;
                else if (ev.type == SDL_KEYDOWN && !ev.key.repeat) {
                    switch (ev.key.keysym.sym) {
                    case SDLK_F8:
                        fprintf(stderr, "F8: host reset pulse\n");
                        P(reset_go) = 1;
                        break;
                    case SDLK_F9:
                        fprintf(stderr, "F9: reload cycle (mode=%s)\n",
                                seqNames[P(seq_mode)]);
                        P(action_go) = 1;
                        break;
                    case SDLK_F10:
                        P(seq_mode_req) = (P(seq_mode) + 1) & 3;
                        fprintf(stderr, "F10: seq mode -> %s\n",
                                seqNames[P(seq_mode)]);
                        break;
                    case SDLK_F7: {
                        char path[64];
                        int f = (int)P(frame_cnt);
                        snprintf(path, sizeof path, "shot_%06d.ppm", f);
                        dumpPpm(path, P(fb).data(),
                                (int)P(fb_w), (int)P(fb_h), 720);
                        fprintf(stderr, "F7: saved %s\n", path);
                        break;
                    }
                    case SDLK_ESCAPE:
                    case SDLK_q:
                        quit = true;
                        break;
                    default:
                        break;
                    }
                }
            }
            // let the event loop breathe a little (sim is the bottleneck,
            // but this keeps the window responsive)
            SDL_Delay(1);
        }
    }

    fprintf(stderr, "pocket_boot: done (frames=%d reads=%u smokePass=%d)\n",
            (int)P(frame_cnt), (unsigned)P(d_reads), (int)smokePass);
    fprintf(stderr, "exit reason: quit=%d gotFinish=%d t=%.3fms\n",
            (int)quit, (int)ctx->gotFinish(),
            top->contextp()->time() / 1e9);   // ps -> ms
    top->final();
    delete top;
    delete[] nargv2;
    if (win) SDL_DestroyWindow(win);
    if (ren) SDL_DestroyRenderer(ren);
    SDL_Quit();
    if (hdvMode && hdvHardFail) return 5;     // verdict not reached (review 2026-11-01)
    if (tcFail) return 3;                      // time-axis self-check failed
    if (smoke && !smokePass) return 1;   // milestone not reached
    return 0;
}
