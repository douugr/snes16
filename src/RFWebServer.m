// Servidor HTTP mínimo para enviar ROMs pelo navegador do computador (mesma rede Wi-Fi).
// Só fica ligado enquanto a tela "Enviar ROMs" está aberta.
//
//   GET  /                     página com arrastar-e-soltar
//   GET  /api/list             lista JSON dos arquivos
//   PUT  /api/upload?name=X    corpo = conteúdo do arquivo
//   POST /api/delete?name=X    apaga o arquivo

#import "RF.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <unistd.h>
#include <dns_sd.h>

#define RF_MAX_HEADER 16384
#define RF_MAX_UPLOAD (128u * 1024 * 1024)

@interface RFWebServer ()
@property (nonatomic, readwrite) BOOL running;
@property (nonatomic, readwrite) uint16_t port;
@property (nonatomic, copy) NSString *romsDir;
@property (nonatomic, assign) int listenFd;
@property (nonatomic, readwrite, copy) NSString *accessCode;
@property (nonatomic, readwrite, copy) NSString *hostName;
@property (nonatomic, copy) NSString *pendingName;
@property (nonatomic, assign) int nameAttempt;
@property (nonatomic, assign) DNSServiceRef dnsRef;
@end

@implementation RFWebServer

+ (instancetype)shared {
    static RFWebServer *server;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ server = [[RFWebServer alloc] init]; });
    return server;
}

+ (NSArray<NSString *> *)acceptedExtensions {
    return @[@"sfc", @"smc", @"swc", @"fig", @"gd3", @"gd7", @"dx2", @"bsx", @"ips", @"bps"];
}

+ (NSString *)localIPAddress {
    struct ifaddrs *list = NULL;
    NSString *found = nil;
    if (getifaddrs(&list) != 0) return nil;
    for (struct ifaddrs *i = list; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
        if (!(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK)) continue;
        char buf[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, buf, sizeof(buf));
        NSString *name = [NSString stringWithUTF8String:i->ifa_name];
        if ([name isEqualToString:@"en0"]) {   // Wi-Fi
            found = [NSString stringWithUTF8String:buf];
            break;
        }
    }
    freeifaddrs(list);
    return found;
}

- (BOOL)startOnPort:(uint16_t)port error:(NSString **)error {
    if (self.running) return YES;
    self.romsDir = RFDir(@"roms");
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = @"Could not create the socket.";
        return NO;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 8) != 0) {
        close(fd);
        if (error) *error = [NSString stringWithFormat:@"Port %u is already in use.", port];
        return NO;
    }
    self.listenFd = fd;
    self.port = port;
    self.accessCode = [RFWebServer newAccessCode];
    self.running = YES;
    self.nameAttempt = 1;
    [self registerName];
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(acceptLoop:) object:@(fd)];
    t.name = @"SNES16.WebServer";
    [t start];
    return YES;
}

- (void)stop {
    if (!self.running) return;
    self.running = NO;
    if (self.dnsRef) {
        DNSServiceRefDeallocate(self.dnsRef);
        self.dnsRef = NULL;
    }
    self.hostName = nil;
    shutdown(self.listenFd, SHUT_RDWR);
    close(self.listenFd);
    self.listenFd = -1;
}

// 5 letras/números fáceis de ler (sem 0/o, 1/l/i)
+ (NSString *)newAccessCode {
    static const char alphabet[] = "abcdefghjkmnpqrstuvwxyz23456789";
    char code[6];
    for (int i = 0; i < 5; i++) code[i] = alphabet[arc4random_uniform((uint32_t)(sizeof(alphabet) - 1))];
    code[5] = 0;
    return [NSString stringWithUTF8String:code];
}

#pragma mark Nome na rede (Bonjour / mDNS)

static void rf_record_registered(DNSServiceRef ref, DNSRecordRef rec, DNSServiceFlags flags, DNSServiceErrorType err, void *ctx) {
    [(__bridge RFWebServer *)ctx recordRegistered:err];
}

// Anuncia "<app>.local" apontando para o IP do Wi-Fi; se outro aparelho já usa o nome, tenta <app>-2, -3...
- (void)registerName {
    if (self.dnsRef) {
        DNSServiceRefDeallocate(self.dnsRef);
        self.dnsRef = NULL;
    }
    NSString *ip = [RFWebServer localIPAddress];
    if (!ip) return;
    struct in_addr a;
    if (inet_pton(AF_INET, ip.UTF8String, &a) != 1) return;
    NSString *base = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] lowercaseString] ?: @"ipad";
    NSString *name = self.nameAttempt > 1 ? [NSString stringWithFormat:@"%@-%d.local.", base, self.nameAttempt]
                                          : [base stringByAppendingString:@".local."];
    DNSServiceRef ref = NULL;
    if (DNSServiceCreateConnection(&ref) != kDNSServiceErr_NoError) return;
    DNSRecordRef rec = NULL;
    DNSServiceErrorType e = DNSServiceRegisterRecord(ref, &rec, kDNSServiceFlagsUnique, if_nametoindex("en0"),
                                                     name.UTF8String, kDNSServiceType_A, kDNSServiceClass_IN,
                                                     sizeof(a), &a, 120, rf_record_registered, (__bridge void *)self);
    if (e != kDNSServiceErr_NoError) {
        DNSServiceRefDeallocate(ref);
        return;
    }
    DNSServiceSetDispatchQueue(ref, dispatch_get_main_queue());
    self.dnsRef = ref;
    self.pendingName = [name substringToIndex:name.length - 1];
}

- (void)recordRegistered:(DNSServiceErrorType)err {
    if (!self.running) return;
    if (err == kDNSServiceErr_NameConflict && self.nameAttempt < 9) {
        self.nameAttempt++;
        [self registerName];
        return;
    }
    if (err == kDNSServiceErr_NoError) {
        self.hostName = self.pendingName;
        if (self.onNameChange) self.onNameChange();
    }
}

- (void)acceptLoop:(NSNumber *)fdNumber {
    int listenFd = fdNumber.intValue;
    for (;;) {
        int client = accept(listenFd, NULL, NULL);
        if (client < 0) break;   // servidor parado
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @autoreleasepool {
                [self handleClient:client];
            }
            close(client);
        });
    }
}

#pragma mark Requisições

static BOOL rf_send_all(int fd, const void *data, size_t len) {
    const uint8_t *p = data;
    while (len) {
        ssize_t n = send(fd, p, len, 0);
        if (n <= 0) return NO;
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

static void rf_respond(int fd, int status, NSString *type, NSData *body) {
    NSString *reason = status == 200 ? @"OK" : status == 403 ? @"Forbidden" : status == 400 ? @"Bad Request" : status == 404 ? @"Not Found" : status == 413 ? @"Payload Too Large" : @"Error";
    NSString *head = [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
                      status, reason, type, (unsigned long)body.length];
    NSData *h = [head dataUsingEncoding:NSUTF8StringEncoding];
    if (rf_send_all(fd, h.bytes, h.length) && body.length) rf_send_all(fd, body.bytes, body.length);
}

static void rf_redirect(int fd, NSString *location) {
    NSString *head = [NSString stringWithFormat:@"HTTP/1.1 301 Moved Permanently\r\nLocation: %@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", location];
    NSData *h = [head dataUsingEncoding:NSUTF8StringEncoding];
    rf_send_all(fd, h.bytes, h.length);
}

static void rf_respond_json(int fd, int status, id object) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil] ?: [NSData data];
    rf_respond(fd, status, @"application/json; charset=utf-8", body);
}

static void rf_respond_error(int fd, int status, NSString *message) {
    rf_respond_json(fd, status, @{@"ok": @NO, @"error": message});
}

- (NSString *)nameFromQuery:(NSString *)query {
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        if (![[pair substringToIndex:eq.location] isEqualToString:@"name"]) continue;
        NSString *raw = [[pair substringFromIndex:eq.location + 1] stringByReplacingOccurrencesOfString:@"+" withString:@" "];
        NSString *name = raw.stringByRemovingPercentEncoding.lastPathComponent;
        // Nada de caminhos: só um nome de arquivo simples, com extensão aceita
        if (!name.length || [name hasPrefix:@"."] || [name containsString:@"/"] || [name containsString:@".."]) return nil;
        if (![[RFWebServer acceptedExtensions] containsObject:name.pathExtension.lowercaseString]) return nil;
        return name;
    }
    return nil;
}

- (void)notifyChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onChange) self.onChange();
    });
}

- (void)handleClient:(int)fd {
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct timeval tv = {30, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    // Lê o cabeçalho (até a linha em branco)
    char *buf = malloc(RF_MAX_HEADER + 1);
    size_t used = 0;
    char *headerEnd = NULL;
    while (used < RF_MAX_HEADER) {
        ssize_t n = recv(fd, buf + used, RF_MAX_HEADER - used, 0);
        if (n <= 0) break;
        used += (size_t)n;
        buf[used] = 0;
        if ((headerEnd = strstr(buf, "\r\n\r\n"))) break;
    }
    if (!headerEnd) {
        free(buf);
        return;
    }
    size_t headerLen = (size_t)(headerEnd - buf) + 4;
    NSString *header = [[NSString alloc] initWithBytes:buf length:headerLen encoding:NSUTF8StringEncoding]
                    ?: [[NSString alloc] initWithBytes:buf length:headerLen encoding:NSISOLatin1StringEncoding];
    NSArray *lines = [header componentsSeparatedByString:@"\r\n"];
    NSArray *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
    if (requestLine.count < 2) {
        free(buf);
        rf_respond_error(fd, 400, @"invalid request");
        return;
    }
    NSString *method = requestLine[0];
    NSString *target = requestLine[1];
    NSString *path = target, *query = @"";
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        path = [target substringToIndex:q.location];
        query = [target substringFromIndex:q.location + 1];
    }
    // Tudo fica sob /<código>/: sem o código certo (que só aparece na tela do iPad), nada responde
    NSString *prefix = [@"/" stringByAppendingString:self.accessCode ?: @"-"];
    if ([path isEqualToString:prefix]) {
        rf_redirect(fd, [prefix stringByAppendingString:@"/"]);
        free(buf);
        return;
    }
    if (![path hasPrefix:[prefix stringByAppendingString:@"/"]]) {
        NSString *page = @"<!DOCTYPE html><meta charset=utf-8><meta name=viewport content='width=device-width'>"
                         @"<body style='font:17px -apple-system,Helvetica,sans-serif;padding:40px;text-align:center'>"
                         @"<h2>Wrong or expired address</h2><p>Open the upload screen on the iPad and use the address shown there. "
                         @"The code at the end changes every time the screen opens.</p></body>";
        rf_respond(fd, 403, @"text/html; charset=utf-8", [page dataUsingEncoding:NSUTF8StringEncoding]);
        free(buf);
        return;
    }
    path = [path substringFromIndex:prefix.length];
    unsigned long long contentLength = 0;
    for (NSString *line in lines) {
        if ([line.lowercaseString hasPrefix:@"content-length:"]) {
            contentLength = strtoull([line substringFromIndex:15].UTF8String, NULL, 10);
        }
    }

    if ([method isEqualToString:@"GET"] && ([path isEqualToString:@"/"] || [path isEqualToString:@"/index.html"])) {
        NSString *file = [[NSBundle mainBundle] pathForResource:@"upload" ofType:@"html"];
        NSData *page = file ? [NSData dataWithContentsOfFile:file] : nil;
        if (page) rf_respond(fd, 200, @"text/html; charset=utf-8", page);
        else rf_respond_error(fd, 404, @"page not found");
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/list"]) {
        rf_respond_json(fd, 200, @{@"ok": @YES, @"files": [self listFiles]});
    } else if ([method isEqualToString:@"PUT"] && [path isEqualToString:@"/api/upload"]) {
        NSString *name = [self nameFromQuery:query];
        if (!name) {
            rf_respond_error(fd, 400, @"file name or extension not accepted");
        } else if (contentLength == 0 || contentLength > RF_MAX_UPLOAD) {
            rf_respond_error(fd, 413, @"file empty or too large");
        } else {
            NSString *err = [self receiveFile:name fd:fd length:contentLength initial:buf + headerLen initialLength:used - headerLen];
            if (err) rf_respond_error(fd, 500, err);
            else {
                rf_respond_json(fd, 200, @{@"ok": @YES, @"name": name});
                [self notifyChange];
            }
        }
    } else if (([method isEqualToString:@"POST"] || [method isEqualToString:@"DELETE"]) && [path isEqualToString:@"/api/delete"]) {
        NSString *name = [self nameFromQuery:query];
        NSString *full = name ? [self.romsDir stringByAppendingPathComponent:name] : nil;
        if (full && [[NSFileManager defaultManager] removeItemAtPath:full error:nil]) {
            rf_respond_json(fd, 200, @{@"ok": @YES});
            [self notifyChange];
        } else {
            rf_respond_error(fd, 404, @"file not found");
        }
    } else {
        rf_respond_error(fd, 404, @"not found");
    }
    free(buf);
}

- (NSArray *)listFiles {
    NSMutableArray *files = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [[fm contentsOfDirectoryAtPath:self.romsDir error:nil] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *name in names) {
        if (![[RFWebServer acceptedExtensions] containsObject:name.pathExtension.lowercaseString]) continue;
        NSDictionary *attrs = [fm attributesOfItemAtPath:[self.romsDir stringByAppendingPathComponent:name] error:nil];
        [files addObject:@{@"name": name, @"size": @(attrs.fileSize)}];
    }
    return files;
}

// Grava o corpo num arquivo temporário e só troca pelo definitivo quando chegar inteiro
- (NSString *)receiveFile:(NSString *)name fd:(int)fd length:(unsigned long long)length
                  initial:(const char *)initial initialLength:(size_t)initialLength {
    NSString *temp = [self.romsDir stringByAppendingPathComponent:[NSString stringWithFormat:@".upload-%@", [NSUUID UUID].UUIDString]];
    FILE *f = fopen(temp.fileSystemRepresentation, "wb");
    if (!f) return @"could not create the file on the iPad";
    unsigned long long remaining = length;
    size_t first = (size_t)MIN((unsigned long long)initialLength, remaining);
    if (first) fwrite(initial, 1, first, f);
    remaining -= first;
    char *chunk = malloc(256 * 1024);
    while (remaining > 0) {
        ssize_t n = recv(fd, chunk, (size_t)MIN((unsigned long long)(256 * 1024), remaining), 0);
        if (n <= 0) break;
        fwrite(chunk, 1, (size_t)n, f);
        remaining -= (unsigned long long)n;
    }
    free(chunk);
    BOOL ok = fclose(f) == 0 && remaining == 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!ok) {
        [fm removeItemAtPath:temp error:nil];
        return @"the upload was interrupted";
    }
    NSString *dest = [self.romsDir stringByAppendingPathComponent:name];
    [fm removeItemAtPath:dest error:nil];
    if (![fm moveItemAtPath:temp toPath:dest error:nil]) {
        [fm removeItemAtPath:temp error:nil];
        return @"could not write the file";
    }
    return nil;
}

@end
