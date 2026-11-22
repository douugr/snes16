// SNES16 — frontend libretro mínimo para iPad com iOS 8 (armv7) + Snes9x 2005
#import <UIKit/UIKit.h>
#include <stdint.h>

#pragma mark - Entrada (bits no formato RetroPad do libretro)

// IDs RETRO_DEVICE_ID_JOYPAD_*: B=0 Y=1 SELECT=2 START=3 UP=4 DOWN=5 LEFT=6 RIGHT=7 A=8 X=9 L=10 R=11
#define RF_BIT(id) (1u << (id))
// No Super Nintendo os botões são os mesmos do RetroPad
#define RF_SN_A      RF_BIT(8)
#define RF_SN_B      RF_BIT(0)
#define RF_SN_X      RF_BIT(9)
#define RF_SN_Y      RF_BIT(1)
#define RF_SN_L      RF_BIT(10)
#define RF_SN_R      RF_BIT(11)
#define RF_SN_START  RF_BIT(3)
#define RF_SN_SELECT RF_BIT(2)
#define RF_UP        RF_BIT(4)
#define RF_DOWN      RF_BIT(5)
#define RF_LEFT      RF_BIT(6)
#define RF_RIGHT     RF_BIT(7)

// Estado atual de cada fonte de entrada (lido pelo core a cada quadro)
extern volatile uint32_t rf_touch_mask;
extern volatile uint32_t rf_pad_mask;
// Quando a entrada mudou pela última vez (CACurrentMediaTime) e um contador de mudanças,
// para medir quanto tempo um botão espera até o emulador usá-lo
extern volatile double rf_input_changed_at;
extern volatile uint32_t rf_input_seq;
void RFInputChanged(void);

// Pastas: Documents/SNES16/{roms,saves,states,system}
NSString *RFBaseDir(void);
NSString *RFDir(NSString *name);
// Acrescenta uma linha com horário em Documents/SNES16/<file> (diagnóstico; arquivo limitado a ~200 KB)
void RFAppendLog(NSString *file, NSString *line);

#pragma mark - Core

@interface RFCore : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) double fps;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) float aspectRatio;
@property (nonatomic, readonly) BOOL loaded;
@property (nonatomic, readonly, copy) NSString *gameName;
- (BOOL)loadGameAtPath:(NSString *)path error:(NSString **)error;
// Patch .ips/.bps com o mesmo nome da ROM, na mesma pasta (nil se não houver)
+ (NSString *)patchPathForROM:(NSString *)romPath;
// O jogo carregado está com patch aplicado?
@property (nonatomic, readonly) BOOL patched;
- (void)runFrame;
// Roda um quadro; com skip=YES o core não desenha o vídeo (só emula e gera áudio)
- (void)runFrameSkippingVideo:(BOOL)skip;
// Run-ahead de 1 quadro: roda o quadro real (sem desenhar), guarda o estado, roda o quadro
// seguinte só para mostrar a imagem (sem som) e volta ao estado guardado. Esconde 1 quadro
// do atraso interno do jogo. Retorna NO se o core não suporta (aí roda um quadro normal).
- (BOOL)runFrameWithRunAhead;
- (void)reset;
- (void)unload;
- (void)saveSRAM;
- (BOOL)saveStateSlot:(int)slot;
- (BOOL)loadStateSlot:(int)slot;
- (BOOL)hasStateSlot:(int)slot;
// Data em que o estado foi salvo (nil se o slot está vazio). Slot 0 = automático, 1 a 3 = manuais.
- (NSDate *)dateForStateSlot:(int)slot;
// Último quadro de vídeo (RGB565). Válido até a próxima chamada de runFrame.
- (const void *)frameData:(unsigned *)width height:(unsigned *)height pitch:(size_t *)pitch;
@end

#pragma mark - Áudio

@interface RFAudio : NSObject
+ (instancetype)shared;
- (void)startWithSampleRate:(double)rate;
- (void)stop;
- (void)clear;
- (void)pushSamples:(const int16_t *)data frames:(size_t)frames;
// Quadros de áudio na fila esperando para tocar
- (uint32_t)bufferedFrames;
// Quantas vezes o som ficou sem dados (contador desde o início)
- (uint32_t)underruns;
@end

#pragma mark - Vídeo

@interface RFGLView : UIView
@property (nonatomic, assign) BOOL smooth;
// 0 pixels nítidos, 1 suave, 2 TV de tubo (CRT), 3 CRT com tela curva
@property (nonatomic, assign) NSInteger filterMode;
- (void)drawFrame;   // envia o último quadro do core para a tela
@end

#pragma mark - Controle na tela

@interface RFTouchPad : UIView
@property (nonatomic, copy) void (^menuHandler)(void);
@property (nonatomic, assign) BOOL controlsHidden;   // esconde direcional/botões (fica só o botão de menu)
@property (nonatomic, assign) CGRect gameRect;      // área do vídeo (para posicionar os controles)
@end

#pragma mark - Controle Bluetooth (BTstack)

typedef NS_ENUM(NSInteger, RFAction) {
    RFActionUp = 0, RFActionDown, RFActionLeft, RFActionRight,
    RFActionA, RFActionB, RFActionX, RFActionY, RFActionStart,   // obrigatórios (até Start)
    RFActionL, RFActionR, RFActionSelect,                        // recomendados
    RFActionMenu,
    RFActionCount
};

NSString *RFActionName(RFAction action);

@protocol RFBluetoothDelegate <NSObject>
@optional
- (void)bluetoothDidChange;
- (void)bluetoothLog:(NSString *)text;
@end

@interface RFBluetooth : NSObject
+ (instancetype)shared;
@property (nonatomic, weak) id<RFBluetoothDelegate> delegate;
@property (nonatomic, readonly, copy) NSString *status;
@property (nonatomic, readonly) BOOL available;     // BTdaemon respondeu
@property (nonatomic, readonly) BOOL connected;
@property (nonatomic, readonly) BOOL hasMapping;
@property (nonatomic, readonly, copy) NSString *connectedName;
@property (nonatomic, copy) void (^menuPressed)(void);
- (void)start;
// Desliga o rádio e fecha a conexão com o BTdaemon (ao encerrar o app)
- (void)stop;
// Últimas linhas do registro de Bluetooth (mais recente por último)
- (NSArray<NSString *> *)recentLog;
// Último relatório bruto do controle, em hexadecimal (diagnóstico)
- (NSString *)lastReportHex;
- (void)scan;
- (NSInteger)deviceCount;
- (NSString *)deviceTitleAtIndex:(NSInteger)index;
- (void)connectDeviceAtIndex:(NSInteger)index;
- (void)disconnect;
- (void)forgetController;
// Assistente de mapeamento
@property (nonatomic, readonly) BOOL calibrating;
@property (nonatomic, readonly) RFAction calibratingAction;
- (void)startCalibration;
- (void)skipCalibrationStep;
- (void)cancelCalibration;
@end

// Servidor HTTP para enviar ROMs pelo navegador (tela "Enviar ROMs")
@interface RFWebServer : NSObject
+ (instancetype)shared;
+ (NSString *)localIPAddress;   // IP do Wi-Fi (nil se não estiver conectado)
- (BOOL)startOnPort:(uint16_t)port error:(NSString **)error;
- (void)stop;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, copy) void (^onChange)(void);
// Parte secreta do endereço (muda a cada vez que o servidor liga): http://<ipad>:<porta>/<código>/
@property (nonatomic, readonly, copy) NSString *accessCode;
// Nome na rede local anunciado por Bonjour (ex.: "psx32.local"); nil até o registro terminar
@property (nonatomic, readonly, copy) NSString *hostName;
@property (nonatomic, copy) void (^onNameChange)(void);   // thread principal   // chamado na thread principal quando chega/sai um arquivo
@end

// RetroAchievements (RFAchievements.m): conquistas via rcheevos, por enquanto só no modo Casual
extern NSString *const RFAchievementsChanged;   // notificação: login, jogo identificado ou conquista nova
struct retro_memory_map;
void RFAchievementsSetMemoryMap(const struct retro_memory_map *map);

@interface RFAchievements : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL loggedIn;
@property (nonatomic, readonly, copy) NSString *userName;
@property (nonatomic, readonly) uint32_t score;
@property (nonatomic, readonly, copy) NSString *status;      // "Signing in…" ou o último erro
@property (nonatomic, readonly, copy) NSString *gameTitle;   // nome do jogo no RetroAchievements
@property (nonatomic, copy) NSString *pendingPath;
@property (nonatomic, assign) uint32_t pendingConsole;
@property (nonatomic, assign) BOOL patchedGame;
- (void)start;   // na abertura do app: entra com o token salvo
- (void)loginWithUser:(NSString *)user password:(NSString *)password completion:(void (^)(NSString *error))completion;
- (void)logout;
- (void)gameLoadedAtPath:(NSString *)path console:(uint32_t)console patched:(BOOL)patched;
- (void)gameUnloaded;
- (void)changeMediaToPath:(NSString *)path;   // jogo de vários discos: disco novo inserido
- (BOOL)gameActive;
- (void)doFrame;   // uma vez por quadro real (não nos quadros previstos do run-ahead)
- (void)reset;
- (NSData *)progress;                       // estado das conquistas, salvo junto com o save state
- (void)restoreProgress:(NSData *)data;     // nil: zera o acompanhamento
- (NSArray *)achievementSections;
- (NSString *)gameSummary;
- (void)imageForURL:(NSString *)url completion:(void (^)(UIImage *image))completion;
- (void)fetchGame:(uint32_t)gameId completion:(void (^)(NSDictionary *info, NSString *error))completion;
- (void)fetchMyGames:(void (^)(NSArray *games, NSString *error))completion;
@end

@interface RFAchievementsAccountViewController : UIViewController
@end

@interface RFAchievementsListViewController : UITableViewController
@property (nonatomic, copy) void (^onDone)(void);
@property (nonatomic, assign) uint32_t gameId;        // 0 = jogo aberto agora; senão busca no site
@property (nonatomic, copy) NSString *gameTitle;
@end

// Tela "Achievements" do menu: conta e conquistas por jogo
@interface RFAchievementsHomeViewController : UITableViewController
@end

// Consoles deste emulador no RetroAchievements: NSDictionary id/name (definido em RFCore.m)
NSArray *RFAchievementsConsoles(void);
uint32_t RFConsoleForPath(NSString *path);

// Menu lateral (RFSideMenu.m). Itens: NSDictionary title, caption, make (bloco que cria a tela), keep (BOOL)
@interface RFSideMenuController : UIViewController
+ (instancetype)shared;
+ (UIBarButtonItem *)menuButton;
- (instancetype)initWithItems:(NSArray *)items;
- (void)showItem:(NSUInteger)index;
@end

// Saves na nuvem (RFCloud.m): repositório privado do GitHub, comum aos três emuladores
extern NSString *const RFCloudChanged;
@interface RFCloud : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL configured;
@property (nonatomic, readonly, copy) NSString *repo;
@property (nonatomic, readonly) NSUInteger pendingCount;
@property (nonatomic, readonly, copy) NSString *lastMessage;
@property (nonatomic, readonly, strong) NSDate *lastSync;
@property (nonatomic, assign) BOOL justDownloaded;   // o último jogo aberto recebeu um save da nuvem
- (NSString *)configureRepo:(NSString *)repo token:(NSString *)token;   // nil = ok; senão o erro (thread de fundo)
- (void)disconnect;
// Antes de abrir o jogo: baixa o save mais novo (ou pergunta, se mudou dos dois lados)
- (void)syncBeforePlaying:(NSString *)romPath from:(UIViewController *)vc completion:(void (^)(void))completion;
- (void)localSaveWritten:(NSString *)localPath;   // o app gravou um save: envia em seguida
- (void)pushPending;
@property (nonatomic, assign) BOOL gameRunning;   // com jogo aberto os envios esperam (rede x Bluetooth/som no iPad 3)
- (void)uploadAllWithCompletion:(void (^)(NSUInteger found))completion;   // todos os saves da biblioteca
@end

// Jogos da biblioteca (caminhos completos), para enviar todos os saves (RFCore.m de cada app)
NSArray *RFCloudLibraryGames(void);
// Diagnóstico da saída do jogo: etapa no log e vigia de 10 s
void RFQuitStep(const char *step);
void RFQuitWatch(BOOL on);

@interface RFCloudViewController : UIViewController
@end

// Arquivos de save de um jogo (RFCore.m de cada app): NSDictionary local + folder (pasta no repositório)
// ou local + shared (caminho fixo no repositório, para o memory card compartilhado do PSX32)
NSArray *RFCloudSaveFiles(NSString *romPath);

// Tema visual (RFTheme.m): grade cinza sobre preto, cromado, vermelho e faixas diagonais
UIColor *RFThemeRed(void);
UIColor *RFThemeLilac(void);
UIColor *RFThemeText(void);
UIColor *RFThemeDim(void);
UIColor *RFThemeCard(void);
UIColor *RFThemeGridColor(void);
UIView *RFThemeGridView(void);
UIFont *RFThemeDisplayFont(CGFloat size);
UIFont *RFThemeLabelFont(CGFloat size);
UIImage *RFThemeChromeText(NSString *text, CGFloat size);
void RFThemeDrawStripes(CGContextRef ctx, CGRect r, CGFloat width);
void RFThemeApplyNavigationBar(UINavigationBar *bar);
void RFThemeApplyTable(UITableView *table);
void RFThemeStyleCell(UITableViewCell *cell);
void RFThemeStyleHeaderFooter(UIView *view, BOOL header);
