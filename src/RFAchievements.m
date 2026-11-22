// RetroAchievements: conquistas no estilo Xbox/Steam para jogos clássicos (retroachievements.org).
// Usa a biblioteca oficial rcheevos (rc_client) para identificar o jogo, acompanhar a memória a cada
// quadro e enviar os desbloqueios. A parte de rede fica aqui (NSURLSession), na thread principal.
//
// Por enquanto só no modo Casual: emuladores novos não podem desbloquear no Hardcore até serem
// aprovados pelo RetroAchievements. Save states continuam liberados.

#import "RF.h"
#import <QuartzCore/QuartzCore.h>
#include "libretro.h"
#include "rc_client.h"
#include "rc_libretro.h"
#include "rc_consoles.h"
#include "rc_api_runtime.h"
#include "rc_api_user.h"

NSString *const RFAchievementsChanged = @"RFAchievementsChanged";

#pragma mark - Mapa de memória vindo do core

static struct retro_memory_descriptor rf_mmap_descs[64];
static struct retro_memory_map rf_mmap = { rf_mmap_descs, 0 };

// Chamado pelo RETRO_ENVIRONMENT_SET_MEMORY_MAPS (o core passa dados temporários: copiamos)
void RFAchievementsSetMemoryMap(const struct retro_memory_map *map) {
    unsigned n = map ? MIN(map->num_descriptors, 64u) : 0;
    for (unsigned i = 0; i < n; i++) rf_mmap_descs[i] = map->descriptors[i];
    rf_mmap.num_descriptors = n;
}

static rc_libretro_memory_regions_t rf_regions;
static rc_client_t *rf_client;

static void rf_core_memory_info(uint32_t id, rc_libretro_core_memory_info_t *info) {
    info->data = retro_get_memory_data(id);
    info->size = retro_get_memory_size(id);
}

static uint32_t rf_read_memory(uint32_t address, uint8_t *buffer, uint32_t num_bytes, rc_client_t *client) {
    return rc_libretro_memory_read(&rf_regions, address, buffer, num_bytes);
}

#pragma mark - Rede

static void rf_event_handler(const rc_client_event_t *event, rc_client_t *client);
static void rf_login_done(int result, const char *error_message, rc_client_t *client, void *userdata);
static void rf_game_loaded(int result, const char *error_message, rc_client_t *client, void *userdata);

@interface RFAchievements () <NSURLSessionDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSArray *extraRoots;
@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic, readwrite) BOOL loggedIn;
@property (nonatomic, readwrite, copy) NSString *userName;
@property (nonatomic, readwrite) uint32_t score;
@property (nonatomic, readwrite, copy) NSString *gameTitle;
@property (nonatomic, readwrite, copy) NSString *status;
- (void)identifyGame;
- (void)toastTitle:(NSString *)title detail:(NSString *)detail badge:(UIImage *)badge;
- (void)toastTitle:(NSString *)title detail:(NSString *)detail badgeURL:(NSString *)badge;
- (void)toastTitle:(NSString *)title detail:(NSString *)detail badgeURL:(NSString *)badge header:(NSString *)header;
@property (nonatomic, assign) BOOL memoryReady;
@property (nonatomic, assign) double lastFrameAt;
@property (nonatomic, strong) NSTimer *idleTimer;
@property (nonatomic, strong) NSMutableArray *toastQueue;
@property (nonatomic, strong) UIView *toastView;
@property (nonatomic, assign) double lastProgressToast;
@end

static void rf_ra_log(const char *message, const rc_client_t *client) {
    RFAppendLog(@"ra.txt", [NSString stringWithUTF8String:message ?: ""]);
}

static void rf_server_call(const rc_api_request_t *request, rc_client_server_callback_t callback, void *callback_data, rc_client_t *client) {
    RFAchievements *ra = [RFAchievements shared];
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:request->url]];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.timeoutInterval = 30;
    [r setValue:ra.userAgent forHTTPHeaderField:@"User-Agent"];
    if (request->post_data) {
        r.HTTPMethod = @"POST";
        r.HTTPBody = [NSData dataWithBytes:request->post_data length:strlen(request->post_data)];
        [r setValue:request->content_type ? [NSString stringWithUTF8String:request->content_type] : @"application/x-www-form-urlencoded"
          forHTTPHeaderField:@"Content-Type"];
    }
    [[ra.session dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            rc_api_server_response_t res;
            memset(&res, 0, sizeof(res));
            if (error) {
                RFAppendLog(@"ra.txt", [NSString stringWithFormat:@"network error %@: %@", url.path, error.localizedDescription]);
                res.http_status_code = RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR;
                res.body = error.localizedDescription.UTF8String;
                res.body_length = strlen(res.body);
            } else {
                res.http_status_code = (int)((NSHTTPURLResponse *)response).statusCode;
                res.body = data.bytes;
                res.body_length = data.length;
            }
            callback(&res, callback_data);
        });
    }] resume];
}

@implementation RFAchievements

+ (instancetype)shared {
    static RFAchievements *ra;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ra = [[RFAchievements alloc] init]; });
    return ra;
}

- (instancetype)init {
    if ((self = [super init])) {
        _toastQueue = [NSMutableArray array];
        // Certificados raiz que o iOS 8 não conhece (ex.: os do Let's Encrypt), usados só se a
        // validação normal falhar. A conexão continua validada; nada de aceitar certificado qualquer.
        NSMutableArray *roots = [NSMutableArray array];
        for (NSString *p in [[NSBundle mainBundle] pathsForResourcesOfType:@"der" inDirectory:nil]) {
            NSData *d = [NSData dataWithContentsOfFile:p];
            SecCertificateRef c = d ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)d) : NULL;
            if (c) {
                [roots addObject:(__bridge_transfer id)c];
            }
        }
        _extraRoots = roots;
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.HTTPMaximumConnectionsPerHost = 4;
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];

        struct retro_system_info sys;
        memset(&sys, 0, sizeof(sys));
        retro_get_system_info(&sys);
        NSString *app = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
        NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *coreName = [[[NSString stringWithUTF8String:sys.library_name ?: "core"] lowercaseString]
                              stringByReplacingOccurrencesOfString:@" " withString:@"_"];
        NSString *coreVer = [[NSString stringWithUTF8String:sys.library_version ?: "0"] componentsSeparatedByString:@" "].firstObject;
        _userAgent = [NSString stringWithFormat:@"%@/%@ (iOS %@) %@/%@", app, ver, [UIDevice currentDevice].systemVersion, coreName, coreVer];

        rf_client = rc_client_create(rf_read_memory, rf_server_call);
        rc_client_enable_logging(rf_client, RC_CLIENT_LOG_LEVEL_WARN, rf_ra_log);   // só avisos e erros: gravar em arquivo a cada evento pesa no jogo
        rc_client_set_event_handler(rf_client, rf_event_handler);
        rc_client_set_hardcore_enabled(rf_client, 0);
        char clause[64];
        if (rc_client_get_user_agent_clause(rf_client, clause, sizeof(clause))) {
            _userAgent = [_userAgent stringByAppendingFormat:@" %s", clause];
        }
        RFAppendLog(@"ra.txt", [@"user agent: " stringByAppendingString:_userAgent]);
    }
    return self;
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
    if (SecTrustEvaluate(trust, &result) == errSecSuccess &&
        (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed)) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
        return;
    }
    BOOL ours = [space.host isEqualToString:@"retroachievements.org"] || [space.host hasSuffix:@".retroachievements.org"];
    if (ours && self.extraRoots.count) {
        SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)self.extraRoots);
        SecTrustSetAnchorCertificatesOnly(trust, false);
        if (SecTrustEvaluate(trust, &result) == errSecSuccess &&
            (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed)) {
            completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
            return;
        }
    }
    RFAppendLog(@"ra.txt", [NSString stringWithFormat:@"TLS: certificate of %@ not trusted (result %d)", space.host, (int)result]);
    completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}

#pragma mark Conta

- (void)start {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *user = [d stringForKey:@"RAUser"], *token = [d stringForKey:@"RAToken"];
    if (!user.length || !token.length) return;
    self.status = @"Signing in…";
    rc_client_begin_login_with_token(rf_client, user.UTF8String, token.UTF8String, rf_login_done, NULL);
}

static void (^rf_login_completion)(NSString *error);

static void rf_login_done(int result, const char *error_message, rc_client_t *client, void *userdata) {
    RFAchievements *ra = [RFAchievements shared];
    NSString *err = nil;
    const rc_client_user_t *user = rc_client_get_user_info(client);
    if (result == RC_OK && user) {
        ra.loggedIn = YES;
        ra.userName = [NSString stringWithUTF8String:user->display_name ?: user->username];
        ra.score = user->score_softcore + user->score;
        ra.status = nil;
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:[NSString stringWithUTF8String:user->username] forKey:@"RAUser"];
        [d setObject:[NSString stringWithUTF8String:user->token] forKey:@"RAToken"];
        // Se um jogo já estava aberto, carrega as conquistas dele agora
        if (ra.pendingPath) [ra identifyGame];
    } else {
        err = error_message ? [NSString stringWithUTF8String:error_message] : @"Could not sign in.";
        ra.loggedIn = NO;
        ra.status = err;
        RFAppendLog(@"ra.txt", [@"login failed: " stringByAppendingString:err]);
        if (result == RC_INVALID_CREDENTIALS || result == RC_EXPIRED_TOKEN || result == RC_ACCESS_DENIED) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"RAToken"];
        }
    }
    void (^done)(NSString *) = rf_login_completion;
    rf_login_completion = nil;
    if (done) done(err);
    [[NSNotificationCenter defaultCenter] postNotificationName:RFAchievementsChanged object:nil];
}

- (void)loginWithUser:(NSString *)user password:(NSString *)password completion:(void (^)(NSString *))completion {
    rf_login_completion = [completion copy];
    self.status = @"Signing in…";
    rc_client_begin_login_with_password(rf_client, user.UTF8String, password.UTF8String, rf_login_done, NULL);
}

- (void)logout {
    rc_client_logout(rf_client);
    self.loggedIn = NO;
    self.userName = nil;
    self.status = nil;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"RAToken"];
    [[NSNotificationCenter defaultCenter] postNotificationName:RFAchievementsChanged object:nil];
}

#pragma mark Jogo

- (void)gameLoadedAtPath:(NSString *)path console:(uint32_t)console patched:(BOOL)patched {
    [self gameUnloaded];
    [RFCloud shared].gameRunning = YES;
    rc_libretro_memory_init(&rf_regions, rf_mmap.num_descriptors ? &rf_mmap : NULL, rf_core_memory_info, console);
    self.memoryReady = YES;
    self.pendingPath = path;
    self.pendingConsole = console;
    self.patchedGame = patched;
    self.idleTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(idleTick) userInfo:nil repeats:YES];
    if (self.loggedIn) [self identifyGame];
}

- (void)identifyGame {
    if (!self.pendingPath) return;
    NSString *ext = self.pendingPath.pathExtension.lowercaseString;
    if (self.pendingConsole == RC_CONSOLE_PLAYSTATION && ([ext isEqualToString:@"chd"] || [ext isEqualToString:@"pbp"])) {
        [self toastTitle:@"Achievements need .cue/.bin" detail:@"RetroAchievements can't identify .chd or .pbp discs here yet" badge:nil];
        return;
    }
    if (self.patchedGame) {
        [self toastTitle:@"Achievements off" detail:@"This ROM has a patch applied, so it can't be identified" badge:nil];
        return;
    }
    rc_client_begin_identify_and_load_game(rf_client, self.pendingConsole, self.pendingPath.fileSystemRepresentation, NULL, 0, rf_game_loaded, NULL);
}

static void rf_game_loaded(int result, const char *error_message, rc_client_t *client, void *userdata) {
    RFAchievements *ra = [RFAchievements shared];
    const rc_client_game_t *game = rc_client_get_game_info(client);
    if (result == RC_OK && game) {
        ra.gameTitle = [NSString stringWithUTF8String:game->title ?: ""];
        NSMutableArray *played = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"RAPlayedGames"] mutableCopy] ?: [NSMutableArray array];
        [played removeObject:@(game->id)];
        [played insertObject:@(game->id) atIndex:0];
        if (played.count > 200) [played removeLastObject];
        [[NSUserDefaults standardUserDefaults] setObject:played forKey:@"RAPlayedGames"];
        rc_client_user_game_summary_t s;
        rc_client_get_user_game_summary(client, &s);
        NSString *detail;
        if (s.num_core_achievements == 0) {
            detail = @"This game has no achievements yet";
        } else {
            detail = [NSString stringWithFormat:@"%u of %u achievements · %u of %u points",
                      s.num_unlocked_achievements, s.num_core_achievements, s.points_unlocked, s.points_core];
        }
        char url[256];
        NSString *icon = rc_client_game_get_image_url(game, url, sizeof(url)) == RC_OK ? [NSString stringWithUTF8String:url] : nil;
        [ra toastTitle:ra.gameTitle detail:detail badgeURL:icon];
    } else if (result == RC_NO_GAME_LOADED) {
        RFAppendLog(@"ra.txt", @"game not recognized (hash unknown)");
        [ra toastTitle:@"No achievements for this ROM" detail:@"RetroAchievements doesn't recognize this version of the game" badge:nil];
    } else {
        NSString *err = error_message ? [NSString stringWithUTF8String:error_message] : @"Unknown error";
        RFAppendLog(@"ra.txt", [@"load game failed: " stringByAppendingString:err]);
        [ra toastTitle:@"Achievements unavailable" detail:err badge:nil];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:RFAchievementsChanged object:nil];
}

- (void)gameUnloaded {
    if ([RFCloud shared].gameRunning) [RFCloud shared].gameRunning = NO;
    [self.idleTimer invalidate];
    self.idleTimer = nil;
    if (rc_client_is_game_loaded(rf_client)) rc_client_unload_game(rf_client);
    if (self.memoryReady) rc_libretro_memory_destroy(&rf_regions);
    self.memoryReady = NO;
    self.pendingPath = nil;
    self.gameTitle = nil;
}

// Troca de disco (jogos de vários CDs): o RetroAchievements confere se o disco novo é do mesmo jogo
static void rf_media_changed(int result, const char *error_message, rc_client_t *client, void *userdata) {
    if (result != RC_OK) {
        RFAppendLog(@"ra.txt", [NSString stringWithFormat:@"change media: %d %s", result, error_message ?: ""]);
        [[RFAchievements shared] toastTitle:@"Disc not recognized" detail:@"Achievements are paused until a disc of this game is inserted" badge:nil];
    }
}

- (void)changeMediaToPath:(NSString *)path {
    if (![self gameActive] || !path) return;
    rc_client_begin_identify_and_change_media(rf_client, path.fileSystemRepresentation, NULL, 0, rf_media_changed, NULL);
}

- (BOOL)gameActive {
    return rc_client_is_game_loaded(rf_client) != 0;
}

- (void)doFrame {
    if (!self.memoryReady) return;
    self.lastFrameAt = CACurrentMediaTime();
    rc_client_do_frame(rf_client);
}

// Jogo pausado (menu aberto, segundo plano): mantém o "online" e reenvia o que ficou pendente
- (void)idleTick {
    if (CACurrentMediaTime() - self.lastFrameAt > 0.5) rc_client_idle(rf_client);
}

- (void)reset {
    if (self.memoryReady) rc_client_reset(rf_client);
}

- (NSData *)progress {
    if (![self gameActive]) return nil;
    size_t n = rc_client_progress_size(rf_client);
    if (!n) return nil;
    NSMutableData *d = [NSMutableData dataWithLength:n];
    if (rc_client_serialize_progress_sized(rf_client, d.mutableBytes, n) != RC_OK) return nil;
    return d;
}

- (void)restoreProgress:(NSData *)data {
    if (![self gameActive]) return;
    rc_client_deserialize_progress_sized(rf_client, data.bytes, data.length);
}

- (NSArray *)achievementSections {
    NSMutableArray *sections = [NSMutableArray array];
    if (![self gameActive]) return sections;
    rc_client_achievement_list_t *list = rc_client_create_achievement_list(rf_client, RC_CLIENT_ACHIEVEMENT_CATEGORY_CORE,
                                                                           RC_CLIENT_ACHIEVEMENT_LIST_GROUPING_PROGRESS);
    if (!list) return sections;
    for (uint32_t b = 0; b < list->num_buckets; b++) {
        const rc_client_achievement_bucket_t *bucket = &list->buckets[b];
        NSMutableArray *items = [NSMutableArray array];
        for (uint32_t i = 0; i < bucket->num_achievements; i++) {
            const rc_client_achievement_t *a = bucket->achievements[i];
            BOOL unlocked = (a->unlocked & RC_CLIENT_ACHIEVEMENT_UNLOCKED_BOTH) != 0;
            const char *badge = unlocked ? a->badge_url : a->badge_locked_url;
            [items addObject:@{
                @"title": [NSString stringWithUTF8String:a->title ?: ""],
                @"description": [NSString stringWithUTF8String:a->description ?: ""],
                @"points": @(a->points),
                @"unlocked": @(unlocked),
                @"progress": [NSString stringWithUTF8String:a->measured_progress],
                @"badge": badge ? [NSString stringWithUTF8String:badge] : @"",
            }];
        }
        [sections addObject:@{ @"label": [NSString stringWithUTF8String:bucket->label ?: ""], @"items": items }];
    }
    rc_client_destroy_achievement_list(list);
    return sections;
}

- (NSString *)gameSummary {
    if (![self gameActive]) return nil;
    rc_client_user_game_summary_t s;
    rc_client_get_user_game_summary(rf_client, &s);
    return [NSString stringWithFormat:@"%u of %u unlocked · %u of %u points · Casual mode",
            s.num_unlocked_achievements, s.num_core_achievements, s.points_unlocked, s.points_core];
}

#pragma mark Eventos

static void rf_event_handler(const rc_client_event_t *event, rc_client_t *client) {
    RFAchievements *ra = [RFAchievements shared];
    const rc_client_achievement_t *a = event->achievement;
    switch (event->type) {
        case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED:
            [ra toastTitle:[NSString stringWithFormat:@"%s  ·  %u pts", a->title, a->points]
                    detail:[NSString stringWithUTF8String:a->description ?: ""]
                  badgeURL:a->badge_url ? [NSString stringWithUTF8String:a->badge_url] : nil
                    header:@"ACHIEVEMENT UNLOCKED"];
            [[NSNotificationCenter defaultCenter] postNotificationName:RFAchievementsChanged object:nil];
            break;
        case RC_CLIENT_EVENT_GAME_COMPLETED:
            [ra toastTitle:ra.gameTitle ?: @"Game" detail:@"Every achievement unlocked!" badgeURL:nil header:@"GAME COMPLETED"];
            break;
        // Progresso ("5/10 rings") e início/falha de leaderboard não aparecem: só conquistas completas
        case RC_CLIENT_EVENT_LEADERBOARD_SUBMITTED:
            [ra toastTitle:[NSString stringWithUTF8String:event->leaderboard->title ?: ""]
                    detail:[NSString stringWithFormat:@"Submitted: %s", event->leaderboard->tracker_value]
                  badgeURL:nil header:@"LEADERBOARD"];
            break;
        case RC_CLIENT_EVENT_RESET:
            [[RFCore shared] reset];
            break;
        case RC_CLIENT_EVENT_SERVER_ERROR:
            RFAppendLog(@"ra.txt", [NSString stringWithFormat:@"server error %s: %s", event->server_error->api, event->server_error->error_message]);
            [ra toastTitle:@"RetroAchievements error" detail:[NSString stringWithUTF8String:event->server_error->error_message ?: ""] badgeURL:nil header:nil];
            break;
        case RC_CLIENT_EVENT_DISCONNECTED:
            [ra toastTitle:@"Offline" detail:@"Unlocks will be sent when the connection returns" badgeURL:nil header:nil];
            break;
        case RC_CLIENT_EVENT_RECONNECTED:
            [ra toastTitle:@"Back online" detail:@"Pending unlocks were sent" badgeURL:nil header:nil];
            break;
        default:
            break;
    }
}

#pragma mark Consultas para as telas (fora do jogo)

- (void)sendRequest:(rc_api_request_t *)request completion:(void (^)(const rc_api_server_response_t *res))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:request->url]];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.timeoutInterval = 30;
    [r setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];
    if (request->post_data) {
        r.HTTPMethod = @"POST";
        r.HTTPBody = [NSData dataWithBytes:request->post_data length:strlen(request->post_data)];
        [r setValue:request->content_type ? [NSString stringWithUTF8String:request->content_type] : @"application/x-www-form-urlencoded"
          forHTTPHeaderField:@"Content-Type"];
    }
    [[self.session dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            rc_api_server_response_t res;
            memset(&res, 0, sizeof(res));
            res.http_status_code = error ? RC_API_SERVER_RESPONSE_CLIENT_ERROR : (int)((NSHTTPURLResponse *)response).statusCode;
            res.body = data.bytes;
            res.body_length = data.length;
            completion(&res);
        });
    }] resume];
}

static NSDictionary *rf_item(const char *title, const char *desc, uint32_t points, BOOL unlocked, const char *progress, const char *badge) {
    return @{
        @"title": [NSString stringWithUTF8String:title ?: ""],
        @"description": [NSString stringWithUTF8String:desc ?: ""],
        @"points": @(points),
        @"unlocked": @(unlocked),
        @"progress": [NSString stringWithUTF8String:progress ?: ""],
        @"badge": badge ? [NSString stringWithUTF8String:badge] : @"",
    };
}

// Conquistas de um jogo qualquer (lista do site + quais o usuário já tem, em qualquer modo)
- (void)fetchGame:(uint32_t)gameId completion:(void (^)(NSDictionary *info, NSString *error))completion {
    const rc_client_user_t *user = rc_client_get_user_info(rf_client);
    if (!user) { completion(nil, @"Sign in first."); return; }
    NSString *username = [NSString stringWithUTF8String:user->username];
    NSString *token = [NSString stringWithUTF8String:user->token];
    rc_api_fetch_game_data_request_t gp;
    memset(&gp, 0, sizeof(gp));
    gp.username = username.UTF8String;
    gp.api_token = token.UTF8String;
    gp.game_id = gameId;
    rc_api_request_t req;
    if (rc_api_init_fetch_game_data_request(&req, &gp) != RC_OK) { completion(nil, @"Invalid request."); return; }
    [self sendRequest:&req completion:^(const rc_api_server_response_t *res) {
        rc_api_fetch_game_data_response_t game;
        int r = rc_api_process_fetch_game_data_server_response(&game, res);
        if (r != RC_OK || !game.response.succeeded) {
            NSString *err = game.response.error_message ? [NSString stringWithUTF8String:game.response.error_message] : @"Could not load the game.";
            rc_api_destroy_fetch_game_data_response(&game);
            completion(nil, err);
            return;
        }
        NSMutableArray *defs = [NSMutableArray array];
        for (uint32_t i = 0; i < game.num_achievements; i++) {
            const rc_api_achievement_definition_t *a = &game.achievements[i];
            if (a->category != RC_ACHIEVEMENT_CATEGORY_CORE) continue;
            [defs addObject:@{ @"id": @(a->id), @"title": [NSString stringWithUTF8String:a->title ?: ""],
                               @"description": [NSString stringWithUTF8String:a->description ?: ""], @"points": @(a->points),
                               @"badge": a->badge_url ? [NSString stringWithUTF8String:a->badge_url] : @"",
                               @"locked": a->badge_locked_url ? [NSString stringWithUTF8String:a->badge_locked_url] : @"" }];
        }
        NSString *title = [NSString stringWithUTF8String:game.title ?: ""];
        NSString *icon = game.image_url ? [NSString stringWithUTF8String:game.image_url] : @"";
        rc_api_destroy_fetch_game_data_response(&game);
        // Desbloqueios: Casual e Hardcore
        NSMutableSet *unlocked = [NSMutableSet set];
        __block int pending = 2;
        void (^finish)(void) = ^{
            if (--pending) return;
            NSMutableArray *got = [NSMutableArray array], *missing = [NSMutableArray array];
            uint32_t pts = 0, total = 0;
            for (NSDictionary *d in defs) {
                BOOL on = [unlocked containsObject:d[@"id"]];
                total += [d[@"points"] unsignedIntValue];
                if (on) pts += [d[@"points"] unsignedIntValue];
                [(on ? got : missing) addObject:rf_item([d[@"title"] UTF8String], [d[@"description"] UTF8String], [d[@"points"] unsignedIntValue],
                                                        on, "", [(on ? d[@"badge"] : d[@"locked"]) UTF8String])];
            }
            NSMutableArray *sections = [NSMutableArray array];
            if (got.count) [sections addObject:@{ @"label": @"Unlocked", @"items": got }];
            if (missing.count) [sections addObject:@{ @"label": @"Locked", @"items": missing }];
            NSString *summary = defs.count ? [NSString stringWithFormat:@"%lu of %lu unlocked · %u of %u points",
                                              (unsigned long)got.count, (unsigned long)defs.count, pts, total]
                                           : @"This game has no achievements yet";
            completion(@{ @"title": title, @"icon": icon, @"sections": sections, @"summary": summary }, nil);
        };
        for (uint32_t hc = 0; hc < 2; hc++) {
            rc_api_fetch_user_unlocks_request_t up;
            memset(&up, 0, sizeof(up));
            up.username = username.UTF8String;
            up.api_token = token.UTF8String;
            up.game_id = gameId;
            up.hardcore = hc;
            rc_api_request_t ureq;
            if (rc_api_init_fetch_user_unlocks_request(&ureq, &up) != RC_OK) { finish(); continue; }
            [self sendRequest:&ureq completion:^(const rc_api_server_response_t *ures) {
                rc_api_fetch_user_unlocks_response_t u;
                if (rc_api_process_fetch_user_unlocks_server_response(&u, ures) == RC_OK && u.response.succeeded) {
                    for (uint32_t k = 0; k < u.num_achievement_ids; k++) [unlocked addObject:@(u.achievement_ids[k])];
                }
                rc_api_destroy_fetch_user_unlocks_response(&u);
                finish();
            }];
            rc_api_destroy_request(&ureq);
        }
    }];
    rc_api_destroy_request(&req);
}

typedef void (^RFProgressBlock)(rc_client_all_user_progress_t *list);
typedef void (^RFTitlesBlock)(rc_client_game_title_list_t *list);

static void rf_progress_done(int result, const char *error_message, rc_client_all_user_progress_t *list, rc_client_t *client, void *ud) {
    RFProgressBlock b = (__bridge_transfer RFProgressBlock)ud;
    b(result == RC_OK ? list : NULL);
    if (list) rc_client_destroy_all_user_progress(list);
}

static void rf_titles_done(int result, const char *error_message, rc_client_game_title_list_t *list, rc_client_t *client, void *ud) {
    RFTitlesBlock b = (__bridge_transfer RFTitlesBlock)ud;
    b(result == RC_OK ? list : NULL);
    if (list) rc_client_destroy_game_title_list(list);
}

// Jogos do usuário nos consoles deste emulador: os que têm desbloqueios e os já abertos aqui
- (void)fetchMyGames:(void (^)(NSArray *games, NSString *error))completion {
    if (!self.loggedIn) { completion(nil, @"Sign in first."); return; }
    NSArray *consoles = RFAchievementsConsoles();
    NSMutableDictionary *byId = [NSMutableDictionary dictionary];
    NSArray *played = [[NSUserDefaults standardUserDefaults] arrayForKey:@"RAPlayedGames"] ?: @[];
    __block NSUInteger pending = consoles.count;
    void (^titles)(void) = ^{
        NSMutableArray *ids = [NSMutableArray array];
        for (NSNumber *gid in byId) [ids addObject:gid];
        if (!ids.count) { completion(@[], nil); return; }
        uint32_t *buf = calloc(ids.count, sizeof(uint32_t));
        for (NSUInteger i = 0; i < ids.count; i++) buf[i] = [ids[i] unsignedIntValue];
        RFTitlesBlock tb = ^(rc_client_game_title_list_t *list) {
            for (uint32_t i = 0; list && i < list->num_entries; i++) {
                NSMutableDictionary *g = byId[@(list->entries[i].game_id)];
                g[@"title"] = [NSString stringWithUTF8String:list->entries[i].title ?: ""];
                if (list->entries[i].badge_url) g[@"icon"] = [NSString stringWithUTF8String:list->entries[i].badge_url];
            }
            NSArray *games = [byId.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                NSUInteger ia = [played indexOfObject:a[@"id"]], ib = [played indexOfObject:b[@"id"]];
                if (ia != ib) return ia < ib ? NSOrderedAscending : NSOrderedDescending;   // abertos aqui primeiro, do mais recente
                return [a[@"title"] ?: @"" localizedCaseInsensitiveCompare:b[@"title"] ?: @""];
            }];
            completion(games, nil);
        };
        rc_client_begin_fetch_game_titles(rf_client, buf, (uint32_t)ids.count, rf_titles_done, (__bridge_retained void *)[tb copy]);
        free(buf);
    };
    for (NSDictionary *c in consoles) {
        uint32_t consoleId = [c[@"id"] unsignedIntValue];
        NSString *consoleName = c[@"name"];
        RFProgressBlock pb = ^(rc_client_all_user_progress_t *list) {
            for (uint32_t i = 0; list && i < list->num_entries; i++) {
                const rc_client_all_user_progress_entry_t *e = &list->entries[i];
                uint32_t got = MAX(e->num_unlocked_achievements, e->num_unlocked_achievements_hardcore);
                if (!got && ![played containsObject:@(e->game_id)]) continue;
                byId[@(e->game_id)] = [@{ @"id": @(e->game_id), @"total": @(e->num_achievements), @"unlocked": @(got),
                                          @"console": consoleName } mutableCopy];
            }
            if (--pending == 0) titles();
        };
        rc_client_begin_fetch_all_user_progress(rf_client, consoleId, rf_progress_done, (__bridge_retained void *)[pb copy]);
    }
}

#pragma mark Imagens (ícones das conquistas)

- (void)imageForURL:(NSString *)urlString completion:(void (^)(UIImage *))completion {
    if (!urlString.length) { completion(nil); return; }
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"retroachievements"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *file = [dir stringByAppendingPathComponent:[[urlString componentsSeparatedByString:@"/"] componentsJoinedByString:@"_"]];
    UIImage *cached = [UIImage imageWithContentsOfFile:file];
    if (cached) { completion(cached); return; }
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    [r setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];
    [[self.session dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *img = data ? [UIImage imageWithData:data] : nil;
        if (img) [data writeToFile:file atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(img); });
    }] resume];
}

#pragma mark Avisos na tela

- (void)toastTitle:(NSString *)title detail:(NSString *)detail badge:(UIImage *)badge {
    [self toastTitle:title detail:detail badgeURL:nil header:nil];
}

- (void)toastTitle:(NSString *)title detail:(NSString *)detail badgeURL:(NSString *)badge {
    [self toastTitle:title detail:detail badgeURL:badge header:nil];
}

- (void)toastTitle:(NSString *)title detail:(NSString *)detail badgeURL:(NSString *)badge header:(NSString *)header {
    NSMutableDictionary *t = [NSMutableDictionary dictionary];
    t[@"title"] = title ?: @"";
    if (detail.length) t[@"detail"] = detail;
    if (badge.length) t[@"badge"] = badge;
    if (header.length) t[@"header"] = header;
    if (self.toastQueue.count > 6) return;   // não acumula avisos demais
    [self.toastQueue addObject:t];
    if (!self.toastView) [self showNextToast];
}

// Ícone do cache (ou baixado) já decodificado, fora da thread principal
- (UIImage *)decodedImageForURL:(NSString *)urlString {
    if (!urlString.length) return nil;
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"retroachievements"];
    NSString *file = [dir stringByAppendingPathComponent:[[urlString componentsSeparatedByString:@"/"] componentsJoinedByString:@"_"]];
    NSData *data = [NSData dataWithContentsOfFile:file];
    if (!data) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSData *got = nil;
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        r.timeoutInterval = 5;
        [r setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];
        [[self.session dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *res, NSError *e) {
            got = d;
            dispatch_semaphore_signal(sem);
        }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
        data = got;
        if (data && [UIImage imageWithData:data]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            [data writeToFile:file atomically:YES];
        }
    }
    return data ? [UIImage imageWithData:data] : nil;
}

// O aviso inteiro vira uma imagem só, desenhada em segundo plano: na tela fica uma única camada
// opaca nas bordas certas, animada por transformação (sem recortes nem redesenho a cada quadro),
// para não roubar tempo do jogo enquanto desliza.
- (UIImage *)renderToast:(NSDictionary *)t width:(CGFloat)w height:(CGFloat)h {
    UIImage *badge = [self decodedImageForURL:t[@"badge"]];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, [UIScreen mainScreen].scale);
    CGContextRef g = UIGraphicsGetCurrentContext();
    UIBezierPath *box = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, w - 2, h - 2) cornerRadius:12];
    [[UIColor colorWithWhite:0.06 alpha:0.94] setFill];
    [box fill];
    // Cor de destaque do app, clareada para ler bem sobre o fundo escuro do aviso
    CGFloat r = 0, gg = 0, b = 0, al = 0;
    [RFThemeRed() getRed:&r green:&gg blue:&b alpha:&al];
    UIColor *accent = [UIColor colorWithRed:r + (1 - r) * 0.35 green:gg + (1 - gg) * 0.35 blue:b + (1 - b) * 0.35 alpha:1];
    [accent setStroke];
    box.lineWidth = 1.5;
    [box stroke];
    CGFloat x = 16;
    if (t[@"badge"]) {
        CGRect r = CGRectMake(12, 12, 60, 60);
        CGContextSaveGState(g);
        [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:6] addClip];
        [[UIColor colorWithWhite:0.15 alpha:1] setFill];
        UIRectFill(r);
        [badge drawInRect:r];
        CGContextRestoreGState(g);
        x = 84;
    }
    NSMutableParagraphStyle *clip = [[NSMutableParagraphStyle alloc] init];
    clip.lineBreakMode = NSLineBreakByTruncatingTail;
    [(t[@"header"] ?: @"RETROACHIEVEMENTS") drawInRect:CGRectMake(x, 10, w - x - 12, 16)
        withAttributes:@{NSFontAttributeName: RFThemeLabelFont(11), NSForegroundColorAttributeName: accent, NSParagraphStyleAttributeName: clip}];
    [t[@"title"] drawInRect:CGRectMake(x, 26, w - x - 12, 26)
        withAttributes:@{NSFontAttributeName: RFThemeDisplayFont(19), NSForegroundColorAttributeName: [UIColor whiteColor], NSParagraphStyleAttributeName: clip}];
    if (t[@"detail"]) {
        [t[@"detail"] drawInRect:CGRectMake(x, 53, w - x - 12, 20)
            withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [UIColor colorWithWhite:0.8 alpha:1], NSParagraphStyleAttributeName: clip}];
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)showNextToast {
    if (!self.toastQueue.count) return;
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;
    NSDictionary *t = self.toastQueue.firstObject;
    [self.toastQueue removeObjectAtIndex:0];
    CGFloat w = MIN(window.bounds.size.width - 40, 520), h = 84;
    UIImageView *view = [[UIImageView alloc] init];
    view.userInteractionEnabled = NO;
    self.toastView = view;   // reserva a vez enquanto o aviso é desenhado
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        UIImage *img = [self renderToast:t width:w height:h];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *win = [UIApplication sharedApplication].keyWindow;
            if (!win || !img) {
                self.toastView = nil;
                [self showNextToast];
                return;
            }
            view.image = img;
            view.frame = CGRectMake(floor((win.bounds.size.width - w) / 2), 20, w, h);
            view.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
            view.transform = CGAffineTransformMakeTranslation(0, -h - 30);
            [win addSubview:view];
            [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                view.transform = CGAffineTransformIdentity;
            } completion:^(BOOL finished) {
                [UIView animateWithDuration:0.3 delay:3.5 options:UIViewAnimationOptionCurveEaseIn animations:^{
                    view.transform = CGAffineTransformMakeTranslation(0, -h - 30);
                } completion:^(BOOL f) {
                    [view removeFromSuperview];
                    self.toastView = nil;
                    [self showNextToast];
                }];
            }];
        });
    });
}

@end

#pragma mark - Tela: conta

@interface RFAchievementsAccountViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *userField;
@property (nonatomic, strong) UITextField *passField;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation RFAchievementsAccountViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"RetroAchievements";
    UIView *grid = RFThemeGridView();
    grid.frame = self.view.bounds;
    grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:grid];

    self.userField = [self field:@"Username" secure:NO];
    self.passField = [self field:@"Password" secure:YES];
    self.button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.button.titleLabel.font = RFThemeDisplayFont(20);
    self.button.backgroundColor = RFThemeCard();
    self.button.layer.cornerRadius = 8;
    self.button.layer.borderWidth = 1.5;
    self.button.layer.borderColor = RFThemeRed().CGColor;
    [self.button addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.button];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];
    self.infoLabel = [[UILabel alloc] init];
    self.infoLabel.numberOfLines = 0;
    self.infoLabel.textAlignment = NSTextAlignmentCenter;
    self.infoLabel.font = [UIFont systemFontOfSize:15];
    self.infoLabel.textColor = RFThemeDim();
    [self.view addSubview:self.infoLabel];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:RFAchievementsChanged object:nil];
    [self refresh];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UITextField *)field:(NSString *)placeholder secure:(BOOL)secure {
    UITextField *f = [[UITextField alloc] init];
    f.placeholder = placeholder;
    f.secureTextEntry = secure;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.font = [UIFont systemFontOfSize:18];
    f.returnKeyType = secure ? UIReturnKeyGo : UIReturnKeyNext;
    f.delegate = self;
    [self.view addSubview:f];
    return f;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.userField) [self.passField becomeFirstResponder];
    else [self buttonTapped];
    return YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat W = self.view.bounds.size.width, w = MIN(W - 40, 420), x = floor((W - w) / 2);
    CGFloat y = self.topLayoutGuide.length + 30;
    self.userField.frame = CGRectMake(x, y, w, 44);
    self.passField.frame = CGRectMake(x, y + 54, w, 44);
    BOOL in = [RFAchievements shared].loggedIn;
    CGFloat by = in ? y : y + 118;
    self.button.frame = CGRectMake(x, by, w, 48);
    self.spinner.center = CGPointMake(x + w - 24, by + 24);
    self.infoLabel.frame = CGRectMake(x - 20, by + 64, w + 40, 220);
}

- (void)refresh {
    RFAchievements *ra = [RFAchievements shared];
    BOOL in = ra.loggedIn;
    self.userField.hidden = self.passField.hidden = in;
    [self.button setTitle:in ? @"Sign out" : @"Sign in" forState:UIControlStateNormal];
    NSString *casual = @"Achievements unlock in Casual mode: this emulator isn't approved for Hardcore yet. "
                       @"Save states stay available. Only original, unmodified ROMs are recognized.";
    if (in) {
        self.infoLabel.text = [NSString stringWithFormat:@"Signed in as %@ · %u points\n\n%@", ra.userName, ra.score, casual];
    } else {
        NSString *s = ra.status.length ? [ra.status stringByAppendingString:@"\n\n"] : @"";
        self.infoLabel.text = [NSString stringWithFormat:@"%@Sign in with your retroachievements.org account. "
                               @"The password is only used to get a sign-in token and is not stored.\n\n%@", s, casual];
    }
    [self.view setNeedsLayout];
}

- (void)buttonTapped {
    RFAchievements *ra = [RFAchievements shared];
    if (ra.loggedIn) {
        [ra logout];
        return;
    }
    if (!self.userField.text.length || !self.passField.text.length) return;
    [self.view endEditing:YES];
    self.button.enabled = NO;
    [self.spinner startAnimating];
    __weak RFAchievementsAccountViewController *weakSelf = self;
    [ra loginWithUser:self.userField.text password:self.passField.text completion:^(NSString *error) {
        weakSelf.passField.text = @"";
        weakSelf.button.enabled = YES;
        [weakSelf.spinner stopAnimating];
        [weakSelf refresh];
    }];
}

@end

#pragma mark - Tela: conquistas do jogo

@interface RFAchievementsListViewController ()
@property (nonatomic, strong) NSArray *sections;
@end

@implementation RFAchievementsListViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    RFAchievements *ra = [RFAchievements shared];
    RFThemeApplyTable(self.tableView);
    self.tableView.rowHeight = 76;
    UILabel *head = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    head.textAlignment = NSTextAlignmentCenter;
    head.font = RFThemeLabelFont(14);
    head.textColor = RFThemeDim();
    self.tableView.tableHeaderView = head;
    if (self.gameId) {
        // Aberta pela tela de conquistas: busca no site
        self.title = self.gameTitle ?: @"Achievements";
        head.text = @"Loading…";
        __weak RFAchievementsListViewController *weakSelf = self;
        [ra fetchGame:self.gameId completion:^(NSDictionary *info, NSString *error) {
            RFAchievementsListViewController *s = weakSelf;
            if (!s) return;
            head.text = error ?: info[@"summary"];
            if (info) {
                s.title = info[@"title"];
                s.sections = info[@"sections"];
                [s.tableView reloadData];
            }
        }];
        return;
    }
    self.title = ra.gameTitle ?: @"Achievements";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self action:@selector(done)];
    self.sections = [ra achievementSections];
    head.text = !ra.loggedIn ? @"Sign in to RetroAchievements in the Achievements screen of the menu" :
                [ra gameActive] ? [ra gameSummary] : @"No achievements for this game";
}

- (void)done {
    void (^cb)(void) = self.onDone;
    [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(); }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sections[section][@"label"];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.sections[section][@"items"] count];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    RFThemeStyleHeaderFooter(view, YES);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"a"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"a"];
        RFThemeStyleCell(cell);
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.detailTextLabel.numberOfLines = 2;
        cell.imageView.layer.cornerRadius = 5;
        cell.imageView.clipsToBounds = YES;
    }
    NSDictionary *a = self.sections[indexPath.section][@"items"][indexPath.row];
    BOOL unlocked = [a[@"unlocked"] boolValue];
    cell.textLabel.text = [NSString stringWithFormat:@"%@  ·  %@ pts", a[@"title"], a[@"points"]];
    NSString *progress = [a[@"progress"] length] && !unlocked ? [NSString stringWithFormat:@"  (%@)", a[@"progress"]] : @"";
    cell.detailTextLabel.text = [a[@"description"] stringByAppendingString:progress];
    cell.textLabel.alpha = unlocked ? 1.0 : 0.75;
    // Espaço reservado do tamanho do ícone até a imagem chegar
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(56, 56), NO, 0);
    [[UIColor colorWithWhite:0.15 alpha:1] setFill];
    UIRectFill(CGRectMake(0, 0, 56, 56));
    cell.imageView.image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSString *badge = a[@"badge"];
    cell.tag = badge.hash;
    __weak UITableViewCell *weakCell = cell;
    [[RFAchievements shared] imageForURL:badge completion:^(UIImage *img) {
        if (!img || weakCell.tag != (NSInteger)badge.hash) return;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(56, 56), NO, 0);
        [img drawInRect:CGRectMake(0, 0, 56, 56)];
        weakCell.imageView.image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        [weakCell setNeedsLayout];
    }];
    return cell;
}

@end

#pragma mark - Tela: conquistas (menu lateral)

@interface RFAchievementsHomeViewController ()
@property (nonatomic, strong) NSArray *games;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, assign) BOOL loading;
@end

@implementation RFAchievementsHomeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Achievements";
    RFThemeApplyTable(self.tableView);
    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    rc.tintColor = RFThemeRed();
    [rc addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:RFAchievementsChanged object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    RFAchievements *ra = [RFAchievements shared];
    if (!ra.loggedIn) {
        self.games = nil;
        self.message = ra.status ?: @"Sign in to see your achievements";
        [self.refreshControl endRefreshing];
        [self.tableView reloadData];
        return;
    }
    if (self.loading) return;
    self.loading = YES;
    if (!self.games) self.message = @"Loading your games…";
    [self.tableView reloadData];
    __weak RFAchievementsHomeViewController *weakSelf = self;
    [ra fetchMyGames:^(NSArray *games, NSString *error) {
        RFAchievementsHomeViewController *s = weakSelf;
        if (!s) return;
        s.loading = NO;
        [s.refreshControl endRefreshing];
        s.games = games;
        s.message = error ?: (games.count ? nil : @"No achievements yet. Open a game with achievements to start!");
        [s.tableView reloadData];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"RetroAchievements account" : @"Your games";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 1 ? self.message : nil;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    RFThemeStyleHeaderFooter(view, YES);
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    RFThemeStyleHeaderFooter(view, NO);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : self.games.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 ? 64 : 76;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *rid = indexPath.section == 0 ? @"acct" : @"game";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
        RFThemeStyleCell(cell);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.font = RFThemeDisplayFont(20);
    }
    RFAchievements *ra = [RFAchievements shared];
    if (indexPath.section == 0) {
        cell.textLabel.text = ra.loggedIn ? ra.userName : @"Sign in";
        cell.detailTextLabel.text = ra.loggedIn ? [NSString stringWithFormat:@"%u points · tap to sign out", ra.score]
                                                : @"Use your retroachievements.org account";
        cell.imageView.image = nil;
        return cell;
    }
    NSDictionary *g = self.games[indexPath.row];
    uint32_t got = [g[@"unlocked"] unsignedIntValue], total = [g[@"total"] unsignedIntValue];
    cell.textLabel.text = g[@"title"] ?: [NSString stringWithFormat:@"Game %@", g[@"id"]];
    int pct = total ? (int)(got * 100 / total) : 0;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %u of %u achievements · %d%%%@", g[@"console"], got, total, pct,
                                 total && got == total ? @"  ★ Completed" : @""];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(56, 56), NO, 0);
    [[UIColor colorWithWhite:0.15 alpha:1] setFill];
    UIRectFill(CGRectMake(0, 0, 56, 56));
    cell.imageView.image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSString *icon = g[@"icon"];
    cell.tag = icon.hash;
    __weak UITableViewCell *weakCell = cell;
    [ra imageForURL:icon completion:^(UIImage *img) {
        if (!img || weakCell.tag != (NSInteger)icon.hash) return;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(56, 56), NO, 0);
        [img drawInRect:CGRectMake(0, 0, 56, 56)];
        weakCell.imageView.image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        [weakCell setNeedsLayout];
    }];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        [self.navigationController pushViewController:[[RFAchievementsAccountViewController alloc] init] animated:YES];
        return;
    }
    NSDictionary *g = self.games[indexPath.row];
    RFAchievementsListViewController *list = [[RFAchievementsListViewController alloc] init];
    list.gameId = [g[@"id"] unsignedIntValue];
    list.gameTitle = g[@"title"];
    [self.navigationController pushViewController:list animated:YES];
}

@end
