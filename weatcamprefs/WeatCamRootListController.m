#import "WeatCamRootListController.h"
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

// ─── roothide path helper ─────────────────────────────────────────
extern NSString *jbRootPath(NSString *path) __attribute__((weak_import));
static NSString *jbPath(NSString *p) { return jbRootPath ? jbRootPath(p) : p; }

#define NOTIFY_KEY  "com.weat.vcamera/ReloadPrefs"

static NSString *prefsFilePath(void) {
    return jbPath(@"/var/mobile/Library/Preferences/com.weat.vcamera.plist");
}

// ─── Prefs I/O ────────────────────────────────────────────────────
static NSDictionary *loadPrefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:prefsFilePath()] ?: @{};
}

static void savePref(NSString *key, id val) {
    NSMutableDictionary *p = [loadPrefs() mutableCopy];
    if (val) p[key] = val; else [p removeObjectForKey:key];
    [p writeToFile:prefsFilePath() atomically:YES];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(NOTIFY_KEY), NULL, NULL, YES);
}

// ─── Controller ───────────────────────────────────────────────────
@implementation WeatCamRootListController

- (NSArray *)specifiers {
    if (!_specifiers)
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"WeatCam";
    self.table.tableHeaderView = [self buildHeader];
    self.navigationController.navigationBar.tintColor =
        [UIColor colorWithRed:0.3 green:0.85 blue:1.0 alpha:1.0];
}

// ─── Header ───────────────────────────────────────────────────────
- (UIView *)buildHeader {
    CGFloat W = UIScreen.mainScreen.bounds.size.width;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0,0,W,110)];

    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = box.bounds;
    g.colors = @[
        (__bridge id)[UIColor colorWithRed:0.04 green:0.06 blue:0.16 alpha:1].CGColor,
        (__bridge id)[UIColor colorWithRed:0.06 green:0.13 blue:0.28 alpha:1].CGColor
    ];
    g.startPoint = CGPointMake(0,0); g.endPoint = CGPointMake(1,1);
    [box.layer addSublayer:g];

    UILabel *t1 = [[UILabel alloc] initWithFrame:CGRectMake(16,18,W-32,34)];
    t1.text = @"🎥  WeatCam Virtual Camera";
    t1.textColor = [UIColor colorWithRed:0.35 green:0.88 blue:1.0 alpha:1];
    t1.font = [UIFont boldSystemFontOfSize:17];
    [box addSubview:t1];

    UILabel *t2 = [[UILabel alloc] initWithFrame:CGRectMake(16,54,W-32,18)];
    t2.text = @"Hook sâu iOS 15+ • roothide • by Weat";
    t2.textColor = [UIColor colorWithWhite:0.65 alpha:1];
    t2.font = [UIFont systemFontOfSize:12];
    [box addSubview:t2];

    UILabel *t3 = [[UILabel alloc] initWithFrame:CGRectMake(16,74,W-32,18)];
    t3.text = @"arm64 / arm64e  •  AVFoundation deep hook";
    t3.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    t3.font = [UIFont systemFontOfSize:11];
    [box addSubview:t3];

    return box;
}

// ─── Actions ──────────────────────────────────────────────────────
- (void)pickVideo {
    self.pickerTarget = @"video";
    UTType *vidType = [UTType typeWithIdentifier:@"public.movie"];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[vidType] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.shouldShowFileExtensions = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)pickImage {
    self.pickerTarget = @"image";
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc]
                                   initWithPhotoLibrary:[PHPhotoLibrary sharedPhotoLibrary]];
    cfg.filter = [PHPickerFilter imagesFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)connectOBS {
    NSDictionary *prefs = loadPrefs();
    NSString *cur = prefs[@"ServerIP"] ?: @"192.168.1.100:8080";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"🔌 Kết Nối OBS"
        message:@"Nhập IP:Port của WeatCam Sender\ntrên PC / Mac (VD: 192.168.1.5:8080)"
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = cur;
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        tf.placeholder  = @"192.168.1.100:8080";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"✅ Lưu & Kết Nối"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *v = alert.textFields.firstObject.text;
            if (v.length) {
                savePref(@"ServerIP",    v);
                savePref(@"NetworkMode", @YES);
                [self showBanner:@"✅ Đã lưu. Bật OBS mode!"];
                [self reloadSpecifiers];
            }
        }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ"
        style:UIAlertActionStyleCancel handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)testConnection {
    NSDictionary *prefs = loadPrefs();
    NSString *addr  = prefs[@"ServerIP"] ?: @"192.168.1.100:8080";
    NSArray  *parts = [addr componentsSeparatedByString:@":"];
    NSString *ip    = parts.firstObject;
    uint16_t  port  = (uint16_t)(parts.count > 1 ? [parts[1] intValue] : 8080);

    [self showBanner:@"🔍 Đang test kết nối..."];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int sk = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        struct timeval tv = {3, 0};
        setsockopt(sk, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(sk, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        struct sockaddr_in sa = {};
        sa.sin_family = AF_INET;
        sa.sin_port   = htons(port);
        inet_pton(AF_INET, ip.UTF8String, &sa.sin_addr);

        BOOL ok = (connect(sk, (struct sockaddr *)&sa, sizeof(sa)) == 0);
        close(sk);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self showBanner:ok
                ? [NSString stringWithFormat:@"✅ OK! %@:%d online", ip, port]
                : [NSString stringWithFormat:@"❌ Không kết nối được %@:%d", ip, port]];
        });
    });
}

// ─── PHPickerViewControllerDelegate ──────────────────────────────
- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *res = results.firstObject;
    if (!res) return;

    NSString *dest = jbPath(@"/var/mobile/Media/DCIM/weat_virtual_img.jpg");

    // Load as UIImage → save JPEG
    [res.itemProvider loadObjectOfClass:[UIImage class]
                      completionHandler:^(UIImage *img, NSError *err) {
        if (!img) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showBanner:@"❌ Không lấy được ảnh"]; });
            return;
        }
        NSData *data = UIImageJPEGRepresentation(img, 0.92);
        dispatch_async(dispatch_get_main_queue(), ^{
            [data writeToFile:dest atomically:YES];
            savePref(@"ImagePath", dest);
            savePref(@"ImageMode", @YES);
            [self showBanner:@"✅ Đã lưu ảnh. Reload prefs!"];
            [self reloadSpecifiers];
        });
    }];
}

// ─── UIDocumentPickerDelegate ─────────────────────────────────────
- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    NSString *dest = jbPath(@"/var/mobile/Media/DCIM/weat_virtual.mp4");
    NSError *err;
    [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
    BOOL ok = [[NSFileManager defaultManager]
                copyItemAtURL:url
                        toURL:[NSURL fileURLWithPath:dest]
                        error:&err];

    savePref(@"VideoPath",  dest);
    savePref(@"ImageMode",  @NO);
    [self showBanner:ok ? @"✅ Video đã copy xong!" : @"❌ Lỗi copy video"];
    [self reloadSpecifiers];
}

// ─── Banner ───────────────────────────────────────────────────────
- (void)showBanner:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *ws = (UIWindowScene *)[UIApplication.sharedApplication
            .connectedScenes.allObjects firstObject];
        UIWindow *win = ws.windows.firstObject;
        if (!win) return;

        CGFloat W = win.bounds.size.width;
        UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(12, -64, W-24, 52)];
        banner.backgroundColor = [UIColor colorWithRed:0.04 green:0.16 blue:0.32 alpha:0.96];
        banner.layer.cornerRadius  = 14;
        banner.layer.shadowOpacity = 0.45;
        banner.layer.shadowRadius  = 10;
        banner.layer.shadowOffset  = CGSizeMake(0, 4);

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14,0,W-52,52)];
        lbl.text      = msg;
        lbl.textColor = [UIColor whiteColor];
        lbl.font      = [UIFont boldSystemFontOfSize:14];
        lbl.numberOfLines = 2;
        [banner addSubview:lbl];
        [win addSubview:banner];

        [UIView animateWithDuration:0.35
                              delay:0
             usingSpringWithDamping:0.72
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            banner.frame = CGRectMake(12, win.safeAreaInsets.top + 8, W-24, 52);
        } completion:^(BOOL done) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{ banner.alpha = 0; }
                                 completion:^(BOOL f){ [banner removeFromSuperview]; }];
            });
        }];
    });
}

@end
