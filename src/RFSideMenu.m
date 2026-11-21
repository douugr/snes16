// Menu lateral: as telas principais (jogos, conquistas, envio de ROMs, controle) ficam numa gaveta
// que abre pelo botão ☰ ou arrastando o dedo a partir da borda esquerda da tela.

#import "RF.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kRFDrawerWidth = 290;

@interface RFSideMenuController () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) NSArray *items;               // NSDictionary: title, caption, make
@property (nonatomic, strong) NSMutableDictionary *screens; // índice -> UINavigationController
@property (nonatomic, strong) UINavigationController *current;
@property (nonatomic, strong) UIView *dim;
@property (nonatomic, strong) UIView *drawer;
@property (nonatomic, strong) NSArray *buttons;
@property (nonatomic, assign) CGFloat panStart;
@end

static __weak RFSideMenuController *rf_menu;

@implementation RFSideMenuController

+ (instancetype)shared {
    return rf_menu;
}

- (instancetype)initWithItems:(NSArray *)items {
    if ((self = [super init])) {
        _items = items;
        _screens = [NSMutableDictionary dictionary];
        rf_menu = self;
    }
    return self;
}

+ (UIBarButtonItem *)menuButton {
    return [[UIBarButtonItem alloc] initWithTitle:@"☰" style:UIBarButtonItemStylePlain target:[self class] action:@selector(toggle)];
}

+ (void)toggle {
    RFSideMenuController *m = rf_menu;
    [m setOpen:m.drawer.frame.origin.x < 0 animated:YES];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    self.dim = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dim.backgroundColor = [UIColor blackColor];
    self.dim.alpha = 0;
    self.dim.hidden = YES;
    [self.dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];

    self.drawer = [[UIView alloc] initWithFrame:CGRectMake(-kRFDrawerWidth, 0, kRFDrawerWidth, self.view.bounds.size.height)];
    self.drawer.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    self.drawer.backgroundColor = RFThemeCard();   // o fundo de grade cobre; cores seguem o tema de cada app
    UIView *grid = RFThemeGridView();
    grid.frame = self.drawer.bounds;
    grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.drawer addSubview:grid];
    UIView *edge = [[UIView alloc] initWithFrame:CGRectMake(kRFDrawerWidth - 3, 0, 3, self.drawer.bounds.size.height)];
    edge.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    edge.backgroundColor = RFThemeRed();
    [self.drawer addSubview:edge];
    self.drawer.layer.shadowColor = [UIColor blackColor].CGColor;
    self.drawer.layer.shadowOpacity = 0.6;
    self.drawer.layer.shadowRadius = 12;
    self.drawer.layer.shadowPath = [UIBezierPath bezierPathWithRect:CGRectMake(0, 0, kRFDrawerWidth, 2000)].CGPath;

    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    UIImageView *logo = [[UIImageView alloc] initWithImage:RFThemeChromeText(appName, 54)];
    logo.frame = CGRectMake(14, 34, logo.image.size.width, logo.image.size.height);
    [self.drawer addSubview:logo];

    NSMutableArray *buttons = [NSMutableArray array];
    CGFloat y = CGRectGetMaxY(logo.frame) + 18;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        NSDictionary *item = self.items[i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, y, kRFDrawerWidth - 3, 68);
        b.tag = i;
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        [b addTarget:self action:@selector(itemTapped:) forControlEvents:UIControlEventTouchUpInside];
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(28, 10, kRFDrawerWidth - 44, 28)];
        title.font = RFThemeDisplayFont(24);
        title.textColor = RFThemeText();
        title.text = [item[@"title"] uppercaseString];
        title.tag = 100;
        [b addSubview:title];
        UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(28, 38, kRFDrawerWidth - 44, 18)];
        caption.font = RFThemeLabelFont(12);
        caption.textColor = RFThemeDim();
        caption.text = item[@"caption"];
        [b addSubview:caption];
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 10, 6, 48)];
        bar.backgroundColor = RFThemeRed();
        bar.tag = 101;
        [b addSubview:bar];
        [self.drawer addSubview:b];
        [buttons addObject:b];
        y += 72;
    }
    self.buttons = buttons;

    UIScreenEdgePanGestureRecognizer *edgePan = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgePan:)];
    edgePan.edges = UIRectEdgeLeft;
    edgePan.delegate = self;
    [self.view addGestureRecognizer:edgePan];
    UIPanGestureRecognizer *closePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(closePan:)];
    [self.drawer addGestureRecognizer:closePan];

    [self showItem:0];
}

// A borda esquerda abre o menu só nas telas principais (nas internas ela é o "voltar" do iOS)
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    return self.current.viewControllers.count <= 1 && !self.presentedViewController;
}

- (void)itemTapped:(UIButton *)b {
    [self showItem:b.tag];
    [self close];
}

- (void)showItem:(NSUInteger)index {
    UINavigationController *nav = self.screens[@(index)];
    if (!nav) {
        UIViewController *(^make)(void) = self.items[index][@"make"];
        UIViewController *root = make();
        root.navigationItem.leftBarButtonItem = [RFSideMenuController menuButton];
        nav = [[UINavigationController alloc] initWithRootViewController:root];
        RFThemeApplyNavigationBar(nav.navigationBar);
        // A tela de envio é recriada a cada vez (ela desliga o servidor ao sair); as outras ficam guardadas
        if ([self.items[index][@"keep"] boolValue]) self.screens[@(index)] = nav;
    }
    if (nav == self.current) return;
    UINavigationController *old = self.current;
    if (old) {
        [old willMoveToParentViewController:nil];
        [old beginAppearanceTransition:NO animated:NO];
        [old.view removeFromSuperview];
        [old endAppearanceTransition];
        [old removeFromParentViewController];
    }
    [self addChildViewController:nav];
    nav.view.frame = self.view.bounds;
    nav.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [nav beginAppearanceTransition:YES animated:NO];
    [self.view insertSubview:nav.view atIndex:0];
    [nav endAppearanceTransition];
    [nav didMoveToParentViewController:self];
    self.current = nav;
    for (UIButton *b in self.buttons) {
        BOOL on = (NSUInteger)b.tag == index;
        [b viewWithTag:101].hidden = !on;
        ((UILabel *)[b viewWithTag:100]).textColor = on ? RFThemeRed() : RFThemeText();
        b.backgroundColor = on ? [RFThemeRed() colorWithAlphaComponent:0.12] : [UIColor clearColor];
    }
}

- (BOOL)shouldAutomaticallyForwardAppearanceMethods {
    return NO;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.current beginAppearanceTransition:YES animated:animated];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.current endAppearanceTransition];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.current beginAppearanceTransition:NO animated:animated];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.current endAppearanceTransition];
}

- (UIViewController *)childViewControllerForStatusBarStyle {
    return nil;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

#pragma mark Gaveta

- (void)setOpen:(BOOL)open animated:(BOOL)animated {
    if (open) {
        [self.view endEditing:YES];
        [self.view addSubview:self.dim];
        [self.view addSubview:self.drawer];
        self.dim.hidden = NO;
    }
    CGRect f = self.drawer.frame;
    f.origin.x = open ? 0 : -kRFDrawerWidth;
    f.size.height = self.view.bounds.size.height;
    [UIView animateWithDuration:animated ? 0.25 : 0 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.drawer.frame = f;
        self.dim.alpha = open ? 0.55 : 0;
    } completion:^(BOOL finished) {
        if (!open) {
            self.dim.hidden = YES;
            [self.drawer removeFromSuperview];
            [self.dim removeFromSuperview];
        }
    }];
}

- (void)close {
    [self setOpen:NO animated:YES];
}

- (void)moveDrawerTo:(CGFloat)x {
    if (!self.drawer.superview) {
        [self.view addSubview:self.dim];
        [self.view addSubview:self.drawer];
        self.dim.hidden = NO;
    }
    x = MAX(-kRFDrawerWidth, MIN(0, x));
    CGRect f = self.drawer.frame;
    f.origin.x = x;
    f.size.height = self.view.bounds.size.height;
    self.drawer.frame = f;
    self.dim.alpha = 0.55 * (1 + x / kRFDrawerWidth);
}

- (void)edgePan:(UIScreenEdgePanGestureRecognizer *)g {
    CGFloat dx = [g translationInView:self.view].x;
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        [self moveDrawerTo:-kRFDrawerWidth + dx];
    } else {
        BOOL open = dx > kRFDrawerWidth * 0.35 || [g velocityInView:self.view].x > 500;
        [self setOpen:open animated:YES];
    }
}

- (void)closePan:(UIPanGestureRecognizer *)g {
    CGFloat dx = MIN(0, [g translationInView:self.view].x);
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        [self moveDrawerTo:dx];
    } else {
        BOOL open = !(dx < -kRFDrawerWidth * 0.3 || [g velocityInView:self.view].x < -500);
        [self setOpen:open animated:YES];
    }
}

@end
