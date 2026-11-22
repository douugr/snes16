#import "RF.h"
#include "libretro.h"
#include "rf_patch.h"
#include "rc_consoles.h"
#include <zlib.h>
#import <QuartzCore/QuartzCore.h>

volatile uint32_t rf_touch_mask = 0;
volatile uint32_t rf_pad_mask = 0;
volatile double rf_input_changed_at = 0;
volatile uint32_t rf_input_seq = 0;

void RFInputChanged(void) {
    rf_input_changed_at = CACurrentMediaTime();
    rf_input_seq++;
}

NSString *RFBaseDir(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *base = [docs stringByAppendingPathComponent:@"SNES16"];
    [[NSFileManager defaultManager] createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
    return base;
}

void RFAppendLog(NSString *file, NSString *line) {
    @synchronized ([NSFileManager class]) {
    static NSDateFormatter *fmt;
    if (!fmt) {
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    }
    NSString *path = [RFBaseDir() stringByAppendingPathComponent:file];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attrs fileSize] > 200 * 1024) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSString *text = [NSString stringWithFormat:@"%@  %@\n", [fmt stringFromDate:[NSDate date]], line];
    FILE *f = fopen(path.fileSystemRepresentation, "a");
    if (!f) return;
    fputs(text.UTF8String, f);
    fclose(f);
    }
}

NSString *RFDir(NSString *name) {
    NSString *dir = [RFBaseDir() stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

#pragma mark - Callbacks do libretro

static char rf_system_dir[1024];
static char rf_save_dir[1024];

static const void *rf_frame_data = NULL;
static unsigned rf_frame_width = 0, rf_frame_height = 0;
static size_t rf_frame_pitch = 0;
static float rf_aspect = 4.0f / 3.0f;
static bool rf_skip_video = false;
static bool rf_mute_audio = false;
static bool rf_fast_states = false;   // run-ahead: o core salva/restaura também o buffer de som   // quadro "previsto" do run-ahead: o som dele é descartado

static bool rf_environment(unsigned cmd, void *data) {
    switch (cmd) {
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            return *(const enum retro_pixel_format *)data == RETRO_PIXEL_FORMAT_RGB565;
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            *(const char **)data = rf_system_dir;
            return true;
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            *(const char **)data = rf_save_dir;
            return true;
        case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
            return true;
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            *(bool *)data = true;
            return true;
        case RETRO_ENVIRONMENT_SET_GEOMETRY: {
            const struct retro_game_geometry *g = data;
            if (g->aspect_ratio > 0) rf_aspect = g->aspect_ratio;
            return true;
        }
        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
            const struct retro_system_av_info *av = data;
            if (av->geometry.aspect_ratio > 0) rf_aspect = av->geometry.aspect_ratio;
            return true;
        }
        case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
            RFAchievementsSetMemoryMap(data);   // RetroAchievements lê a RAM do jogo por este mapa
            return true;
        case RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS:
            return true;
        case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE:
            // bit 0 = vídeo, bit 1 = áudio. Pular o vídeo poupa a renderização do VDP.
            // bit 2 = "estados rápidos" (run-ahead): mantém o som contínuo ao voltar o estado
            *(int *)data = (rf_skip_video ? 2 : 3) | (rf_fast_states ? 4 : 0);
            return true;
        default:
            return false;   // opções do core ficam no padrão
    }
}

static void rf_video_refresh(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (!data) return;   // quadro repetido
    rf_frame_data = data;
    rf_frame_width = width;
    rf_frame_height = height;
    rf_frame_pitch = pitch;
}

static void rf_audio_sample(int16_t left, int16_t right) {
    if (rf_mute_audio) return;
    int16_t s[2] = {left, right};
    [[RFAudio shared] pushSamples:s frames:1];
}

static size_t rf_audio_sample_batch(const int16_t *data, size_t frames) {
    if (rf_mute_audio) return frames;
    [[RFAudio shared] pushSamples:data frames:frames];
    return frames;
}

static void rf_input_poll(void) {
}

static int16_t rf_input_state(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (port != 0 || device != RETRO_DEVICE_JOYPAD) return 0;
    uint32_t mask = rf_touch_mask | rf_pad_mask;
    if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)(mask & 0xFFFF);
    return (mask >> id) & 1;
}

#pragma mark - RFCore

@interface RFCore ()
@property (nonatomic, readwrite) double fps;
@property (nonatomic, readwrite) double sampleRate;
@property (nonatomic, readwrite) BOOL loaded;
@property (nonatomic, readwrite, copy) NSString *gameName;
@property (nonatomic, assign) BOOL initialized;
@property (nonatomic, readwrite) BOOL patched;
@end

uint32_t RFConsoleForPath(NSString *path) {
    return RC_CONSOLE_SUPER_NINTENDO;
}

// Save do cartucho (SRAM) e a pasta dele no repositório da nuvem
NSArray *RFCloudSaveFiles(NSString *romPath) {
    NSString *local = [RFDir(@"saves") stringByAppendingPathComponent:[romPath.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:@"srm"]];
    NSMutableArray *files = [@[ @{ @"local": local, @"folder": @"snes" } ] mutableCopy];
    // Save states dos slots 1 a 3 (o automático fica só neste aparelho): o mesmo pacote .rfst do Switch.
    // O Switch grava os states no layout do iPad (ver o patch do Snes9x 2005 no SNES16 do Switch)
    NSString *game = romPath.lastPathComponent.stringByDeletingPathExtension;
    for (int slot = 1; slot <= 3; slot++) {
        NSString *st = [RFDir(@"states") stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.state%d.rfst", game, slot]];
        [files addObject:@{ @"local": st, @"folder": @"snes", @"suffix": [NSString stringWithFormat:@".state%d.rfst", slot],
                            @"label": [NSString stringWithFormat:@"save state slot %d", slot] }];
    }
    return files;
}

#pragma mark Pacote de save state para a nuvem (.rfst, o mesmo formato do Switch)
// "RFSZ" + tamanho original (u32) + zlib de: "RFST" + versão (u32 = 1) + n (u32) + n seções (etiqueta de 4 letras,
// tamanho u32, dados). STAT = state, RAPG = progresso das conquistas, THMB = miniatura (só o Switch grava; aqui é ignorada)

static void rf_put32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = { v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255 };
    [d appendBytes:b length:4];
}

static uint32_t rf_get32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }

static NSData *rf_bundle(NSData *state, NSData *progress) {
    NSMutableData *raw = [NSMutableData dataWithBytes:"RFST" length:4];
    rf_put32(raw, 1);
    rf_put32(raw, progress.length ? 2 : 1);
    [raw appendBytes:"STAT" length:4]; rf_put32(raw, (uint32_t)state.length); [raw appendData:state];
    if (progress.length) { [raw appendBytes:"RAPG" length:4]; rf_put32(raw, (uint32_t)progress.length); [raw appendData:progress]; }
    uLongf zlen = compressBound(raw.length);
    NSMutableData *out = [NSMutableData dataWithBytes:"RFSZ" length:4];
    rf_put32(out, (uint32_t)raw.length);
    [out increaseLengthBy:zlen];
    if (compress2((Bytef *)out.mutableBytes + 8, &zlen, raw.bytes, raw.length, 6) != Z_OK) return nil;
    out.length = 8 + zlen;
    return out;
}

// Um pacote chegou da nuvem: vira os arquivos do slot (.stateN e .stateN.ra)
void RFCloudDidDownload(NSString *localPath) {
    if (![localPath.pathExtension isEqualToString:@"rfst"]) return;
    NSData *z = [NSData dataWithContentsOfFile:localPath];
    const uint8_t *zp = z.bytes;
    if (z.length < 8 || memcmp(zp, "RFSZ", 4)) return;
    uLongf len = rf_get32(zp + 4);
    NSMutableData *raw = [NSMutableData dataWithLength:len];
    if (uncompress(raw.mutableBytes, &len, zp + 8, z.length - 8) != Z_OK || len < 12 || memcmp(raw.bytes, "RFST", 4)) {
        RFAppendLog(@"cloud.txt", [@"damaged state package " stringByAppendingString:localPath.lastPathComponent]);
        return;
    }
    const uint8_t *p = raw.bytes;
    uint32_t n = rf_get32(p + 8);
    size_t at = 12;
    NSData *state = nil, *progress = nil;
    for (uint32_t i = 0; i < n && at + 8 <= len; i++) {
        uint32_t sz = rf_get32(p + at + 4);
        if (at + 8 + sz > len) break;
        NSData *d = [NSData dataWithBytes:p + at + 8 length:sz];
        if (!memcmp(p + at, "STAT", 4)) state = d;
        else if (!memcmp(p + at, "RAPG", 4)) progress = d;
        at += 8 + sz;
    }
    if (!state.length) return;
    NSString *base = localPath.stringByDeletingPathExtension;   // .../jogo.state1
    [state writeToFile:base atomically:YES];
    NSString *ra = [base stringByAppendingString:@".ra"];
    if (progress.length) [progress writeToFile:ra atomically:YES];
    else [[NSFileManager defaultManager] removeItemAtPath:ra error:nil];
    RFAppendLog(@"cloud.txt", [@"unpacked " stringByAppendingString:localPath.lastPathComponent]);
}

// ROMs da biblioteca (as mesmas da lista de jogos)
NSArray *RFCloudLibraryGames(void) {
    NSString *dir = RFDir(@"roms");
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
        if ([@[@"sfc", @"smc", @"swc", @"fig", @"gd3", @"gd7", @"dx2", @"bsx"] containsObject:f.pathExtension.lowercaseString]) [out addObject:[dir stringByAppendingPathComponent:f]];
    }
    return out;
}

NSArray *RFAchievementsConsoles(void) {
    return @[ @{ @"id": @(RC_CONSOLE_SUPER_NINTENDO), @"name": @"SNES" } ];
}

@implementation RFCore

+ (instancetype)shared {
    static RFCore *core;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ core = [[RFCore alloc] init]; });
    return core;
}

- (float)aspectRatio {
    return rf_aspect;
}

- (void)ensureInit {
    if (self.initialized) return;
    strlcpy(rf_system_dir, RFDir(@"system").fileSystemRepresentation, sizeof(rf_system_dir));
    strlcpy(rf_save_dir, RFDir(@"saves").fileSystemRepresentation, sizeof(rf_save_dir));
    retro_set_environment(rf_environment);
    retro_set_video_refresh(rf_video_refresh);
    retro_set_audio_sample(rf_audio_sample);
    retro_set_audio_sample_batch(rf_audio_sample_batch);
    retro_set_input_poll(rf_input_poll);
    retro_set_input_state(rf_input_state);
    retro_init();
    self.initialized = YES;
}

- (NSString *)sramPath {
    return [RFDir(@"saves") stringByAppendingPathComponent:[self.gameName stringByAppendingPathExtension:@"srm"]];
}

- (NSString *)statePath:(int)slot {
    NSString *file = [NSString stringWithFormat:@"%@.state%d", self.gameName, slot];
    return [RFDir(@"states") stringByAppendingPathComponent:file];
}

+ (NSString *)patchPathForROM:(NSString *)romPath {
    NSString *base = romPath.stringByDeletingPathExtension;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *ext in @[@"bps", @"BPS", @"ips", @"IPS"]) {
        NSString *p = [base stringByAppendingPathExtension:ext];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

// Aplica o patch numa cópia temporária (a ROM original não é alterada)
- (NSString *)patchedCopyOf:(NSString *)romPath patch:(NSString *)patchPath error:(NSString **)error {
    NSData *rom = [NSData dataWithContentsOfFile:romPath];
    NSData *patch = [NSData dataWithContentsOfFile:patchPath];
    if (!rom || !patch) {
        if (error) *error = @"Could not read the ROM or the patch.";
        return nil;
    }
    uint8_t *out = NULL;
    size_t outLen = 0;
    // ROMs de SNES às vezes têm 512 bytes de cabeçalho de copiadora; os patches quase sempre
    // são feitos para a ROM sem cabeçalho. Tenta sem cabeçalho e, se o BPS reclamar, com ele.
    const uint8_t *src = rom.bytes;
    size_t srcLen = rom.length;
    BOOL header = (srcLen % 1024) == 512;
    rf_patch_result r = rf_apply_patch(header ? src + 512 : src, header ? srcLen - 512 : srcLen,
                                       patch.bytes, patch.length, &out, &outLen);
    if (r == RF_PATCH_WRONG_SOURCE && header) {
        r = rf_apply_patch(src, srcLen, patch.bytes, patch.length, &out, &outLen);
    }
    if (r != RF_PATCH_OK) {
        if (error) {
            switch (r) {
                case RF_PATCH_WRONG_SOURCE:
                    *error = [NSString stringWithFormat:@"The patch %@ was made for a different version of this ROM (the CRC does not match). Use the original ROM listed on the hack's page.", patchPath.lastPathComponent];
                    break;
                case RF_PATCH_UNKNOWN_FORMAT:
                    *error = [NSString stringWithFormat:@"%@ is not an IPS or BPS patch.", patchPath.lastPathComponent];
                    break;
                case RF_PATCH_NO_MEMORY:
                    *error = @"Not enough memory to apply the patch.";
                    break;
                default:
                    *error = [NSString stringWithFormat:@"The patch %@ seems to be damaged.", patchPath.lastPathComponent];
                    break;
            }
        }
        return nil;
    }
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"patched"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dest = [dir stringByAppendingPathComponent:romPath.lastPathComponent];
    NSData *data = [NSData dataWithBytesNoCopy:out length:outLen freeWhenDone:YES];
    if (![data writeToFile:dest atomically:YES]) {
        if (error) *error = @"Could not write the patched ROM.";
        return nil;
    }
    return dest;
}

- (BOOL)loadGameAtPath:(NSString *)path error:(NSString **)error {
    [self ensureInit];
    if (self.loaded) [self unload];

    NSString *originalPath = path;
    NSString *patchPath = [RFCore patchPathForROM:path];
    self.patched = NO;
    if (patchPath) {
        NSString *patchedPath = [self patchedCopyOf:path patch:patchPath error:error];
        if (!patchedPath) return NO;
        path = patchedPath;
        self.patched = YES;
    }

    struct retro_game_info info;
    memset(&info, 0, sizeof(info));
    info.path = path.fileSystemRepresentation;
    if (!retro_load_game(&info)) {
        if (error) *error = @"The emulator core could not load this file.";
        return NO;
    }

    struct retro_system_av_info av;
    memset(&av, 0, sizeof(av));
    retro_get_system_av_info(&av);
    self.fps = av.timing.fps > 0 ? av.timing.fps : 60.0;
    self.sampleRate = av.timing.sample_rate > 0 ? av.timing.sample_rate : 44100.0;
    if (av.geometry.aspect_ratio > 0) rf_aspect = av.geometry.aspect_ratio;
    else if (av.geometry.base_height) rf_aspect = (float)av.geometry.base_width / av.geometry.base_height;

    self.gameName = originalPath.lastPathComponent.stringByDeletingPathExtension;
    self.loaded = YES;
    rf_frame_data = NULL;

    // Restaura a SRAM (saves internos do cartucho)
    NSData *sram = [NSData dataWithContentsOfFile:[self sramPath]];
    size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    void *mem = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (sram && mem && size) {
        memcpy(mem, sram.bytes, MIN(size, sram.length));
    }
    // RetroAchievements identifica o jogo pela ROM original (sem patch)
    [[RFAchievements shared] gameLoadedAtPath:originalPath console:RFConsoleForPath(originalPath) patched:self.patched];
    return YES;
}

- (void)runFrame {
    [self runFrameSkippingVideo:NO];
}

- (void)runFrameSkippingVideo:(BOOL)skip {
    if (!self.loaded) return;
    rf_skip_video = skip;
    retro_run();
    rf_skip_video = false;
    if (!rf_mute_audio) [[RFAchievements shared] doFrame];   // quadros previstos do run-ahead não contam
}

static void *rf_ahead_state = NULL;
static size_t rf_ahead_size = 0;

- (BOOL)runFrameWithRunAhead {
    if (!self.loaded) return NO;
    size_t size = retro_serialize_size();
    if (!size) {
        [self runFrameSkippingVideo:NO];
        return NO;
    }
    if (size > rf_ahead_size) {
        free(rf_ahead_state);
        rf_ahead_state = malloc(size);
        rf_ahead_size = rf_ahead_state ? size : 0;
    }
    // 1) Quadro real: avança o jogo e gera o som, sem desenhar
    [self runFrameSkippingVideo:YES];
    rf_fast_states = true;
    BOOL saved = rf_ahead_state && retro_serialize(rf_ahead_state, size);
    rf_fast_states = false;
    if (!saved) {
        // Sem estado não dá para prever: desenha o próximo quadro de verdade na próxima volta
        return NO;
    }
    // 2) Quadro previsto: mesmo controle, só para a imagem
    rf_mute_audio = true;
    [self runFrameSkippingVideo:NO];
    rf_mute_audio = false;
    // 3) Volta ao quadro real
    rf_fast_states = true;
    retro_unserialize(rf_ahead_state, size);
    rf_fast_states = false;
    return YES;
}

- (void)reset {
    if (!self.loaded) return;
    retro_reset();
    [[RFAchievements shared] reset];
}

- (void)saveSRAM {
    if (!self.loaded) return;
    size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    void *mem = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!mem || !size) return;
    // Só grava se houver algo diferente de zero (evita criar arquivos vazios)
    const uint8_t *p = mem;
    BOOL any = NO;
    for (size_t i = 0; i < size; i++) {
        if (p[i] != 0 && p[i] != 0xFF) { any = YES; break; }
    }
    if (any && [[NSData dataWithBytes:mem length:size] writeToFile:[self sramPath] atomically:YES]) [[RFCloud shared] localSaveWritten:[self sramPath]];
}

- (void)unload {
    if (!self.loaded) return;
    RFQuitStep("sram");
    [self saveSRAM];
    RFQuitStep("achievements unload");
    [[RFAchievements shared] gameUnloaded];
    RFQuitStep("core unload");
    retro_unload_game();
    RFQuitStep("core unloaded");
    self.loaded = NO;
    rf_frame_data = NULL;
}

- (BOOL)saveStateSlot:(int)slot {
    if (!self.loaded) return NO;
    size_t size = retro_serialize_size();
    if (!size) return NO;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (!retro_serialize(data.mutableBytes, size)) return NO;
    // Estado das conquistas junto (para não disparar ou perder conquistas ao carregar)
    NSString *raPath = [[self statePath:slot] stringByAppendingString:@".ra"];
    NSData *progress = [[RFAchievements shared] progress];
    if (progress) [progress writeToFile:raPath atomically:YES];
    else [[NSFileManager defaultManager] removeItemAtPath:raPath error:nil];
    BOOL ok = [data writeToFile:[self statePath:slot] atomically:YES];
    if (ok && slot >= 1) {
        // Pacote para a nuvem, comprimido fora da thread principal (o A5X leva um instante); sobe ao sair do jogo
        NSString *bundlePath = [[self statePath:slot] stringByAppendingString:@".rfst"];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            NSData *b = rf_bundle(data, progress);
            if (b && [b writeToFile:bundlePath atomically:YES]) [[RFCloud shared] localSaveWritten:bundlePath];
        });
    }
    return ok;
}

- (BOOL)loadStateSlot:(int)slot {
    if (!self.loaded) return NO;
    NSData *data = [NSData dataWithContentsOfFile:[self statePath:slot]];
    if (!data) return NO;
    if (!retro_unserialize(data.bytes, data.length)) return NO;
    [[RFAchievements shared] restoreProgress:[NSData dataWithContentsOfFile:[[self statePath:slot] stringByAppendingString:@".ra"]]];
    return YES;
}

- (NSDate *)dateForStateSlot:(int)slot {
    if (!self.loaded) return nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:[self statePath:slot] error:nil];
    return attrs.fileModificationDate;
}

- (BOOL)hasStateSlot:(int)slot {
    return self.loaded && [[NSFileManager defaultManager] fileExistsAtPath:[self statePath:slot]];
}

- (const void *)frameData:(unsigned *)width height:(unsigned *)height pitch:(size_t *)pitch {
    if (width) *width = rf_frame_width;
    if (height) *height = rf_frame_height;
    if (pitch) *pitch = rf_frame_pitch;
    return rf_frame_data;
}

@end

#pragma mark - Áudio (RemoteIO + buffer circular)

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#define RF_RING_FRAMES 16384   // ~370 ms a 44,1 kHz
static int16_t rf_ring[RF_RING_FRAMES * 2];
static volatile uint32_t rf_ring_write = 0;   // em quadros (estéreo)
static volatile uint32_t rf_ring_read = 0;
static volatile uint32_t rf_underruns = 0;
static volatile int rf_audio_primed = 0;   // só conta falhas depois que o som começou

static OSStatus rf_render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                          UInt32 bus, UInt32 frames, AudioBufferList *io) {
    int16_t *out = io->mBuffers[0].mData;
    uint32_t r = rf_ring_read;
    uint32_t w = rf_ring_write;
    __sync_synchronize();
    uint32_t available = w - r;
    uint32_t n = MIN(available, frames);
    for (uint32_t i = 0; i < n; i++) {
        uint32_t idx = (r + i) % RF_RING_FRAMES;
        out[i * 2] = rf_ring[idx * 2];
        out[i * 2 + 1] = rf_ring[idx * 2 + 1];
    }
    if (n < frames) {
        memset(out + n * 2, 0, (frames - n) * 4);   // faltou som: silêncio
        if (rf_audio_primed) rf_underruns++;
    } else {
        rf_audio_primed = 1;
    }
    __sync_synchronize();
    rf_ring_read = r + n;
    return noErr;
}

@interface RFAudio ()
@property (nonatomic, assign) AudioComponentInstance unit;
@property (nonatomic, assign) BOOL running;
@end

@implementation RFAudio

+ (instancetype)shared {
    static RFAudio *audio;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ audio = [[RFAudio alloc] init]; });
    return audio;
}

- (void)startWithSampleRate:(double)rate {
    [self stop];
    [self clear];
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    [session setPreferredIOBufferDuration:0.012 error:nil];
    [session setActive:YES error:nil];

    AudioComponentDescription desc = {0};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    AudioComponentInstance unit = NULL;
    if (!comp || AudioComponentInstanceNew(comp, &unit) != noErr) return;

    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate = rate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel = 16;
    fmt.mBytesPerFrame = 4;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerPacket = 4;
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));

    AURenderCallbackStruct cb = { rf_render, NULL };
    AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));

    if (AudioUnitInitialize(unit) == noErr && AudioOutputUnitStart(unit) == noErr) {
        self.unit = unit;
        self.running = YES;
    } else {
        AudioComponentInstanceDispose(unit);
    }
}

- (void)stop {
    if (!self.unit) return;
    AudioOutputUnitStop(self.unit);
    AudioUnitUninitialize(self.unit);
    AudioComponentInstanceDispose(self.unit);
    self.unit = NULL;
    self.running = NO;
}

- (void)clear {
    rf_ring_read = 0;
    rf_ring_write = 0;
    rf_audio_primed = 0;
}

- (uint32_t)bufferedFrames {
    uint32_t w = rf_ring_write;
    uint32_t r = rf_ring_read;
    return w - r;
}

- (uint32_t)underruns {
    return rf_underruns;
}

- (void)pushSamples:(const int16_t *)data frames:(size_t)frames {
    uint32_t w = rf_ring_write;
    uint32_t r = rf_ring_read;
    uint32_t used = w - r;
    // Mantém a latência baixa: se o buffer encher demais, descarta o excesso
    uint32_t limit = RF_RING_FRAMES / 2;   // o ritmo do jogo já segura a fila; isto é só proteção
    if (used > limit) return;
    uint32_t space = RF_RING_FRAMES - used;
    uint32_t n = (uint32_t)MIN(frames, space);
    for (uint32_t i = 0; i < n; i++) {
        uint32_t idx = (w + i) % RF_RING_FRAMES;
        rf_ring[idx * 2] = data[i * 2];
        rf_ring[idx * 2 + 1] = data[i * 2 + 1];
    }
    __sync_synchronize();
    rf_ring_write = w + n;
}

@end
