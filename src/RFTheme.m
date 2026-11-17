// Visual inspirado no console de 16 bits da Nintendo: carcaça cinza clara de dois tons com
// frisos horizontais, detalhes em roxo e lilás, letreiros pesados em itálico e cartuchos
// cinza com etiqueta. Nada de logos: só a linguagem visual.

#import "RF.h"
#import <QuartzCore/QuartzCore.h>

// Cor de destaque (roxo). O nome segue o do MD16 para manter o resto do código igual.
UIColor *RFThemeRed(void) {
    return [UIColor colorWithRed:0.36 green:0.29 blue:0.62 alpha:1];
}

UIColor *RFThemeLilac(void) {
    return [UIColor colorWithRed:0.72 green:0.67 blue:0.92 alpha:1];
}

UIColor *RFThemeText(void) {
    return [UIColor colorWithRed:0.15 green:0.14 blue:0.18 alpha:1];
}

UIColor *RFThemeDim(void) {
    return [UIColor colorWithRed:0.42 green:0.40 blue:0.47 alpha:1];
}

UIColor *RFThemeCard(void) {
    return [UIColor colorWithRed:0.97 green:0.96 blue:0.98 alpha:1];
}

UIFont *RFThemeDisplayFont(CGFloat size) {
    return [UIFont fontWithName:@"AvenirNext-HeavyItalic" size:size] ?: [UIFont boldSystemFontOfSize:size];
}

UIFont *RFThemeLabelFont(CGFloat size) {
    return [UIFont fontWithName:@"AvenirNext-DemiBold" size:size] ?: [UIFont boldSystemFontOfSize:size];
}

// Cinza claro com frisos horizontais, como o tampo do console
UIColor *RFThemeGridColor(void) {
    static UIColor *color;
    if (color) return color;
    CGFloat h = 9;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(4, h), YES, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor colorWithRed:0.80 green:0.79 blue:0.83 alpha:1] setFill];
    CGContextFillRect(ctx, CGRectMake(0, 0, 4, h));
    CGFloat px = 1.0 / [UIScreen mainScreen].scale;
    [[UIColor colorWithRed:0.70 green:0.69 blue:0.74 alpha:1] setFill];   // sulco
    CGContextFillRect(ctx, CGRectMake(0, h - px * 2, 4, px * 2));
    [[UIColor colorWithRed:0.88 green:0.87 blue:0.90 alpha:1] setFill];   // brilho logo abaixo
    CGContextFillRect(ctx, CGRectMake(0, 0, 4, px * 2));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    color = [UIColor colorWithPatternImage:img];
    return color;
}

UIView *RFThemeGridView(void) {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = RFThemeGridColor();
    return v;
}

// Três barras horizontais (roxo, lilás, cinza) com a ponta esquerda inclinada
void RFThemeDrawStripes(CGContextRef ctx, CGRect r, CGFloat width) {
    NSArray *colors = @[RFThemeRed(), RFThemeLilac(), [UIColor colorWithRed:0.62 green:0.60 blue:0.67 alpha:1]];
    CGFloat y = r.origin.y;
    for (NSInteger i = 0; i < 3; i++) {
        CGFloat h = width * (1.0 - i * 0.25);
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(r.origin.x + h, y)];
        [p addLineToPoint:CGPointMake(CGRectGetMaxX(r), y)];
        [p addLineToPoint:CGPointMake(CGRectGetMaxX(r), y + h)];
        [p addLineToPoint:CGPointMake(r.origin.x, y + h)];
        [p closePath];
        [colors[i] setFill];
        [p fill];
        y += h + width * 0.3;
    }
    (void)ctx;
}

// Letreiro em itálico pesado: roxo em degradê, contorno claro e sombra (como uma peça moldada)
UIImage *RFThemeChromeText(NSString *text, CGFloat size) {
    UIFont *font = RFThemeDisplayFont(size);
    NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor whiteColor]};
    CGSize ts = [text sizeWithAttributes:attrs];
    CGFloat pad = size * 0.12;
    CGSize canvas = CGSizeMake(ceil(ts.width + pad * 2), ceil(ts.height + pad * 2));
    CGFloat scale = [UIScreen mainScreen].scale;

    // 1) Máscara do texto
    size_t mw = (size_t)(canvas.width * scale), mh = (size_t)(canvas.height * scale);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef mctx = CGBitmapContextCreate(NULL, mw, mh, 8, mw, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    CGContextSetGrayFillColor(mctx, 0, 1);
    CGContextFillRect(mctx, CGRectMake(0, 0, mw, mh));
    CGContextTranslateCTM(mctx, 0, mh);
    CGContextScaleCTM(mctx, scale, -scale);
    UIGraphicsPushContext(mctx);
    [text drawAtPoint:CGPointMake(pad, pad) withAttributes:attrs];
    UIGraphicsPopContext();
    CGImageRef mask = CGBitmapContextCreateImage(mctx);
    CGContextRelease(mctx);

    UIGraphicsBeginImageContextWithOptions(canvas, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    // 2) Contorno claro com sombra
    NSDictionary *strokeAttrs = @{NSFontAttributeName: font,
                                  NSStrokeColorAttributeName: [UIColor colorWithRed:0.96 green:0.95 blue:0.99 alpha:1],
                                  NSStrokeWidthAttributeName: @(size > 40 ? 10 : 7)};
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, size * 0.05), size * 0.06, [UIColor colorWithRed:0.20 green:0.17 blue:0.30 alpha:0.6].CGColor);
    [text drawAtPoint:CGPointMake(pad, pad) withAttributes:strokeAttrs];
    CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);

    // 3) Preenchimento roxo recortado pela máscara
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0, canvas.height);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextClipToMask(ctx, CGRectMake(0, 0, canvas.width, canvas.height), mask);
    CGFloat comps[] = {
        0.62, 0.55, 0.90, 1,
        0.40, 0.32, 0.70, 1,
        0.27, 0.21, 0.50, 1,
    };
    CGFloat locs[] = {0.0, 0.55, 1.0};
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGGradientRef g = CGGradientCreateWithColorComponents(rgb, comps, locs, 3);
    CGColorSpaceRelease(rgb);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, canvas.height - pad), CGPointMake(0, pad), 0);
    CGGradientRelease(g);
    CGContextRestoreGState(ctx);
    CGImageRelease(mask);

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

void RFThemeApplyNavigationBar(UINavigationBar *bar) {
    bar.barStyle = UIBarStyleBlack;
    bar.barTintColor = [UIColor colorWithRed:0.24 green:0.22 blue:0.28 alpha:1];
    bar.translucent = NO;
    bar.tintColor = RFThemeLilac();
    bar.titleTextAttributes = @{NSFontAttributeName: RFThemeDisplayFont(20), NSForegroundColorAttributeName: [UIColor whiteColor]};
}

// Tabelas agrupadas (telas de Controle): fundo frisado e células claras
void RFThemeApplyTable(UITableView *table) {
    table.backgroundView = RFThemeGridView();
    table.backgroundColor = [UIColor colorWithRed:0.80 green:0.79 blue:0.83 alpha:1];
    table.separatorColor = [UIColor colorWithRed:0.82 green:0.81 blue:0.85 alpha:1];
    table.indicatorStyle = UIScrollViewIndicatorStyleBlack;
}

void RFThemeStyleCell(UITableViewCell *cell) {
    cell.backgroundColor = RFThemeCard();
    if ([cell.textLabel.textColor isEqual:[UIColor blackColor]] || !cell.textLabel.textColor) cell.textLabel.textColor = RFThemeText();
    cell.detailTextLabel.textColor = RFThemeDim();
    UIView *sel = [[UIView alloc] init];
    sel.backgroundColor = [RFThemeLilac() colorWithAlphaComponent:0.45];
    cell.selectedBackgroundView = sel;
}

void RFThemeStyleHeaderFooter(UIView *view, BOOL header) {
    if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
    UITableViewHeaderFooterView *v = (UITableViewHeaderFooterView *)view;
    v.textLabel.textColor = header ? RFThemeRed() : RFThemeDim();
    if (header) v.textLabel.font = RFThemeLabelFont(13);
}
