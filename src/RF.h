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
