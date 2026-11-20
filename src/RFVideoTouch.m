#import "RF.h"
#import <GLKit/GLKit.h>
#import <OpenGLES/ES2/gl.h>

#pragma mark - Vídeo (GLKView + textura RGB565)

static const char *kRFVertexShader =
    "attribute vec2 aPos;\n"
    "attribute vec2 aTex;\n"
    "varying vec2 vTex;\n"
    "void main() { vTex = aTex; gl_Position = vec4(aPos, 0.0, 1.0); }\n";

static const char *kRFFragmentShader =
    "precision mediump float;\n"
    "varying vec2 vTex;\n"
    "uniform sampler2D uTex;\n"
    "void main() { gl_FragColor = texture2D(uTex, vTex); }\n";

// Filtro CRT. A curvatura e o escurecimento das bordas são calculados por vértice numa malha
// de 32x24 (a GPU só interpola), então o shader de pixel faz só o feixe e a máscara: barato o bastante
// para desenhar em Retina (2048x1536), onde cada linha do jogo ocupa ~7 pixels e não há moiré.
static const char *kRFCRTVertexShader =
    "attribute vec2 aPos;\n"
    "uniform float uCurve;\n"
    "uniform vec2 uSrc;\n"      // área usada da textura (0..1)
    "uniform float uLines;\n"   // linhas de TV na textura inteira (tamanho / passo)
    "uniform float uDx;\n"      // deslocamento horizontal do borrão (largura de banda do sinal de vídeo)
    "varying highp vec2 vTc;\n"
    "varying highp vec2 vTl1;\n"
    "varying highp vec2 vTr1;\n"
    "varying highp vec2 vMisc;\n"   // x: linha de TV, y: escurecimento das bordas
    "varying mediump vec2 vPos;\n"
    "void main() {\n"
    "  vec2 p = aPos * (1.0 + uCurve * aPos.yx * aPos.yx) / (1.0 + uCurve);\n"
    "  vTc = vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5) * uSrc;\n"
    "  vTl1 = vTc - vec2(uDx * 1.15, 0.0);\n"
    "  vTr1 = vTc + vec2(uDx * 1.15, 0.0);\n"
    "  vMisc = vec2(vTc.y * uLines, 1.0 - uCurve * 3.0 * dot(aPos * aPos, vec2(0.5)));\n"
    "  vPos = aPos;\n"
    "  gl_Position = vec4(aPos, 0.0, 1.0);\n"
    "}\n";

// Sinal composto de TV: o brilho (luma) borra pouco e a cor (croma) borra bem mais, o que mistura o
// pontilhado (dithering) dos jogos e faz as cores "vazarem" de leve. Feixe macio que engorda nas cores
// claras e um brilho difuso (halation) por cima. As 3 leituras (com filtro linear, cada uma já mistura dois pixels vizinhos) usam coordenadas vindas direto do
// vértice (sem "dependent read", o caminho rápido do PowerVR do A5X).
static const char *kRFCRTFragmentShader =
    "precision mediump float;\n"
    "varying highp vec2 vTc;\n"
    "varying highp vec2 vTl1;\n"
    "varying highp vec2 vTr1;\n"
    "varying highp vec2 vMisc;\n"
    "varying mediump vec2 vPos;\n"
    "uniform sampler2D uTex;\n"
    "uniform vec2 uHalf;\n"       // metade da tela em pixels (cantos arredondados)
    "uniform float uRadius;\n"
    "void main() {\n"
    "  vec3 c = texture2D(uTex, vTc).rgb;\n"
    "  vec3 l1 = texture2D(uTex, vTl1).rgb;\n"
    "  vec3 r1 = texture2D(uTex, vTr1).rgb;\n"
    "  const vec3 kY = vec3(0.299, 0.587, 0.114);\n"
    "  vec3 wide = c * 0.46 + (l1 + r1) * 0.27;\n"
    "  float y = dot(c * 0.7 + (l1 + r1) * 0.15, kY);\n"
    "  vec3 col = clamp(wide + (y - dot(wide, kY)), 0.0, 1.0);\n"
    "  highp float f = fract(vMisc.x) - 0.5;\n"
    "  float beam = exp2(-f * f * mix(10.0, 3.5, y));\n"
    "  col = col * (beam * 1.3) + wide * 0.16;\n"
    "  float m = fract(gl_FragCoord.x * 0.5);\n"
    "  col *= m < 0.5 ? vec3(1.06, 0.95, 1.06) : vec3(0.95, 1.06, 0.95);\n"
    "  vec2 q = max(abs(vPos) * uHalf - (uHalf - uRadius), 0.0);\n"
    "  col *= vMisc.y * clamp(uRadius - length(q), 0.0, 1.0);\n"
    "  gl_FragColor = vec4(col, 1.0);\n"
    "}\n";

#define RF_CRT_COLS 32
#define RF_CRT_ROWS 24

#define RF_TEX_SIZE 512

@interface RFGLView () <GLKViewDelegate>
@property (nonatomic, strong) EAGLContext *context;
@property (nonatomic, strong) GLKView *glView;
@property (nonatomic, assign) GLuint program;
@property (nonatomic, assign) GLuint texture;
@property (nonatomic, assign) GLint posAttr;
@property (nonatomic, assign) GLint texAttr;
@property (nonatomic, assign) GLuint crtProgram;
@property (nonatomic, assign) GLint crtPosAttr;
@property (nonatomic, assign) GLfloat *crtMesh;
@property (nonatomic, assign) GLushort *crtIndices;
@property (nonatomic, assign) int crtIndexCount;
@property (nonatomic, assign) uint16_t *staging;
@property (nonatomic, assign) unsigned lastWidth;
@property (nonatomic, assign) unsigned lastHeight;
@end

@implementation RFGLView

static GLuint rf_compile(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    return s;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor blackColor];
        _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        _glView = [[GLKView alloc] initWithFrame:self.bounds context:_context];
        _glView.delegate = self;
        _glView.enableSetNeedsDisplay = NO;
        _glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _glView.userInteractionEnabled = NO;
        // Desenha em 1x (1024x768) em vez de Retina (2048x1536): 4x menos pixels para a GPU do A5X.
        // A imagem do Super Nintendo tem 256x224, então não se perde nitidez visível.
        _glView.contentScaleFactor = 1.0;
        _glView.opaque = YES;
        [self addSubview:_glView];
        _staging = calloc(RF_TEX_SIZE * RF_TEX_SIZE, sizeof(uint16_t));
        [self setupGL];
    }
    return self;
}

- (void)dealloc {
    [EAGLContext setCurrentContext:self.context];
    if (_texture) glDeleteTextures(1, &_texture);
    if (_program) glDeleteProgram(_program);
    if (_crtProgram) glDeleteProgram(_crtProgram);
    free(_crtMesh);
    free(_crtIndices);
    [EAGLContext setCurrentContext:nil];
    free(_staging);
}

- (void)setupGL {
    [EAGLContext setCurrentContext:self.context];
    GLuint vs = rf_compile(GL_VERTEX_SHADER, kRFVertexShader);
    GLuint fs = rf_compile(GL_FRAGMENT_SHADER, kRFFragmentShader);
    _program = glCreateProgram();
    glAttachShader(_program, vs);
    glAttachShader(_program, fs);
    glLinkProgram(_program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    _posAttr = glGetAttribLocation(_program, "aPos");
    _texAttr = glGetAttribLocation(_program, "aTex");

    vs = rf_compile(GL_VERTEX_SHADER, kRFCRTVertexShader);
    fs = rf_compile(GL_FRAGMENT_SHADER, kRFCRTFragmentShader);
    _crtProgram = glCreateProgram();
    glAttachShader(_crtProgram, vs);
    glAttachShader(_crtProgram, fs);
    glLinkProgram(_crtProgram);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint linked = 0;
    glGetProgramiv(_crtProgram, GL_LINK_STATUS, &linked);
    if (!linked) {
        char log[512] = {0};
        glGetProgramInfoLog(_crtProgram, sizeof(log) - 1, NULL, log);
        RFAppendLog(@"core.txt", [NSString stringWithFormat:@"CRT shader failed: %s", log]);
        glDeleteProgram(_crtProgram);
        _crtProgram = 0;
    }
    _crtPosAttr = _crtProgram ? glGetAttribLocation(_crtProgram, "aPos") : -1;
    // Malha da tela (a curvatura fica nos vértices)
    _crtMesh = malloc((RF_CRT_COLS + 1) * (RF_CRT_ROWS + 1) * 2 * sizeof(GLfloat));
    for (int y = 0; y <= RF_CRT_ROWS; y++) {
        for (int x = 0; x <= RF_CRT_COLS; x++) {
            GLfloat *p = _crtMesh + (y * (RF_CRT_COLS + 1) + x) * 2;
            p[0] = -1.0f + 2.0f * x / RF_CRT_COLS;
            p[1] = -1.0f + 2.0f * y / RF_CRT_ROWS;
        }
    }
    _crtIndexCount = RF_CRT_COLS * RF_CRT_ROWS * 6;
    _crtIndices = malloc(_crtIndexCount * sizeof(GLushort));
    int k = 0;
    for (int y = 0; y < RF_CRT_ROWS; y++) {
        for (int x = 0; x < RF_CRT_COLS; x++) {
            GLushort a = y * (RF_CRT_COLS + 1) + x, b = a + 1, c = a + RF_CRT_COLS + 1, d = c + 1;
            _crtIndices[k++] = a; _crtIndices[k++] = b; _crtIndices[k++] = c;
            _crtIndices[k++] = b; _crtIndices[k++] = d; _crtIndices[k++] = c;
        }
    }

    glGenTextures(1, &_texture);
    glBindTexture(GL_TEXTURE_2D, _texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, RF_TEX_SIZE, RF_TEX_SIZE, 0, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, _staging);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    [self applyFilter];
}

- (void)applyFilter {
    [EAGLContext setCurrentContext:self.context];
    glBindTexture(GL_TEXTURE_2D, _texture);
    GLint f = self.filterMode == 0 ? GL_NEAREST : GL_LINEAR;   // no CRT a suavização é só na horizontal
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, f);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, f);
}

- (void)setSmooth:(BOOL)smooth {
    self.filterMode = smooth ? 1 : 0;
}

- (BOOL)smooth {
    return self.filterMode != 0;
}

- (BOOL)crtActive {
    return self.filterMode >= 2 && self.crtProgram;
}

// Sempre 1x (1024x768). Testado no iPad 3: o CRT em Retina (2048x1536) passava de 17 ms por quadro
// só para desenhar e compor a tela, e caía para 35 fps; em 1x cabe com folga.
- (CGFloat)renderScale {
    return 1.0;
}

- (void)setFilterMode:(NSInteger)filterMode {
    _filterMode = filterMode;
    [self applyFilter];
    self.glView.contentScaleFactor = [self renderScale];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    self.glView.contentScaleFactor = [self renderScale];
}

- (void)drawFrame {
    [self.glView display];
}

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect {
    unsigned w = 0, h = 0;
    size_t pitch = 0;
    const void *data = [[RFCore shared] frameData:&w height:&h pitch:&pitch];

    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    if (!data || !w || !h) {
        if (!self.lastWidth) return;
        w = self.lastWidth;
        h = self.lastHeight;
    } else {
        w = MIN(w, RF_TEX_SIZE);
        h = MIN(h, RF_TEX_SIZE);
        glBindTexture(GL_TEXTURE_2D, _texture);
        if (pitch == w * 2) {
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, data);
        } else {
            // O core usa um pitch maior que a largura: copia linha a linha
            const uint8_t *src = data;
            for (unsigned y = 0; y < h; y++) {
                memcpy(self.staging + y * w, src + y * pitch, w * 2);
            }
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, self.staging);
        }
        self.lastWidth = w;
        self.lastHeight = h;
    }

    if ([self crtActive]) {
        glUseProgram(_crtProgram);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, _texture);
        glUniform1i(glGetUniformLocation(_crtProgram, "uTex"), 0);
        glUniform1f(glGetUniformLocation(_crtProgram, "uCurve"), self.filterMode == 3 ? 0.035f : 0.0f);
        glUniform2f(glGetUniformLocation(_crtProgram, "uSrc"), (float)w / RF_TEX_SIZE, (float)h / RF_TEX_SIZE);
        glUniform1f(glGetUniformLocation(_crtProgram, "uDx"), (float)w / 320.0f / RF_TEX_SIZE);   // ~1/320 da largura, como um sinal composto
        glUniform1f(glGetUniformLocation(_crtProgram, "uLines"), RF_TEX_SIZE / (h > 300 ? 2.0f : 1.0f));   // 480i: 240 linhas de TV
        GLfloat sw = view.drawableWidth, sh = view.drawableHeight;
        glUniform2f(glGetUniformLocation(_crtProgram, "uHalf"), sw * 0.5f, sh * 0.5f);
        glUniform1f(glGetUniformLocation(_crtProgram, "uRadius"), self.filterMode == 3 ? sh * 0.035f : 1.0f);
        glVertexAttribPointer(_crtPosAttr, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(GLfloat), _crtMesh);
        glEnableVertexAttribArray(_crtPosAttr);
        glDrawElements(GL_TRIANGLES, _crtIndexCount, GL_UNSIGNED_SHORT, _crtIndices);
        return;
    }

    float u = (float)w / RF_TEX_SIZE;
    float v = (float)h / RF_TEX_SIZE;
    const GLfloat quad[] = {
        -1, -1, 0, v,
         1, -1, u, v,
        -1,  1, 0, 0,
         1,  1, u, 0,
    };
    glUseProgram(_program);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _texture);
    glUniform1i(glGetUniformLocation(_program, "uTex"), 0);
    glVertexAttribPointer(_posAttr, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), quad);
    glVertexAttribPointer(_texAttr, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), quad + 2);
    glEnableVertexAttribArray(_posAttr);
    glEnableVertexAttribArray(_texAttr);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

@end

#pragma mark - Controle na tela

typedef struct {
    CGPoint center;
    CGFloat radius;
    uint32_t mask;
    __unsafe_unretained NSString *label;
    BOOL pill;       // botão alongado (L, R, Select, Start)
    int tone;        // 0 = roxo escuro (A/B), 1 = lilás (X/Y), 2 = cinza (resto)
} RFButton;

// 0 A, 1 B, 2 X, 3 Y, 4 L, 5 R, 6 SELECT, 7 START
#define RF_BUTTONS 8

@interface RFTouchPad ()
@property (nonatomic, assign) CGPoint dpadCenter;
@property (nonatomic, assign) CGFloat dpadRadius;
@property (nonatomic, assign) CGRect menuRect;
@property (nonatomic, assign) uint32_t drawnMask;
- (void)drawControlsInContext:(CGContextRef)ctx;
@end

// Pedaço pequeno do controle na tela. A view grande (RFTouchPad) não desenha nada e não tem
// bitmap próprio: assim o iOS só mistura em cima do vídeo as áreas dos botões, e não a tela inteira.
@interface RFPadPart : UIView
@property (nonatomic, weak) RFTouchPad *owner;
@end

@implementation RFPadPart
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(ctx, -self.frame.origin.x, -self.frame.origin.y);
    [self.owner drawControlsInContext:ctx];
}
@end

@implementation RFTouchPad {
    RFButton _buttons[RF_BUTTONS];
    RFPadPart *_dpadPart, *_abcPart, *_startPart, *_menuPart, *_lPart, *_rPart;
}

- (RFPadPart *)makePart {
    RFPadPart *part = [[RFPadPart alloc] initWithFrame:CGRectZero];
    part.owner = self;
    part.backgroundColor = [UIColor clearColor];
    part.opaque = NO;
    part.userInteractionEnabled = NO;
    part.contentMode = UIViewContentModeRedraw;
    [self addSubview:part];
    return part;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = nil;
        self.opaque = NO;
        self.multipleTouchEnabled = YES;
        _dpadPart = [self makePart];
        _abcPart = [self makePart];
        _startPart = [self makePart];
        _lPart = [self makePart];
        _rPart = [self makePart];
        _menuPart = [self makePart];
    }
    return self;
}

- (void)setNeedsDisplay {
    // Não chama o super: esta view não tem desenho próprio
    [_dpadPart setNeedsDisplay];
    [_abcPart setNeedsDisplay];
    [_startPart setNeedsDisplay];
    [_lPart setNeedsDisplay];
    [_rPart setNeedsDisplay];
    [_menuPart setNeedsDisplay];
}

- (void)setControlsHidden:(BOOL)controlsHidden {
    _controlsHidden = controlsHidden;
    rf_touch_mask = 0;
    _dpadPart.hidden = _abcPart.hidden = _startPart.hidden = _lPart.hidden = _rPart.hidden = controlsHidden;
    [self setNeedsDisplay];
}

static CGRect rf_button_rect(RFButton b) {
    CGRect br = CGRectMake(b.center.x - b.radius, b.center.y - b.radius, 2 * b.radius, 2 * b.radius);
    return b.pill ? CGRectInset(br, -b.radius * 0.8, b.radius * 0.35) : br;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    BOOL landscape = s.width > s.height;
    CGFloat unit = MIN(s.width, s.height);
    CGFloat btn = unit * (landscape ? 0.075 : 0.085);

    CGFloat bottomY;
    if (landscape) {
        bottomY = s.height - unit * 0.22;
    } else {
        // Retrato: controles na área abaixo do vídeo
        CGFloat top = CGRectGetMaxY(self.gameRect);
        bottomY = top + (s.height - top) * 0.5;
    }
    self.dpadRadius = unit * (landscape ? 0.15 : 0.17);
    self.dpadCenter = CGPointMake(self.dpadRadius + unit * 0.05, bottomY);

    // A B X Y em losango, como no controle do Super Nintendo
    CGFloat d = btn * 1.25;
    CGFloat cx = s.width - unit * 0.06 - btn - d;
    CGFloat cy = bottomY;
    _buttons[0] = (RFButton){CGPointMake(cx + d, cy), btn, RF_SN_A, @"A", NO, 0};
    _buttons[1] = (RFButton){CGPointMake(cx, cy + d), btn, RF_SN_B, @"B", NO, 0};
    _buttons[2] = (RFButton){CGPointMake(cx, cy - d), btn, RF_SN_X, @"X", NO, 1};
    _buttons[3] = (RFButton){CGPointMake(cx - d, cy), btn, RF_SN_Y, @"Y", NO, 1};

    // L e R nos cantos de cima (abaixo do botão de menu); Select e Start embaixo, no meio
    CGFloat shoulderY = landscape ? 96 : CGRectGetMaxY(self.gameRect) + btn * 0.9;
    _buttons[4] = (RFButton){CGPointMake(unit * 0.05 + btn * 1.4, shoulderY), btn * 0.75, RF_SN_L, @"L", YES, 2};
    _buttons[5] = (RFButton){CGPointMake(s.width - unit * 0.05 - btn * 1.4, shoulderY), btn * 0.75, RF_SN_R, @"R", YES, 2};
    CGFloat smallY = s.height - btn * 0.9;
    _buttons[6] = (RFButton){CGPointMake(s.width / 2.0 - btn * 1.35, smallY), btn * 0.55, RF_SN_SELECT, @"SELECT", YES, 2};
    _buttons[7] = (RFButton){CGPointMake(s.width / 2.0 + btn * 1.35, smallY), btn * 0.55, RF_SN_START, @"START", YES, 2};

    CGFloat m = 44;
    self.menuRect = CGRectMake(s.width - m - 10, 10, m, m);

    CGFloat r = self.dpadRadius;
    _dpadPart.frame = CGRectIntegral(CGRectInset(CGRectMake(self.dpadCenter.x - r, self.dpadCenter.y - r, 2 * r, 2 * r), -4, -4));
    CGRect face = rf_button_rect(_buttons[0]);
    for (int i = 1; i < 4; i++) face = CGRectUnion(face, rf_button_rect(_buttons[i]));
    _abcPart.frame = CGRectIntegral(CGRectInset(face, -4, -4));
    _lPart.frame = CGRectIntegral(CGRectInset(rf_button_rect(_buttons[4]), -4, -4));
    _rPart.frame = CGRectIntegral(CGRectInset(rf_button_rect(_buttons[5]), -4, -4));
    _startPart.frame = CGRectIntegral(CGRectInset(CGRectUnion(rf_button_rect(_buttons[6]), rf_button_rect(_buttons[7])), -4, -4));
    _menuPart.frame = CGRectIntegral(CGRectInset(self.menuRect, -3, -3));
    [self setNeedsDisplay];
}

- (uint32_t)maskForTouches:(NSSet *)touches {
    uint32_t mask = 0;
    for (UITouch *t in touches) {
        if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) continue;
        CGPoint p = [t locationInView:self];
        // Direcional (8 direções)
        CGFloat dx = p.x - self.dpadCenter.x, dy = p.y - self.dpadCenter.y;
        CGFloat dist = sqrt(dx * dx + dy * dy);
        if (dist < self.dpadRadius * 1.6) {
            if (dist > self.dpadRadius * 0.18) {
                double angle = atan2(-dy, dx) * 180.0 / M_PI;   // 0 = direita, 90 = cima
                if (angle < 0) angle += 360;
                if (angle >= 22.5 && angle < 157.5) mask |= RF_UP;
                if (angle >= 202.5 && angle < 337.5) mask |= RF_DOWN;
                if (angle >= 112.5 && angle < 247.5) mask |= RF_LEFT;
                if (angle < 67.5 || angle >= 292.5) mask |= RF_RIGHT;
            }
            continue;
        }
        // Botão mais próximo dentro do alcance
        int best = -1;
        CGFloat bestDist = CGFLOAT_MAX;
        for (int i = 0; i < RF_BUTTONS; i++) {
            CGFloat bx = p.x - _buttons[i].center.x, by = p.y - _buttons[i].center.y;
            CGFloat d = sqrt(bx * bx + by * by);
            BOOL inside = _buttons[i].pill
                ? CGRectContainsPoint(CGRectInset(rf_button_rect(_buttons[i]), -_buttons[i].radius * 0.4, -_buttons[i].radius * 0.4), p)
                : d < _buttons[i].radius * 1.25;
            if (inside && d < bestDist) {
                best = i;
                bestDist = d;
            }
        }
        if (best >= 0) mask |= _buttons[best].mask;
    }
    return mask;
}

- (void)updateWithEvent:(UIEvent *)event {
    if (self.controlsHidden) return;
    uint32_t mask = [self maskForTouches:[event touchesForView:self]];
    if (mask != rf_touch_mask) {
        rf_touch_mask = mask;
        RFInputChanged();
    }
    if (mask != self.drawnMask) {
        self.drawnMask = mask;
        [self setNeedsDisplay];
    }
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        if (CGRectContainsPoint(CGRectInset(self.menuRect, -12, -12), [t locationInView:self])) {
            if (self.menuHandler) self.menuHandler();
            return;
        }
    }
    [self updateWithEvent:event];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [self updateWithEvent:event];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [self updateWithEvent:event];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    rf_touch_mask = 0;
    self.drawnMask = 0;
    [self setNeedsDisplay];
}

- (void)drawControlsInContext:(CGContextRef)ctx {
    UIColor *line = [UIColor colorWithWhite:1 alpha:0.35];
    UIColor *fill = [UIColor colorWithWhite:1 alpha:0.10];
    UIColor *pressed = [UIColor colorWithWhite:1 alpha:0.40];

    // Botão de menu (sempre visível)
    UIBezierPath *menu = [UIBezierPath bezierPathWithRoundedRect:self.menuRect cornerRadius:10];
    [[UIColor colorWithWhite:0 alpha:0.35] setFill];
    [menu fill];
    [line setStroke];
    [menu stroke];
    for (int i = 0; i < 3; i++) {
        CGFloat y = CGRectGetMinY(self.menuRect) + 14 + i * 8;
        CGContextFillRect(ctx, CGRectMake(CGRectGetMinX(self.menuRect) + 11, y, 22, 2.5));
    }
    if (self.controlsHidden) return;

    uint32_t mask = self.drawnMask;
    CGPoint c = self.dpadCenter;
    CGFloat r = self.dpadRadius;
    UIBezierPath *base = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r)];
    [fill setFill];
    [base fill];
    [line setStroke];
    base.lineWidth = 2;
    [base stroke];

    // Cruz do direcional
    CGFloat arm = r * 0.36;
    struct { CGRect rect; uint32_t bit; } arms[4] = {
        {CGRectMake(c.x - arm / 2, c.y - r * 0.85, arm, r * 0.62), RF_UP},
        {CGRectMake(c.x - arm / 2, c.y + r * 0.23, arm, r * 0.62), RF_DOWN},
        {CGRectMake(c.x - r * 0.85, c.y - arm / 2, r * 0.62, arm), RF_LEFT},
        {CGRectMake(c.x + r * 0.23, c.y - arm / 2, r * 0.62, arm), RF_RIGHT},
    };
    for (int i = 0; i < 4; i++) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:arms[i].rect cornerRadius:4];
        [(mask & arms[i].bit ? pressed : fill) setFill];
        [p fill];
        [line setStroke];
        [p stroke];
    }

    // Tons: roxo escuro (A/B), lilás (X/Y), cinza (L, R, Select, Start)
    UIColor *tones[3][2] = {
        {[UIColor colorWithRed:0.33 green:0.24 blue:0.55 alpha:0.45], [UIColor colorWithRed:0.45 green:0.34 blue:0.72 alpha:0.85]},
        {[UIColor colorWithRed:0.62 green:0.56 blue:0.85 alpha:0.40], [UIColor colorWithRed:0.75 green:0.69 blue:0.95 alpha:0.85]},
        {fill, pressed},
    };
    for (int i = 0; i < RF_BUTTONS; i++) {
        RFButton b = _buttons[i];
        UIBezierPath *p = b.pill ? [UIBezierPath bezierPathWithRoundedRect:rf_button_rect(b) cornerRadius:b.radius * 0.6]
                                 : [UIBezierPath bezierPathWithOvalInRect:rf_button_rect(b)];
        [tones[b.tone][(mask & b.mask) ? 1 : 0] setFill];
        [p fill];
        [line setStroke];
        p.lineWidth = 2;
        [p stroke];
        NSDictionary *attrs = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:(b.pill ? b.radius * (b.label.length > 1 ? 0.55 : 0.8) : b.radius * 0.8)],
                                 NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.7] };
        CGSize ts = [b.label sizeWithAttributes:attrs];
        [b.label drawAtPoint:CGPointMake(b.center.x - ts.width / 2, b.center.y - ts.height / 2) withAttributes:attrs];
    }
}

@end
