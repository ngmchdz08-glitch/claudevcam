#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/lock.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

// ─── roothide path helper ────────────────────────────────────────
// roothide remaps /var/jb → actual jailbreak prefix at runtime
extern NSString *jbRootPath(NSString *path) __attribute__((weak_import));

static NSString *jbPath(NSString *path) {
    if (jbRootPath) return jbRootPath(path);
    return path; // fallback: no prefix change
}

// ─── Global State ─────────────────────────────────────────────────
static BOOL isEnabled          = NO;
static BOOL isNetworkMode      = NO;
static BOOL isImageMode        = NO;
static NSString *videoPath     = nil;
static NSString *imagePath     = nil;
static NSString *serverIP      = @"192.168.1.100";
static NSInteger serverPort    = 8080;

static NSString *prefsPath(void) {
    return jbPath(@"/var/mobile/Library/Preferences/com.weat.vcamera.plist");
}

// ─── Frame Buffer ───────────────────────────────────────────────
static CVPixelBufferRef  gAtomicFrame = NULL;
static dispatch_queue_t  gFrameQueue  = nil;
static os_unfair_lock    gFrameLock   = OS_UNFAIR_LOCK_INIT;

static inline void storeFrame(CVPixelBufferRef newBuf) {
    if (!newBuf) return;
    CVPixelBufferRetain(newBuf);
    os_unfair_lock_lock(&gFrameLock);
    CVPixelBufferRef old = gAtomicFrame;
    gAtomicFrame = newBuf;
    os_unfair_lock_unlock(&gFrameLock);
    if (old) CVPixelBufferRelease(old);
}

static inline CVPixelBufferRef borrowFrame(void) {
    os_unfair_lock_lock(&gFrameLock);
    CVPixelBufferRef ref = gAtomicFrame;
    if (ref) CVPixelBufferRetain(ref);
    os_unfair_lock_unlock(&gFrameLock);
    return ref;
}

// ─── Prefs ────────────────────────────────────────────────────────
static void loadPreferences(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefsPath()];
    isEnabled     = [prefs[@"Enabled"]     boolValue];
    isNetworkMode = [prefs[@"NetworkMode"] boolValue];
    isImageMode   = [prefs[@"ImageMode"]   boolValue];
    videoPath     = prefs[@"VideoPath"] ?: jbPath(@"/var/mobile/Media/DCIM/weat_virtual.mp4");
    imagePath     = prefs[@"ImagePath"] ?: @"";

    NSString *addr = prefs[@"ServerIP"] ?: @"192.168.1.100:8080";
    NSArray  *parts = [addr componentsSeparatedByString:@":"];
    serverIP   = parts.firstObject ?: @"192.168.1.100";
    serverPort = parts.count > 1 ? [parts[1] integerValue] : 8080;
}

// ─── Static Image → PixelBuffer ──────────────────────────────────
static void loadStaticImage(void) {
    if (imagePath.length == 0) return;
    UIImage *img = [UIImage imageWithContentsOfFile:imagePath];
    if (!img) return;

    CGImageRef cg = img.CGImage;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);

    CVPixelBufferRef buf = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},          // GPU-accelerated
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h,
            kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)attrs, &buf) != kCVReturnSuccess || !buf) return;

    CVPixelBufferLockBaseAddress(buf, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        CVPixelBufferGetBaseAddress(buf), w, h, 8,
        CVPixelBufferGetBytesPerRow(buf), cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0,0,w,h), cg);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(buf, 0);

    storeFrame(buf);
    CVPixelBufferRelease(buf);
}

// ─── Video Reader (AVAssetReader loop @ 30fps) ────────────────────
static AVAssetReader       *gReader  = nil;
static AVAssetReaderOutput *gOutput  = nil;
static dispatch_source_t    gVTimer  = nil;
static BOOL                 gVActive = NO;

static void stopVideoReader(void) {
    if (gVTimer) { dispatch_source_cancel(gVTimer); gVTimer = nil; }
    [gReader cancelReading];
    gReader = nil; gOutput = nil; gVActive = NO;
}

static void startVideoReader(void);

static void videoTick(void) {
    if (!gReader || gReader.status != AVAssetReaderStatusReading) {
        stopVideoReader(); startVideoReader(); return;
    }
    CMSampleBufferRef sb = [gOutput copyNextSampleBuffer];
    if (!sb) { stopVideoReader(); startVideoReader(); return; }

    // Check dropped-frame reason (iOS 15+ protection)
    CFTypeRef reason = CMGetAttachment(sb,
        kCMSampleBufferAttachmentKey_DroppedFrameReason, NULL);
    if (!reason) {
        CVPixelBufferRef px = CMSampleBufferGetImageBuffer(sb);
        if (px) storeFrame(px);
    }
    CFRelease(sb);
}

static void startVideoReader(void) {
    if (gVActive || !videoPath.length) return;

    NSURL *url = [NSURL fileURLWithPath:videoPath];
    AVAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{
        AVURLAssetPreferPreciseDurationAndTimingKey: @NO  // faster open
    }];

    NSError *err = nil;
    gReader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (err || !gReader) return;

    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) return;

    CGSize nat = track.naturalSize;
    NSDictionary *outSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey:  @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:            @((int)nat.width),
        (id)kCVPixelBufferHeightKey:           @((int)nat.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    gOutput = [[AVAssetReaderTrackOutput alloc]
                initWithTrack:track outputSettings:outSettings];
    gOutput.alwaysCopiesSampleData = NO;
    if (![gReader canAddOutput:gOutput]) return;
    [gReader addOutput:gOutput];
    if (![gReader startReading]) return;

    gVActive = YES;
    uint64_t interval = (uint64_t)(NSEC_PER_SEC / 30);
    gVTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gFrameQueue);
    dispatch_source_set_timer(gVTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval, interval / 2);
    dispatch_source_set_event_handler(gVTimer, ^{ videoTick(); });
    dispatch_resume(gVTimer);
}

// ─── OBS TCP Receiver ────────────────────────────────────────────
static int               gSock     = -1;
static dispatch_source_t gSockSrc  = nil;

static void stopOBS(void) {
    if (gSockSrc) { dispatch_source_cancel(gSockSrc); gSockSrc = nil; }
    if (gSock >= 0) { close(gSock); gSock = -1; }
}

static void scheduleOBSReconnect(void);

static void startOBS(void) {
    stopOBS();
    gSock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (gSock < 0) { scheduleOBSReconnect(); return; }

    // TCP_NODELAY — no delay on small packets
    int yes = 1;
    setsockopt(gSock, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));

    // Non-blocking connect
    fcntl(gSock, F_SETFL, O_NONBLOCK);

    struct sockaddr_in sa = {};
    sa.sin_family = AF_INET;
    sa.sin_port   = htons((uint16_t)serverPort);
    inet_pton(AF_INET, [serverIP UTF8String], &sa.sin_addr);

    connect(gSock, (struct sockaddr *)&sa, sizeof(sa)); // will return EINPROGRESS

    // Wait for connect via write source
    dispatch_source_t connectSrc = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)gSock, 0, gFrameQueue);
    dispatch_source_set_event_handler(connectSrc, ^{
        dispatch_source_cancel(connectSrc);

        int soerr = 0; socklen_t len = sizeof(soerr);
        getsockopt(gSock, SOL_SOCKET, SO_ERROR, &soerr, &len);
        if (soerr != 0) { stopOBS(); scheduleOBSReconnect(); return; }

        // Restore blocking
        fcntl(gSock, F_SETFL, 0);

        // Recv source: protocol = [uint32 width][uint32 height][BGRA pixels]
        gSockSrc = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_READ, (uintptr_t)gSock, 0, gFrameQueue);
        dispatch_source_set_event_handler(gSockSrc, ^{
            uint32_t hdr[2];
            if (recv(gSock, hdr, 8, MSG_WAITALL) < 8) {
                stopOBS(); scheduleOBSReconnect(); return;
            }
            uint32_t w = ntohl(hdr[0]), h = ntohl(hdr[1]);
            if (w == 0 || h == 0 || w > 4096 || h > 4096) return;

            size_t rowBytes = (size_t)w * 4;
            size_t total    = rowBytes * h;
            uint8_t *raw    = (uint8_t *)malloc(total);
            if (!raw) return;

            ssize_t got = 0;
            while ((size_t)got < total) {
                ssize_t n = recv(gSock, raw + got, total - got, 0);
                if (n <= 0) { free(raw); stopOBS(); scheduleOBSReconnect(); return; }
                got += n;
            }

            // Wrap raw buffer — zero-copy via IOSurface-backed pixel buffer
            NSDictionary *attrs = @{
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
            };
            CVPixelBufferRef buf = NULL;
            CVReturn cvr = CVPixelBufferCreateWithBytes(
                kCFAllocatorDefault, w, h,
                kCVPixelFormatType_32BGRA, raw, rowBytes,
                ^(void *refcon, const void *base) { free((void *)base); },
                NULL, (__bridge CFDictionaryRef)attrs, &buf);

            if (cvr == kCVReturnSuccess && buf) {
                storeFrame(buf);
                CVPixelBufferRelease(buf);
            } else {
                free(raw);
            }
        });
        dispatch_resume(gSockSrc);
    });
    dispatch_resume(connectSrc);
}

static void scheduleOBSReconnect(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   gFrameQueue, ^{
        if (isEnabled && isNetworkMode) startOBS();
    });
}

// ─── Engine ───────────────────────────────────────────────────────
static void startEngine(void) {
    if (isNetworkMode)   { stopVideoReader(); startOBS(); }
    else if (isImageMode){ stopVideoReader(); stopOBS();  loadStaticImage(); }
    else                 { stopOBS();         startVideoReader(); }
}

static void stopEngine(void) {
    stopVideoReader(); stopOBS();
}

static void onPrefsReload(CFNotificationCenterRef c, void *o,
                          CFStringRef n, const void *obj,
                          CFDictionaryRef info) {
    loadPreferences();
    if (isEnabled) startEngine(); else stopEngine();
}

// ─── Pixel copy helper ────────────────────────────────────────────
// Injects gAtomicFrame pixels into dst buffer (in-place, zero allocation)
static void injectIntoBuffer(CVPixelBufferRef dst) {
    if (!dst) return;
    CVPixelBufferRef src = borrowFrame();
    if (!src) return;

    CVPixelBufferLockBaseAddress(dst, 0);
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);

    uint8_t *d    = (uint8_t *)CVPixelBufferGetBaseAddress(dst);
    uint8_t *s    = (uint8_t *)CVPixelBufferGetBaseAddress(src);
    size_t  dw    = CVPixelBufferGetWidth(dst),  dh = CVPixelBufferGetHeight(dst);
    size_t  sw    = CVPixelBufferGetWidth(src),  sh = CVPixelBufferGetHeight(src);
    size_t  dRow  = CVPixelBufferGetBytesPerRow(dst);
    size_t  sRow  = CVPixelBufferGetBytesPerRow(src);

    if (d && s) {
        if (dw == sw && dh == sh) {
            // Fast path: single memcpy
            memcpy(d, s, dRow * dh);
        } else {
            // Scale path: row-by-row nearest neighbour (no crash on mismatch)
            size_t rows  = MIN(dh, sh);
            size_t bytes = MIN(dRow, sRow);
            for (size_t r = 0; r < rows; r++)
                memcpy(d + r * dRow, s + r * sRow, bytes);
        }
    }

    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferRelease(src);
}

// ─── HOOK: CMSampleBufferGetImageBuffer (CoreMedia) ──────────────
CVImageBufferRef (*orig_GetImageBuffer)(CMSampleBufferRef);
CVImageBufferRef hook_GetImageBuffer(CMSampleBufferRef sb) {
    CVImageBufferRef orig = orig_GetImageBuffer(sb);
    if (!isEnabled || !orig) return orig;
    injectIntoBuffer((CVPixelBufferRef)orig);
    return orig;
}

// ─── HOOK: AVCaptureVideoDataOutput captureOutput delegate ────────
// Hook sâu hơn: intercept tại output trước khi delegate nhận
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    %orig;
    // Mark that a camera session is active → ensure engine is running
    if (isEnabled && delegate) {
        dispatch_async(gFrameQueue, ^{
            if (isEnabled && !gVActive && !gSockSrc && !isImageMode) startVideoReader();
        });
    }
}

%end

// ─── HOOK: AVCaptureSession ───────────────────────────────────────
%hook AVCaptureSession

- (void)startRunning {
    %orig;
    if (isEnabled) dispatch_async(gFrameQueue, ^{ startEngine(); });
}

- (void)stopRunning {
    %orig;
    // engine keeps running — ready for next startRunning call
}

%end

// ─── Constructor ──────────────────────────────────────────────────
%ctor {
    // High-priority serial queue for frame ops
    dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, -1);
    gFrameQueue = dispatch_queue_create("com.weat.vcamera.fq", qos);

    loadPreferences();

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        onPrefsReload,
        CFSTR("com.weat.vcamera/ReloadPrefs"),
        NULL, CFNotificationSuspensionBehaviorCoalesce);

    MSHookFunction(
        (void *)CMSampleBufferGetImageBuffer,
        (void *)hook_GetImageBuffer,
        (void **)&orig_GetImageBuffer);

    if (isEnabled) startEngine();
}
