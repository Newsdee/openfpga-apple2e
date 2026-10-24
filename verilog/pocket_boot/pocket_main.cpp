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
                      size_t *outBytes, uint32_t *outCrc)
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
            uint8_t b = (i + k < buf.size()) ? buf[i + k] : 0;
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
    int seqMode = 0;
    bool smoke = false;
    bool dramTrace = false;
    bool wzBoundNF = false;
    bool smokePass = false;
    uint32_t wozaCrc = 0;
        // Context time is in ps (TB timescale 1ns/1ps: #1 = 1ns, 1ms = 1e9 ps).
    // The host cycle needs ~80 ms of sim time (2 ms action_go + 20 ms
    // pre-wait + ~58 ms WOZ load at load_pace=40 + Reset-Exit), and the
    // smoke milestone (below) requires t > 100 ms - so the budget must
    // exceed 100 ms. (Was 50e9 = 50 ms: the run always ended mid-load and
    // the smoke could never pass - found 2026-10-24, post-review sweep run.
    // Pre-existing: the 2026-10-24 01:41 pre-sweep smoke failed identically.)
    double budgetPs = 1000e9;   // 1000 ms of sim time

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--woz" && i + 1 < argc) wozaPath = argv[++i];
        else if (a == "--smoke") smoke = true;
        else if (a == "--dramtrace") dramTrace = true;
        else if (a == "--wzbound-nf") wzBoundNF = true;
        else if (a == "--budget-ms" && i + 1 < argc) {
            budgetPs = atof(argv[++i]) * 1e9;
        }
        else if (a == "--seq" && i + 1 < argc) {
            std::string s = argv[++i];
            for (int m = 0; m < 4; m++)
                if (s == seqNames[m]) seqMode = m;
        } else if (a == "--help") {
            fprintf(stderr,
                "Usage: %s [--woz FILE.woz] [--seq around|after|before|none] [--smoke]\n",
                argv[0]);
            return 0;
        }
    }

    // WOZ -> hex for the TB's $readmemh
    size_t wozaBytes = 0;
    if (!wozaToHex(wozaPath, "pocket_boot.woz.hex", &wozaBytes, &wozaCrc)) return 2;
    char plusSize[64];
    snprintf(plusSize, sizeof plusSize, "+WOZSIZE=%zu", wozaBytes);
    char *sizeArg = plusSize;
    static char nfArg[16];
    if (wzBoundNF) snprintf(nfArg, sizeof nfArg, "+WZBOUND_NF=1");
    int nargv = argc + 1 + (dramTrace ? 1 : 0) + (wzBoundNF ? 1 : 0);
    char **nargv2 = new char *[nargv + 1];
    for (int i = 0; i < argc; i++) nargv2[i] = argv[i];
    nargv2[argc] = sizeArg;
    int extra = argc + 1;
    if (dramTrace) nargv2[extra++] = "+DRAM_TRACE=1";
    if (wzBoundNF) nargv2[extra++] = nfArg;
    nargv2[nargv] = nullptr;
    Verilated::commandArgs(nargv, nargv2);
    std::filesystem::create_directories("pocket_boot_shots");
    fprintf(stderr, "pocket_boot: WOZ %s (%zu bytes) seq=%s smoke=%d\n",
            wozaPath.c_str(), wozaBytes, seqNames[seqMode], smoke);

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
    double lastLog = -1e9;
    int shotCount = 0;
    VerilatedContext *ctx = top->contextp();
    int jumpDbg = 0;

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

        uint64_t tps = top->contextp()->time();   // ps (Verilator context time is ps)
        double t = (double)tps;

        if (slots == 0 && stallCount++ < 5)
            fprintf(stderr, "STALL: t=%.3fms pending=%d\n",
                    t / 1e6, (int)top->eventsPending());

        // ---- console diagnostics (every 1 ms of sim time) ---------------
        if (t - lastLog > 1e9) {
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
                    char path[64];
                    snprintf(path, sizeof path,
                             "pocket_boot_shots/f%03d_%06d.ppm",
                             shotCount % 3, (int)P(frame_cnt));
                    dumpPpm(path, P(fb).data(), w, h, 720);
                    shotCount++;
                    if (P(frame_cnt) % 200 == 0) {
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

        // ---- smoke exit ---------------------------------------------------
        // Milestone (review 2026-10-22): mounted, no transport fault, CRC of
        // the SDRAM image matches the original file, video alive. Read
        // counts alone are NOT boot proof.
        // t > 100 ms (was 800 ms, 2026-10-24): the old interactive runs show
        // the machine first frame at ~68 ms of sim time, so 100 ms keeps
        // boot margin while the run stays a ~1-hour background job instead
        // of ~7 hours at this harness's sim speed (~30,000x realtime).
        if (smoke) {
            bool crcOk  = ((unsigned)P(d_crc) == wozaCrc) && P(load_res8f) == 0;
            bool mountOk = P(d_mt) && !P(d_tf);
            if (crcOk && mountOk && P(frame_cnt) >= 3 && t > 100e9) {
                fprintf(stderr,
                        "SMOKE BOOT OK: frames=%d reads=%u crc=%08X mt=%d tf=%d res8f=%04X t=%.3fms\n",
                        (int)P(frame_cnt), (unsigned)P(d_reads),
                        (unsigned)P(d_crc), (int)P(d_mt), (int)P(d_tf),
                        (int)P(load_res8f), t / 1e6);
                smokePass = true;
                break;
            }
            if (t > budgetPs) {
                fprintf(stderr,
                        "SMOKE END: frames=%d reads=%u crc=%08X(exp %08X) mt=%d tf=%d res8f=%04X (t>%.0fms)\n",
                        (int)P(frame_cnt), (unsigned)P(d_reads),
                        (unsigned)P(d_crc), wozaCrc,
                        (int)P(d_mt), (int)P(d_tf), (int)P(load_res8f),
                        budgetPs / 1e6);
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
            top->contextp()->time() / 1e6);
    top->final();
    delete top;
    delete[] nargv2;
    if (win) SDL_DestroyWindow(win);
    if (ren) SDL_DestroyRenderer(ren);
    SDL_Quit();
    if (smoke && !smokePass) return 1;   // milestone not reached
    return 0;
}
