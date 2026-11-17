#import "RF.h"
#include "btstack.h"
#include "hci_cmds.h"
#include "run_loop.h"
#include "utils.h"

NSString *RFActionName(RFAction action) {
    switch (action) {
        case RFActionUp: return @"Cima";
        case RFActionDown: return @"Baixo";
        case RFActionLeft: return @"Esquerda";
        case RFActionRight: return @"Direita";
        case RFActionA: return @"A";
        case RFActionB: return @"B";
        case RFActionX: return @"X";
        case RFActionY: return @"Y";
        case RFActionStart: return @"Start";
        case RFActionL: return @"L (ombro esquerdo)";
        case RFActionR: return @"R (ombro direito)";
        case RFActionSelect: return @"Select";
        case RFActionMenu: return @"Abrir o menu do emulador (opcional)";
        default: return @"?";
    }
}

static const uint32_t kRFActionMask[RFActionCount] = {
    RF_UP, RF_DOWN, RF_LEFT, RF_RIGHT,
    RF_SN_A, RF_SN_B, RF_SN_X, RF_SN_Y, RF_SN_START,
    RF_SN_L, RF_SN_R, RF_SN_SELECT,
    0,
};

typedef enum { RFMapNone = 0, RFMapBit, RFMapHat, RFMapAxis } RFMapKind;

typedef struct {
    RFMapKind kind;
    uint8_t byteIndex;
    uint8_t mask;     // RFMapBit
    uint8_t center;   // RFMapAxis: valor em repouso
    int8_t sign;      // RFMapAxis: -1 ou +1
} RFMapping;

#define RF_MAX_DEVICES 16
#define RF_REPORT_MAX 64

typedef struct {
    bd_addr_t addr;
    uint8_t psrm;
    uint16_t clock;
    uint32_t cod;
    char name[64];
    int nameRequested;
} RFDevice;

static RFDevice gDevices[RF_MAX_DEVICES];
static int gDeviceCount;
static int gInquiry;
static int gNamePending;
static bd_addr_t gTarget;
static int gHasTarget;
static uint16_t gControlCid, gInterruptCid;
static RFMapping gMap[RFActionCount];
static uint8_t gBaseline[RF_REPORT_MAX];
static int gBaselineLen;
static uint8_t gLast[RF_REPORT_MAX];
static int gLastLen;
static int gWaitRelease;
static uint8_t gCandidate[RF_REPORT_MAX];   // relatório "mais apertado" visto desde que algo mudou
static int gCandidateLen;
static int gCandidateScore;
static int gLearnScheduled;
static int gMenuDown;

static void rf_bt_handler(uint8_t type, uint16_t channel, uint8_t *packet, uint16_t size);

@interface RFBluetooth ()
@property (nonatomic, readwrite, copy) NSString *status;
@property (nonatomic, readwrite) BOOL available;
@property (nonatomic, readwrite) BOOL connected;
@property (nonatomic, readwrite, copy) NSString *connectedName;
@property (nonatomic, readwrite) BOOL calibrating;
@property (nonatomic, readwrite) RFAction calibratingAction;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL ready;
@property (nonatomic, strong) NSMutableArray<NSString *> *logBuffer;
@property (nonatomic, strong) NSThread *btThread;
@property (nonatomic, assign) CFRunLoopRef btRunLoop;
- (void)handleReport:(const uint8_t *)r length:(int)len;
- (void)log:(NSString *)text;
- (void)changed;
- (void)onConnectedTo:(bd_addr_t)addr;
@end

static NSString *rf_addr(bd_addr_t a) {
    return [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X", a[0], a[1], a[2], a[3], a[4], a[5]];
}

static int rf_find(bd_addr_t a) {
    for (int i = 0; i < gDeviceCount; i++) {
        if (BD_ADDR_CMP(gDevices[i].addr, a) == 0) return i;
    }
    return -1;
}

static int rf_add(bd_addr_t a, uint8_t psrm, uint16_t clock, uint32_t cod) {
    int i = rf_find(a);
    if (i < 0) {
        if (gDeviceCount >= RF_MAX_DEVICES) return -1;
        i = gDeviceCount++;
        memset(&gDevices[i], 0, sizeof(RFDevice));
        BD_ADDR_COPY(gDevices[i].addr, a);
        [[RFBluetooth shared] log:[NSString stringWithFormat:@"Encontrado %@ (classe 0x%06X)", rf_addr(a), cod]];
    }
    gDevices[i].psrm = psrm;
    gDevices[i].clock = clock;
    gDevices[i].cod = cod;
    [[RFBluetooth shared] changed];
    return i;
}

static void rf_next_name(void) {
    if (gNamePending || gInquiry) return;
    for (int i = 0; i < gDeviceCount; i++) {
        if (!gDevices[i].nameRequested && !gDevices[i].name[0]) {
            gDevices[i].nameRequested = 1;
            gNamePending = 1;
            bt_send_cmd(&hci_remote_name_request, gDevices[i].addr, gDevices[i].psrm, 0, gDevices[i].clock | 0x8000);
            return;
        }
    }
}

@implementation RFBluetooth

+ (instancetype)shared {
    static RFBluetooth *bt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bt = [[RFBluetooth alloc] init]; });
    return bt;
}

- (instancetype)init {
    if ((self = [super init])) {
        _status = @"Bluetooth desligado";
    }
    return self;
}

#pragma mark Thread do Bluetooth
// O BTstack roda numa thread só dele. Na thread principal ele disputava tempo com o jogo
// (emulação + desenho ocupam quase os 16 ms de cada quadro): os dados do controle atrasavam
// segundos, chegavam em rajadas e a conexão com o BTdaemon acabava corrompida.

- (void)btThreadMain:(dispatch_semaphore_t)ready {
    @autoreleasepool {
        self.btRunLoop = CFRunLoopGetCurrent();
        CFRetain(self.btRunLoop);
        // Uma porta vazia mantém o run loop vivo mesmo sem fontes
        [[NSRunLoop currentRunLoop] addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
        dispatch_semaphore_signal(ready);
    }
    while (YES) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        }
    }
}

- (void)ensureThread {
    if (self.btThread) return;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(btThreadMain:) object:ready];
    t.name = @"SNES16.Bluetooth";
    t.threadPriority = 0.9;
    if ([t respondsToSelector:@selector(setQualityOfService:)]) t.qualityOfService = NSQualityOfServiceUserInteractive;
    self.btThread = t;
    [t start];
    dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
}

// Executa o bloco na thread do Bluetooth (na hora, se já estiver nela)
- (void)onBT:(dispatch_block_t)block {
    [self ensureThread];
    if ([NSThread currentThread] == self.btThread) {
        block();
        return;
    }
    CFRunLoopPerformBlock(self.btRunLoop, kCFRunLoopDefaultMode, block);
    CFRunLoopWakeUp(self.btRunLoop);
}

static void rf_main(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

- (void)start { [self onBT:^{ [self bt_start]; }]; }
- (void)scan { [self onBT:^{ [self bt_scan]; }]; }
- (void)disconnect { [self onBT:^{ [self bt_disconnect]; }]; }
- (void)forgetController { [self onBT:^{ [self bt_forgetController]; }]; }
- (void)startCalibration { [self onBT:^{ [self bt_startCalibration]; }]; }
- (void)skipCalibrationStep { [self onBT:^{ [self bt_skipCalibrationStep]; }]; }
- (void)cancelCalibration { [self onBT:^{ [self bt_cancelCalibration]; }]; }
- (void)connectDeviceAtIndex:(NSInteger)index { [self onBT:^{ [self bt_connectDeviceAtIndex:index]; }]; }

- (void)stop {
    if (!self.btThread) return;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [self onBT:^{
        [self bt_stop];
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)));
}

#pragma mark Registro e avisos

- (void)log:(NSString *)text {
    NSLog(@"[SNES16 BT] %@", text);
    RFAppendLog(@"bt.txt", text);
    @synchronized (self) {
        if (!self.logBuffer) self.logBuffer = [NSMutableArray array];
        [self.logBuffer addObject:text];
        while (self.logBuffer.count > 12) [self.logBuffer removeObjectAtIndex:0];
    }
    rf_main(^{
        if ([self.delegate respondsToSelector:@selector(bluetoothLog:)]) [self.delegate bluetoothLog:text];
    });
}

- (void)changed {
    rf_main(^{
        if ([self.delegate respondsToSelector:@selector(bluetoothDidChange)]) [self.delegate bluetoothDidChange];
    });
}

- (NSArray<NSString *> *)recentLog {
    @synchronized (self) {
        return self.logBuffer ? [self.logBuffer copy] : @[];
    }
}

- (void)setStatusText:(NSString *)text {
    if (![text isEqualToString:self.status]) [self log:[@"Estado: " stringByAppendingString:text]];
    self.status = text;
    [self changed];
}

#pragma mark Ciclo de vida

- (void)bt_start {
    if (self.started) return;
    self.started = YES;
    [self log:@"---- SNES16 iniciado ----"];
    run_loop_init(RUN_LOOP_COCOA);
    if (bt_open()) {
        self.available = NO;
        [self setStatusText:@"BTstack indisponível (o app precisa estar em /Applications)"];
        return;
    }
    self.available = YES;
    bt_register_packet_handler(rf_bt_handler);
    [self setStatusText:@"Ligando o Bluetooth..."];
    bt_send_cmd(&btstack_set_power_mode, HCI_POWER_ON);
    [self performSelector:@selector(checkReady) withObject:nil afterDelay:8.0];
}

- (void)bt_stop {
    if (!self.available) return;
    [self disconnect];
    bt_send_cmd(&btstack_set_power_mode, HCI_POWER_OFF);
    bt_close();
    self.available = NO;
    self.started = NO;
}

- (void)checkReady {
    if (self.ready || !self.available) return;
    // No iPad 3 o Wi-Fi e o Bluetooth dividem o mesmo chip: com o Wi-Fi desligado o BTstack não inicializa
    [self log:@"BTstack não ficou pronto em 8 s"];
    [self setStatusText:@"O Bluetooth não iniciou. Deixe o Wi-Fi do iPad LIGADO, feche e abra o app de novo."];
}

- (void)btReady {
    self.ready = YES;
    bt_send_cmd(&l2cap_register_service, PSM_HID_CONTROL, 250);
    bt_send_cmd(&l2cap_register_service, PSM_HID_INTERRUPT, 250);
    bt_send_cmd(&hci_write_inquiry_mode, 0x02);
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"RFControllerAddress"];
    if (saved.length && [self parseAddress:saved into:gTarget]) {
        gHasTarget = 1;
        [self loadMappingFor:saved];
        [self setStatusText:@"Bluetooth ligado. Ligue o controle para reconectar."];
        // Tenta conectar ao controle salvo (funciona se ele estiver ligado)
        bt_send_cmd(&l2cap_create_channel, gTarget, PSM_HID_CONTROL);
    } else {
        [self setStatusText:@"Bluetooth ligado. Nenhum controle pareado."];
    }
}

- (BOOL)parseAddress:(NSString *)s into:(bd_addr_t)addr {
    NSArray *parts = [s componentsSeparatedByString:@":"];
    if (parts.count != 6) return NO;
    for (int i = 0; i < 6; i++) {
        unsigned v = 0;
        [[NSScanner scannerWithString:parts[i]] scanHexInt:&v];
        addr[i] = (uint8_t)v;
    }
    return YES;
}

#pragma mark Busca e conexão

- (void)bt_scan {
    if (!self.available) return;
    if (!self.ready) {
        [self setStatusText:@"O Bluetooth ainda não está pronto. Deixe o Wi-Fi do iPad LIGADO, feche e abra o app de novo."];
        return;
    }
    if (gInquiry) {
        bt_send_cmd(&hci_inquiry_cancel);
        gInquiry = 0;
        [self setStatusText:@"Busca cancelada"];
        return;
    }
    gInquiry = 1;
    [self log:@"Busca iniciada (~12 s)"];
    [self setStatusText:@"Procurando... coloque o controle em modo de pareamento"];
    bt_send_cmd(&hci_inquiry, HCI_INQUIRY_LAP, 10, 0);
}

- (NSInteger)deviceCount {
    return gDeviceCount;
}

- (NSString *)deviceTitleAtIndex:(NSInteger)index {
    if (index < 0 || index >= gDeviceCount) return @"";
    RFDevice *d = &gDevices[index];
    NSString *name = d->name[0] ? [NSString stringWithUTF8String:d->name] : @"(sem nome)";
    return [NSString stringWithFormat:@"%@  ·  %@", name, rf_addr(d->addr)];
}

- (void)bt_connectDeviceAtIndex:(NSInteger)index {
    if (!self.available || index < 0 || index >= gDeviceCount) return;
    if (gInquiry) {
        bt_send_cmd(&hci_inquiry_cancel);
        gInquiry = 0;
    }
    BD_ADDR_COPY(gTarget, gDevices[index].addr);
    gHasTarget = 1;
    gControlCid = gInterruptCid = 0;
    [self log:[NSString stringWithFormat:@"Conectando a %@", rf_addr(gTarget)]];
    [self setStatusText:@"Conectando..."];
    bt_send_cmd(&l2cap_create_channel, gTarget, PSM_HID_CONTROL);
}

- (void)bt_disconnect {
    if (gInterruptCid) bt_send_cmd(&l2cap_disconnect, gInterruptCid, 0);
    if (gControlCid) bt_send_cmd(&l2cap_disconnect, gControlCid, 0);
}

- (void)bt_forgetController {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"RFControllerAddress"];
    if (saved) [[NSUserDefaults standardUserDefaults] removeObjectForKey:[@"RFMap-" stringByAppendingString:saved]];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"RFControllerAddress"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    memset(gMap, 0, sizeof(gMap));
    gHasTarget = 0;
    [self disconnect];
    [self setStatusText:@"Controle esquecido"];
}

- (void)onConnectedTo:(bd_addr_t)addr {
    NSString *a = rf_addr(addr);
    int idx = rf_find(addr);
    NSString *name = (idx >= 0 && gDevices[idx].name[0]) ? [NSString stringWithUTF8String:gDevices[idx].name] : a;
    self.connected = YES;
    self.connectedName = name;
    gBaselineLen = 0;
    gLastLen = 0;
    [[NSUserDefaults standardUserDefaults] setObject:a forKey:@"RFControllerAddress"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self loadMappingFor:a];
    [self setStatusText:[NSString stringWithFormat:@"Conectado: %@", name]];
}

- (void)onDisconnected {
    self.connected = NO;
    rf_pad_mask = 0;
    [self setStatusText:@"Controle desconectado"];
}

#pragma mark Mapeamento

- (BOOL)hasMapping {
    for (int i = RFActionUp; i <= RFActionStart; i++) {
        if (gMap[i].kind == RFMapNone) return NO;
    }
    return YES;
}

- (void)saveMapping {
    NSString *a = [[NSUserDefaults standardUserDefaults] stringForKey:@"RFControllerAddress"];
    if (!a) return;
    NSMutableArray *arr = [NSMutableArray array];
    for (int i = 0; i < RFActionCount; i++) {
        [arr addObject:@[@(gMap[i].kind), @(gMap[i].byteIndex), @(gMap[i].mask), @(gMap[i].center), @(gMap[i].sign)]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:arr forKey:[@"RFMap-" stringByAppendingString:a]];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)loadMappingFor:(NSString *)address {
    memset(gMap, 0, sizeof(gMap));
    [self log:[NSString stringWithFormat:@"Carregando mapeamento de %@: %@", address,
               [[NSUserDefaults standardUserDefaults] arrayForKey:[@"RFMap-" stringByAppendingString:address]] ? @"encontrado" : @"nenhum"]];
    NSArray *arr = [[NSUserDefaults standardUserDefaults] arrayForKey:[@"RFMap-" stringByAppendingString:address]];
    for (NSInteger i = 0; i < (NSInteger)arr.count && i < RFActionCount; i++) {
        NSArray *m = arr[i];
        if (![m isKindOfClass:[NSArray class]] || m.count < 5) continue;
        gMap[i].kind = [m[0] intValue];
        gMap[i].byteIndex = [m[1] intValue];
        gMap[i].mask = [m[2] intValue];
        gMap[i].center = [m[3] intValue];
        gMap[i].sign = [m[4] intValue];
    }
}

- (void)bt_startCalibration {
    if (!self.connected) return;
    [self log:[NSString stringWithFormat:@"Configuração iniciada; repouso = %@", gLastLen ? rf_hex(gLast, gLastLen) : @"(sem dados)"]];
    memset(gMap, 0, sizeof(gMap));
    if (gLastLen) {
        memcpy(gBaseline, gLast, gLastLen);
        gBaselineLen = gLastLen;
    }
    gWaitRelease = 0;
    gCandidateLen = 0;
    gCandidateScore = 0;
    gLearnScheduled = 0;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(learnFromLast) object:nil];
    self.calibrating = YES;
    self.calibratingAction = RFActionUp;
    rf_pad_mask = 0;
    [self changed];
}

- (void)bt_skipCalibrationStep {
    if (!self.calibrating) return;
    [self advanceCalibration];
}

- (void)bt_cancelCalibration {
    self.calibrating = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(learnFromLast) object:nil];
    if ([self hasMapping]) {
        // Direcional, A, B, C e Start já foram aprendidos: guarda e pula os opcionais
        [self saveMapping];
        [self log:@"Configuração concluída (opcionais pulados)"];
    } else {
        NSString *a = [[NSUserDefaults standardUserDefaults] stringForKey:@"RFControllerAddress"];
        if (a) [self loadMappingFor:a];
        [self log:@"Configuração cancelada"];
    }
    [self changed];
}

- (void)advanceCalibration {
    RFAction next = self.calibratingAction + 1;
    // Se o direcional foi detectado como "hat", as outras direções já estão mapeadas
    while (next < RFActionCount && gMap[next].kind != RFMapNone) next++;
    if (next >= RFActionCount) {
        self.calibrating = NO;
        [self saveMapping];
        [self log:@"Mapeamento salvo"];
    } else {
        self.calibratingAction = next;
    }
    [self changed];
}

static BOOL rf_is_center(uint8_t v) {
    return v >= 0x60 && v <= 0xA0;
}

// Há alguma diferença relevante em relação ao repouso?
static BOOL rf_differs(const uint8_t *r, int len) {
    for (int i = 2; i < len && i < gBaselineLen; i++) {
        int d = (int)r[i] - (int)gBaseline[i];
        if (rf_is_center(gBaseline[i])) {
            if (abs(d) > 0x40) return YES;   // eixo analógico: ignora ruído perto do centro
        } else if (d != 0) {
            return YES;
        }
    }
    return NO;
}

// Quanto o relatório se afasta do repouso (para escolher o momento "mais apertado")
static int rf_score(const uint8_t *r, int len) {
    int score = 0;
    for (int i = 2; i < len && i < gBaselineLen; i++) {
        int d = abs((int)r[i] - (int)gBaseline[i]);
        if (rf_is_center(gBaseline[i]) && d <= 0x40) continue;   // ruído do analógico
        score += d ? (d + 0x100) : 0;   // cada byte alterado conta muito; o tamanho da mudança desempata
    }
    return score;
}

- (void)learnFromLast {
    gLearnScheduled = 0;
    if (!self.calibrating || gWaitRelease || !gCandidateLen) return;
    int len = gCandidateLen;
    gCandidateLen = 0;
    gCandidateScore = 0;
    [self learnFrom:gCandidate length:len];
}

- (void)learnFrom:(const uint8_t *)r length:(int)len {
    RFAction action = self.calibratingAction;
    BOOL direction = action <= RFActionRight;
    int n = MIN(len, gBaselineLen);
    RFMapping m = {0};

    // 1) Direcional "hat" (0..7, solto = 0x0F/0x08)
    if (direction) {
        for (int i = 2; i < n; i++) {
            uint8_t b = gBaseline[i], v = r[i];
            if ((b == 0x0F || b == 0x08 || b == 0xFF) && v <= 7) {
                m.kind = RFMapHat;
                m.byteIndex = i;
                break;
            }
        }
        if (m.kind == RFMapHat) {
            for (int a = RFActionUp; a <= RFActionRight; a++) gMap[a] = m;
            [self log:[NSString stringWithFormat:@"Direcional (hat) no byte %d", m.byteIndex]];
            gWaitRelease = rf_differs(gLast, gLastLen);
            [self advanceCalibration];
            return;
        }
    }
    // 2) Botão digital: um bit novo num byte que não é eixo analógico
    for (int i = 2; i < n && m.kind == RFMapNone; i++) {
        if (rf_is_center(gBaseline[i])) continue;
        uint8_t added = r[i] & ~gBaseline[i];
        if (added && (added & (added - 1)) == 0 && (r[i] ^ gBaseline[i]) == added) {
            m.kind = RFMapBit;
            m.byteIndex = i;
            m.mask = added;
        }
    }
    // 3) Eixo analógico (analógico como direcional, ou gatilho como botão)
    if (m.kind == RFMapNone) {
        int best = -1, bestDelta = 0;
        for (int i = 2; i < n; i++) {
            int d = (int)r[i] - (int)gBaseline[i];
            if (abs(d) > 0x50 && abs(d) > abs(bestDelta)) {
                best = i;
                bestDelta = d;
            }
        }
        if (best >= 0) {
            m.kind = RFMapAxis;
            m.byteIndex = best;
            m.center = gBaseline[best];
            m.sign = bestDelta > 0 ? 1 : -1;
        }
    }
    if (m.kind == RFMapNone) return;   // ainda não deu para identificar; espera mais dados
    gMap[action] = m;
    [self log:[NSString stringWithFormat:@"%@ → tipo %d, byte %d, máscara %02X", RFActionName(action), m.kind, m.byteIndex, m.mask]];
    if ([self hasMapping]) [self saveMapping];   // salva a cada passo depois dos obrigatórios
    gWaitRelease = rf_differs(gLast, gLastLen);   // já soltou? então não precisa esperar
    [self advanceCalibration];
}

static BOOL rf_mapping_active(RFMapping *m, const uint8_t *r, int len) {
    if (m->kind == RFMapNone || m->byteIndex >= len) return NO;
    uint8_t v = r[m->byteIndex];
    switch (m->kind) {
        case RFMapBit: return (v & m->mask) != 0;
        case RFMapAxis: return m->sign > 0 ? (int)v > (int)m->center + 0x40 : (int)v < (int)m->center - 0x40;
        default: return NO;
    }
}

static NSString *rf_hex(const uint8_t *r, int len) {
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < len; i++) [s appendFormat:@"%02X ", r[i]];
    return s;
}

- (NSString *)lastReportHex {
    return gLastLen ? rf_hex(gLast, gLastLen) : @"(nenhum dado recebido do controle)";
}

- (void)handleReport:(const uint8_t *)r length:(int)len {
    len = MIN(len, RF_REPORT_MAX);
    if (!self.connected && gHasTarget) {
        // O controle reconectou sozinho e já está mandando dados: considera conectado
        [self log:@"Dados do controle chegando: marcando como conectado"];
        [self onConnectedTo:gTarget];
    }
    memcpy(gLast, r, len);
    gLastLen = len;
    if (!gBaselineLen) {
        memcpy(gBaseline, r, len);
        gBaselineLen = len;
    }

    if (self.calibrating) {
        rf_pad_mask = 0;
        if (gWaitRelease) {
            if (!rf_differs(r, len)) gWaitRelease = 0;
            return;
        }
        // Guarda o momento "mais apertado" e decide 0,2 s depois do primeiro sinal, ou assim que
        // o botão for solto (toques rápidos chegam a durar só ~0,1 s).
        if (rf_differs(r, len)) {
            int score = rf_score(r, len);
            if (score >= gCandidateScore) {
                memcpy(gCandidate, r, len);
                gCandidateLen = len;
                gCandidateScore = score;
            }
            if (!gLearnScheduled) {
                gLearnScheduled = 1;
                [self performSelector:@selector(learnFromLast) withObject:nil afterDelay:0.2];
            }
        } else if (gCandidateLen) {
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(learnFromLast) object:nil];
            [self learnFromLast];
        }
        return;
    }

    uint32_t mask = 0;
    // Analógico esquerdo também move: no 8BitDo os eixos X/Y vêm logo depois do byte do direcional
    if (gMap[RFActionUp].kind == RFMapHat) {
        int xi = gMap[RFActionUp].byteIndex + 1, yi = xi + 1;
        if (yi < len && yi < gBaselineLen && rf_is_center(gBaseline[xi]) && rf_is_center(gBaseline[yi])) {
            if (r[xi] < 0x40) mask |= RF_LEFT;
            if (r[xi] > 0xC0) mask |= RF_RIGHT;
            if (r[yi] < 0x40) mask |= RF_UP;
            if (r[yi] > 0xC0) mask |= RF_DOWN;
        }
    }
    for (int a = 0; a < RFActionCount; a++) {
        RFMapping *m = &gMap[a];
        if (m->kind == RFMapHat) {
            if (a != RFActionUp) continue;   // os quatro apontam para o mesmo byte
            uint8_t v = m->byteIndex < len ? r[m->byteIndex] : 0x0F;
            if (v <= 7) {
                if (v == 7 || v == 0 || v == 1) mask |= RF_UP;
                if (v >= 1 && v <= 3) mask |= RF_RIGHT;
                if (v >= 3 && v <= 5) mask |= RF_DOWN;
                if (v >= 5 && v <= 7) mask |= RF_LEFT;
            }
        } else if (rf_mapping_active(m, r, len)) {
            mask |= kRFActionMask[a];
        }
    }
    if (mask != rf_pad_mask) {
        rf_pad_mask = mask;
        RFInputChanged();
    }

    BOOL menu = rf_mapping_active(&gMap[RFActionMenu], r, len);
    if (menu && !gMenuDown && self.menuPressed) {
        dispatch_block_t handler = self.menuPressed;
        rf_main(handler);
    }
    gMenuDown = menu;
}

@end

#pragma mark - Eventos do BTstack

static void rf_bt_handler(uint8_t type, uint16_t channel, uint8_t *packet, uint16_t size) {
    RFBluetooth *bt = [RFBluetooth shared];
    bd_addr_t addr;

    if (type == L2CAP_DATA_PACKET) {
        // Aceita relatórios de qualquer canal: em reconexões o controle pode abrir os canais
        // ele mesmo e o cid guardado pode não ser o que traz os dados.
        if (size > 2 && packet[0] == 0xA1) {
            [bt handleReport:packet length:size];
        }
        return;
    }
    if (type != HCI_EVENT_PACKET) return;

    switch (packet[0]) {
        case BTSTACK_EVENT_STATE:
            [bt log:[NSString stringWithFormat:@"BTstack estado %u%@", packet[2], packet[2] == HCI_STATE_WORKING ? @" (pronto)" : @""]];
            if (packet[2] == HCI_STATE_WORKING) [bt btReady];
            break;
        case L2CAP_EVENT_SERVICE_REGISTERED:
            // status != 0: outro app (ex.: PadProbe aberto em segundo plano) já registrou o serviço HID
            [bt log:[NSString stringWithFormat:@"Serviço HID PSM 0x%02X registrado, status 0x%02X%@", READ_BT_16(packet, 3), packet[2],
                     packet[2] ? @" (FALHOU: feche o PadProbe e outros apps de Bluetooth)" : @""]];
            break;
        case HCI_EVENT_COMMAND_STATUS:
            if (packet[2] != 0) {
                [bt log:[NSString stringWithFormat:@"Comando HCI 0x%04X recusado, status 0x%02X", READ_BT_16(packet, 4), packet[2]]];
            }
            break;
        case HCI_EVENT_MODE_CHANGE_EVENT:
            // modo 0 = ativo, 2 = sniff (economia de energia: pode atrasar os dados)
            [bt log:[NSString stringWithFormat:@"Modo do link: %u (status 0x%02X, intervalo %u)", packet[5], packet[2], READ_BT_16(packet, 6)]];
            break;
        case HCI_EVENT_ROLE_CHANGE:
            [bt log:[NSString stringWithFormat:@"Troca de papel: status 0x%02X, papel %u", packet[2], packet[9]]];
            break;
        case HCI_EVENT_HARDWARE_ERROR:
            [bt log:[NSString stringWithFormat:@"ERRO DE HARDWARE do Bluetooth: 0x%02X", packet[2]]];
            break;
        case HCI_EVENT_DATA_BUFFER_OVERFLOW:
            [bt log:@"Buffer de dados do Bluetooth estourou"];
            break;
        case HCI_EVENT_USER_CONFIRMATION_REQUEST:
            [bt log:@"Pareamento seguro (SSP) pedido; o BTstack aceita automaticamente"];
            break;
        case HCI_EVENT_AUTHENTICATION_COMPLETE_EVENT:
            [bt log:[NSString stringWithFormat:@"Autenticação concluída, status 0x%02X", packet[2]]];
            break;
        case BTSTACK_EVENT_POWERON_FAILED:
            [bt setStatusText:@"Falha ao ligar o Bluetooth (desligue o Bluetooth do iOS em Ajustes)"];
            break;
        case HCI_EVENT_INQUIRY_RESULT: {
            int num = packet[2];
            for (int i = 0; i < num; i++) {
                bt_flip_addr(addr, &packet[3 + i * 6]);
                rf_add(addr, packet[3 + num * 6 + i], READ_BT_16(packet, 3 + num * 12 + i * 2), READ_BT_24(packet, 3 + num * 9 + i * 3));
            }
            break;
        }
        case HCI_EVENT_INQUIRY_RESULT_WITH_RSSI: {
            int num = packet[2];
            for (int i = 0; i < num; i++) {
                bt_flip_addr(addr, &packet[3 + i * 6]);
                rf_add(addr, packet[3 + num * 6 + i], READ_BT_16(packet, 3 + num * 11 + i * 2), READ_BT_24(packet, 3 + num * 8 + i * 3));
            }
            break;
        }
        case HCI_EVENT_EXTENDED_INQUIRY_RESPONSE: {
            bt_flip_addr(addr, &packet[3]);
            int idx = rf_add(addr, packet[9], READ_BT_16(packet, 14), READ_BT_24(packet, 11));
            int pos = 17;
            while (idx >= 0 && pos + 1 < size) {
                int len = packet[pos];
                if (!len || pos + 1 + len > size) break;
                if (packet[pos + 1] == 0x08 || packet[pos + 1] == 0x09) {
                    int n = MIN(len - 1, 63);
                    memcpy(gDevices[idx].name, &packet[pos + 2], n);
                    gDevices[idx].name[n] = 0;
                    [bt changed];
                    break;
                }
                pos += len + 1;
            }
            break;
        }
        case HCI_EVENT_INQUIRY_COMPLETE:
            gInquiry = 0;
            [bt log:[NSString stringWithFormat:@"Busca terminada: %d dispositivo(s)", gDeviceCount]];
            [bt setStatusText:@"Busca terminada. Toque no controle para conectar."];
            rf_next_name();
            break;
        case HCI_EVENT_REMOTE_NAME_REQUEST_COMPLETE: {
            gNamePending = 0;
            bt_flip_addr(addr, &packet[3]);
            int idx = rf_find(addr);
            if (idx >= 0 && packet[2] == 0) {
                strncpy(gDevices[idx].name, (const char *)&packet[9], 63);
                gDevices[idx].name[63] = 0;
                [bt log:[NSString stringWithFormat:@"Nome de %@: %s", rf_addr(addr), gDevices[idx].name]];
                [bt changed];
            }
            rf_next_name();
            break;
        }
        case HCI_EVENT_PIN_CODE_REQUEST: {
            uint8_t pin[16] = {'0', '0', '0', '0'};
            bt_flip_addr(addr, &packet[2]);
            [bt log:[NSString stringWithFormat:@"Pedido de PIN de %@, respondendo 0000", rf_addr(addr)]];
            bt_send_cmd(&hci_pin_code_request_reply, addr, 4, pin);
            break;
        }
        case L2CAP_EVENT_INCOMING_CONNECTION:
            bt_flip_addr(addr, &packet[2]);
            [bt log:[NSString stringWithFormat:@"Conexão de entrada de %@, PSM 0x%02X: aceitando", rf_addr(addr), READ_BT_16(packet, 10)]];
            bt_send_cmd(&l2cap_accept_connection, READ_BT_16(packet, 12));
            break;
        case L2CAP_EVENT_CHANNEL_OPENED: {
            bt_flip_addr(addr, &packet[3]);
            uint16_t psm = READ_BT_16(packet, 11);
            uint16_t cid = READ_BT_16(packet, 13);
            if (packet[2]) {
                [bt log:[NSString stringWithFormat:@"Falha ao abrir canal 0x%02X: 0x%02X", psm, packet[2]]];
                if (!bt.connected) [bt setStatusText:@"Não conectou. Ligue o controle (ou coloque em pareamento) e tente de novo."];
                break;
            }
            [bt log:[NSString stringWithFormat:@"Canal aberto: PSM 0x%02X com %@", psm, rf_addr(addr)]];
            if (psm == PSM_HID_CONTROL) {
                // Proíbe o modo "sniff" (economia de energia) neste link: nele o controle só
                // conversa em intervalos espaçados e os botões chegam com atraso.
                uint16_t handle = READ_BT_16(packet, 9);
                bt_send_cmd(&hci_write_link_policy_settings, handle, 0x0001);   // só troca de papel
                gControlCid = cid;
                // Conexão iniciada por nós: abre também o canal de dados
                if (!gInterruptCid && gHasTarget && BD_ADDR_CMP(addr, gTarget) == 0) {
                    bt_send_cmd(&l2cap_create_channel, addr, PSM_HID_INTERRUPT);
                }
            } else if (psm == PSM_HID_INTERRUPT) {
                gInterruptCid = cid;
                [bt onConnectedTo:addr];
            }
            break;
        }
        case L2CAP_EVENT_CHANNEL_CLOSED: {
            uint16_t cid = READ_BT_16(packet, 2);
            [bt log:[NSString stringWithFormat:@"Canal 0x%04X fechado", cid]];
            if (cid == gInterruptCid) gInterruptCid = 0;
            if (cid == gControlCid) gControlCid = 0;
            if (!gInterruptCid && bt.connected) [bt onDisconnected];
            break;
        }
        case HCI_EVENT_DISCONNECTION_COMPLETE:
            [bt log:[NSString stringWithFormat:@"Desconectado (motivo 0x%02X)", packet[5]]];
            gInterruptCid = gControlCid = 0;
            if (bt.connected) [bt onDisconnected];
            break;
        default:
            break;
    }
}
