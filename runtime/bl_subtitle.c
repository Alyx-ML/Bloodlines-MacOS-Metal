// Subtitle Pause Fix 1.3.0, the Unofficial Patch's loader plugin, redone as instruction
// replacements at its four hook sites, which are the same in the port's engine and vampire
// (native/modules/engine, native/modules/vampire). The plugin replaces the clock the
// engine's caption timing reads with one that stops while the game is paused, or with the
// playing sound's own position. For the radio it keeps the station's broadcast going while
// the radio is switched off (the stream is decoded forward to where it would be when it is
// switched back on), wraps a looping station's caption time around the loop, and recreates
// the stream's state when a saved location loads.
//
// Each native stands in for the instruction it replaces: a replaced call takes its callee's
// stack arguments off and leaves the callee's answer in eax (or ST0).
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "bl_vm.h"
#include "bl_win32.h"
#include "llasm_cpu.h"

extern char engine_PauseStateOrig[], engine_MixerGetOutputData[], engine_SourceSampleRate[],
    engine_ChannelSamplePos[], vampire_EntityActivate[], vampire_SetFakeSilence[], mssmp3_Decode[],
    vaudio_miles_StreamVt0[], vaudio_miles_StreamVt1[];

#define ST0 cpu->_st[cpu->_st_top]

static uint32_t u32_at(uint32_t g) { return *(const uint32_t *)bl_g2h(g); }
static float f32_at(uint32_t g) { return *(const float *)bl_g2h(g); }
static double f64_at(uint32_t g) { return *(const double *)bl_g2h(g); }

static uint32_t pop(_cpu *cpu)
{
    uint32_t v = *(const uint32_t *)REG2PTR(esp);
    esp += 4;
    return v;
}

static void x87_push(_cpu *cpu, double v)
{
    cpu->_st_top = (cpu->_st_top + 7) & 7;
    ST0 = v;
}

static double x87_pop(_cpu *cpu)
{
    double v = ST0;
    cpu->_st_top = (cpu->_st_top + 1) & 7;
    return v;
}

static uint32_t this_call(_cpu *cpu, uint32_t fn, uint32_t self, int n, const uint32_t *args)
{
    return bl_call_guest(cpu, fn, BL_THISCALL, self, n, args);
}

// Engine globals, from the labels the engine hooks push: cl.paused (0x20314874), the sound
// channel count (0x213107D4) and channels (0x21310B08, 0xA0 bytes each: +0 the sound,
// +4 its mixer, +0x2C the entity index, +0x98 the start time), the vtables of the MP3
// mixer (0x20188600) and the MP3 source (0x20188394), g_pFileSystem (0x20197144) and the
// engine file system's vtable (0x201735DC).
static struct { uint32_t paused, nchan, chans, mixer_vt, source_vt, fs, fs_vt; } eng;
// vampire globals, from the labels the vampire hooks push: g_pEntityList's entries
// (0x10566458: {?, entity, serial} each) and gpGlobals (0x1070B228, curtime at +0xC).
static struct { uint32_t entlist, globals; } vam;

static void pop_engine(_cpu *cpu)
{
    eng.fs_vt = pop(cpu), eng.fs = pop(cpu), eng.source_vt = pop(cpu), eng.mixer_vt = pop(cpu);
    eng.chans = pop(cpu), eng.nchan = pop(cpu), eng.paused = pop(cpu);
}

static void pop_vampire(_cpu *cpu) { vam.globals = pop(cpu), vam.entlist = pop(cpu); }

// The plugin's clock: Plat_FloatTime less the time spent paused.
static struct { int init, paused; double pause_start, paused_total, now, out; } clk;

static double plat_time(_cpu *cpu)
{
    static uint32_t fn;
    if (!fn) fn = bl_module_export(bl_load_module("tier0.dll"), "Plat_FloatTime");
    bl_call_guest(cpu, fn, BL_CDECL, 0, 0, NULL);
    return x87_pop(cpu);
}

static double clock_update(_cpu *cpu, int paused)
{
    double now = plat_time(cpu);
    clk.now = now;
    if (!clk.init) {
        clk.init = 1;
        clk.paused_total = 0;
        clk.pause_start = now;
    } else if (clk.paused != paused) {
        if (paused)
            clk.pause_start = now;
        else
            clk.paused_total += now - clk.pause_start;
    }
    clk.paused = paused;
    return clk.out = (paused ? clk.pause_start : now) - clk.paused_total;
}

static double clock_now(_cpu *cpu) { return eng.paused ? clock_update(cpu, u32_at(eng.paused) != 0) : -1; }

static double curtime(void)
{
    uint32_t g = vam.globals ? u32_at(vam.globals) : 0;
    return g ? f32_at(g + 0xc) : -1;
}

static double clamp_time(double t) { return t < 1e8 && t >= 0 ? t : -1; }

// A radio the plugin follows, by its entity slot.
struct radio_rec {
    uint32_t radio, chan, source, mixer, sfx, idx, serial, gen, id;
    double start, snap_time;  // the station's start; the time the radio went silent
    int started, snap_pos, snap_rate;
    int live;     // following the station's live stream
    int snapped;  // snap_* hold the stream's position when the radio went silent
    uint32_t c_chan, c_source, c_mixer, c_sfx;  // the loop length's cache key
    int cached, loop_len;
};
static struct radio_rec recs[32];
static uint32_t gen, next_id, last_entlist, last_player = 0xffffffff;
static double last_time = -1;

// The radio_loop_ channel playing for the radio, with its MP3 mixer and source.
struct chan_info { uint32_t chan, source, sfx, mixer; int pos, rate; };

static int find_channel(_cpu *cpu, const struct radio_rec *r, struct chan_info *out)
{
    if (!eng.nchan || !r) return 0;
    uint32_t n = u32_at(eng.nchan), found = 0;
    if (n - 1 > 127) return 0;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t ch = eng.chans + i * 0xa0, sfx = u32_at(ch);
        if (!sfx || u32_at(ch + 0x2c) != r->idx) continue;
        const char *name = bl_g2h(sfx + 4);
        int match = 0;
        for (int k = 0; k < 0xf0 && name[k]; k++)
            if (!strncmp(name + k, "radio_loop_", 11)) {
                match = 1;
                break;
            }
        if (!match) continue;
        uint32_t mixer = u32_at(ch + 4), source = u32_at(sfx + 0x104);
        if (!mixer || !source) continue;
        uint32_t mvt = u32_at(mixer), svt = u32_at(source);
        if (mvt != eng.mixer_vt || svt != eng.source_vt || u32_at(mvt + 0x30) != bl_h2g(engine_MixerGetOutputData) ||
            u32_at(svt + 0xc) != bl_h2g(engine_SourceSampleRate))
            continue;
        double pos = f64_at(mixer + 8);
        uint32_t rate = this_call(cpu, bl_h2g(engine_SourceSampleRate), source, 0, NULL);
        if (!(pos >= 0) || !(pos < 2147483647.0) || rate - 8000 > 192000 - 8000) continue;
        if (found) return 0;
        *out = (struct chan_info){ ch, source, sfx, mixer, (int)pos, (int)rate };
        found++;
    }
    return found == 1;
}

// Samples in a whole MPEG-1 Layer III file at the given rate, less one frame; 0 if it is
// anything else.
static int mp3_samples(const uint8_t *b, uint32_t size, uint32_t rate)
{
    static const uint32_t kbps[16] = { 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
    static const uint32_t rates[3] = { 44100, 48000, 32000 };
    uint32_t pos = 0, frames = 0;
    for (;;) {
        uint32_t h1 = b[pos + 1], h2 = b[pos + 2];
        if ((h1 & 0x1e) != 0x1a || ((uint32_t)b[pos] << 24 | h1 << 16) < 0xffe00000) return 0;
        if (h2 < 0x10 || h2 >> 4 == 0xf || (h2 >> 2 & 3) == 3 || rates[h2 >> 2 & 3] != rate) return 0;
        uint32_t len = kbps[h2 >> 4] * 144000 / rate + (h2 >> 1 & 1);
        if (len < 4 || len > size - pos) return 0;
        frames++;
        pos += len;
        if (pos + 4 > size) break;
    }
    return frames - 2 < 999998 && pos == size ? (int)(frames - 1) * 1152 : 0;
}

// The radio loop's length in samples, from its file (cached per stream); 0 if unknown.
static int loop_length(_cpu *cpu, struct radio_rec *r, const struct chan_info *c)
{
    if (r->cached && r->c_chan == c->chan && r->c_source == c->source && r->c_mixer == c->mixer && r->c_sfx == c->sfx)
        return r->loop_len;
    r->c_chan = c->chan, r->c_source = c->source, r->c_mixer = c->mixer, r->c_sfx = c->sfx;
    r->cached = 1, r->loop_len = 0;
    uint32_t fs = eng.fs ? u32_at(eng.fs) : 0;
    if (!fs) return 0;
    uint32_t size = u32_at(c->source + 0xc);
    if (size - 8 > 0x1000000 - 8 || !*(const uint8_t *)bl_g2h(c->source + 0x14)) return 0;
    // Decoded by Miles' MP3 provider (vaudio_miles' stream, mssmp3's decoder).
    uint32_t stream = u32_at(c->mixer + 0x2c);
    if (!stream) return 0;
    uint32_t svt = u32_at(stream);
    if (u32_at(svt) != bl_h2g(vaudio_miles_StreamVt0) || u32_at(svt + 4) != bl_h2g(vaudio_miles_StreamVt1) ||
        u32_at(stream + 0x24) != bl_h2g(mssmp3_Decode))
        return 0;
    uint32_t fvt = u32_at(fs);
    if (fvt != eng.fs_vt) return 0;
    uint32_t buf = bl_guest_malloc(size);
    if (!buf) return 0;
    // The file system's Open (+0), Read (+4) and Close (+8); the name after its '*'.
    uint32_t name = c->sfx + 1, h = this_call(cpu, u32_at(fvt), fs, 1, &name), n = 0;
    if (h) {
        uint32_t args[3] = { buf, size, h };
        if (this_call(cpu, u32_at(fvt + 4), fs, 3, args) == size) n = (uint32_t)mp3_samples(bl_g2h(buf), size, c->rate);
        this_call(cpu, u32_at(fvt + 8), fs, 1, &h);
    }
    bl_guest_free(buf);
    return r->loop_len = (int)n;
}

static void clear_rec(struct radio_rec *r) { memset(r, 0, sizeof *r); }

// The entity list slot holding the entity, or -1.
static int entity_slot(uint32_t entlist, uint32_t ent)
{
    for (int i = 0; i < 0x2000; i++)
        if (u32_at(entlist + i * 12 + 4) == ent) return i;
    return -1;
}

// The radio's record, made if new. A new entity list, a new player or the time going back
// (a saved location loading) forgets every record.
static struct radio_rec *radio_record(uint32_t radio)
{
    uint32_t player = 0xffffffff, entlist = 0;
    double t = -1;
    if (vam.entlist) {
        t = clamp_time(curtime());
        if ((entlist = u32_at(vam.entlist)))
            for (int i = 0; i < 0x2000; i++) {
                uint32_t ent = u32_at(entlist + i * 12 + 4), cls = ent ? u32_at(ent + 0x11c) : 0;
                if (cls && !strcmp(bl_g2h(cls), "player")) {
                    player = (u32_at(entlist + i * 12 + 8) << 13) + (uint32_t)i;
                    break;
                }
            }
    }
    if (entlist == last_entlist && last_player == 0xffffffff && player != 0xffffffff) last_player = player;
    if (entlist != last_entlist || player != last_player || (t >= 0 && last_time >= 0 && last_time > t)) {
        gen++;
        memset(recs, 0, sizeof recs);
        last_entlist = entlist, last_player = player;
    }
    last_time = t;
    for (int i = 0; i < 32; i++) {
        struct radio_rec *r = &recs[i];
        if (r->radio && (!entlist || r->gen != gen || u32_at(entlist + r->idx * 12 + 4) != r->radio ||
                         u32_at(entlist + r->idx * 12 + 8) != r->serial))
            clear_rec(r);
    }
    if (!vam.entlist || !(entlist = u32_at(vam.entlist)) || !radio) return NULL;
    int slot = entity_slot(entlist, radio);
    if (slot < 0) return NULL;
    uint32_t serial = u32_at(entlist + slot * 12 + 8);
    struct radio_rec *free_rec = NULL;
    for (int i = 0; i < 32; i++) {
        struct radio_rec *r = &recs[i];
        if (r->radio == radio && r->idx == (uint32_t)slot && r->serial == serial) return r;
        if (!r->radio && !free_rec) free_rec = r;
    }
    if (free_rec) free_rec->radio = radio, free_rec->idx = (uint32_t)slot, free_rec->serial = serial, free_rec->gen = gen;
    return free_rec;
}

// A radio loop's position wrapped around the loop, for its captions.
static int loop_wrap(_cpu *cpu, uint32_t ch, int pos, int rate)
{
    uint32_t entlist = vam.entlist ? u32_at(vam.entlist) : 0;
    if (!ch || pos < 0 || !entlist) return pos;
    for (int i = 0; i < 32; i++) {
        struct radio_rec *r = &recs[i];
        if (!r->radio || r->gen != gen || r->idx != u32_at(ch + 0x2c) || u32_at(entlist + r->idx * 12 + 4) != r->radio ||
            u32_at(entlist + r->idx * 12 + 8) != r->serial)
            continue;
        struct chan_info c;
        if (!find_channel(cpu, r, &c) || c.chan != ch || c.rate != rate) return pos;
        int len = loop_length(cpu, r, &c);
        return len ? pos % len : pos;
    }
    return pos;
}

// engine 0x201188B0, in the caption timing: the sound device's time (vtable +0x38, in ST0)
// for the sentence's channel ([esp+0x10]). Now the channel's start time plus its played
// samples, or else the clock that stops while paused.
void bl_engine_SentenceTime(_cpu *cpu)
{
    pop_engine(cpu);
    double t = clock_update(cpu, u32_at(eng.paused) != 0);
    uint32_t ch = *(const uint32_t *)REG2PTR(esp + 0x10), sfx, source;
    if (ch && !(u32_at(ch + 0x98) & 0x80000000) && u32_at(ch + 4) && (sfx = u32_at(ch)) && (source = u32_at(sfx + 0x104))) {
        int rate = (int)this_call(cpu, u32_at(u32_at(source) + 0xc), source, 0, NULL);
        if (rate > 0) {
            int pos = (int)this_call(cpu, bl_h2g(engine_ChannelSamplePos), ch, 0, NULL);
            if (pos >= 0) t = (double)loop_wrap(cpu, ch, pos, rate) / rate + f32_at(ch + 0x98);
        }
    }
    x87_push(cpu, t);
}

// engine 0x2002D130: the call that reads the pause state into cl.paused, which also moves
// the clock.
void bl_engine_PauseState(_cpu *cpu)
{
    pop_engine(cpu);
    uint32_t paused = bl_call_guest(cpu, bl_h2g(engine_PauseStateOrig), BL_CDECL, 0, 0, NULL);
    clock_update(cpu, paused != 0);
    eax = paused;
}

// vampire 0x1022C50F, in CPropRadio::Activate (also on a saved location's load): after
// CBaseEntity::Activate stops the old station, the new one starts now.
void bl_vampire_RadioActivate(_cpu *cpu)
{
    pop_vampire(cpu);
    uint32_t radio = ecx;
    bl_call_guest(cpu, bl_h2g(vampire_EntityActivate), BL_THISCALL, radio, 0, NULL);
    double t = curtime();
    struct radio_rec *r = radio_record(radio);
    if (!r) return;
    t = clamp_time(t);
    if (t < 0) return;
    clear_rec(r);
    uint32_t entlist = u32_at(vam.entlist);
    int slot;
    if (!entlist || !radio || (slot = entity_slot(entlist, radio)) < 0) return;
    r->radio = radio, r->idx = (uint32_t)slot, r->serial = u32_at(entlist + slot * 12 + 8), r->gen = gen;
    r->id = ++next_id;
    r->start = t, r->started = 1;
    r->live = !*(const uint8_t *)bl_g2h(radio + 0x104);
}

static void set_silence(_cpu *cpu, uint32_t radio, uint32_t on)
{
    this_call(cpu, bl_h2g(vampire_SetFakeSilence), radio, 1, &on);
}

// vampire 0x1022C807, the radio's switch: CBaseEntity::SetFakeSilence (thiscall, the flag,
// stored at +0x104). Going silent remembers where the stream was; coming back decodes the
// stream forward to where the station's broadcast is now.
void bl_vampire_RadioSilence(_cpu *cpu)
{
    pop_vampire(cpu);
    uint32_t radio = ecx, silence = pop(cpu);
    struct radio_rec *r = radio_record(radio);
    double now = curtime();
    if (!r) {
        set_silence(cpu, radio, silence);
        return;
    }
    double t = clamp_time(now);
    int audible = !*(const uint8_t *)bl_g2h(radio + 0x104);
    struct chan_info c;
    if (silence) {
        int take;
        if (audible)
            r->live = 1, take = 1;
        else if (!r->snapped)
            take = r->live != 0;
        else {
            set_silence(cpu, radio, silence);
            return;
        }
        r->snapped = 0;
        if (take && t >= 0 && find_channel(cpu, r, &c)) {
            r->chan = c.chan, r->source = c.source, r->mixer = c.mixer, r->sfx = c.sfx;
            r->snap_pos = c.pos, r->snap_rate = c.rate, r->snap_time = t, r->snapped = 1;
        }
        set_silence(cpu, radio, silence);
        return;
    }
    if (r->live && !r->snapped && audible) {
        set_silence(cpu, radio, 0);
        return;
    }
    double pos;
    if (!r->started || r->start > t || !find_channel(cpu, r, &c) || !loop_length(cpu, r, &c)) goto keep;
    if (!r->live) {
        pos = c.rate * (t - r->start);
        if (!(pos >= 0) || !(pos < 2147483647.0)) goto keep;
    } else {
        if (!r->snapped || c.mixer != r->mixer || c.sfx != r->sfx || c.source != r->source || c.chan != r->chan ||
            c.rate != r->snap_rate)
            goto keep;
        pos = r->snap_pos + c.rate * (t - r->snap_time);
        if (!(pos >= 0) || !(pos < 2147483647.0) || r->snap_time > t) goto keep;
        int moved = c.pos - r->snap_pos;
        if (moved < 0 || moved >= 0x1001) goto keep;
    }
    // Decode forward with the mixer's GetOutputData (+0x30), 4096 samples at a time.
    int left = (int)(pos + 0.5) - c.pos, done = 0;
    if (left < 0) left = 0;
    static uint32_t data;
    if (!data) data = bl_guest_malloc(4);
    uint32_t fn = u32_at(u32_at(c.mixer) + 0x30);
    while (left) {
        uint32_t chunk = (uint32_t)left < 0x1000 ? (uint32_t)left : 0x1000;
        *(uint32_t *)bl_g2h(data) = 0;
        uint32_t args[3] = { data, chunk, 0 };
        int got = (int)this_call(cpu, fn, c.mixer, 3, args);
        if (got <= 0 || (uint32_t)got > chunk || !u32_at(data)) break;
        done += got;
        left -= got;
    }
    *(double *)bl_g2h(c.mixer + 8) = (double)c.pos + done;
    if (left) goto keep;
    if (f32_at(c.chan + 0x98) < 0) *(float *)bl_g2h(c.chan + 0x98) = (float)clock_now(cpu);
    r->live = 1, r->snapped = 0;
    r->mixer = c.mixer, r->sfx = c.sfx, r->source = c.source, r->chan = c.chan;
    set_silence(cpu, radio, 0);
    return;
keep:
    set_silence(cpu, radio, 1);
}
