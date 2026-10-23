// DirectSound on Core Audio. The engine (CAudioDirectSound) and Miles load dsound.dll
// with LoadLibrary, so this file registers a "dsound.dll" module whose exports are the
// import thunks for DirectSoundCreate and friends (runtime/imports.def).
//
// Every buffer is software: a block of guest memory the game fills between Lock and
// Unlock. One mixer resamples all playing buffers (linear interpolation, DirectSound
// volume and pan) into 44.1 kHz float stereo. With BL_WINDOW (or BL_AUDIO=1) the mix goes
// to the default output device through an AudioUnit; otherwise a thread runs the mixer
// at the same rate into nothing, so play cursors still advance in headless runs.
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "bl_win32.h"
#include "com_gen.h"
#include "d3d9_objects.h"

#define DS_OK 0u
#define DSERR_INVALIDPARAM 0x80070057u
#define DSERR_BADFORMAT 0x88780064u
#define DSERR_NODRIVER 0x88780078u
#define DSERR_ALREADYINITIALIZED 0x88780082u

#define DSBCAPS_PRIMARYBUFFER 0x1u
#define DSBCAPS_LOCSOFTWARE 0x8u
#define DSSCL_WRITEPRIMARY 4u
#define DSBPLAY_LOOPING 1u
#define DSBSTATUS_PLAYING 1u
#define DSBSTATUS_LOOPING 4u
#define DSBLOCK_FROMWRITECURSOR 1u
#define DSBLOCK_ENTIREBUFFER 2u
#define DSSPEAKER_STEREO 4u

#define OUT_RATE 44100
#define PRIMARY_BYTES 65536

struct dsbuf {
    struct obj *o;
    struct obj *share;  // DuplicateSoundBuffer: the original, which owns the memory
    struct dsbuf *next;
    uint32_t mem, size, flags;
    uint16_t channels, bits, align;
    uint32_t rate, freq;  // format rate; SetFrequency (0: the format rate)
    int32_t volume, pan;  // hundredths of a dB
    int playing, looping, primary;
    double pos;  // play position in frames
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct dsbuf *buffers;
static uint32_t coop_level;
static int started;

static int trace(void)
{
    static int on = -1;
    if (on < 0) on = getenv("BL_AUDIO_TRACE") != NULL;
    return on;
}
#define TRACE(...) do { if (trace()) fprintf(stderr, "[dsound] " __VA_ARGS__); } while (0)

static struct dsbuf *buf(uint32_t self) { return obj_of(self)->sound; }

// --- mixer ---------------------------------------------------------------------

static float gain_of(int32_t hundredths_db)
{
    if (hundredths_db <= -10000) return 0;
    return hundredths_db >= 0 ? 1.0f : powf(10.0f, (float)hundredths_db / 2000.0f);
}

static float sample(const struct dsbuf *b, const uint8_t *mem, uint32_t frame, int ch)
{
    if (ch >= b->channels) ch = b->channels - 1;
    const uint8_t *p = mem + frame * b->align + ch * (b->bits / 8);
    return b->bits == 8 ? (p[0] - 128) / 128.0f : (int16_t)(p[0] | p[1] << 8) / 32768.0f;
}

// Adds every playing buffer into out (frames of interleaved stereo). Lock held.
static void mix(float *out, uint32_t frames)
{
    memset(out, 0, frames * 2 * sizeof *out);
    for (struct dsbuf *b = buffers; b; b = b->next) {
        if (!b->playing || !b->size || !b->align) continue;
        if (b->primary && coop_level != DSSCL_WRITEPRIMARY) continue;
        const uint8_t *mem = bl_g2h(b->mem);
        uint32_t n = b->size / b->align;
        if (!n) continue;
        double step = (double)(b->freq ? b->freq : b->rate) / OUT_RATE;
        float g = gain_of(b->volume), gl = g, gr = g;
        if (b->pan < 0) gr *= gain_of(b->pan);
        if (b->pan > 0) gl *= gain_of(-b->pan);
        for (uint32_t i = 0; i < frames; i++) {
            uint32_t f0 = (uint32_t)b->pos, f1 = f0 + 1;
            if (f1 >= n) f1 = b->looping ? 0 : n - 1;
            float t = (float)(b->pos - f0);
            float l = sample(b, mem, f0, 0) * (1 - t) + sample(b, mem, f1, 0) * t;
            float r = sample(b, mem, f0, 1) * (1 - t) + sample(b, mem, f1, 1) * t;
            out[2 * i] += l * gl, out[2 * i + 1] += r * gr;
            b->pos += step;
            if (b->pos >= n) {
                if (b->looping) {
                    b->pos = fmod(b->pos, n);
                } else {
                    b->playing = 0, b->pos = 0;
                    break;
                }
            }
        }
    }
    static float peak;
    static uint32_t counted;
    for (uint32_t i = 0; i < 2 * frames; i++) {
        out[i] = out[i] > 1 ? 1 : out[i] < -1 ? -1 : out[i];
        if (fabsf(out[i]) > peak) peak = fabsf(out[i]);
    }
    // BL_AUDIO_TRACE: the loudest sample of each second of output.
    if ((counted += frames) >= OUT_RATE) {
        int playing = 0;
        for (struct dsbuf *b = buffers; b; b = b->next) playing += b->playing;
        TRACE("level: peak %.3f, %d buffers playing\n", peak, playing);
        counted = 0, peak = 0;
    }
}

static OSStatus render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                       UInt32 frames, AudioBufferList *data)
{
    (void)ref, (void)flags, (void)ts, (void)bus;
    pthread_mutex_lock(&lock);
    mix(data->mBuffers[0].mData, frames);
    pthread_mutex_unlock(&lock);
    return noErr;
}

static void *silent_mixer(void *arg)
{
    (void)arg;
    static float scratch[2 * 441];
    for (;;) {
        struct timespec ts = {0, 10 * 1000 * 1000};
        nanosleep(&ts, NULL);
        pthread_mutex_lock(&lock);
        mix(scratch, 441);
        pthread_mutex_unlock(&lock);
    }
    return NULL;
}

static void start_output(void)
{
    if (started) return;
    started = 1;
    if (getenv("BL_WINDOW") || (getenv("BL_AUDIO") && atoi(getenv("BL_AUDIO")))) {
        AudioComponentDescription d = {kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput,
                                       kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent c = AudioComponentFindNext(NULL, &d);
        AudioUnit unit;
        AudioStreamBasicDescription f = {OUT_RATE, kAudioFormatLinearPCM,
                                         kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0};
        AURenderCallbackStruct cb = {render, NULL};
        if (c && !AudioComponentInstanceNew(c, &unit) &&
            !AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f) &&
            !AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb,
                                  sizeof cb) &&
            !AudioUnitInitialize(unit) && !AudioOutputUnitStart(unit)) {
            fprintf(stderr, "[dsound] output: default device, %d Hz stereo\n", OUT_RATE);
            return;
        }
        fprintf(stderr, "[dsound] no output device; mixing silently\n");
    }
    pthread_t t;
    pthread_create(&t, NULL, silent_mixer, NULL);
    pthread_detach(t);
}

// --- dsound.dll ----------------------------------------------------------------

uint32_t bl_ds_DirectSoundCreate_c(uint32_t guid, uint32_t out, uint32_t outer)
{
    (void)guid, (void)outer;
    G32(out) = obj_new(OBJ_DSOUND, bl_vtbl_IDirectSound())->guest;
    TRACE("DirectSoundCreate\n");
    start_output();
    return DS_OK;
}

uint32_t bl_ds_DirectSoundEnumerateA_c(uint32_t callback, uint32_t ctx)
{
    static uint32_t desc, module;
    if (!desc) {
        desc = bl_guest_malloc(32), module = bl_guest_malloc(4);
        strcpy(bl_g2h(desc), "Primary Sound Driver");
        G32(module) = 0;
    }
    uint32_t args[4] = {0, desc, module, ctx};  // the primary device has a NULL GUID
    bl_call_guest(bl_thread_cpu, callback, BL_STDCALL, 0, 4, args);
    return DS_OK;
}

uint32_t bl_ds_DirectSoundCaptureCreate_c(uint32_t guid, uint32_t out, uint32_t outer)
{
    (void)guid, (void)outer;
    G32(out) = 0;
    return DSERR_NODRIVER;  // no voice chat
}

extern char imp_DirectSoundCreate[], imp_DirectSoundEnumerateA[], imp_DirectSoundCaptureCreate[];
static const struct bl_export exports[] = {
    {"DirectSoundCreate", imp_DirectSoundCreate},
    {"DirectSoundEnumerateA", imp_DirectSoundEnumerateA},
    {"DirectSoundCaptureCreate", imp_DirectSoundCaptureCreate},
    {0, 0},
};
static struct bl_module module = {"dsound.dll", 0, exports, 3, 0, 0, 0};
__attribute__((constructor)) static void register_module(void) { bl_register_module(&module); }

// --- IDirectSound --------------------------------------------------------------

static int set_format(struct dsbuf *b, uint32_t wfx)
{
    // WAVEFORMATEX: wFormatTag, nChannels, nSamplesPerSec, nAvgBytesPerSec, nBlockAlign, wBitsPerSample.
    const uint8_t *w = bl_g2h(wfx);
    uint16_t tag = (uint16_t)(w[0] | w[1] << 8), ch = (uint16_t)(w[2] | w[3] << 8);
    uint16_t align = (uint16_t)(w[12] | w[13] << 8), bits = (uint16_t)(w[14] | w[15] << 8);
    uint32_t rate = G32(wfx + 4);
    if ((tag != 1 && tag != 0xFFFE) || !ch || (bits != 8 && bits != 16) || !rate) return 0;
    b->channels = ch, b->bits = bits, b->rate = rate;
    b->align = align ? align : (uint16_t)(ch * bits / 8);
    return 1;
}

static struct dsbuf *new_buffer(struct obj **po)
{
    struct obj *o = obj_new(OBJ_DSOUND_BUFFER, bl_vtbl_IDirectSoundBuffer());
    struct dsbuf *b = calloc(1, sizeof *b);
    b->o = o;
    o->sound = b;
    *po = o;
    return b;
}

static void link_buffer(struct dsbuf *b)
{
    pthread_mutex_lock(&lock);
    b->next = buffers, buffers = b;
    pthread_mutex_unlock(&lock);
}

uint32_t bl_IDirectSound_CreateSoundBuffer_c(uint32_t self, uint32_t desc, uint32_t out, uint32_t outer)
{
    (void)self, (void)outer;
    // DSBUFFERDESC: dwSize, dwFlags, dwBufferBytes, dwReserved, lpwfxFormat.
    uint32_t flags = G32(desc + 4), bytes = G32(desc + 8), wfx = G32(desc + 16);
    struct obj *o;
    struct dsbuf b0 = {0};
    if (flags & DSBCAPS_PRIMARYBUFFER) {
        // 22.05 kHz 8-bit stereo until SetFormat, as on Windows.
        b0.channels = 2, b0.bits = 8, b0.align = 2, b0.rate = 22050;
        bytes = PRIMARY_BYTES;
    } else if (!wfx || !set_format(&b0, wfx) || bytes < 4 || bytes > 0x10000000) {
        G32(out) = 0;
        TRACE("CreateSoundBuffer: bad format or size %u\n", bytes);
        return DSERR_BADFORMAT;
    }
    struct dsbuf *b = new_buffer(&o);
    b->channels = b0.channels, b->bits = b0.bits, b->align = b0.align, b->rate = b0.rate;
    b->flags = flags | DSBCAPS_LOCSOFTWARE;
    b->primary = (flags & DSBCAPS_PRIMARYBUFFER) != 0;
    b->size = bytes - bytes % b->align;
    o->mem = b->mem = bl_guest_calloc(1, b->size);
    if (b->bits == 8) memset(bl_g2h(b->mem), 0x80, b->size);
    o->size = b->size;
    link_buffer(b);
    G32(out) = o->guest;
    TRACE("CreateSoundBuffer %s: %u bytes, %u Hz %u-bit %u ch, flags %#x\n", b->primary ? "primary" : "secondary",
          b->size, b->rate, b->bits, b->channels, flags);
    return DS_OK;
}

uint32_t bl_IDirectSound_GetCaps_c(uint32_t self, uint32_t caps)
{
    (void)self;
    uint32_t size = G32(caps);
    memset(bl_g2h(caps + 4), 0, size > 4 ? size - 4 : 0);
    // DSCAPS_PRIMARY{MONO,STEREO,8BIT,16BIT} | CONTINUOUSRATE | SECONDARY{MONO,STEREO,8BIT,16BIT}.
    G32(caps + 4) = 0xF | 0x10 | 0xF00;
    G32(caps + 8) = 100, G32(caps + 12) = 200000;  // secondary sample rates
    G32(caps + 16) = 1;                            // primary buffers
    return DS_OK;
}

uint32_t bl_IDirectSound_DuplicateSoundBuffer_c(uint32_t self, uint32_t orig, uint32_t out)
{
    (void)self;
    struct dsbuf *a = buf(orig);
    struct obj *o;
    struct dsbuf *b = new_buffer(&o);
    struct obj *keep = b->o;
    *b = *a;
    b->o = keep, b->next = NULL, b->playing = 0, b->pos = 0;
    b->share = a->share ? a->share : a->o;
    obj_addref(b->share);
    o->size = b->size;  // o->mem stays 0: the original frees the memory
    link_buffer(b);
    G32(out) = o->guest;
    return DS_OK;
}

uint32_t bl_IDirectSound_SetCooperativeLevel_c(uint32_t self, uint32_t hwnd, uint32_t level)
{
    (void)self, (void)hwnd;
    coop_level = level;
    TRACE("SetCooperativeLevel %u\n", level);
    return DS_OK;
}

uint32_t bl_IDirectSound_Compact_c(uint32_t self) { (void)self; return DS_OK; }

uint32_t bl_IDirectSound_GetSpeakerConfig_c(uint32_t self, uint32_t out)
{
    (void)self;
    G32(out) = DSSPEAKER_STEREO;
    return DS_OK;
}

uint32_t bl_IDirectSound_SetSpeakerConfig_c(uint32_t self, uint32_t cfg) { (void)self, (void)cfg; return DS_OK; }
uint32_t bl_IDirectSound_Initialize_c(uint32_t self, uint32_t guid) { (void)self, (void)guid; return DSERR_ALREADYINITIALIZED; }

// --- IDirectSoundBuffer --------------------------------------------------------

void dsound_buffer_free(struct obj *o)
{
    struct dsbuf *b = o->sound;
    if (!b) return;
    pthread_mutex_lock(&lock);
    for (struct dsbuf **p = &buffers; *p; p = &(*p)->next)
        if (*p == b) {
            *p = b->next;
            break;
        }
    pthread_mutex_unlock(&lock);
    if (b->share) obj_release(b->share);
    o->sound = NULL;
    free(b);
}

uint32_t bl_IDirectSoundBuffer_GetCaps_c(uint32_t self, uint32_t caps)
{
    struct dsbuf *b = buf(self);
    // DSBCAPS: dwSize, dwFlags, dwBufferBytes, dwUnlockTransferRate, dwPlayCpuOverhead.
    G32(caps + 4) = b->flags, G32(caps + 8) = b->size, G32(caps + 12) = 0, G32(caps + 16) = 0;
    return DS_OK;
}

// Lead of the write cursor over the play cursor: about 10 ms.
static uint32_t lead_bytes(const struct dsbuf *b)
{
    uint32_t rate = b->freq ? b->freq : b->rate;
    return (rate / 100 + 1) * b->align;
}

uint32_t bl_IDirectSoundBuffer_GetCurrentPosition_c(uint32_t self, uint32_t play, uint32_t write)
{
    struct dsbuf *b = buf(self);
    pthread_mutex_lock(&lock);
    uint32_t p = ((uint32_t)b->pos * b->align) % b->size;
    uint32_t w = b->playing ? (p + lead_bytes(b)) % b->size : p;
    pthread_mutex_unlock(&lock);
    if (play) G32(play) = p;
    if (write) G32(write) = w;
    return DS_OK;
}

uint32_t bl_IDirectSoundBuffer_GetFormat_c(uint32_t self, uint32_t fmt, uint32_t size, uint32_t written)
{
    struct dsbuf *b = buf(self);
    uint8_t w[18] = {0};
    w[0] = 1;
    memcpy(w + 2, &b->channels, 2);
    memcpy(w + 4, &b->rate, 4);
    uint32_t avg = b->rate * b->align;
    memcpy(w + 8, &avg, 4);
    memcpy(w + 12, &b->align, 2);
    memcpy(w + 14, &b->bits, 2);
    if (fmt) memcpy(bl_g2h(fmt), w, size < 18 ? size : 18);
    if (written) G32(written) = 18;
    return DS_OK;
}

uint32_t bl_IDirectSoundBuffer_GetVolume_c(uint32_t self, uint32_t out) { G32(out) = (uint32_t)buf(self)->volume; return DS_OK; }
uint32_t bl_IDirectSoundBuffer_GetPan_c(uint32_t self, uint32_t out) { G32(out) = (uint32_t)buf(self)->pan; return DS_OK; }

uint32_t bl_IDirectSoundBuffer_GetFrequency_c(uint32_t self, uint32_t out)
{
    struct dsbuf *b = buf(self);
    G32(out) = b->freq ? b->freq : b->rate;
    return DS_OK;
}

uint32_t bl_IDirectSoundBuffer_GetStatus_c(uint32_t self, uint32_t out)
{
    struct dsbuf *b = buf(self);
    pthread_mutex_lock(&lock);
    G32(out) = b->playing ? DSBSTATUS_PLAYING | (b->looping ? DSBSTATUS_LOOPING : 0) : 0;
    pthread_mutex_unlock(&lock);
    return DS_OK;
}

uint32_t bl_IDirectSoundBuffer_Initialize_c(uint32_t self, uint32_t ds, uint32_t desc)
{
    (void)self, (void)ds, (void)desc;
    return DSERR_ALREADYINITIALIZED;
}

uint32_t bl_IDirectSoundBuffer_Lock_c(uint32_t self, uint32_t offset, uint32_t bytes, uint32_t p1, uint32_t n1,
                                      uint32_t p2, uint32_t n2, uint32_t flags)
{
    struct dsbuf *b = buf(self);
    if (flags & DSBLOCK_FROMWRITECURSOR) {
        pthread_mutex_lock(&lock);
        offset = ((uint32_t)b->pos * b->align + (b->playing ? lead_bytes(b) : 0)) % b->size;
        pthread_mutex_unlock(&lock);
    }
    if (flags & DSBLOCK_ENTIREBUFFER) bytes = b->size;
    if (offset >= b->size || !bytes) return DSERR_INVALIDPARAM;
    if (bytes > b->size) bytes = b->size;
    uint32_t first = b->size - offset < bytes ? b->size - offset : bytes;
    G32(p1) = b->mem + offset;
    G32(n1) = first;
    if (p2) G32(p2) = bytes > first ? b->mem : 0;
    if (n2) G32(n2) = bytes - first;
    return DS_OK;
}

uint32_t bl_IDirectSoundBuffer_Play_c(uint32_t self, uint32_t reserved, uint32_t priority, uint32_t flags)
{
    (void)reserved, (void)priority;
    struct dsbuf *b = buf(self);
    pthread_mutex_lock(&lock);
    b->playing = 1, b->looping = (flags & DSBPLAY_LOOPING) != 0;
    pthread_mutex_unlock(&lock);
    return DS_OK;
}

uint32_t bl_IDirectSoundBuffer_SetCurrentPosition_c(uint32_t self, uint32_t pos)
{
    struct dsbuf *b = buf(self);
    pthread_mutex_lock(&lock);
    b->pos = (double)((pos % b->size) / b->align);
    pthread_mutex_unlock(&lock);
    return DS_OK;
}

uint32_t bl_IDirectSoundBuffer_SetFormat_c(uint32_t self, uint32_t wfx)
{
    struct dsbuf *b = buf(self);
    if (!b->primary) return DSERR_INVALIDPARAM;
    pthread_mutex_lock(&lock);
    int ok = set_format(b, wfx);
    if (ok) b->size = PRIMARY_BYTES - PRIMARY_BYTES % b->align, b->pos = 0;
    pthread_mutex_unlock(&lock);
    TRACE("primary SetFormat: %u Hz %u-bit %u ch%s\n", b->rate, b->bits, b->channels, ok ? "" : " (rejected)");
    return ok ? DS_OK : DSERR_BADFORMAT;
}

uint32_t bl_IDirectSoundBuffer_SetVolume_c(uint32_t self, uint32_t v) { buf(self)->volume = (int32_t)v; return DS_OK; }
uint32_t bl_IDirectSoundBuffer_SetPan_c(uint32_t self, uint32_t v) { buf(self)->pan = (int32_t)v; return DS_OK; }
uint32_t bl_IDirectSoundBuffer_SetFrequency_c(uint32_t self, uint32_t f) { buf(self)->freq = f; return DS_OK; }

uint32_t bl_IDirectSoundBuffer_Stop_c(uint32_t self)
{
    struct dsbuf *b = buf(self);
    pthread_mutex_lock(&lock);
    b->playing = 0;
    pthread_mutex_unlock(&lock);
    return DS_OK;
}

uint32_t bl_IDirectSoundBuffer_Unlock_c(uint32_t self, uint32_t p1, uint32_t n1, uint32_t p2, uint32_t n2)
{
    (void)self, (void)p1, (void)n1, (void)p2, (void)n2;
    return DS_OK;
}

uint32_t bl_IDirectSoundBuffer_Restore_c(uint32_t self) { (void)self; return DS_OK; }
