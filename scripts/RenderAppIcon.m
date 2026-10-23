#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

static void Fail(const char *stage, const char *path) {
    if (path && path[0])
        fprintf(stderr, "RenderAppIcon failed during %s: %s\n", stage, path);
    else
        fprintf(stderr, "RenderAppIcon failed during %s\n", stage);
}

static BOOL SizeAllowed(long pixels) {
    switch (pixels) {
        case 16: case 32: case 64: case 128: case 256: case 512: case 1024:
            return YES;
        default:
            return NO;
    }
}

static CGContextRef MakeContext(size_t pixels, CGColorSpaceRef colorSpace) {
    return CGBitmapContextCreate(
        NULL, pixels, pixels, 8, 0, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
}

// Draw the source centered at 82% of the canvas with high-quality scaling.
static void DrawPaddedArtwork(CGContextRef context, CGImageRef sourceImage, size_t pixels) {
    const CGFloat fraction = 0.82;
    CGRect canvas = CGRectMake(0, 0, (CGFloat)pixels, (CGFloat)pixels);
    CGFloat edge = (CGFloat)pixels * fraction;
    CGRect artwork = CGRectMake(((CGFloat)pixels - edge) / 2.0,
                                ((CGFloat)pixels - edge) / 2.0, edge, edge);
    CGContextClearRect(context, canvas);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, artwork, sourceImage);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            Fail("argument validation", NULL);
            return 1;
        }

        const char *sourcePath = argv[1];
        const char *outputPath = argv[2];
        const char *sizeText = argv[3];
        char *end = NULL;
        long pixelsLong = strtol(sizeText, &end, 10);
        if (sizeText[0] == '\0' || end == sizeText || *end != '\0' || !SizeAllowed(pixelsLong)) {
            Fail("size validation", sizeText);
            return 1;
        }
        size_t pixels = (size_t)pixelsLong;

        CFURLRef sourceURL = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorDefault, (const UInt8 *)sourcePath, (CFIndex)strlen(sourcePath), false);
        if (!sourceURL) {
            Fail("source URL", sourcePath);
            return 1;
        }

        CGImageSourceRef imageSource = CGImageSourceCreateWithURL(sourceURL, NULL);
        CFRelease(sourceURL);
        if (!imageSource) {
            Fail("source open", sourcePath);
            return 1;
        }

        CFStringRef uti = CGImageSourceGetType(imageSource);
        if (!uti || CFStringCompare(uti, CFSTR("public.png"), 0) != kCFCompareEqualTo) {
            CFRelease(imageSource);
            Fail("PNG type check", sourcePath);
            return 1;
        }

        CGImageRef sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, NULL);
        CFRelease(imageSource);
        if (!sourceImage) {
            Fail("source decode", sourcePath);
            return 1;
        }

        size_t sourceWidth = CGImageGetWidth(sourceImage);
        size_t sourceHeight = CGImageGetHeight(sourceImage);
        if (sourceWidth == 0 || sourceHeight == 0 || sourceWidth != sourceHeight) {
            CGImageRelease(sourceImage);
            Fail("square source", sourcePath);
            return 1;
        }

        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        if (!colorSpace) {
            CGImageRelease(sourceImage);
            Fail("color space", outputPath);
            return 1;
        }

        // High-quality scaling softens the alpha>=128 silhouette by ~1px per
        // side. At 16/32 that exceeds the approved ±1px occupancy tolerance, so
        // render the same 82% geometry at 8x and nearest-neighbor downsample.
        size_t workPixels = pixels <= 32 ? pixels * 8 : pixels;
        CGContextRef workContext = MakeContext(workPixels, colorSpace);
        if (!workContext) {
            CGColorSpaceRelease(colorSpace);
            CGImageRelease(sourceImage);
            Fail("bitmap context", outputPath);
            return 1;
        }

        DrawPaddedArtwork(workContext, sourceImage, workPixels);
        CGImageRelease(sourceImage);

        CGImageRef workImage = CGBitmapContextCreateImage(workContext);
        CGContextRelease(workContext);
        if (!workImage) {
            CGColorSpaceRelease(colorSpace);
            Fail("result image", outputPath);
            return 1;
        }

        CGImageRef resultImage = workImage;
        if (workPixels != pixels) {
            CGContextRef finalContext = MakeContext(pixels, colorSpace);
            if (!finalContext) {
                CGImageRelease(workImage);
                CGColorSpaceRelease(colorSpace);
                Fail("bitmap context", outputPath);
                return 1;
            }
            CGContextClearRect(finalContext, CGRectMake(0, 0, (CGFloat)pixels, (CGFloat)pixels));
            CGContextSetInterpolationQuality(finalContext, kCGInterpolationNone);
            CGContextDrawImage(finalContext, CGRectMake(0, 0, (CGFloat)pixels, (CGFloat)pixels), workImage);
            CGImageRelease(workImage);
            resultImage = CGBitmapContextCreateImage(finalContext);
            CGContextRelease(finalContext);
            if (!resultImage) {
                CGColorSpaceRelease(colorSpace);
                Fail("result image", outputPath);
                return 1;
            }
        }
        CGColorSpaceRelease(colorSpace);

        CFURLRef outputURL = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorDefault, (const UInt8 *)outputPath, (CFIndex)strlen(outputPath), false);
        if (!outputURL) {
            CGImageRelease(resultImage);
            Fail("output URL", outputPath);
            return 1;
        }

        CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
            outputURL, CFSTR("public.png"), 1, NULL);
        CFRelease(outputURL);
        if (!destination) {
            CGImageRelease(resultImage);
            Fail("destination create", outputPath);
            return 1;
        }

        CGImageDestinationAddImage(destination, resultImage, NULL);
        CGImageRelease(resultImage);
        if (!CGImageDestinationFinalize(destination)) {
            CFRelease(destination);
            Fail("destination finalize", outputPath);
            return 1;
        }
        CFRelease(destination);
        return 0;
    }
}
