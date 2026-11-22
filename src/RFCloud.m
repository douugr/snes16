// Saves na nuvem: os saves dos jogos (SRAM dos cartuchos e memory cards do PS1) ficam num repositório
// privado do GitHub, para continuar o jogo em outro emulador ou aparelho. Cada save é identificado pela
// impressão digital da ROM (o mesmo hash do RetroAchievements), então o nome do arquivo pode mudar
// entre aparelhos. O histórico de versões é o próprio histórico de commits do repositório.
//
// A configuração (repositório + token de acesso) é comum aos três emuladores e fica em
// Documents/RetroCloud/config.plist; cada app guarda o próprio estado de sincronização ao lado.

#import "RF.h"
#import <CommonCrypto/CommonDigest.h>
#include "rc_hash.h"
#include <fcntl.h>
#include <unistd.h>

NSString *const RFCloudChanged = @"RFCloudChanged";

static NSString *rf_cloud_dir(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"RetroCloud"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *rf_md5(NSData *data) {
    if (!data) return @"";
    unsigned char d[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, d);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", d[i]];
    return s;
}

@interface RFCloud () <NSURLSessionDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSArray *extraRoots;
@property (nonatomic, strong) NSMutableDictionary *state;     // remoto -> {sha, md5, local, name, at}
@property (nonatomic, strong) NSMutableSet *dirty;            // remotos com mudança local a enviar
@property (nonatomic, strong) NSTimer *pushTimer;
@property (nonatomic, readwrite, copy) NSString *lastMessage;
@property (nonatomic, readwrite, strong) NSDate *lastSync;
@property (nonatomic, assign) BOOL waitingNetwork;
@property (nonatomic, assign) BOOL pushing;
@end

#pragma mark Diagnóstico da saída do jogo

static char rf_quit_step[128];
static volatile int rf_quit_serial = 0;

// Marca a etapa da saída do jogo no log; se a saída ficar presa por 10 s, registra onde e fecha o app
void RFQuitStep(const char *step) {
    strlcpy(rf_quit_step, step ?: "", sizeof(rf_quit_step));
    RFAppendLog(@"core.txt", [NSString stringWithFormat:@"quit: %s", step]);
    // Garante que a linha chegou ao disco: se o iPad inteiro congelar, ela não se perde
    int fd = open([RFDir(@"") stringByAppendingPathComponent:@"core.txt"].fileSystemRepresentation, O_WRONLY | O_APPEND);
    if (fd >= 0) { fsync(fd); close(fd); }
}

void RFQuitWatch(BOOL on) {
    int serial = ++rf_quit_serial;
    if (!on) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        if (serial != rf_quit_serial) return;
        RFAppendLog(@"core.txt", [NSString stringWithFormat:@"quit: STUCK for 10 s at \"%s\", closing the app", rf_quit_step]);
        _exit(0);
    });
}

@implementation RFCloud

+ (instancetype)shared {
    static RFCloud *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [[RFCloud alloc] init]; });
    return c;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSMutableArray *roots = [NSMutableArray array];
        for (NSString *p in [[NSBundle mainBundle] pathsForResourcesOfType:@"der" inDirectory:nil]) {
            NSData *d = [NSData dataWithContentsOfFile:p];
            SecCertificateRef c = d ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)d) : NULL;
            if (c) [roots addObject:(__bridge_transfer id)c];
        }
        _extraRoots = roots;
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.URLCache = nil;
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
        _state = [[NSDictionary dictionaryWithContentsOfFile:[self statePath]] mutableCopy] ?: [NSMutableDictionary dictionary];
        _dirty = [NSMutableSet set];
        for (NSString *remote in _state) if ([_state[remote][@"pending"] boolValue]) [_dirty addObject:remote];
        // Ao sair do app (o jogo grava o save nessa hora): envia logo, sem esperar o temporizador
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pushPendingForce:YES]; });
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self pushPending]; });
    }
    return self;
}

#pragma mark Configuração

+ (NSString *)configPath {
    return [rf_cloud_dir() stringByAppendingPathComponent:@"config.plist"];
}

- (NSString *)statePath {
    NSString *app = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    return [rf_cloud_dir() stringByAppendingPathComponent:[NSString stringWithFormat:@"state-%@.plist", app]];
}

- (NSDictionary *)config {
    return [NSDictionary dictionaryWithContentsOfFile:[RFCloud configPath]];
}

- (BOOL)configured {
    NSDictionary *c = [self config];
    return [c[@"repo"] length] && [c[@"token"] length];
}

- (NSString *)repo {
    return [self config][@"repo"];
}

- (void)saveState {
    [self.state writeToFile:[self statePath] atomically:YES];
}

// Chamado pela página de envio (thread do servidor): confere o acesso antes de gravar
- (NSString *)configureRepo:(NSString *)repo token:(NSString *)token {
    repo = [repo stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    token = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([repo hasPrefix:@"https://github.com/"]) repo = [repo substringFromIndex:19];
    if ([repo hasSuffix:@".git"]) repo = [repo substringToIndex:repo.length - 4];
    if ([repo componentsSeparatedByString:@"/"].count != 2 || !token.length) return @"Use owner/repository and a token.";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *error = nil;
    NSMutableURLRequest *r = [self requestForPath:[NSString stringWithFormat:@"/repos/%@", repo] token:token];
    [[self.session dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) {
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (e) error = [NSString stringWithFormat:@"No connection to GitHub: %@", e.localizedDescription];
        else if (status == 401) error = @"GitHub refused the token (expired or mistyped?).";
        else if (status == 404) error = @"Repository not found, or the token has no access to it.";
        else if (status != 200) error = [NSString stringWithFormat:@"GitHub answered %ld.", (long)status];
        else if (![json[@"private"] boolValue]) error = @"This repository is public. Use a private one: saves are personal.";
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    if (error) return error;
    NSDictionary *c = @{ @"repo": repo, @"token": token };
    [c writeToFile:[RFCloud configPath] atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:[RFCloud configPath] error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.lastMessage = [@"Connected to " stringByAppendingString:repo];
        [[NSNotificationCenter defaultCenter] postNotificationName:RFCloudChanged object:nil];
        [self pushPending];
    });
    return nil;
}

- (void)disconnect {
    [[NSFileManager defaultManager] removeItemAtPath:[RFCloud configPath] error:nil];
    self.lastMessage = @"Disconnected";
    [[NSNotificationCenter defaultCenter] postNotificationName:RFCloudChanged object:nil];
}

#pragma mark GitHub

- (NSMutableURLRequest *)requestForPath:(NSString *)path token:(NSString *)token {
    NSURL *url = [NSURL URLWithString:[@"https://api.github.com" stringByAppendingString:path]];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.timeoutInterval = 20;
    [r setValue:[@"Bearer " stringByAppendingString:token ?: @""] forHTTPHeaderField:@"Authorization"];
    [r setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [r setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    NSString *app = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    [r setValue:[app stringByAppendingString:@"-cloud-saves"] forHTTPHeaderField:@"User-Agent"];
    return r;
}

- (NSString *)encodedPath:(NSString *)remote {
    NSMutableCharacterSet *ok = [[NSCharacterSet URLPathAllowedCharacterSet] mutableCopy];
    return [remote stringByAddingPercentEncodingWithAllowedCharacters:ok];
}

// GET do arquivo: completion(sha, conteúdo, status) na thread principal (sha nil = não existe).
// Arquivos maiores que 1 MB (save states) não vêm no JSON: o conteúdo é baixado à parte, e só se o sha
// for diferente de knownSha (o que este aparelho já tem)
- (void)fetch:(NSString *)remote knownSha:(NSString *)knownSha completion:(void (^)(NSString *sha, NSData *content, NSInteger status))completion {
    NSDictionary *c = [self config];
    NSString *p = [NSString stringWithFormat:@"/repos/%@/contents/%@", c[@"repo"], [self encodedPath:remote]];
    [[self.session dataTaskWithRequest:[self requestForPath:p token:c[@"token"]] completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) {
        NSInteger status = e ? -1 : ((NSHTTPURLResponse *)response).statusCode;
        NSDictionary *json = (status == 200 && data) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *sha = json[@"sha"];
        NSString *b64 = json[@"content"];
        NSData *content = b64.length ? [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters] : nil;
        BOOL big = !content && [json[@"size"] longLongValue] > 0;
        if (big && ![sha isEqualToString:knownSha ?: @""]) {
            NSMutableURLRequest *raw = [self requestForPath:p token:c[@"token"]];
            [raw setValue:@"application/vnd.github.raw" forHTTPHeaderField:@"Accept"];
            raw.timeoutInterval = 120;
            [[self.session dataTaskWithRequest:raw completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
                NSInteger st2 = e2 ? -1 : ((NSHTTPURLResponse *)r2).statusCode;
                dispatch_async(dispatch_get_main_queue(), ^{ completion(st2 == 200 ? sha : nil, st2 == 200 ? d2 : nil, st2 == 200 ? 200 : st2); });
            }] resume];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(sha, content, status); });
    }] resume];
}

// Data e aparelho do último envio (só para a pergunta de conflito)
- (void)lastCommitFor:(NSString *)remote completion:(void (^)(NSString *description))completion {
    NSDictionary *c = [self config];
    NSString *p = [NSString stringWithFormat:@"/repos/%@/commits?per_page=1&path=%@", c[@"repo"], [self encodedPath:remote]];
    [[self.session dataTaskWithRequest:[self requestForPath:p token:c[@"token"]] completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) {
        NSArray *list = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *commit = [list isKindOfClass:[NSArray class]] ? [list.firstObject objectForKey:@"commit"] : nil;
        NSString *msg = [commit[@"message"] componentsSeparatedByString:@"\n"].firstObject;
        NSString *date = commit[@"committer"][@"date"];
        NSString *desc = nil;
        if (date.length >= 16) {
            NSDateFormatter *in = [[NSDateFormatter alloc] init];
            in.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            in.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
            in.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            NSDate *d = [in dateFromString:date];
            NSString *when = d ? [NSDateFormatter localizedStringFromDate:d dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle] : date;
            desc = msg.length ? [NSString stringWithFormat:@"%@ (%@)", when, msg] : when;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(desc); });
    }] resume];
}

- (void)put:(NSString *)remote data:(NSData *)data sha:(NSString *)sha message:(NSString *)message
 completion:(void (^)(NSString *newSha, NSInteger status))completion {
    NSDictionary *c = [self config];
    NSString *p = [NSString stringWithFormat:@"/repos/%@/contents/%@", c[@"repo"], [self encodedPath:remote]];
    NSMutableURLRequest *r = [self requestForPath:p token:c[@"token"]];
    r.HTTPMethod = @"PUT";
    NSMutableDictionary *body = [@{ @"message": message, @"content": [data base64EncodedStringWithOptions:0] } mutableCopy];
    if (sha) body[@"sha"] = sha;
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [[self.session dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *response, NSError *e) {
        NSInteger status = e ? -1 : ((NSHTTPURLResponse *)response).statusCode;
        NSDictionary *json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSString *newSha = [json isKindOfClass:[NSDictionary class]] ? json[@"content"][@"sha"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(newSha, status); });
    }] resume];
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    NSURLProtectionSpace *space = challenge.protectionSpace;
    if (![space.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }
    SecTrustRef trust = space.serverTrust;
    SecTrustResultType result = kSecTrustResultInvalid;
    if (SecTrustEvaluate(trust, &result) == errSecSuccess && (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed)) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
        return;
    }
    // Certificados raiz que o iOS 8 não conhece (ex.: USERTrust ECC, usado pelo GitHub); a validação continua
    if ([space.host isEqualToString:@"api.github.com"] && self.extraRoots.count) {
        SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)self.extraRoots);
        SecTrustSetAnchorCertificatesOnly(trust, false);
        if (SecTrustEvaluate(trust, &result) == errSecSuccess && (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed)) {
            completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
            return;
        }
    }
    RFAppendLog(@"cloud.txt", [NSString stringWithFormat:@"TLS: certificate of %@ not trusted (%d)", space.host, (int)result]);
    completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}

#pragma mark Antes de jogar: baixa o save mais novo

static NSString *rf_device(void) {
    UIDevice *d = [UIDevice currentDevice];
    return [NSString stringWithFormat:@"%@ (%@ %@)", d.name, d.model, d.systemVersion];
}

// Saves do jogo com o caminho no repositório (o hash da ROM sai em segundo plano)
- (NSArray *)savesForGame:(NSString *)romPath {
    char hash[33] = {0};
    uint32_t console = RFConsoleForPath(romPath);
    NSString *key = rc_hash_generate_from_file(hash, console, romPath.fileSystemRepresentation) ? [NSString stringWithUTF8String:hash] : nil;
    if (!key) {
        RFAppendLog(@"cloud.txt", [@"no hash for " stringByAppendingString:romPath.lastPathComponent]);
        return @[];
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *s in RFCloudSaveFiles(romPath)) {
        // save states (s[@"suffix"]): <pasta>/states/<impressão digital><suffix>, o mesmo caminho do Switch
        NSString *remote = s[@"shared"] ?: (s[@"suffix"] ? [NSString stringWithFormat:@"%@/states/%@%@", s[@"folder"], key, s[@"suffix"]]
                                                         : [NSString stringWithFormat:@"%@/%@.srm", s[@"folder"], key]);
        [out addObject:@{ @"local": s[@"local"], @"remote": remote, @"name": s[@"label"] ?: romPath.lastPathComponent.stringByDeletingPathExtension }];
    }
    return out;
}

- (void)syncBeforePlaying:(NSString *)romPath from:(UIViewController *)vc completion:(void (^)(void))completion {
    self.justDownloaded = NO;
    if (![self configured]) { completion(); return; }
    UIView *hud = [self hudIn:vc.view text:@"Syncing save…"];
    __block BOOL finished = NO;
    void (^done)(void) = ^{
        if (finished) return;
        finished = YES;
        [hud removeFromSuperview];
        completion();
    };
    // Sem resposta em 8 s (sem internet): joga com o save local mesmo
    self.waitingNetwork = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (finished || !self.waitingNetwork) return;
        self.lastMessage = @"Cloud didn't answer: playing with the save on this device";
        done();
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *saves = [self savesForGame:romPath];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self syncSaves:saves index:0 from:vc completion:^{ done(); }];
        });
    });
}

- (void)syncSaves:(NSArray *)saves index:(NSUInteger)i from:(UIViewController *)vc completion:(void (^)(void))completion {
    if (i >= saves.count) { completion(); return; }
    self.waitingNetwork = YES;
    NSDictionary *s = saves[i];
    NSString *remote = s[@"remote"], *local = s[@"local"];
    NSMutableDictionary *st = [self.state[remote] mutableCopy] ?: [NSMutableDictionary dictionary];
    st[@"local"] = local;
    st[@"name"] = s[@"name"];
    self.state[remote] = st;
    [self fetch:remote knownSha:st[@"sha"] completion:^(NSString *sha, NSData *content, NSInteger status) {
        self.waitingNetwork = NO;
        void (^next)(void) = ^{ [self saveState]; [self syncSaves:saves index:i + 1 from:vc completion:completion]; };
        if (status != 200 && status != 404) {
            self.lastMessage = status == 401 ? @"GitHub refused the token: set it up again" : @"Cloud unavailable right now";
            RFAppendLog(@"cloud.txt", [NSString stringWithFormat:@"fetch %@: %ld", remote, (long)status]);
            next();
            return;
        }
        NSData *mine = [NSData dataWithContentsOfFile:local];
        NSString *mineMD5 = mine ? rf_md5(mine) : nil;
        BOOL localChanged = mine && ![mineMD5 isEqualToString:st[@"md5"] ?: @""];
        if (!sha) {
            // Ainda não está na nuvem: envia o daqui
            if (mine) [self markDirty:remote];
            next();
            return;
        }
        if ([sha isEqualToString:st[@"sha"] ?: @""] || [rf_md5(content) isEqualToString:mineMD5 ?: @""]) {
            st[@"sha"] = sha;
            if (!localChanged || [rf_md5(content) isEqualToString:mineMD5 ?: @""]) st[@"md5"] = mineMD5 ?: rf_md5(content);
            else [self markDirty:remote];
            self.state[remote] = st;
            next();
            return;
        }
        // A nuvem mudou desde a última vez
        if (!mine || (!localChanged && st[@"md5"])) {
            [self useCloud:content sha:sha remote:remote local:local];
            next();
            return;
        }
        // Mudou dos dois lados (ou é a primeira vez neste aparelho): pergunta
        [self lastCommitFor:remote completion:^(NSString *when) {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:local error:nil];
            NSString *localWhen = [NSDateFormatter localizedStringFromDate:attrs.fileModificationDate ?: [NSDate date]
                                                                dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Which save do you want?"
                message:[NSString stringWithFormat:@"%@ has a different save in the cloud.\n\nCloud: %@\nThis iPad: %@\n\nThe other one stays in the cloud history on GitHub.",
                         s[@"name"], when ?: @"unknown date", localWhen]
                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"Use the cloud save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                [self useCloud:content sha:sha remote:remote local:local];
                next();
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"Keep this iPad's save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                NSMutableDictionary *s2 = [self.state[remote] mutableCopy];
                s2[@"sha"] = sha;   // vai por cima da versão da nuvem (que continua no histórico)
                self.state[remote] = s2;
                [self markDirty:remote];
                next();
            }]];
            [vc presentViewController:a animated:YES completion:nil];
        }];
    }];
}

- (void)useCloud:(NSData *)content sha:(NSString *)sha remote:(NSString *)remote local:(NSString *)local {
    [[NSFileManager defaultManager] createDirectoryAtPath:local.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [content writeToFile:local atomically:YES];
    NSMutableDictionary *st = [self.state[remote] mutableCopy];
    st[@"sha"] = sha;
    st[@"md5"] = rf_md5(content);
    st[@"at"] = [NSDate date];
    self.state[remote] = st;
    self.lastSync = [NSDate date];
    self.lastMessage = [NSString stringWithFormat:@"Downloaded the save of %@", st[@"name"]];
    self.justDownloaded = YES;
    RFAppendLog(@"cloud.txt", [@"downloaded " stringByAppendingString:remote]);
    RFCloudDidDownload(local);   // o app desempacota os save states
}

#pragma mark Depois de salvar: envia

// Chamado quando o app grava um save no disco (qualquer thread)
- (void)localSaveWritten:(NSString *)localPath {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Percorre uma cópia das chaves: markDirty altera o dicionário (alterar durante a varredura derruba o app)
        for (NSString *remote in self.state.allKeys) {
            if ([self.state[remote][@"local"] isEqualToString:localPath]) [self markDirty:remote];
        }
    });
}

- (void)setGameRunning:(BOOL)running {
    _gameRunning = running;
    // Saiu do jogo: envia o que ficou pendente (durante o jogo a rede atrapalha o Bluetooth e o som do iPad 3)
    if (!running) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self pushPending]; });
}

- (void)markDirty:(NSString *)remote {
    [self.dirty addObject:remote];
    NSMutableDictionary *st = [self.state[remote] mutableCopy];
    st[@"pending"] = @YES;
    self.state[remote] = st;
    [self saveState];
    [self.pushTimer invalidate];
    self.pushTimer = [NSTimer scheduledTimerWithTimeInterval:6 target:self selector:@selector(pushPending) userInfo:nil repeats:NO];
}

- (NSUInteger)pendingCount {
    return self.dirty.count;
}

- (void)pushPending {
    [self pushPendingForce:NO];
}

// Um envio por vez: o GitHub recusa (409) dois commits ao mesmo tempo no mesmo repositório
- (void)pushPendingForce:(BOOL)force {
    if (![self configured] || !self.dirty.count || self.pushing) return;
    if (self.gameRunning && !force) return;
    self.pushing = YES;
    UIBackgroundTaskIdentifier task = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
    RFAppendLog(@"cloud.txt", [NSString stringWithFormat:@"push start: %lu pending", (unsigned long)self.dirty.count]);
    [self pushNextWithTask:task tries:0];
}

- (void)pushNextWithTask:(UIBackgroundTaskIdentifier)task tries:(int)tries {
    NSString *remote = self.dirty.anyObject;
    if (!remote) {
        self.pushing = NO;
        [self saveState];
        [[NSNotificationCenter defaultCenter] postNotificationName:RFCloudChanged object:nil];
        RFAppendLog(@"cloud.txt", @"push done");
        [[UIApplication sharedApplication] endBackgroundTask:task];
        return;
    }
    NSDictionary *st = self.state[remote];
    NSData *data = [NSData dataWithContentsOfFile:st[@"local"]];
    if (!data) {
        [self.dirty removeObject:remote];
        [self pushNextWithTask:task tries:0];
        return;
    }
    NSString *app = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    NSString *msg = [NSString stringWithFormat:@"%@ · %@ · %@", st[@"name"] ?: remote, app, rf_device()];
    [self put:remote data:data sha:st[@"sha"] message:msg completion:^(NSString *newSha, NSInteger status) {
        RFAppendLog(@"cloud.txt", [NSString stringWithFormat:@"put %@: %ld", remote, (long)status]);
        NSMutableDictionary *s2 = [self.state[remote] mutableCopy];
        if (newSha) {
            s2[@"sha"] = newSha;
            s2[@"md5"] = rf_md5(data);
            s2[@"at"] = [NSDate date];
            [s2 removeObjectForKey:@"pending"];
            [self.dirty removeObject:remote];
            self.state[remote] = s2;
            self.lastSync = [NSDate date];
            self.lastMessage = [NSString stringWithFormat:@"Uploaded the save of %@", s2[@"name"]];
            [self pushNextWithTask:task tries:0];
        } else if (status == 409 && tries < 3) {
            // Outro commit acabou de entrar: tenta de novo daqui a pouco
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self pushNextWithTask:task tries:tries + 1];
            });
        } else if (status == 409 || status == 422) {
            // A nuvem tem outra versão (de outro aparelho): o jogador escolhe na próxima vez que o jogo abrir
            [self.dirty removeObject:remote];
            self.lastMessage = [NSString stringWithFormat:@"%@ changed on another device: you'll choose next time it opens", s2[@"name"]];
            [self pushNextWithTask:task tries:0];
        } else {
            // Sem rede ou erro do GitHub: para e tenta de novo mais tarde (continua pendente)
            self.lastMessage = status == 401 ? @"GitHub refused the token: set it up again" : @"Upload failed: will retry later";
            self.pushing = NO;
            [self saveState];
            [[NSNotificationCenter defaultCenter] postNotificationName:RFCloudChanged object:nil];
            [[UIApplication sharedApplication] endBackgroundTask:task];
        }
    }];
}

#pragma mark Enviar todos os saves (botão da tela da nuvem)

- (void)uploadAllWithCompletion:(void (^)(NSUInteger found))completion {
    if (![self configured]) { completion(0); return; }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *found = [NSMutableArray array];
        for (NSString *rom in RFCloudLibraryGames()) {
            for (NSDictionary *s in [self savesForGame:rom]) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:s[@"local"]]) [found addObject:s];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableSet *seen = [NSMutableSet set];
            for (NSDictionary *s in found) {
                if ([seen containsObject:s[@"remote"]]) continue;   // memory card compartilhado aparece em todo jogo
                [seen addObject:s[@"remote"]];
                NSMutableDictionary *st = [self.state[s[@"remote"]] mutableCopy] ?: [NSMutableDictionary dictionary];
                st[@"local"] = s[@"local"];
                if (!st[@"name"]) st[@"name"] = s[@"name"];
                self.state[s[@"remote"]] = st;
                // Só envia o que mudou desde a última sincronização (ou nunca foi enviado)
                NSData *d = [NSData dataWithContentsOfFile:s[@"local"]];
                if (!st[@"md5"] || ![rf_md5(d) isEqualToString:st[@"md5"]]) [self.dirty addObject:s[@"remote"]];
            }
            for (NSString *r in self.dirty) {
                NSMutableDictionary *st = [self.state[r] mutableCopy];
                st[@"pending"] = @YES;
                self.state[r] = st;
            }
            [self saveState];
            [self pushPendingForce:YES];
            [[NSNotificationCenter defaultCenter] postNotificationName:RFCloudChanged object:nil];
            completion(seen.count);
        });
    });
}

#pragma mark Interface

- (UIView *)hudIn:(UIView *)parent text:(NSString *)text {
    UIView *hud = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 220, 110)];
    hud.center = CGPointMake(CGRectGetMidX(parent.bounds), CGRectGetMidY(parent.bounds));
    hud.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                           UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    hud.layer.cornerRadius = 14;
    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    spin.center = CGPointMake(110, 42);
    [spin startAnimating];
    [hud addSubview:spin];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, 72, 200, 24)];
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont boldSystemFontOfSize:15];
    l.text = text;
    [hud addSubview:l];
    [parent addSubview:hud];
    return hud;
}

@end

#pragma mark - Tela: saves na nuvem

@interface RFCloudViewController ()
@property (nonatomic, strong) UILabel *info;
@property (nonatomic, strong) UIButton *syncButton;
@property (nonatomic, strong) UIButton *offButton;
@end

@implementation RFCloudViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Cloud saves";
    UIView *grid = RFThemeGridView();
    grid.frame = self.view.bounds;
    grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:grid];
    self.info = [[UILabel alloc] init];
    self.info.numberOfLines = 0;
    self.info.font = [UIFont systemFontOfSize:16];
    self.info.textColor = RFThemeText();
    [self.view addSubview:self.info];
    self.syncButton = [self button:@"Upload all saves on this iPad now" action:@selector(syncNow)];
    self.offButton = [self button:@"Disconnect this iPad" action:@selector(disconnect)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:RFCloudChanged object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = RFThemeDisplayFont(18);
    b.backgroundColor = RFThemeCard();
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 1.5;
    b.layer.borderColor = RFThemeRed().CGColor;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    return b;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat W = self.view.bounds.size.width, w = MIN(W - 40, 560), x = floor((W - w) / 2);
    CGFloat y = self.topLayoutGuide.length + 24;
    CGSize s = [self.info sizeThatFits:CGSizeMake(w, 1000)];
    self.info.frame = CGRectMake(x, y, w, s.height);
    y += s.height + 24;
    self.syncButton.frame = CGRectMake(x, y, w, 46);
    self.offButton.frame = CGRectMake(x, y + 58, w, 46);
}

- (void)refresh {
    RFCloud *c = [RFCloud shared];
    BOOL on = [c configured];
    self.syncButton.hidden = self.offButton.hidden = !on;
    NSMutableString *t = [NSMutableString string];
    if (on) {
        [t appendFormat:@"Connected to the private repository %@ on GitHub.\n\n", c.repo];
        [t appendString:@"Saves made inside the games (cartridge saves and memory cards) are downloaded when a game opens "
                        @"and uploaded a few seconds after the game saves. Every version stays in the repository's history.\n\n"];
        [t appendFormat:@"Waiting to upload: %lu\n", (unsigned long)c.pendingCount];
        if (c.lastSync) [t appendFormat:@"Last sync: %@\n", [NSDateFormatter localizedStringFromDate:c.lastSync dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle]];
        if (c.lastMessage) [t appendFormat:@"\n%@", c.lastMessage];
    } else {
        [t appendString:@"Keep your saves in a private GitHub repository and continue on another device or emulator.\n\n"
                        @"To set it up, open the Upload screen in this menu and open its address in a computer's browser: "
                        @"the page has a \"Cloud saves\" section where you paste the repository name and an access token. "
                        @"The setup is shared by MD16, SNES16 and PSX32."];
        if (c.lastMessage) [t appendFormat:@"\n\n%@", c.lastMessage];
    }
    self.info.text = t;
    [self.view setNeedsLayout];
}

- (void)syncNow {
    self.syncButton.enabled = NO;
    [self.syncButton setTitle:@"Looking for saves…" forState:UIControlStateNormal];
    __weak RFCloudViewController *weakSelf = self;
    [[RFCloud shared] uploadAllWithCompletion:^(NSUInteger found) {
        weakSelf.syncButton.enabled = YES;
        [weakSelf.syncButton setTitle:@"Upload all saves on this iPad now" forState:UIControlStateNormal];
        [weakSelf refresh];
    }];
}

- (void)disconnect {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Disconnect cloud saves?"
        message:@"The access token is removed from this iPad (for all three emulators). Saves already in the cloud are kept."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Disconnect" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [[RFCloud shared] disconnect];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
