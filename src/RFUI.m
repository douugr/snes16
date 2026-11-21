#import "RF.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>

static UIColor *RFAccent(void) {
    return RFThemeRed();
}

#pragma mark - Tela do jogo

@interface RFGameViewController : UIViewController
- (instancetype)initWithPath:(NSString *)path;
@end

@interface RFGameViewController ()
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) RFGLView *video;
@property (nonatomic, strong) RFTouchPad *pad;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, assign) BOOL paused;
@property (nonatomic, assign) BOOL menuOpen;
@property (nonatomic, strong) UILabel *toast;
@property (nonatomic, strong) UILabel *perfLabel;
@end

// Estatísticas de desempenho (zeradas a cada janela de ~2 s)
typedef struct {
    double windowStart;
    double lastTimestamp;
    int ticks, frames, extraFrames, skippedTicks, lateTicks, draws;
    double emuSum, emuMax, drawSum, drawMax;
    double inputSum, inputMax;
    int inputs, aheadFrames;
    uint32_t underrunsAtStart;
    uint32_t minAudio, maxAudio;
} RFPerf;

@implementation RFGameViewController {
    RFPerf _perf;
    uint32_t _lastInputSeq;
    double _aheadCost;          // custo médio (ms) de um quadro com run-ahead
    double _aheadPausedUntil;   // run-ahead suspenso até este instante (iPad não deu conta)
    double _lastTickStamp;      // horário de tela da volta anterior
    BOOL _lastTickAhead;        // a volta anterior usou run-ahead?
    int _aheadLate;             // voltas com run-ahead que perderam o quadro
    double _aheadLateWindow;    // início da janela de contagem
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
    }
    return self;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    self.video = [[RFGLView alloc] initWithFrame:CGRectZero];
    NSNumber *filterPref = [[NSUserDefaults standardUserDefaults] objectForKey:@"RFFilter"];
    self.video.filterMode = filterPref ? filterPref.integerValue : [[NSUserDefaults standardUserDefaults] boolForKey:@"RFSmooth"];
    [self.view addSubview:self.video];

    self.pad = [[RFTouchPad alloc] initWithFrame:self.view.bounds];
    self.pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    __weak RFGameViewController *weakSelf = self;
    self.pad.menuHandler = ^{ [weakSelf showMenu]; };
    [self.view addSubview:self.pad];
    [self updateTouchControls];

    self.toast = [[UILabel alloc] init];
    self.toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
    self.toast.textColor = [UIColor whiteColor];
    self.toast.textAlignment = NSTextAlignmentCenter;
    self.toast.font = [UIFont boldSystemFontOfSize:17];
    self.toast.layer.cornerRadius = 10;
    self.toast.clipsToBounds = YES;
    self.toast.alpha = 0;
    [self.view addSubview:self.toast];

    self.perfLabel = [[UILabel alloc] init];
    self.perfLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    self.perfLabel.textColor = [UIColor greenColor];
    self.perfLabel.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    self.perfLabel.numberOfLines = 0;
    self.perfLabel.userInteractionEnabled = NO;
    self.perfLabel.hidden = ![[NSUserDefaults standardUserDefaults] boolForKey:@"RFShowPerf"];
    [self.view addSubview:self.perfLabel];

    NSString *error = nil;
    if (![[RFCore shared] loadGameAtPath:self.path error:&error]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Error" message:error preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) {
                [weakSelf dismissViewControllerAnimated:YES completion:nil];
            }]];
            [weakSelf presentViewController:a animated:YES completion:nil];
        });
        return;
    }
    [[RFAudio shared] startWithSampleRate:[RFCore shared].sampleRate];

    [RFBluetooth shared].menuPressed = ^{ [weakSelf showMenu]; };

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(willResign) name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(didBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (![RFCore shared].loaded || self.link) return;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    if ([RFCore shared].patched) [self showToast:@"Patch applied"];
    if ([[RFCore shared] hasStateSlot:0]) [self offerResume];
}

// Há um salvamento automático da última sessão: pergunta se quer continuar dele
- (void)offerResume {
    self.menuOpen = YES;
    self.paused = YES;
    NSString *when = [self describeDate:[[RFCore shared] dateForStateSlot:0]];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Continue where you left off?"
                                                               message:[NSString stringWithFormat:@"There is an autosave from %@.", when]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak RFGameViewController *weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Start over" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) {
        [weakSelf resume];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        if (![[RFCore shared] loadStateSlot:0]) [weakSelf showToast:@"Could not load"];
        [weakSelf resume];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSString *)describeDate:(NSDate *)date {
    if (!date) return @"empty";
    static NSDateFormatter *fmt;
    if (!fmt) {
        fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
        fmt.dateFormat = @"MMM d 'at' HH:mm";
    }
    return [fmt stringFromDate:date];
}

// Lista os slots para salvar (1 a 3) ou carregar (os que existem, incluindo o automático)
- (void)showSlotsForSaving:(BOOL)saving {
    RFCore *core = [RFCore shared];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:saving ? @"Save to which slot?" : @"Load which state?"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak RFGameViewController *weakSelf = self;
    for (int slot = saving ? 1 : 0; slot <= 3; slot++) {
        NSDate *date = [core dateForStateSlot:slot];
        if (!saving && !date) continue;
        NSString *name = slot == 0 ? @"Autosave" : [NSString stringWithFormat:@"Slot %d", slot];
        NSString *title = [NSString stringWithFormat:@"%@ — %@", name, [self describeDate:date]];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            BOOL ok = saving ? [[RFCore shared] saveStateSlot:slot] : [[RFCore shared] loadStateSlot:slot];
            NSString *msg = saving ? (ok ? @"Saved to %@" : @"Could not save") : (ok ? @"%@ loaded" : @"Could not load");
            [weakSelf showToast:[NSString stringWithFormat:msg, name]];
            [weakSelf resume];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [weakSelf resume];
    }]];
    sheet.popoverPresentationController.sourceView = self.pad;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width - 60, 10, 50, 50);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (BOOL)hasAnyState {
    for (int slot = 0; slot <= 3; slot++) {
        if ([[RFCore shared] hasStateSlot:slot]) return YES;
    }
    return NO;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize s = self.view.bounds.size;
    float aspect = [RFCore shared].aspectRatio > 0 ? [RFCore shared].aspectRatio : 4.0f / 3.0f;
    CGRect r;
    if (s.width > s.height) {
        CGFloat h = s.height, w = h * aspect;
        if (w > s.width) { w = s.width; h = w / aspect; }
        r = CGRectMake((s.width - w) / 2.0, (s.height - h) / 2.0, w, h);
    } else {
        CGFloat w = s.width, h = w / aspect;
        r = CGRectMake(0, s.height * 0.06, w, h);
    }
    self.video.frame = CGRectIntegral(r);
    self.pad.gameRect = self.video.frame;
    [self.pad setNeedsLayout];
    self.toast.frame = CGRectMake((s.width - 320) / 2.0, 20, 320, 44);
    self.perfLabel.frame = CGRectMake(8, 8, 360, 84);
}

// Ritmo guiado pelo áudio: a fila de som diz se estamos atrasados ou adiantados.
// Atrasado -> roda um quadro extra sem desenhar (o jogo não fica lento e o som não picota).
// Adiantado demais -> pula esta volta (evita latência de som crescendo).
- (void)tick {
    if (self.paused) {
        _perf.lastTimestamp = 0;
        _lastTickStamp = 0;
        return;
    }
    RFCore *core = [RFCore shared];
    RFAudio *audio = [RFAudio shared];
    double spf = core.sampleRate / core.fps;            // ~735 amostras por quadro
    uint32_t queued = [audio bufferedFrames];

    int runs = 1;
    if (queued > spf * 4) runs = 0;
    else if (queued < spf * 2) runs = 2;   // fila curta: menos atraso entre o jogo e o som

    double t0 = CACurrentMediaTime();
    // Run-ahead só é suspenso se fizer o iPad perder quadros de verdade
    double stamp = self.link.timestamp;
    if (_lastTickAhead && _lastTickStamp > 0 && stamp - _lastTickStamp > 1.5 / 60.0) {
        if (t0 - _aheadLateWindow > 2.0) {
            _aheadLateWindow = t0;
            _aheadLate = 0;
        }
        if (++_aheadLate >= 3) {
            _aheadPausedUntil = t0 + 5.0;
            _aheadLate = 0;
        }
    }
    _lastTickStamp = stamp;
    // Quanto tempo o último botão apertado esperou até este quadro usá-lo
    uint32_t seq = rf_input_seq;
    if (runs && seq != _lastInputSeq) {
        _lastInputSeq = seq;
        [self recordInputAge:t0 - rf_input_changed_at];
    }
    BOOL ahead = NO;
    for (int i = 0; i < runs; i++) {
        BOOL last = (i == runs - 1);
        if (last && [self runAheadActive:t0]) {
            double a0 = CACurrentMediaTime();
            ahead = [core runFrameWithRunAhead];
            double cost = (CACurrentMediaTime() - a0) * 1000.0;
            _aheadCost = _aheadCost ? _aheadCost * 0.9 + cost * 0.1 : cost;
            // Perto de estourar os 16,7 ms do quadro: desliga por uns segundos e tenta de novo
            if (_aheadCost > 14.5) {
                _aheadPausedUntil = t0 + 5.0;
                _aheadCost = 0;
            }
        } else {
            [core runFrameSkippingVideo:!last];
        }
    }
    double t1 = CACurrentMediaTime();
    if (runs) [self.video drawFrame];
    double t2 = CACurrentMediaTime();

    if (ahead) _perf.aheadFrames++;
    _lastTickAhead = ahead;
    [self recordPerfRuns:runs queued:queued emu:(t1 - t0) draw:(runs ? t2 - t1 : 0) timestamp:self.link.timestamp now:t2];
}

- (BOOL)runAheadEnabled {
    NSNumber *pref = [[NSUserDefaults standardUserDefaults] objectForKey:@"RFRunAhead"];
    return pref ? pref.boolValue : NO;   // no SNES o core é mais pesado: começa desligado
}

- (BOOL)runAheadActive:(double)now {
    return [self runAheadEnabled] && now >= _aheadPausedUntil;
}

- (void)recordInputAge:(double)age {
    if (age < 0 || age > 0.25) return;   // fora disso não é uma medida útil (pausa, menu...)
    _perf.inputs++;
    _perf.inputSum += age;
    if (age > _perf.inputMax) _perf.inputMax = age;
}

- (void)recordPerfRuns:(int)runs queued:(uint32_t)queued emu:(double)emu draw:(double)draw timestamp:(double)ts now:(double)now {
    RFPerf *p = &_perf;
    if (p->windowStart == 0) {
        memset(p, 0, sizeof(*p));
        p->windowStart = now;
        p->underrunsAtStart = [[RFAudio shared] underruns];
        p->minAudio = UINT32_MAX;
    }
    if (p->lastTimestamp > 0 && ts - p->lastTimestamp > 1.5 / 60.0) p->lateTicks++;
    p->lastTimestamp = ts;
    p->ticks++;
    p->frames += runs;
    if (runs == 2) p->extraFrames++;
    if (runs == 0) p->skippedTicks++;
    if (runs) {
        p->draws++;
        double perFrame = emu / runs;
        p->emuSum += emu;
        if (perFrame > p->emuMax) p->emuMax = perFrame;
        p->drawSum += draw;
        if (draw > p->drawMax) p->drawMax = draw;
    }
    if (queued < p->minAudio) p->minAudio = queued;
    if (queued > p->maxAudio) p->maxAudio = queued;

    double elapsed = now - p->windowStart;
    if (elapsed < 2.0) return;

    double emuAvg = p->frames ? p->emuSum * 1000.0 / p->frames : 0;
    double drawAvg = p->draws ? p->drawSum * 1000.0 / p->draws : 0;
    uint32_t underruns = [[RFAudio shared] underruns] - p->underrunsAtStart;
    NSString *ahead = ![self runAheadEnabled] ? @"off" :
                      (CACurrentMediaTime() < _aheadPausedUntil ? @"paused (no headroom)" :
                       [NSString stringWithFormat:@"on (%d%%)", p->ticks ? p->aheadFrames * 100 / p->ticks : 0]);
    NSString *input = p->inputs ? [NSString stringWithFormat:@"%.1f ms (max %.1f)", p->inputSum * 1000.0 / p->inputs, p->inputMax * 1000.0] : @"—";
    NSString *text = [NSString stringWithFormat:
        @"screen %.1f/s  game %.1f f/s\nemu %.1f ms (max %.1f)  gl %.1f ms (max %.1f)\nextra %d  skips %d  late %d  audio-gaps %u  queue %u-%u\nbutton→frame %@  run-ahead %@",
        p->ticks / elapsed, p->frames / elapsed, emuAvg, p->emuMax * 1000.0, drawAvg, p->drawMax * 1000.0,
        p->extraFrames, p->skippedTicks, p->lateTicks, underruns, p->minAudio == UINT32_MAX ? 0 : p->minAudio, p->maxAudio,
        input, ahead];
    if (!self.perfLabel.hidden) self.perfLabel.text = text;
    // Com o medidor ligado, também grava em Documents/SNES16/perf.txt (para análise pelo Mac)
    if (!self.perfLabel.hidden) RFAppendLog(@"perf.txt", [text stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);
    p->windowStart = 0;
}

- (void)updateTouchControls {
    NSNumber *pref = [[NSUserDefaults standardUserDefaults] objectForKey:@"RFShowTouch"];
    BOOL btReady = [RFBluetooth shared].connected && [RFBluetooth shared].hasMapping;
    BOOL show = pref ? pref.boolValue : !btReady;
    self.pad.controlsHidden = !show;
}

- (void)showToast:(NSString *)text {
    self.toast.text = text;
    self.toast.alpha = 1;
    [UIView animateWithDuration:0.4 delay:1.5 options:0 animations:^{ self.toast.alpha = 0; } completion:nil];
}

#pragma mark Pausa / menu

- (void)setPaused:(BOOL)paused {
    _paused = paused;
    _perf.windowStart = 0;
    if (paused) {
        rf_touch_mask = 0;
        [[RFAudio shared] clear];
    }
}

- (void)willResign {
    self.paused = YES;
    [[RFCore shared] saveSRAM];
    [[RFCore shared] saveStateSlot:0];   // salvamento automático
}

- (void)didBecomeActive {
    if (!self.menuOpen) self.paused = NO;
}

- (void)resume {
    self.menuOpen = NO;
    self.paused = NO;
}

- (void)showMenu {
    if (self.menuOpen || !self.isViewLoaded || !self.view.window) return;
    self.menuOpen = YES;
    self.paused = YES;
    RFCore *core = [RFCore shared];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:core.gameName message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak RFGameViewController *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf resume];
    }]];
    // O menu continua "aberto" (jogo pausado) enquanto a lista de slots aparece
    [sheet addAction:[UIAlertAction actionWithTitle:@"Save state…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf showSlotsForSaving:YES]; });
    }]];
    if ([self hasAnyState]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Load state…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf showSlotsForSaving:NO]; });
        }]];
    }
    if ([RFAchievements shared].loggedIn) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Achievements…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                RFAchievementsListViewController *list = [[RFAchievementsListViewController alloc] init];
                list.onDone = ^{ [weakSelf resume]; };
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:list];
                RFThemeApplyNavigationBar(nav.navigationBar);
                nav.modalPresentationStyle = UIModalPresentationFormSheet;
                [weakSelf presentViewController:nav animated:YES completion:nil];
            });
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Reset game" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[RFCore shared] reset];
        [weakSelf resume];
    }]];
    NSString *touchTitle = self.pad.controlsHidden ? @"Show on-screen controls" : @"Hide on-screen controls";
    [sheet addAction:[UIAlertAction actionWithTitle:touchTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        BOOL show = weakSelf.pad.controlsHidden;
        [[NSUserDefaults standardUserDefaults] setBool:show forKey:@"RFShowTouch"];
        weakSelf.pad.controlsHidden = !show;
        [weakSelf resume];
    }]];
    NSArray *filterNames = @[@"sharp pixels", @"smooth", @"CRT TV", @"CRT TV, curved"];
    NSInteger fm = MAX(0, MIN(3, self.video.filterMode));
    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Image: %@…", filterNames[fm]]
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf showFilters]; });
    }]];
    NSString *aheadTitle = [self runAheadEnabled] ? @"Reduce input lag (run-ahead): on" : @"Reduce input lag (run-ahead): off";
    [sheet addAction:[UIAlertAction actionWithTitle:aheadTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[NSUserDefaults standardUserDefaults] setBool:![weakSelf runAheadEnabled] forKey:@"RFRunAhead"];
        [weakSelf resume];
    }]];
    NSString *perfTitle = self.perfLabel.hidden ? @"Show performance" : @"Hide performance";
    [sheet addAction:[UIAlertAction actionWithTitle:perfTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        weakSelf.perfLabel.hidden = !weakSelf.perfLabel.hidden;
        [[NSUserDefaults standardUserDefaults] setBool:!weakSelf.perfLabel.hidden forKey:@"RFShowPerf"];
        [weakSelf resume];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Quit game" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [weakSelf quit];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [weakSelf resume];
    }]];
    sheet.popoverPresentationController.sourceView = self.pad;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width - 60, 10, 50, 50);
    [self presentViewController:sheet animated:YES completion:nil];
}

// Modos de imagem: pixels, suave, TV de tubo e TV de tubo com tela curva
- (void)showFilters {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Image" message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak RFGameViewController *weakSelf = self;
    NSArray *names = @[@"Sharp pixels", @"Smooth", @"CRT TV (scanlines and phosphor mask)", @"CRT TV with a curved screen"];
    for (NSInteger i = 0; i < 4; i++) {
        NSString *title = i == self.video.filterMode ? [names[i] stringByAppendingString:@"  ✓"] : names[i];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            weakSelf.video.filterMode = i;
            [[NSUserDefaults standardUserDefaults] setInteger:i forKey:@"RFFilter"];
            [weakSelf resume];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [weakSelf resume];
    }]];
    sheet.popoverPresentationController.sourceView = self.pad;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width - 60, 10, 50, 50);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)quit {
    [self.link invalidate];
    self.link = nil;
    [RFBluetooth shared].menuPressed = nil;
    [[RFAudio shared] stop];
    [[RFCore shared] saveStateSlot:0];   // salvamento automático ao sair
    [[RFCore shared] unload];
    rf_touch_mask = 0;
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Tela do controle Bluetooth

@interface RFControllerViewController : UITableViewController <RFBluetoothDelegate>
@property (nonatomic, strong) NSTimer *liveTimer;
@property (nonatomic, strong) NSMutableArray *logLines;
@end

@implementation RFControllerViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Bluetooth Controller";
    self.logLines = [NSMutableArray array];
    RFThemeApplyTable(self.tableView);
    [RFBluetooth shared].delegate = self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.liveTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(liveTick) userInfo:nil repeats:YES];
    [self.tableView reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.liveTimer invalidate];
    self.liveTimer = nil;
    if ([RFBluetooth shared].calibrating) [[RFBluetooth shared] cancelCalibration];
}

- (void)liveTick {
    // Atualiza só a linha do teste ao vivo
    if (![RFBluetooth shared].connected) return;
    NSIndexPath *ip = [NSIndexPath indexPathForRow:1 inSection:0];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
    if (cell) cell.detailTextLabel.text = [self liveText];
}

- (NSString *)liveText {
    return [self pressedText];
}

- (NSString *)pressedText {
    uint32_t m = rf_pad_mask;
    NSMutableArray *names = [NSMutableArray array];
    struct { uint32_t bit; __unsafe_unretained NSString *name; } map[] = {
        {RF_UP, @"↑"}, {RF_DOWN, @"↓"}, {RF_LEFT, @"←"}, {RF_RIGHT, @"→"},
        {RF_SN_A, @"A"}, {RF_SN_B, @"B"}, {RF_SN_X, @"X"}, {RF_SN_Y, @"Y"},
        {RF_SN_L, @"L"}, {RF_SN_R, @"R"}, {RF_SN_START, @"Start"}, {RF_SN_SELECT, @"Select"},
    };
    for (unsigned i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
        if (m & map[i].bit) [names addObject:map[i].name];
    }
    return names.count ? [names componentsJoinedByString:@" "] : @"(nothing pressed)";
}

- (void)bluetoothDidChange {
    [self.tableView reloadData];
}

- (void)bluetoothLog:(NSString *)text {
}

// Seções: 0 status, 1 ações, 2 dispositivos encontrados
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Status", @"Actions", @"Devices found"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) {
        return @"To pair: turn off iOS Bluetooth in Settings, put your controller in pairing mode and tap Search. "
               @"Once connected, use \"Set up buttons\" once; the button map is saved.";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    RFBluetooth *bt = [RFBluetooth shared];
    if (section == 0) return bt.connected ? 2 : 1;
    if (section == 1) return bt.calibrating ? 2 : (bt.connected ? 3 : 2);
    return MAX(1, bt.deviceCount);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    RFBluetooth *bt = [RFBluetooth shared];

    if (indexPath.section == 0) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = bt.status;
            cell.detailTextLabel.text = bt.connected ? (bt.hasMapping ? @"Buttons set up" : @"Buttons not set up yet") : nil;
        } else {
            cell.textLabel.text = @"Live test";
            cell.detailTextLabel.text = [self liveText];
            cell.detailTextLabel.font = [UIFont boldSystemFontOfSize:20];
        }
        return cell;
    }

    if (indexPath.section == 1) {
        cell.textLabel.textColor = RFAccent();
        if (bt.calibrating) {
            if (indexPath.row == 0) {
                cell.textLabel.text = [NSString stringWithFormat:@"Press: %@", RFActionName(bt.calibratingAction)];
                cell.textLabel.font = [UIFont boldSystemFontOfSize:24];
                cell.textLabel.textColor = RFThemeText();
                cell.detailTextLabel.text = @"Release the button after pressing it. Tap here to skip this one.";
            } else {
                if (bt.hasMapping) {
                    cell.textLabel.text = @"Finish now (skip the rest)";
                } else {
                    cell.textLabel.text = @"Cancel setup";
                    cell.textLabel.textColor = [UIColor redColor];
                }
            }
            return cell;
        }
        NSArray *titles = bt.connected ? @[@"Search for controllers", @"Set up buttons", @"Forget this controller"]
                                       : @[@"Search for controllers", @"Forget saved controller"];
        cell.textLabel.text = titles[indexPath.row];
        if ([titles[indexPath.row] hasPrefix:@"Forget"]) cell.textLabel.textColor = [UIColor redColor];
        return cell;
    }

    if (bt.deviceCount == 0) {
        cell.textLabel.text = @"None yet";
        cell.textLabel.textColor = RFThemeDim();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = [bt deviceTitleAtIndex:indexPath.row];
        cell.detailTextLabel.text = @"Tap to connect";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    RFThemeStyleCell(cell);
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    RFThemeStyleHeaderFooter(view, YES);
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    RFThemeStyleHeaderFooter(view, NO);
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    RFBluetooth *bt = [RFBluetooth shared];
    if (indexPath.section == 0) return 60;
    if (indexPath.section == 1 && bt.calibrating && indexPath.row == 0) return 80;
    return 50;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    RFBluetooth *bt = [RFBluetooth shared];
    if (indexPath.section == 1) {
        if (bt.calibrating) {
            if (indexPath.row == 0) [bt skipCalibrationStep];
            else [bt cancelCalibration];
            return;
        }
        if (indexPath.row == 0) [bt scan];
        else if (bt.connected && indexPath.row == 1) [bt startCalibration];
        else [bt forgetController];
    } else if (indexPath.section == 2 && bt.deviceCount > 0) {
        [bt connectDeviceAtIndex:indexPath.row];
    }
}

@end

#pragma mark - Enviar ROMs pelo navegador

@interface RFUploadViewController : UIViewController
@property (nonatomic, strong) UILabel *addressLabel;
@property (nonatomic, strong) UILabel *ipLabel;
@property (nonatomic, strong) UIImageView *qrView;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, assign) NSInteger received;
@end

@implementation RFUploadViewController

// QR code (CoreImage) ampliado sem suavizar, com margem branca
static UIImage *RFQRCode(NSString *text, CGFloat side) {
    CIFilter *f = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [f setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [f setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *ci = f.outputImage;
    if (!ci) return nil;
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
    if (!cg) return nil;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), YES, 0);
    CGContextRef g = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] setFill];
    CGContextFillRect(g, CGRectMake(0, 0, side, side));
    CGContextSetInterpolationQuality(g, kCGInterpolationNone);
    CGFloat m = side * 0.08;
    CGContextTranslateCTM(g, 0, side);
    CGContextScaleCTM(g, 1, -1);
    CGContextDrawImage(g, CGRectMake(m, m, side - 2 * m, side - 2 * m), cg);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGImageRelease(cg);
    return img;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Upload ROMs";
    self.view.backgroundColor = RFThemeGridColor();

    UILabel *step = [[UILabel alloc] init];
    step.numberOfLines = 0;
    step.textAlignment = NSTextAlignmentCenter;
    step.font = RFThemeLabelFont(17);
    step.textColor = RFThemeText();
    step.text = @"On your computer (same Wi-Fi network), open this address in a browser:";
    step.tag = 1;
    [self.view addSubview:step];

    self.addressLabel = [[UILabel alloc] init];
    self.addressLabel.textAlignment = NSTextAlignmentCenter;
    self.addressLabel.font = [UIFont fontWithName:@"Menlo-Bold" size:34] ?: [UIFont boldSystemFontOfSize:34];
    self.addressLabel.textColor = RFThemeRed();
    self.addressLabel.backgroundColor = RFThemeCard();
    self.addressLabel.layer.borderColor = RFThemeRed().CGColor;
    self.addressLabel.layer.borderWidth = 2;
    self.addressLabel.layer.cornerRadius = 8;
    self.addressLabel.clipsToBounds = YES;
    self.addressLabel.adjustsFontSizeToFitWidth = YES;
    [self.view addSubview:self.addressLabel];

    self.ipLabel = [[UILabel alloc] init];
    self.ipLabel.textAlignment = NSTextAlignmentCenter;
    self.ipLabel.font = [UIFont fontWithName:@"Menlo" size:15] ?: [UIFont systemFontOfSize:15];
    self.ipLabel.textColor = RFThemeDim();
    self.ipLabel.adjustsFontSizeToFitWidth = YES;
    [self.view addSubview:self.ipLabel];

    self.qrView = [[UIImageView alloc] init];
    self.qrView.layer.magnificationFilter = kCAFilterNearest;
    self.qrView.layer.cornerRadius = 6;
    self.qrView.clipsToBounds = YES;
    [self.view addSubview:self.qrView];

    self.infoLabel = [[UILabel alloc] init];
    self.infoLabel.numberOfLines = 0;
    self.infoLabel.textAlignment = NSTextAlignmentCenter;
    self.infoLabel.textColor = RFThemeDim();
    self.infoLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:self.infoLabel];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = MIN(self.view.bounds.size.width - 40, 640);
    CGFloat x = (self.view.bounds.size.width - w) / 2;
    CGFloat y = self.topLayoutGuide.length + 50;
    [self.view viewWithTag:1].frame = CGRectMake(x, y, w, 50);
    self.addressLabel.frame = CGRectMake(x, y + 60, w, 64);
    self.ipLabel.frame = CGRectMake(x, y + 130, w, 22);
    CGFloat q = 180;
    self.qrView.frame = CGRectMake(floor((self.view.bounds.size.width - q) / 2), y + 164, q, q);
    self.infoLabel.frame = CGRectMake(x, y + 164 + q + 10, w, 200);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    RFWebServer *server = [RFWebServer shared];
    __weak RFUploadViewController *weakSelf = self;
    server.onChange = ^{
        weakSelf.received++;
        [weakSelf updateInfo];
    };
    server.onNameChange = ^{ [weakSelf updateAddress]; };
    NSString *ip = [RFWebServer localIPAddress];
    NSString *error = nil;
    if (!ip) {
        self.addressLabel.text = @"No Wi-Fi";
        self.infoLabel.text = @"Connect the iPad to a Wi-Fi network and open this screen again.";
        return;
    }
    if (![server startOnPort:8716 error:&error]) {
        self.addressLabel.text = @"Error";
        self.infoLabel.text = error;
        return;
    }
    [self updateAddress];
    [self updateInfo];
}

// Endereço com nome (.local) em destaque e com IP embaixo; o QR code usa o IP, que todo celular entende
- (void)updateAddress {
    RFWebServer *server = [RFWebServer shared];
    NSString *ip = [RFWebServer localIPAddress];
    if (!ip || !server.running) return;
    NSString *ipURL = [NSString stringWithFormat:@"http://%@:%u/%@/", ip, server.port, server.accessCode];
    if (server.hostName) {
        self.addressLabel.text = [NSString stringWithFormat:@"http://%@:%u/%@/", server.hostName, server.port, server.accessCode];
        self.ipLabel.text = [@"or " stringByAppendingString:ipURL];
    } else {
        self.addressLabel.text = ipURL;
        self.ipLabel.text = nil;
    }
    self.qrView.image = RFQRCode(ipURL, 180);
}

- (void)updateInfo {
    NSString *base = @"Drag your ROMs (and .ips/.bps patches) onto the page.\n"
                     @"A patch with the same name as the ROM is applied automatically when the game starts.\n\n"
                     @"Uploading only works while this screen is open.";
    base = [@"Scan the code with a phone to upload from it. The address changes every time this screen opens.\n\n" stringByAppendingString:base];
    self.infoLabel.text = self.received ? [NSString stringWithFormat:@"%@\n\nChanges received: %ld", base, (long)self.received] : base;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[RFWebServer shared] stop];
    [RFWebServer shared].onChange = nil;
    [RFWebServer shared].onNameChange = nil;
}

@end

#pragma mark - Cartucho (célula da biblioteca)

// Cartão no formato de etiqueta de cartucho: grade, faixas diagonais e selo do sistema
@interface RFCartView : UIView
@property (nonatomic, copy) NSString *badge;     // texto da faixa da etiqueta
@property (nonatomic, assign) BOOL lit;          // destacado (toque)
@end

@implementation RFCartView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)setLit:(BOOL)lit {
    _lit = lit;
    [self setNeedsDisplay];
}

// Área da etiqueta dentro do cartucho (coordenadas do próprio cartucho)
static CGRect rf_label_rect(CGRect b) {
    CGFloat h = b.size.height;
    return CGRectMake(b.origin.x + 16, b.origin.y + 10, b.size.width - h * 1.15 - 16, h - 18);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect r = CGRectInset(self.bounds, 1, 1);
    CGFloat h = r.size.height, notch = h * 0.16;

    // Corpo do cartucho: cinza, cantos de cima chanfrados
    UIBezierPath *body = [UIBezierPath bezierPath];
    [body moveToPoint:CGPointMake(r.origin.x + notch, r.origin.y)];
    [body addLineToPoint:CGPointMake(CGRectGetMaxX(r) - notch, r.origin.y)];
    [body addLineToPoint:CGPointMake(CGRectGetMaxX(r), r.origin.y + notch)];
    [body addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r) - 6)];
    [body addQuadCurveToPoint:CGPointMake(CGRectGetMaxX(r) - 6, CGRectGetMaxY(r)) controlPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r))];
    [body addLineToPoint:CGPointMake(r.origin.x + 6, CGRectGetMaxY(r))];
    [body addQuadCurveToPoint:CGPointMake(r.origin.x, CGRectGetMaxY(r) - 6) controlPoint:CGPointMake(r.origin.x, CGRectGetMaxY(r))];
    [body addLineToPoint:CGPointMake(r.origin.x, r.origin.y + notch)];
    [body closePath];

    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 2), 4, [UIColor colorWithWhite:0 alpha:0.25].CGColor);
    [[UIColor colorWithRed:0.66 green:0.65 blue:0.70 alpha:1] setFill];
    [body fill];
    CGContextRestoreGState(ctx);

    CGContextSaveGState(ctx);
    [body addClip];
    CGFloat comps[] = {0.80, 0.79, 0.83, 1,  0.62, 0.61, 0.66, 1};
    CGFloat locs[] = {0, 1};
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGGradientRef g = CGGradientCreateWithColorComponents(rgb, comps, locs, 2);
    CGColorSpaceRelease(rgb);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, r.origin.y), CGPointMake(0, CGRectGetMaxY(r)), 0);
    CGGradientRelease(g);
    // Frisos de pegada à direita
    CGFloat gx = CGRectGetMaxX(r) - h * 1.0;
    for (int i = 0; i < 7; i++) {
        CGFloat x = gx + i * (h * 0.12);
        [[UIColor colorWithWhite:0.45 alpha:0.5] setFill];
        UIRectFill(CGRectMake(x, r.origin.y + h * 0.22, 2, h * 0.56));
        [[UIColor colorWithWhite:1 alpha:0.45] setFill];
        UIRectFill(CGRectMake(x + 2, r.origin.y + h * 0.22, 1, h * 0.56));
    }
    CGContextRestoreGState(ctx);

    // Etiqueta: clara, com faixa roxa no topo e o selo do sistema
    CGRect label = rf_label_rect(r);
    UIBezierPath *lp = [UIBezierPath bezierPathWithRoundedRect:label cornerRadius:4];
    [RFThemeCard() setFill];
    [lp fill];
    CGContextSaveGState(ctx);
    [lp addClip];
    [RFThemeRed() setFill];
    UIRectFill(CGRectMake(label.origin.x, label.origin.y, label.size.width, 16));
    [RFThemeLilac() setFill];
    UIRectFill(CGRectMake(label.origin.x, label.origin.y + 16, label.size.width, 3));
    CGContextRestoreGState(ctx);
    NSDictionary *attrs = @{NSFontAttributeName: RFThemeDisplayFont(11), NSForegroundColorAttributeName: [UIColor whiteColor]};
    [self.badge drawAtPoint:CGPointMake(label.origin.x + 8, label.origin.y + 1) withAttributes:attrs];
    [[UIColor colorWithWhite:0 alpha:0.15] setStroke];
    lp.lineWidth = 1;
    [lp stroke];

    // Contorno: lilás quando tocado
    body.lineWidth = self.lit ? 3 : 1;
    [(self.lit ? RFThemeLilac() : [UIColor colorWithWhite:0.40 alpha:0.6]) setStroke];
    [body stroke];
}

@end

@interface RFCartCell : UITableViewCell
@property (nonatomic, strong) RFCartView *cart;
@property (nonatomic, strong) UILabel *title;
@property (nonatomic, strong) UILabel *subtitle;
@end

@implementation RFCartCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.cart = [[RFCartView alloc] init];
        [self.contentView addSubview:self.cart];
        self.title = [[UILabel alloc] init];
        self.title.font = RFThemeDisplayFont(21);
        self.title.textColor = RFThemeText();
        self.title.adjustsFontSizeToFitWidth = YES;
        self.title.minimumScaleFactor = 0.6;
        [self.contentView addSubview:self.title];
        self.subtitle = [[UILabel alloc] init];
        self.subtitle.font = RFThemeLabelFont(11);
        self.subtitle.textColor = RFThemeDim();
        [self.contentView addSubview:self.subtitle];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat margin = b.size.width > 600 ? 40 : 14;
    CGRect card = CGRectMake(margin, 6, b.size.width - margin * 2, b.size.height - 12);
    self.cart.frame = card;
    CGRect label = rf_label_rect(CGRectMake(card.origin.x + 1, card.origin.y + 1, card.size.width - 2, card.size.height - 2));
    CGFloat left = label.origin.x + 10, right = CGRectGetMaxX(label) - 10;
    CGFloat top = label.origin.y + 21, avail = CGRectGetMaxY(label) - top - 2;
    self.title.frame = CGRectMake(left, top, right - left, avail * 0.6);
    self.subtitle.frame = CGRectMake(left, top + avail * 0.6, right - left, avail * 0.4);
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    self.cart.lit = highlighted;
}

@end

// Cabeçalho da biblioteca: letreiro cromado sobre a grade
@interface RFLibraryHeader : UIView
@property (nonatomic, strong) UIImageView *logo;
@property (nonatomic, strong) UILabel *tagline;
@end

@implementation RFLibraryHeader

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
        self.logo = [[UIImageView alloc] initWithImage:RFThemeChromeText(@"SNES16", 74)];
        [self addSubview:self.logo];
        self.tagline = [[UILabel alloc] init];
        self.tagline.font = RFThemeLabelFont(14);
        self.tagline.textColor = RFThemeRed();
        [self addSubview:self.tagline];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat margin = self.bounds.size.width > 600 ? 40 : 14;
    CGSize ls = self.logo.image.size;
    self.logo.frame = CGRectMake(margin - 8, 14, ls.width, ls.height);
    self.tagline.frame = CGRectMake(margin, CGRectGetMaxY(self.logo.frame) - 4, self.bounds.size.width - margin * 2, 20);
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    // Barras horizontais roxo/lilás/cinza saindo pela direita, atrás do letreiro
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    RFThemeDrawStripes(UIGraphicsGetCurrentContext(), CGRectMake(w * 0.5, h * 0.22, w * 0.5, h * 0.5), 13);
}

@end

#pragma mark - Biblioteca de jogos

@interface RFLibraryViewController : UITableViewController <RFBluetoothDelegate>
@property (nonatomic, strong) NSArray *roms;
@end

@implementation RFLibraryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SNES16";
    self.navigationItem.titleView = [[UIView alloc] init];   // o letreiro fica no cabeçalho
    self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Games" style:UIBarButtonItemStylePlain target:nil action:nil];
    self.tableView.backgroundView = RFThemeGridView();
    self.tableView.backgroundColor = [UIColor colorWithRed:0.80 green:0.79 blue:0.83 alpha:1];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 100;
    self.tableView.indicatorStyle = UIScrollViewIndicatorStyleBlack;
    self.tableView.tableHeaderView = [[RFLibraryHeader alloc] initWithFrame:CGRectMake(0, 0, 320, 150)];
    // Controle, conquistas e envio ficam no menu lateral (☰ ou arrastar da borda esquerda)
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self
                                                                                           action:@selector(reload)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [RFBluetooth shared].delegate = self;
    [self reload];
}

- (void)bluetoothDidChange {
    [self updatePrompt];
}

- (void)updatePrompt {
    RFBluetooth *bt = [RFBluetooth shared];
    self.navigationItem.prompt = bt.connected ? [NSString stringWithFormat:@"🎮 %@", bt.connectedName] : nil;
}

- (void)reload {
    NSArray *exts = @[@"sfc", @"smc", @"swc", @"fig", @"gd3", @"gd7", @"dx2", @"bsx"];
    NSMutableArray *list = [NSMutableArray array];
    NSString *dir = RFDir(@"roms");
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
        if ([exts containsObject:f.pathExtension.lowercaseString]) [list addObject:f];
    }
    self.roms = [list sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    RFLibraryHeader *header = (RFLibraryHeader *)self.tableView.tableHeaderView;
    header.tagline.text = self.roms.count == 1 ? @"1 CARTRIDGE ON THE SHELF · PRESS START" :
                          [NSString stringWithFormat:@"%lu CARTRIDGES ON THE SHELF · PRESS START", (unsigned long)self.roms.count];
    [self updatePrompt];
    [self.tableView reloadData];
}


- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.roms.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.roms.count) return nil;
    return @"No cartridges yet. Tap \"Upload ROMs\" to send files from your computer's browser.";
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    RFThemeStyleHeaderFooter(view, NO);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RFCartCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cart"];
    if (!cell) cell = [[RFCartCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cart"];
    NSString *f = self.roms[indexPath.row];
    cell.title.text = f.stringByDeletingPathExtension.uppercaseString;
    NSString *ext = f.pathExtension.lowercaseString;
    NSString *system = [ext isEqualToString:@"bsx"] ? @"SATELLAVIEW" : @"SUPER NINTENDO · 16-BIT";
    cell.cart.badge = @"16-BIT CARTRIDGE";
    [cell.cart setNeedsDisplay];
    NSString *patch = [RFCore patchPathForROM:[RFDir(@"roms") stringByAppendingPathComponent:f]];
    cell.subtitle.text = patch ? [NSString stringWithFormat:@"%@ · %@ PATCH", system, patch.pathExtension.uppercaseString] : system;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    return @"Delete";
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSString *f = self.roms[indexPath.row];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Delete game?"
                                                               message:[NSString stringWithFormat:@"%@ will be removed from the iPad (saves and states are kept).", f]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) {
        [tableView setEditing:NO animated:YES];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [[NSFileManager defaultManager] removeItemAtPath:[RFDir(@"roms") stringByAppendingPathComponent:f] error:nil];
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *path = [RFDir(@"roms") stringByAppendingPathComponent:self.roms[indexPath.row]];
    RFGameViewController *game = [[RFGameViewController alloc] initWithPath:path];
    [self presentViewController:game animated:YES completion:nil];
}

@end

#pragma mark - App

@interface RFAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation RFAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    NSArray *items = @[
        @{ @"title": @"Games", @"caption": @"Your cartridges", @"keep": @YES,
           @"make": ^UIViewController *{ return [[RFLibraryViewController alloc] initWithStyle:UITableViewStylePlain]; } },
        @{ @"title": @"Achievements", @"caption": @"RetroAchievements: your games and unlocks", @"keep": @YES,
           @"make": ^UIViewController *{ return [[RFAchievementsHomeViewController alloc] init]; } },
        @{ @"title": @"Upload ROMs", @"caption": @"Send games from a computer or phone", @"keep": @NO,
           @"make": ^UIViewController *{ return [[RFUploadViewController alloc] init]; } },
        @{ @"title": @"Controller", @"caption": @"Bluetooth controller and buttons", @"keep": @YES,
           @"make": ^UIViewController *{ return [[RFControllerViewController alloc] init]; } },
    ];
    self.window.tintColor = RFThemeRed();
    self.window.rootViewController = [[RFSideMenuController alloc] initWithItems:items];
    [self.window makeKeyAndVisible];
    application.idleTimerDisabled = YES;
    [[RFBluetooth shared] start];
    [[RFAchievements shared] start];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [[RFCore shared] saveSRAM];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [[RFCore shared] unload];
    [[RFBluetooth shared] stop];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([RFAppDelegate class]));
    }
}
