#import <AppKit/AppKit.h>
#import <math.h>

static void Require(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL %s\n", message.UTF8String);
    exit(1);
}

typedef struct {
    NSInteger size;
    const char *name;
} YMIconSlot;

static const YMIconSlot kSlots[] = {
    {16, "icon_16x16.png"},
    {32, "icon_16x16@2x.png"},
    {32, "icon_32x32.png"},
    {64, "icon_32x32@2x.png"},
    {128, "icon_128x128.png"},
    {256, "icon_128x128@2x.png"},
    {256, "icon_256x256.png"},
    {512, "icon_256x256@2x.png"},
    {512, "icon_512x512.png"},
    {1024, "icon_512x512@2x.png"},
};

static NSBitmapImageRep *LoadPNG(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    Require(data != nil && data.length > 0, [NSString stringWithFormat:@"readable %@", path]);
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithData:data];
    Require(bitmap != nil, [NSString stringWithFormat:@"decodable %@", path]);
    return bitmap;
}

static NSColor *SampleNormalized(NSBitmapImageRep *bitmap, double u, double v) {
    NSInteger n = bitmap.pixelsWide;
    NSInteger x = (NSInteger)lround(u * (n - 1));
    NSInteger y = (NSInteger)lround(v * (n - 1));
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= n) x = n - 1;
    if (y >= n) y = n - 1;
    NSColor *color = [[bitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    Require(color != nil, @"sample converts to sRGB");
    return color;
}

static void AssertIconGeometry(NSBitmapImageRep *bitmap, NSInteger n, NSString *label) {
    Require(bitmap.pixelsWide == n && bitmap.pixelsHigh == n,
        [NSString stringWithFormat:@"%@ size %ldx%ld", label, (long)n, (long)n]);
    Require(bitmap.hasAlpha, [NSString stringWithFormat:@"%@ has alpha", label]);

    NSInteger minX = n, minY = n, maxX = -1, maxY = -1;
    for (NSInteger y = 0; y < n; y++) {
        for (NSInteger x = 0; x < n; x++) {
            NSColor *color = [bitmap colorAtX:x y:y];
            CGFloat alpha = color.alphaComponent;
            if (x == 0 || y == 0 || x == n - 1 || y == n - 1)
                Require(alpha == 0, [NSString stringWithFormat:@"%@ transparent outer edge", label]);
            if (alpha * 255.0 >= 128.0) {
                if (x < minX) minX = x;
                if (y < minY) minY = y;
                if (x > maxX) maxX = x;
                if (y > maxY) maxY = y;
            }
        }
    }

    Require(maxX >= minX && maxY >= minY,
        [NSString stringWithFormat:@"%@ visible icon body", label]);
    NSInteger width = maxX - minX + 1;
    NSInteger height = maxY - minY + 1;
    fprintf(stderr, "INFO %s body bounds min=(%ld,%ld) max=(%ld,%ld) size=%ldx%ld of %ld\n",
        label.UTF8String, (long)minX, (long)minY, (long)maxX, (long)maxY,
        (long)width, (long)height, (long)n);

    if (n >= 64) {
        Require(width >= 0.78 * n && width <= 0.82 * n,
            [NSString stringWithFormat:@"%@ body width occupancy", label]);
        Require(height >= 0.78 * n && height <= 0.82 * n,
            [NSString stringWithFormat:@"%@ body height occupancy", label]);
    } else {
        Require(labs(width - lround(0.80 * n)) <= 1,
            [NSString stringWithFormat:@"%@ small body width", label]);
        Require(labs(height - lround(0.80 * n)) <= 1,
            [NSString stringWithFormat:@"%@ small body height", label]);
    }
    double tolerance = fmax(1.0, 0.01 * n);
    Require(fabs((double)(minX - (n - 1 - maxX))) <= tolerance,
        [NSString stringWithFormat:@"%@ horizontal centering", label]);
    Require(fabs((double)(minY - (n - 1 - maxY))) <= tolerance,
        [NSString stringWithFormat:@"%@ vertical centering", label]);
}

static void AssertBrandFidelity(NSBitmapImageRep *icon, NSBitmapImageRep *source, NSString *label) {
    struct {
        double u;
        double v;
        const char *tag;
    } points[] = {
        {0.20, 0.50, "navy tile"},
        {0.50, 0.50, "warm window"},
        {0.65, 0.22, "crescent notch"},
        {0.50, 0.70, "lower window"},
    };

    NSColor *samples[4];
    for (int i = 0; i < 4; i++) {
        double u = points[i].u;
        double v = points[i].v;
        NSColor *expected = SampleNormalized(source, u, v);
        NSColor *actual = SampleNormalized(icon, 0.09 + 0.82 * u, 0.09 + 0.82 * v);
        samples[i] = actual;
        Require(actual.alphaComponent >= 0.98,
            [NSString stringWithFormat:@"%@ %s opaque", label, points[i].tag]);
        Require(fabs(actual.redComponent - expected.redComponent) <= 0.12 &&
                fabs(actual.greenComponent - expected.greenComponent) <= 0.12 &&
                fabs(actual.blueComponent - expected.blueComponent) <= 0.12,
            [NSString stringWithFormat:@"%@ %s brand RGB", label, points[i].tag]);
    }

    CGFloat windowLuma = samples[1].redComponent + samples[1].greenComponent + samples[1].blueComponent;
    CGFloat tileLuma = samples[0].redComponent + samples[0].greenComponent + samples[0].blueComponent;
    CGFloat notchLuma = samples[2].redComponent + samples[2].greenComponent + samples[2].blueComponent;
    CGFloat lowerLuma = samples[3].redComponent + samples[3].greenComponent + samples[3].blueComponent;
    Require(windowLuma > tileLuma + 0.3 && lowerLuma > tileLuma + 0.3,
        [NSString stringWithFormat:@"%@ window brighter than tile", label]);
    Require(windowLuma > notchLuma + 0.3 && lowerLuma > notchLuma + 0.3,
        [NSString stringWithFormat:@"%@ window brighter than notch", label]);
}

static void AssertRGBAEqual(NSBitmapImageRep *a, NSBitmapImageRep *b, NSString *label) {
    Require(a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh,
        [NSString stringWithFormat:@"%@ matching dimensions", label]);
    NSInteger n = a.pixelsWide;
    const double tol = 1.0 / 255.0;
    for (NSInteger y = 0; y < n; y++) {
        for (NSInteger x = 0; x < n; x++) {
            NSColor *ca = [[a colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            NSColor *cb = [[b colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            Require(ca != nil && cb != nil, [NSString stringWithFormat:@"%@ sRGB sample", label]);
            Require(fabs(ca.redComponent - cb.redComponent) <= tol &&
                    fabs(ca.greenComponent - cb.greenComponent) <= tol &&
                    fabs(ca.blueComponent - cb.blueComponent) <= tol &&
                    fabs(ca.alphaComponent - cb.alphaComponent) <= tol,
                [NSString stringWithFormat:@"%@ pixel (%ld,%ld)", label, (long)x, (long)y]);
        }
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Require(argc == 3 || argc == 4, @"usage: AppIconTests <iconset> <source.png> [comparison-iconset]");
        NSString *iconset = [NSString stringWithUTF8String:argv[1]];
        NSString *sourcePath = [NSString stringWithUTF8String:argv[2]];
        NSString *comparison = argc == 4 ? [NSString stringWithUTF8String:argv[3]] : nil;

        NSBitmapImageRep *source = LoadPNG(sourcePath);
        Require(source.pixelsWide == source.pixelsHigh && source.pixelsWide > 0, @"square source");

        for (size_t i = 0; i < sizeof(kSlots) / sizeof(kSlots[0]); i++) {
            NSString *name = [NSString stringWithUTF8String:kSlots[i].name];
            NSInteger n = kSlots[i].size;
            NSString *path = [iconset stringByAppendingPathComponent:name];
            NSBitmapImageRep *bitmap = LoadPNG(path);
            NSString *label = [NSString stringWithFormat:@"%@", name];
            AssertIconGeometry(bitmap, n, label);
            if (n >= 64)
                AssertBrandFidelity(bitmap, source, label);
            printf("PASS %s geometry%s\n", name.UTF8String, n >= 64 ? " and brand" : "");

            if (comparison) {
                NSString *otherPath = [comparison stringByAppendingPathComponent:name];
                NSBitmapImageRep *other = LoadPNG(otherPath);
                AssertRGBAEqual(bitmap, other, [NSString stringWithFormat:@"%@ vs comparison", name]);
                printf("PASS %s matches comparison iconset\n", name.UTF8String);
            }
        }
    }
    return 0;
}
