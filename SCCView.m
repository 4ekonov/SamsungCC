#import "SCC.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define CALL_B(o, s)        (((BOOL (*)(id, SEL))objc_msgSend)((o), sel_registerName(s)))
#define CALL_V_B(o, s, a)   (((void (*)(id, SEL, BOOL))objc_msgSend)((o), sel_registerName(s), (a)))
#define CALL_V(o, s)        (((void (*)(id, SEL))objc_msgSend)((o), sel_registerName(s)))
#define HAS(o, s)           ([(o) respondsToSelector:sel_registerName(s)])

static NSString *const kLayoutKey = @"SCC.layout.v2";

#pragma mark - Каталог плиток

// k: t = переключатель, s = слайдер, m = медиа
// s: допустимые размеры "WxH" (в клетках, сетка 4 колонки)
// o: что открыть по тапу (bundle id или URL)   p: что открыть по долгому нажатию
#define E(n, i, k, ...) @{@"n":n, @"i":i, @"k":k, @"s":@[__VA_ARGS__]}
#define EO(n, i, k, o, ...) @{@"n":n, @"i":i, @"k":k, @"o":o, @"s":@[__VA_ARGS__]}

static NSDictionary *Cat(void) {
    static NSDictionary *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = @{
            @"wifi":       @{@"n":@"Wi-Fi", @"i":@"wifi", @"k":@"t", @"p":@"prefs:root=WIFI", @"s":@[@"2x1", @"1x1", @"2x2"]},
            @"bluetooth":  @{@"n":@"Bluetooth", @"i":@"bluetooth", @"k":@"t", @"p":@"prefs:root=Bluetooth", @"s":@[@"2x1", @"1x1", @"2x2"]},
            @"connect":    @{@"n":@"Connectivity", @"i":@"wifi", @"k":@"g", @"s":@[@"2x2"]},
            @"airplane":   E(@"Airplane", @"airplane", @"t", @"1x1", @"2x1"),
            @"cellular":   @{@"n":@"Mobile data", @"i":@"arrow.up.arrow.down", @"k":@"t", @"o":@"prefs:root=MOBILE_DATA_SETTINGS_ID", @"s":@[@"1x1", @"2x1"]},
            @"flashlight": E(@"Flashlight", @"flashlight.on.fill", @"t", @"1x1", @"2x1"),
            @"rotation":   E(@"Rotation lock", @"lock.rotation", @"t", @"1x1", @"2x1"),
            @"dark":       @{@"n":@"Dark mode", @"i":@"moon.fill", @"k":@"t", @"p":@"prefs:root=DISPLAY", @"s":@[@"1x1", @"2x1"]},
            @"lowpower":   @{@"n":@"Power saving", @"i":@"battery.25", @"k":@"t", @"p":@"prefs:root=BATTERY_USAGE", @"s":@[@"1x1", @"2x1"]},
            @"mute":       E(@"Mute", @"speaker.slash.fill", @"t", @"1x1", @"2x1"),
            @"location":   EO(@"Location", @"mappin.and.ellipse", @"t", @"prefs:root=Privacy&path=LOCATION", @"1x1", @"2x1"),
            @"modes":      EO(@"Modes", @"bed.double.fill", @"t", @"prefs:root=DO_NOT_DISTURB", @"2x1", @"1x1"),
            @"smartview":  @{@"n":@"Smart View", @"i":@"rectangle.on.rectangle", @"k":@"t", @"o":@"prefs:root=DISPLAY", @"sub":@"Mirror screen", @"s":@[@"2x1", @"1x1"]},
            @"nearby":     EO(@"Nearby devices", @"dot.radiowaves.left.and.right", @"t", @"prefs:root=Bluetooth", @"2x1", @"1x1"),
            @"camera":     EO(@"Camera", @"camera.fill", @"t", @"com.apple.camera", @"1x1", @"2x1"),
            @"calculator": EO(@"Calculator", @"plus.forwardslash.minus", @"t", @"com.apple.calculator", @"1x1", @"2x1"),
            @"timer":      EO(@"Timer", @"timer", @"t", @"com.apple.mobiletimer", @"1x1", @"2x1"),
            @"notes":      EO(@"Notes", @"note.text", @"t", @"com.apple.mobilenotes", @"1x1", @"2x1"),
            @"magnifier":  EO(@"Magnifier", @"magnifyingglass", @"t", @"com.apple.Magnifier", @"1x1", @"2x1"),
            @"settings":   EO(@"Settings", @"gearshape.fill", @"t", @"com.apple.Preferences", @"1x1", @"2x1"),
            @"brightness": E(@"Brightness", @"sun.max.fill", @"s", @"1x3", @"3x1", @"4x1", @"2x1"),
            @"volume":     E(@"Volume", @"speaker.wave.2.fill", @"s", @"1x3", @"3x1", @"4x1", @"2x1"),
            @"media":      E(@"Media", @"music.note", @"m", @"2x2", @"4x2", @"4x1"),
        };
    });
    return c;
}

static NSArray *DefaultLayout(void) {
    return @[@"connect:2x2", @"media:2x2",
             @"rotation:1x1", @"location:1x1", @"brightness:1x3", @"volume:1x3",
             @"modes:2x1", @"smartview:2x1",
             @"flashlight:1x1", @"magnifier:1x1", @"lowpower:1x1", @"camera:1x1",
             @"calculator:1x1", @"timer:1x1", @"notes:1x1", @"settings:1x1"];
}

static BOOL ParseItem(NSString *s, NSString **tid, int *w, int *h) {
    NSArray *a = [s componentsSeparatedByString:@":"];
    if (a.count != 2) return NO;
    NSArray *b = [a[1] componentsSeparatedByString:@"x"];
    if (b.count != 2 || !Cat()[a[0]]) return NO;
    *tid = a[0]; *w = [b[0] intValue]; *h = [b[1] intValue];
    return (*w >= 1 && *w <= 4 && *h >= 1 && *h <= 4);
}

#pragma mark - Системные вызовы (private API)

static id Obj(const char *cn, const char *sel) {
    Class c = objc_getClass(cn);
    SEL s = sel_registerName(sel);
    if (!c || ![c respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(c, s);
}

static void OpenTarget(NSString *t) {
    if (!t.length) t = @"com.apple.Preferences";
    id ws = Obj("LSApplicationWorkspace", "defaultWorkspace");
    if (!ws) return;
    if ([t containsString:@":"]) {
        SEL s = sel_registerName("openSensitiveURL:withOptions:");
        if ([ws respondsToSelector:s])
            ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, s, [NSURL URLWithString:t], nil);
    } else {
        SEL s = sel_registerName("openApplicationWithBundleID:");
        if ([ws respondsToSelector:s])
            ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, s, t);
    }
}

static id RadiosPrefs(void) {
    static id rp;
    if (!rp) { Class c = objc_getClass("RadiosPreferences"); if (c) rp = [[c alloc] init]; }
    return rp;
}

static float GetVolume(void) {
    id av = Obj("AVSystemController", "sharedAVSystemController");
    float v = 0;
    SEL s = sel_registerName("getVolume:forCategory:");
    if ([av respondsToSelector:s])
        ((BOOL (*)(id, SEL, float *, id))objc_msgSend)(av, s, &v, @"Audio/Video");
    return v;
}
static void SetVolume(float v) {
    id av = Obj("AVSystemController", "sharedAVSystemController");
    SEL s = sel_registerName("setVolumeTo:forCategory:");
    if ([av respondsToSelector:s])
        ((BOOL (*)(id, SEL, float, id))objc_msgSend)(av, s, v, @"Audio/Video");
}
static void SetBrightness(float v) {
    id b = Obj("SBBrightnessController", "sharedBrightnessController");
    SEL s = sel_registerName("setBrightnessLevel:");
    if ([b respondsToSelector:s]) ((void (*)(id, SEL, float))objc_msgSend)(b, s, v);
    else [UIScreen mainScreen].brightness = v;
}

static BOOL TileState(NSString *t) {
    if ([t isEqual:@"wifi"]) { id m = Obj("SBWiFiManager", "sharedInstance"); return m && HAS(m, "wiFiEnabled") ? CALL_B(m, "wiFiEnabled") : NO; }
    if ([t isEqual:@"bluetooth"]) { id m = Obj("BluetoothManager", "sharedInstance"); return m && HAS(m, "enabled") ? CALL_B(m, "enabled") : NO; }
    if ([t isEqual:@"airplane"]) { id r = RadiosPrefs(); return r ? CALL_B(r, "airplaneMode") : NO; }
    if ([t isEqual:@"flashlight"]) { AVCaptureDevice *d = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo]; return d.torchMode == AVCaptureTorchModeOn; }
    if ([t isEqual:@"rotation"]) { id m = Obj("SBOrientationLockManager", "sharedInstance"); return m ? CALL_B(m, "isUserLocked") : NO; }
    if ([t isEqual:@"dark"]) return [UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    if ([t isEqual:@"lowpower"]) return [NSProcessInfo processInfo].lowPowerModeEnabled;
    if ([t isEqual:@"mute"]) return GetVolume() < 0.01f;
    return NO;
}

static void TileToggle(NSString *t) {
    BOOL on = TileState(t);
    if ([t isEqual:@"wifi"]) { id m = Obj("SBWiFiManager", "sharedInstance"); if (m) CALL_V_B(m, "setWiFiEnabled:", !on); }
    else if ([t isEqual:@"bluetooth"]) { id m = Obj("BluetoothManager", "sharedInstance"); if (m) CALL_V_B(m, "setPowered:", !on); if (m && HAS(m, "setEnabled:")) CALL_V_B(m, "setEnabled:", !on); }
    else if ([t isEqual:@"airplane"]) { id r = RadiosPrefs(); if (r) { CALL_V_B(r, "setAirplaneMode:", !on); CALL_V(r, "synchronize"); } }
    else if ([t isEqual:@"flashlight"]) {
        AVCaptureDevice *d = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if (d.hasTorch && [d lockForConfiguration:nil]) {
            d.torchMode = on ? AVCaptureTorchModeOff : AVCaptureTorchModeOn;
            [d unlockForConfiguration];
        }
    }
    else if ([t isEqual:@"rotation"]) { id m = Obj("SBOrientationLockManager", "sharedInstance"); if (m) CALL_V(m, on ? "unlock" : "lock"); }
    else if ([t isEqual:@"dark"]) { id a = Obj("UIUserInterfaceStyleArbiter", "sharedInstance"); if (a && HAS(a, "toggleCurrentStyle")) CALL_V(a, "toggleCurrentStyle"); }
    else if ([t isEqual:@"lowpower"]) {
        id b = Obj("_CDBatterySaver", "batterySaver");
        SEL s = sel_registerName("setPowerMode:error:");
        if ([b respondsToSelector:s]) ((BOOL (*)(id, SEL, long long, id))objc_msgSend)(b, s, on ? 0 : 1, nil);
    }
    else if ([t isEqual:@"mute"]) {
        static float last = 0.5f;
        float v = GetVolume();
        if (v > 0.01f) { last = v; SetVolume(0); } else SetVolume(last);
    }
}

#pragma mark - MediaRemote

typedef void (^MRInfoBlock)(CFDictionaryRef info);
static void (*MRGetInfo)(dispatch_queue_t, MRInfoBlock);
static Boolean (*MRSend)(int, id);

static void MRInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (h) {
            MRGetInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
            MRSend = dlsym(h, "MRMediaRemoteSendCommand");
        }
    });
}

#pragma mark - Утилиты

static void Tick(void) {
    UISelectionFeedbackGenerator *g = [UISelectionFeedbackGenerator new];
    [g selectionChanged];
}

static CGFloat TopInset(void) {
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGFloat r = MAX(s.width, s.height) / MIN(s.width, s.height);
    return r > 2.0 ? 54 : 22;   // айфон с вырезом / с рамками
}

BOOL SCCIsEnabled(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.samsungcc.tweak"];
    id v = [d objectForKey:@"enabled"];
    return v ? [v boolValue] : YES;
}

void SCCLog(NSString *msg) {
    NSString *path = @"/var/mobile/SamsungCC.log";
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([at fileSize] > 200000) return;
    NSData *line = [[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [line writeToFile:path atomically:NO]; return; }
    [h seekToEndOfFile];
    [h writeData:line];
    [h closeFile];
}

static NSUserDefaults *Prefs(void) {
    return [[NSUserDefaults alloc] initWithSuiteName:@"com.samsungcc.tweak"];
}

#pragma mark - Хранилище уведомлений

@interface SCCNote : NSObject
@property (nonatomic, strong) id request;
@property (nonatomic, copy) NSString *ident, *bundle, *app, *title, *message;
@property (nonatomic, strong) NSDate *date;
@end
@implementation SCCNote
@end

static NSMutableArray<SCCNote *> *gNotes;
static __weak id gMaster;

static id SafeKV(id o, NSString *k) {
    if (!o) return nil;
    @try { return [o valueForKey:k]; } @catch (NSException *e) { return nil; }
}
static NSString *Str(id o) { return [o isKindOfClass:[NSString class]] ? o : nil; }

void SCCNotifInsert(id r, id master) {
    if (!r) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gNotes) gNotes = [NSMutableArray new];
        if (master) gMaster = master;
        id content = SafeKV(r, @"content");
        SCCNote *n = [SCCNote new];
        n.request = r;
        n.ident = Str(SafeKV(r, @"notificationIdentifier"));
        n.bundle = Str(SafeKV(r, @"sectionIdentifier"));
        n.app = Str(SafeKV(content, @"header"));
        n.title = Str(SafeKV(content, @"title"));
        n.message = Str(SafeKV(content, @"message"));
        id d = SafeKV(content, @"date");
        if (![d isKindOfClass:[NSDate class]]) d = SafeKV(r, @"timestamp");
        n.date = [d isKindOfClass:[NSDate class]] ? d : [NSDate date];
        for (SCCNote *o in [gNotes copy]) {
            if (o.request == r || (n.ident && [o.ident isEqual:n.ident])) [gNotes removeObject:o];
        }
        [gNotes insertObject:n atIndex:0];
        [[SCCManager shared] notesChanged];
    });
}

void SCCNotifRemove(id r) {
    if (!r) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *ident = Str(SafeKV(r, @"notificationIdentifier"));
        for (SCCNote *o in [gNotes copy]) {
            if (o.request == r || (ident && [o.ident isEqual:ident])) [gNotes removeObject:o];
        }
        [[SCCManager shared] notesChanged];
    });
}

static void RemoveFromSystem(SCCNote *n) {
    id m = gMaster;
    SEL s = sel_registerName("removeNotificationRequest:");
    if (m && n.request && [m respondsToSelector:s]) ((void (*)(id, SEL, id))objc_msgSend)(m, s, n.request);
}

#pragma mark - Плитка

static UIColor *GlassFill(void)  { return [UIColor colorWithRed:0.50 green:0.52 blue:0.56 alpha:0.36]; }
static UIColor *GlassDeep(void)  { return [UIColor colorWithRed:0.36 green:0.38 blue:0.43 alpha:0.30]; }
static UIColor *Ink(void)        { return [UIColor colorWithWhite:0.16 alpha:1]; }
static UIColor *OutlineC(void)   { return [UIColor colorWithWhite:1 alpha:0.55]; }
static UIColor *ActiveFill(void) { return [UIColor colorWithWhite:1 alpha:0.97]; }

// У Bluetooth нет системного SF Symbol, поэтому рисуем руну сами
static UIImage *BTImage(CGFloat sz) {
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(sz, sz)];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPath];
        CGFloat s = sz;
        [p moveToPoint:CGPointMake(0.27 * s, 0.30 * s)];
        [p addLineToPoint:CGPointMake(0.73 * s, 0.70 * s)];
        [p addLineToPoint:CGPointMake(0.50 * s, 0.92 * s)];
        [p addLineToPoint:CGPointMake(0.50 * s, 0.08 * s)];
        [p addLineToPoint:CGPointMake(0.73 * s, 0.30 * s)];
        [p addLineToPoint:CGPointMake(0.27 * s, 0.70 * s)];
        p.lineWidth = s * 0.085;
        p.lineCapStyle = kCGLineCapRound;
        p.lineJoinStyle = kCGLineJoinRound;
        [[UIColor blackColor] setStroke];
        [p stroke];
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIImage *Icon(NSString *name, CGFloat pt) {
    if ([name isEqual:@"bluetooth"]) return BTImage(pt);
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightRegular];
    UIImage *i = [UIImage systemImageNamed:name withConfiguration:cfg];
    if (!i) i = [UIImage systemImageNamed:@"circle" withConfiguration:cfg];
    return [i imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static NSString *TimeStr(double t) {
    if (t < 0 || isnan(t)) t = 0;
    return [NSString stringWithFormat:@"%02d:%02d", (int)t / 60, (int)t % 60];
}

@class SCCView;

@interface SCCTile : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSString *tid;
@property (nonatomic) int w, h;
@property (nonatomic, readonly) NSDictionary *info;
@property (nonatomic) BOOL editing;
@property (nonatomic) CGRect slot;
@property (nonatomic) CGPoint origin;
@property (nonatomic, weak) SCCView *host;
@property (nonatomic, strong) UILongPressGestureRecognizer *dragLP;
@property (nonatomic, strong) UIButton *minus;
@property (nonatomic, strong) UIView *handle;
- (instancetype)initWithId:(NSString *)tid w:(int)w h:(int)h host:(SCCView *)host;
- (void)refresh;
@end

@implementation SCCTile {
    UIView *_bg, *_plate, *_fill, *_edge, *_artDim, *_prog, *_progFill;
    UIImageView *_icon, *_art;
    UILabel *_label, *_sub, *_title, *_artist, *_t0, *_t1;
    UIButton *_prev, *_play, *_next, *_comp;
    NSMutableArray<UIView *> *_gc;
    NSMutableArray<UIImageView *> *_gi;
    float _val;
    CGFloat _frac;
    BOOL _playing, _on, _hasArt, _interacting;
    double _elapsed, _duration;
    NSDate *_stamp;
}

- (NSDictionary *)info { return Cat()[_tid]; }
- (NSString *)kind { return self.info[@"k"]; }
- (BOOL)isVertical { return [self.kind isEqual:@"s"] && _w == 1 && _h >= 2; }

- (instancetype)initWithId:(NSString *)tid w:(int)w h:(int)h host:(SCCView *)host {
    self = [super initWithFrame:CGRectZero];
    _tid = tid; _w = w; _h = h; _host = host;
    NSString *k = self.kind;
    BOOL isT = [k isEqual:@"t"], isS = [k isEqual:@"s"], isM = [k isEqual:@"m"], isG = [k isEqual:@"g"];

    _bg = [UIView new];
    _bg.layer.masksToBounds = YES;
    _bg.layer.borderWidth = 1;
    _bg.layer.borderColor = OutlineC().CGColor;
    [self addSubview:_bg];

    if (isS) {
        _fill = [UIView new];
        _fill.backgroundColor = ActiveFill();
        [_bg addSubview:_fill];
    }
    if (isM) {
        _art = [UIImageView new];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.clipsToBounds = YES;
        _art.hidden = YES;
        [_bg addSubview:_art];
        _artDim = [UIView new];
        _artDim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.30];
        _artDim.hidden = YES;
        [_bg addSubview:_artDim];
    }

    _plate = [UIView new];
    _plate.layer.masksToBounds = YES;
    [self addSubview:_plate];
    _icon = [UIImageView new];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_icon];
    _label = [UILabel new];
    _label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self addSubview:_label];
    _sub = [UILabel new];
    _sub.font = [UIFont systemFontOfSize:12.5];
    [self addSubview:_sub];
    if (!isT) { _plate.hidden = YES; _label.hidden = YES; _sub.hidden = YES; }
    if (!isT && !isS) _icon.hidden = YES;

    if (isS) {
        _comp = [UIButton buttonWithType:UIButtonTypeCustom];
        _comp.layer.masksToBounds = YES;
        [_comp addTarget:self action:@selector(compTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_comp];
    }

    if (isM) {
        _title = [UILabel new];
        _title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        _artist = [UILabel new];
        _artist.font = [UIFont systemFontOfSize:12.5];
        _t0 = [UILabel new]; _t0.font = [UIFont monospacedDigitSystemFontOfSize:9.5 weight:UIFontWeightRegular];
        _t1 = [UILabel new]; _t1.font = [UIFont monospacedDigitSystemFontOfSize:9.5 weight:UIFontWeightRegular];
        _t1.textAlignment = NSTextAlignmentRight;
        _prog = [UIView new]; _prog.layer.cornerRadius = 1.5;
        _progFill = [UIView new]; _progFill.layer.cornerRadius = 1.5;
        [_prog addSubview:_progFill];
        for (UIView *v in @[_title, _artist, _t0, _t1, _prog]) [self addSubview:v];
        _prev = [self mediaBtn:@selector(prevTapped)];
        _play = [self mediaBtn:@selector(playTapped)];
        _next = [self mediaBtn:@selector(nextTapped)];
    }

    if (isG) {
        _gc = [NSMutableArray new];
        _gi = [NSMutableArray new];
        for (int i = 0; i < 4; i++) {
            UIView *c = [UIView new];
            c.layer.masksToBounds = YES;
            c.layer.borderWidth = 1;
            c.layer.borderColor = OutlineC().CGColor;
            [self addSubview:c];
            UIImageView *iv = [UIImageView new];
            iv.contentMode = UIViewContentModeScaleAspectFit;
            [self addSubview:iv];
            [_gc addObject:c];
            [_gi addObject:iv];
        }
    }

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    tap.delegate = self;
    [self addGestureRecognizer:tap];
    UILongPressGestureRecognizer *open = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longOpen:)];
    open.minimumPressDuration = 0.5;
    open.delegate = self;
    [self addGestureRecognizer:open];
    if (isS) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(slide:)];
        pan.delegate = self;
        [self addGestureRecognizer:pan];
    }
    _dragLP = [[UILongPressGestureRecognizer alloc] initWithTarget:nil action:nil];
    _dragLP.minimumPressDuration = 0.12;
    _dragLP.delegate = self;
    [self addGestureRecognizer:_dragLP];

    // оформление режима редактирования
    _edge = [UIView new];
    _edge.userInteractionEnabled = NO;
    _edge.layer.borderWidth = 1.5;
    _edge.layer.borderColor = [Ink() colorWithAlphaComponent:0.55].CGColor;
    _edge.alpha = 0;
    [self addSubview:_edge];

    _minus = [UIButton buttonWithType:UIButtonTypeSystem];
    _minus.backgroundColor = [UIColor colorWithWhite:0.14 alpha:0.94];
    _minus.tintColor = [UIColor whiteColor];
    [_minus setImage:[UIImage systemImageNamed:@"minus" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    _minus.layer.cornerRadius = 13;
    _minus.alpha = 0;
    _minus.userInteractionEnabled = NO;
    [self addSubview:_minus];

    _handle = [UIView new];
    _handle.backgroundColor = [UIColor colorWithWhite:0.14 alpha:0.94];
    _handle.layer.cornerRadius = 14;
    UIImageView *hi = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold]]];
    hi.tintColor = [UIColor whiteColor];
    hi.frame = CGRectMake(7, 7, 14, 14);
    hi.contentMode = UIViewContentModeScaleAspectFit;
    [_handle addSubview:hi];
    _handle.alpha = 0;
    _handle.userInteractionEnabled = NO;
    [self addSubview:_handle];

    [self refresh];
    return self;
}

- (UIButton *)mediaBtn:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e {
    if (_editing) {
        if (CGRectContainsPoint(CGRectInset(_minus.frame, -6, -6), p)) return YES;
        if (_handle.alpha > 0.5 && CGRectContainsPoint(CGRectInset(_handle.frame, -8, -8), p)) return YES;
    }
    return [super pointInside:p withEvent:e];
}

- (void)setEditing:(BOOL)e {
    _editing = e;
    BOOL canResize = [self.info[@"s"] count] > 1;
    _minus.userInteractionEnabled = e;
    _handle.userInteractionEnabled = e && canResize;
    _prev.userInteractionEnabled = _play.userInteractionEnabled = _next.userInteractionEnabled = !e;
    _comp.userInteractionEnabled = !e;
    [UIView animateWithDuration:0.25 animations:^{
        self->_edge.alpha = e ? 1 : 0;
        self->_minus.alpha = e ? 1 : 0;
        self->_handle.alpha = (e && canResize) ? 1 : 0;
    }];
    [self.layer removeAnimationForKey:@"wiggle"];
    if (e) {
        CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
        a.values = @[@(-0.008), @(0.008), @(-0.008)];
        a.duration = 0.25 + (arc4random_uniform(100) / 1000.0);
        a.repeatCount = HUGE_VALF;
        [self.layer addAnimation:a forKey:@"wiggle"];
    }
}

- (CGRect)trackRect {
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat compD = W - 10;
    return CGRectMake(5, 5, compD, MAX(10, H - compD - 16));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    NSString *k = self.kind;
    BOOL vert = [self isVertical];
    CGFloat R;

    _bg.frame = self.bounds;

    if ([k isEqual:@"t"]) {
        BOOL round = (_w == 1 && _h == 1);
        BOOL wide = (_h == 1 && _w >= 2);
        R = (_h == 1) ? H / 2 : 34;
        CGFloat a = round ? 0 : 1;
        _plate.alpha = _label.alpha = _sub.alpha = a;
        if (round) {
            _icon.frame = CGRectMake((W - 26) / 2, (H - 26) / 2, 26, 26);
            _plate.frame = CGRectMake(W / 2 - 1, H / 2 - 1, 2, 2);
            _plate.layer.cornerRadius = 1;
        } else if (wide) {
            CGFloat d = H - 16;
            _plate.frame = CGRectMake(8, 8, d, d);
            _plate.layer.cornerRadius = d / 2;
            _icon.frame = CGRectMake(8 + (d - 22) / 2, 8 + (d - 22) / 2, 22, 22);
            CGFloat x = 8 + d + 10, tw = MAX(0, W - x - 12);
            _label.numberOfLines = 1;
            if (_sub.text.length) {
                _label.frame = CGRectMake(x, H / 2 - 20, tw, 20);
                _sub.frame = CGRectMake(x, H / 2 + 1, tw, 16);
            } else {
                _label.frame = CGRectMake(x, 0, tw, H);
            }
        } else {
            _plate.frame = CGRectMake(14, 14, 46, 46);
            _plate.layer.cornerRadius = 23;
            _icon.frame = CGRectMake(14 + 12, 14 + 12, 22, 22);
            _label.numberOfLines = 2;
            if (_sub.text.length) {
                _label.frame = CGRectMake(16, H - 58, MAX(0, W - 32), 22);
                _sub.frame = CGRectMake(16, H - 36, MAX(0, W - 32), 18);
            } else {
                _label.frame = CGRectMake(16, H - 50, MAX(0, W - 32), 36);
            }
        }
    } else if ([k isEqual:@"g"]) {
        R = 36;
        CGFloat pad = 12;
        CGFloat d = MAX(10, MIN((W - 3 * pad) / 2, (H - 3 * pad) / 2));
        CGFloat x0 = (W - (2 * d + pad)) / 2, y0 = (H - (2 * d + pad)) / 2;
        for (int i = 0; i < 4; i++) {
            CGFloat x = x0 + (i % 2) * (d + pad), y = y0 + (i / 2) * (d + pad);
            _gc[i].frame = CGRectMake(x, y, d, d);
            _gc[i].layer.cornerRadius = d / 2;
            _gi[i].frame = CGRectMake(x + (d - 24) / 2, y + (d - 24) / 2, 24, 24);
        }
    } else if ([k isEqual:@"s"]) {
        if (vert) {
            R = W / 2;
            CGRect tr = [self trackRect];
            CGFloat fh = MAX(tr.size.width, tr.size.height * _val);
            _fill.frame = CGRectMake(tr.origin.x, CGRectGetMaxY(tr) - fh, tr.size.width, fh);
            _fill.layer.cornerRadius = tr.size.width / 2;
            _icon.frame = CGRectMake(tr.origin.x + (tr.size.width - 26) / 2, CGRectGetMaxY(tr) - tr.size.width + (tr.size.width - 26) / 2, 26, 26);
            CGFloat cd = W - 10;
            _comp.frame = CGRectMake(5, H - cd - 5, cd, cd);
            _comp.layer.cornerRadius = cd / 2;
            _comp.alpha = 1;
        } else {
            R = H / 2;
            _fill.frame = CGRectMake(0, 0, MAX(H, W * _val), H);
            _fill.layer.cornerRadius = 0;
            _icon.frame = CGRectMake(18, (H - 26) / 2, 26, 26);
            _comp.alpha = 0;
        }
    } else { // media
        BOOL big = _h >= 2;
        R = big ? 30 : H / 2;
        _art.frame = _artDim.frame = _bg.bounds;
        CGFloat pad = 16;
        if (big) {
            _title.frame = CGRectMake(pad, 12, MAX(0, W - 2 * pad), 20);
            _artist.frame = CGRectMake(pad, 32, MAX(0, W - 2 * pad), 16);
            CGFloat py = 60;
            _prog.frame = CGRectMake(pad, py, MAX(0, W - 2 * pad), 3);
            _progFill.frame = CGRectMake(0, 0, _prog.bounds.size.width * _frac, 3);
            _t0.frame = CGRectMake(pad, py + 6, 50, 12);
            _t1.frame = CGRectMake(W - pad - 50, py + 6, 50, 12);
            _t0.alpha = _t1.alpha = _prog.alpha = 1;
            CGFloat bw = 44, by = H - bw - 8;
            _prev.frame = CGRectMake(W / 2 - bw * 1.5, by, bw, bw);
            _play.frame = CGRectMake(W / 2 - bw / 2, by, bw, bw);
            _next.frame = CGRectMake(W / 2 + bw / 2, by, bw, bw);
        } else {
            _title.frame = CGRectMake(pad + 4, 10, MAX(0, W / 2 - pad), 20);
            _artist.frame = CGRectMake(pad + 4, 32, MAX(0, W / 2 - pad), 16);
            _t0.alpha = _t1.alpha = _prog.alpha = 0;
            CGFloat bw = 44, by = (H - bw) / 2, cx = W * 0.74;
            _prev.frame = CGRectMake(cx - bw * 1.5, by, bw, bw);
            _play.frame = CGRectMake(cx - bw / 2, by, bw, bw);
            _next.frame = CGRectMake(cx + bw / 2, by, bw, bw);
        }
    }

    _bg.layer.cornerRadius = R;
    _edge.frame = self.bounds;
    _edge.layer.cornerRadius = R;
    _minus.frame = CGRectMake(-6, -6, 26, 26);
    _handle.frame = CGRectMake(W - 22, H - 22, 28, 28);
}

- (void)refresh {
    NSDictionary *i = self.info;
    NSString *k = self.kind;

    if ([k isEqual:@"t"]) {
        BOOL stateful = (i[@"o"] == nil);
        _on = stateful && TileState(_tid);
        BOOL round = (_w == 1 && _h == 1);
        _icon.image = Icon(i[@"i"], 22);
        _label.text = i[@"n"];
        _label.textColor = Ink();
        _sub.textColor = [UIColor colorWithWhite:0.22 alpha:0.85];
        _bg.backgroundColor = _on ? ActiveFill() : GlassFill();
        if (round) {
            _icon.tintColor = Ink();
        } else {
            _plate.backgroundColor = _on ? [UIColor colorWithWhite:0.16 alpha:0.92] : GlassDeep();
            _icon.tintColor = _on ? [UIColor whiteColor] : Ink();
        }
        NSString *st = i[@"sub"] ?: (stateful ? (_on ? @"On" : @"Off") : nil);
        if (![st isEqual:_sub.text]) { _sub.text = st; [self setNeedsLayout]; }
    } else if ([k isEqual:@"g"]) {
        _bg.backgroundColor = GlassFill();
        NSArray *ids = @[@"wifi", @"bluetooth", @"airplane", @"cellular"];
        for (int n = 0; n < 4; n++) {
            BOOL on = (n < 3) && TileState(ids[n]);
            _gc[n].backgroundColor = on ? ActiveFill() : GlassDeep();
            _gi[n].image = Icon(Cat()[ids[n]][@"i"], 24);
            _gi[n].tintColor = Ink();
        }
    } else if ([k isEqual:@"s"]) {
        _bg.backgroundColor = GlassFill();
        _icon.image = Icon(i[@"i"], 22);
        _icon.tintColor = Ink();
        if (!_interacting) _val = [_tid isEqual:@"brightness"] ? [UIScreen mainScreen].brightness : GetVolume();
        if ([self isVertical]) {
            BOOL bright = [_tid isEqual:@"brightness"];
            BOOL on = bright ? TileState(@"dark") : TileState(@"mute");
            NSString *sym = bright ? @"moon.fill" : (on ? @"speaker.slash.fill" : @"speaker.wave.2.fill");
            [_comp setImage:Icon(sym, 20) forState:UIControlStateNormal];
            _comp.tintColor = Ink();
            _comp.backgroundColor = on ? ActiveFill() : GlassDeep();
        }
        [self setNeedsLayout];
    } else { // media
        _bg.backgroundColor = GlassFill();
        [self applyMediaColors];
        MRInit();
        if (MRGetInfo) {
            __weak SCCTile *ws = self;
            MRGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef d) {
                SCCTile *s = ws;
                if (!s) return;
                NSDictionary *n = d ? (__bridge NSDictionary *)d : nil;
                NSString *t = n[@"kMRMediaRemoteNowPlayingInfoTitle"];
                NSString *a = n[@"kMRMediaRemoteNowPlayingInfoArtist"];
                NSData *art = n[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                s->_title.text = t.length ? t : @"Not playing";
                s->_artist.text = a ?: @"";
                UIImage *ai = art ? [UIImage imageWithData:art] : nil;
                s->_art.image = ai;
                s->_hasArt = (ai != nil);
                s->_art.hidden = s->_artDim.hidden = !s->_hasArt;
                s->_playing = [n[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] floatValue] > 0;
                s->_elapsed = [n[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
                s->_duration = [n[@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
                id st = n[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                s->_stamp = [st isKindOfClass:[NSDate class]] ? st : nil;
                double el = s->_elapsed + ((s->_playing && s->_stamp) ? [[NSDate date] timeIntervalSinceDate:s->_stamp] : 0);
                if (s->_duration > 0) el = MIN(el, s->_duration);
                s->_frac = s->_duration > 0 ? (CGFloat)(el / s->_duration) : 0;
                s->_t0.text = TimeStr(el);
                s->_t1.text = TimeStr(s->_duration);
                [s applyMediaColors];
                [s setNeedsLayout];
            });
        }
    }
}

- (void)applyMediaColors {
    UIColor *tc = _hasArt ? [UIColor whiteColor] : Ink();
    UIColor *sc = _hasArt ? [UIColor colorWithWhite:1 alpha:0.78] : [UIColor colorWithWhite:0.2 alpha:0.75];
    _title.textColor = tc;
    _artist.textColor = sc;
    _t0.textColor = _t1.textColor = sc;
    _prog.backgroundColor = _hasArt ? [UIColor colorWithWhite:1 alpha:0.35] : [UIColor colorWithWhite:0.15 alpha:0.20];
    _progFill.backgroundColor = tc;
    for (UIButton *b in @[_prev, _next]) b.tintColor = tc;
    _play.tintColor = tc;
    [_prev setImage:Icon(@"backward.fill", 19) forState:UIControlStateNormal];
    [_next setImage:Icon(@"forward.fill", 19) forState:UIControlStateNormal];
    [_play setImage:Icon(_playing ? @"pause.fill" : @"play.fill", 23) forState:UIControlStateNormal];
}

#pragma mark действия

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g == _dragLP) {
        if (!_editing) return NO;
        CGPoint p = [g locationInView:self];
        if (_handle.alpha > 0.5 && CGRectContainsPoint(CGRectInset(_handle.frame, -10, -10), p)) return NO;
        if (CGRectContainsPoint(CGRectInset(_minus.frame, -8, -8), p)) return NO;
        return YES;
    }
    if (_editing) return NO;
    if ([g isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:self];
        return [self isVertical] ? (fabs(v.y) > fabs(v.x)) : (fabs(v.x) > fabs(v.y));
    }
    return YES;
}

- (int)groupIndexAt:(CGPoint)p {
    for (int i = 0; i < (int)_gc.count; i++)
        if (CGRectContainsPoint(CGRectInset(_gc[i].frame, -8, -8), p)) return i;
    return -1;
}

- (void)haptic {
    id hv = [Prefs() objectForKey:@"haptics"];
    if (!hv || [hv boolValue]) {
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [fb impactOccurred];
    }
}

- (void)tapped:(UITapGestureRecognizer *)g {
    NSString *k = self.kind;
    if ([k isEqual:@"m"]) return;
    if ([k isEqual:@"s"]) { [self setValueFromPoint:[g locationInView:self]]; return; }
    [self haptic];
    if ([k isEqual:@"g"]) {
        int idx = [self groupIndexAt:[g locationInView:self]];
        if (idx < 0) return;
        NSArray *ids = @[@"wifi", @"bluetooth", @"airplane", @"cellular"];
        NSString *gid = ids[idx];
        if ([gid isEqual:@"cellular"]) { OpenTarget(Cat()[gid][@"o"]); [self.host dismissCC]; return; }
        TileToggle(gid);
        [self refresh];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refresh]; });
        return;
    }
    NSString *o = self.info[@"o"];
    if (o) { OpenTarget(o); [self.host dismissCC]; return; }
    TileToggle(_tid);
    [self refresh];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refresh]; });
}

- (void)longOpen:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSString *p = self.info[@"p"] ?: self.info[@"o"];
    if ([self.kind isEqual:@"g"]) {
        int idx = [self groupIndexAt:[g locationInView:self]];
        NSArray *ids = @[@"wifi", @"bluetooth", @"airplane", @"cellular"];
        if (idx >= 0) p = Cat()[ids[idx]][@"p"] ?: Cat()[ids[idx]][@"o"];
    }
    OpenTarget(p);
    [self.host dismissCC];
}

- (void)slide:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) _interacting = YES;
    [self setValueFromPoint:[g locationInView:self]];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled || g.state == UIGestureRecognizerStateFailed)
        _interacting = NO;
}

- (void)setValueFromPoint:(CGPoint)p {
    float v;
    if ([self isVertical]) {
        CGRect tr = [self trackRect];
        v = (CGRectGetMaxY(tr) - p.y) / tr.size.height;
    } else {
        v = p.x / self.bounds.size.width;
    }
    v = MAX(0, MIN(1, v));
    _val = v;
    if ([_tid isEqual:@"brightness"]) SetBrightness(v); else SetVolume(v);
    [self setNeedsLayout];
}

- (void)compTapped {
    [self haptic];
    TileToggle([_tid isEqual:@"brightness"] ? @"dark" : @"mute");
    [self refresh];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refresh]; });
}

- (void)prevTapped { if (MRSend) MRSend(5, nil); [self performSelector:@selector(refresh) withObject:nil afterDelay:0.4]; }
- (void)nextTapped { if (MRSend) MRSend(4, nil); [self performSelector:@selector(refresh) withObject:nil afterDelay:0.4]; }
- (void)playTapped { if (MRSend) MRSend(2, nil); [self performSelector:@selector(refresh) withObject:nil afterDelay:0.3]; }

@end

#pragma mark - Шторка

static void SCCResetCB(CFNotificationCenterRef c, void *obs, CFStringRef n, const void *o, CFDictionaryRef i) {
    SCCView *v = (__bridge SCCView *)obs;
    dispatch_async(dispatch_get_main_queue(), ^{ ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"loadTiles")); });
}

@interface SCCView () <UIGestureRecognizerDelegate, UIScrollViewDelegate>
@end

@implementation SCCView {
    UIVisualEffectView *_blur;
    UIView *_dim, *_panel, *_qs, *_notif;
    UIScrollView *_pager, *_scroll, *_nScroll;
    UILabel *_time, *_date, *_nTitle, *_empty;
    UIButton *_edit, *_power, *_gear, *_add, *_clear;
    NSMutableArray<SCCTile *> *_tiles;
    BOOL _editing;
    SCCTile *_dragging, *_resizing;
    NSTimer *_timer;
    NSDateFormatter *_tf, *_df, *_nf;
    UIPanGestureRecognizer *_closePan;
    CGFloat _progress, _mx, _cellW, _cellH, _gap, _vgap;
    NSInteger _page;
}

- (NSInteger)currentPage { return _page; }

- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;

    // небольшое размытие, сквозь которое виден рабочий стол / экран блокировки
    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight]];
    _blur.alpha = 0;
    [self addSubview:_blur];
    _dim = [UIView new];
    _dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.12];
    _dim.alpha = 0;
    [self addSubview:_dim];

    _panel = [UIView new];
    [self addSubview:_panel];

    _pager = [UIScrollView new];
    _pager.pagingEnabled = YES;
    _pager.bounces = NO;
    _pager.showsHorizontalScrollIndicator = NO;
    _pager.directionalLockEnabled = YES;
    _pager.delegate = self;
    [_panel addSubview:_pager];

    _notif = [UIView new];
    _qs = [UIView new];
    [_pager addSubview:_notif];
    [_pager addSubview:_qs];

    // --- страница быстрых настроек ---
    _scroll = [UIScrollView new];
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = NO;
    [_qs addSubview:_scroll];

    _tf = [NSDateFormatter new];
    _tf.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"jm" options:0 locale:[NSLocale currentLocale]];
    _df = [NSDateFormatter new];
    _df.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEEdMMM" options:0 locale:[NSLocale currentLocale]];
    _nf = [NSDateFormatter new];
    _nf.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"jm" options:0 locale:[NSLocale currentLocale]];

    _time = [UILabel new];
    _time.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    _time.textColor = [UIColor colorWithWhite:0.1 alpha:1];
    _date = [UILabel new];
    _date.font = [UIFont systemFontOfSize:15];
    _date.textColor = [UIColor colorWithWhite:0.2 alpha:1];
    [_qs addSubview:_time];
    [_qs addSubview:_date];

    _edit = [self headerBtn:@"pencil" action:@selector(toggleEdit)];
    _power = [self headerBtn:@"power" action:@selector(powerTapped)];
    _gear = [self headerBtn:@"gearshape.fill" action:@selector(gearTapped)];

    _add = [UIButton buttonWithType:UIButtonTypeSystem];
    [_add setTitle:@"  Add tile" forState:UIControlStateNormal];
    [_add setImage:[UIImage systemImageNamed:@"plus"] forState:UIControlStateNormal];
    _add.tintColor = [UIColor colorWithWhite:0.1 alpha:1];
    _add.backgroundColor = [UIColor colorWithWhite:1 alpha:0.30];
    _add.layer.cornerRadius = 22;
    _add.hidden = YES;
    [_add addTarget:self action:@selector(addTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:_add];

    // --- страница уведомлений ---
    _nTitle = [UILabel new];
    _nTitle.text = @"Notifications";
    _nTitle.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    _nTitle.textColor = [UIColor colorWithWhite:0.1 alpha:1];
    [_notif addSubview:_nTitle];

    _nScroll = [UIScrollView new];
    _nScroll.showsVerticalScrollIndicator = NO;
    _nScroll.alwaysBounceVertical = YES;
    [_notif addSubview:_nScroll];

    _empty = [UILabel new];
    _empty.text = @"No notifications";
    _empty.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    _empty.textColor = [UIColor colorWithWhite:0.2 alpha:0.7];
    _empty.textAlignment = NSTextAlignmentCenter;
    [_notif addSubview:_empty];

    _clear = [UIButton buttonWithType:UIButtonTypeSystem];
    [_clear setTitle:@"Clear all" forState:UIControlStateNormal];
    _clear.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _clear.tintColor = [UIColor colorWithWhite:0.1 alpha:1];
    _clear.backgroundColor = [UIColor colorWithWhite:1 alpha:0.45];
    _clear.layer.cornerRadius = 22;
    [_clear addTarget:self action:@selector(clearAll) forControlEvents:UIControlEventTouchUpInside];
    [_notif addSubview:_clear];

    // жесты закрытия
    UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTapped)];
    bgTap.delegate = self;
    [self addGestureRecognizer:bgTap];
    _closePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(closePanned:)];
    _closePan.delegate = self;
    [self addGestureRecognizer:_closePan];

    _tiles = [NSMutableArray new];
    [self loadTiles];
    [self tick];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self,
        SCCResetCB, CFSTR("com.samsungcc.tweak/reset"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    [self setProgress:0];
    return self;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self);
}

- (UIButton *)headerBtn:(NSString *)sym action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium]] forState:UIControlStateNormal];
    b.tintColor = [UIColor colorWithWhite:0.1 alpha:1];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    [_qs addSubview:b];
    return b;
}

#pragma mark раскладка

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    _blur.frame = _dim.frame = self.bounds;
    _panel.bounds = CGRectMake(0, 0, W, H);
    _panel.center = CGPointMake(W / 2, H / 2);
    _pager.frame = _panel.bounds;
    _pager.contentSize = CGSizeMake(2 * W, H);
    _notif.bounds = _qs.bounds = CGRectMake(0, 0, W, H);
    _notif.center = CGPointMake(W / 2, H / 2);
    _qs.center = CGPointMake(W + W / 2, H / 2);

    CGFloat top = TopInset();

    // QS
    _time.frame = CGRectMake(20, top + 6, 96, 30);
    _date.frame = CGRectMake(CGRectGetMaxX(_time.frame) + 2, top + 10, 170, 22);
    CGFloat bx = W - 14 - 38;
    _gear.frame = CGRectMake(bx, top + 3, 38, 36);
    _power.frame = CGRectMake(bx - 40, top + 3, 38, 36);
    _edit.frame = CGRectMake(bx - 80, top + 3, 38, 36);
    CGFloat sy = top + 52;
    _scroll.frame = CGRectMake(0, sy, W, H - sy - 20);
    [self relayoutAnimated:NO];

    // уведомления
    _nTitle.frame = CGRectMake(20, top + 6, W - 40, 30);
    CGFloat ny = top + 52;
    _nScroll.frame = CGRectMake(0, ny, W, H - ny - 84);
    _empty.frame = CGRectMake(0, H / 2 - 20, W, 30);
    _clear.frame = CGRectMake(W / 2 - 70, H - 72, 140, 44);
    [self reloadNotifications];
}

static BOOL Fits(BOOL occ[][4], int r, int c, int w, int h) {
    for (int dr = 0; dr < h; dr++)
        for (int dc = 0; dc < w; dc++)
            if (occ[r + dr][c + dc]) return NO;
    return YES;
}

- (void)relayoutAnimated:(BOOL)anim {
    CGFloat W = _scroll.bounds.size.width;
    if (W <= 0) return;
    CGFloat m = 16, g = 10, cw = (W - 2 * m - 3 * g) / 4, ch = 64, vg = 12;
    _mx = m; _cellW = cw; _cellH = ch; _gap = g; _vgap = vg;

    void (^apply)(void) = ^{
        BOOL occ[90][4];
        memset(occ, 0, sizeof(occ));
        int mr = 0;
        for (SCCTile *t in self->_tiles) {
            int w = t.w, h = t.h, pr = 0, pc = 0;
            BOOL found = NO;
            for (int r = 0; r < 80 && !found; r++) {
                for (int c = 0; c + w <= 4; c++) {
                    if (Fits(occ, r, c, w, h)) { pr = r; pc = c; found = YES; break; }
                }
            }
            for (int dr = 0; dr < h; dr++)
                for (int dc = 0; dc < w; dc++)
                    occ[pr + dr][pc + dc] = YES;
            mr = MAX(mr, pr + h);
            CGFloat x = m + pc * (cw + g), y = pr * (ch + vg);
            CGFloat tw = w * cw + (w - 1) * g, th = h * ch + (h - 1) * vg;
            t.origin = CGPointMake(x, y);
            CGRect fr = CGRectMake(x, y, tw, th);
            if (w == 1 && h == 1 && [t.info[@"k"] isEqual:@"t"]) {
                CGFloat sq = MIN(tw, th);
                fr = CGRectMake(x + (tw - sq) / 2, y + (th - sq) / 2, sq, sq);
            }
            t.slot = fr;
            if (t != self->_dragging) { t.frame = fr; if (anim) [t layoutIfNeeded]; }
        }
        CGFloat endY = mr * (ch + vg);
        self->_add.frame = CGRectMake(m, endY, W - 2 * m, 44);
        self->_scroll.contentSize = CGSizeMake(W, endY + 44 + 40);
    };
    if (anim) {
        [UIView animateWithDuration:0.62 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.15
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:apply completion:nil];
    } else {
        apply();
    }
}

#pragma mark плитки

- (void)loadTiles {
    for (SCCTile *t in _tiles) [t removeFromSuperview];
    [_tiles removeAllObjects];
    NSArray *saved = [Prefs() arrayForKey:kLayoutKey] ?: DefaultLayout();
    for (NSString *s in saved) {
        NSString *tid; int w, h;
        if (ParseItem(s, &tid, &w, &h)) [self addTileId:tid w:w h:h];
    }
    [self relayoutAnimated:NO];
}

- (SCCTile *)addTileId:(NSString *)tid w:(int)w h:(int)h {
    SCCTile *t = [[SCCTile alloc] initWithId:tid w:w h:h host:self];
    [t.dragLP addTarget:self action:@selector(drag:)];
    [t.minus addTarget:self action:@selector(removeTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *rp = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(resizePan:)];
    [t.handle addGestureRecognizer:rp];
    t.editing = _editing;
    [_scroll insertSubview:t belowSubview:_add];
    [_tiles addObject:t];
    return t;
}

- (void)save {
    NSMutableArray *a = [NSMutableArray new];
    for (SCCTile *t in _tiles) [a addObject:[NSString stringWithFormat:@"%@:%dx%d", t.tid, t.w, t.h]];
    [Prefs() setObject:a forKey:kLayoutKey];
}

#pragma mark редактирование

- (void)toggleEdit { [self setEditing:!_editing]; }

- (void)setEditing:(BOOL)e {
    _editing = e;
    for (SCCTile *t in _tiles) t.editing = e;
    _add.hidden = !e;
    _pager.scrollEnabled = !e;
    UIImage *img = [UIImage systemImageNamed:e ? @"checkmark" : @"pencil" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold]];
    [_edit setImage:img forState:UIControlStateNormal];
    if (!e) [self save];
}

- (void)drag:(UILongPressGestureRecognizer *)g {
    SCCTile *t = (SCCTile *)g.view;
    CGPoint p = [g locationInView:_scroll];
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            _dragging = t;
            [_scroll bringSubviewToFront:t];
            [t.layer removeAnimationForKey:@"wiggle"];
            [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:0 animations:^{
                t.transform = CGAffineTransformMakeScale(1.07, 1.07);
                t.alpha = 0.92;
            } completion:nil];
            _scroll.scrollEnabled = NO;
            Tick();
            break;
        }
        case UIGestureRecognizerStateChanged: {
            t.center = p;
            CGPoint inView = [g locationInView:_scroll.superview];
            if (inView.y > _scroll.frame.origin.y + _scroll.bounds.size.height - 50)
                [_scroll setContentOffset:CGPointMake(0, MAX(0, MIN(_scroll.contentSize.height - _scroll.bounds.size.height, _scroll.contentOffset.y + 8))) animated:NO];
            else if (inView.y < _scroll.frame.origin.y + 40)
                [_scroll setContentOffset:CGPointMake(0, MAX(0, _scroll.contentOffset.y - 8)) animated:NO];
            for (SCCTile *o in _tiles) {
                if (o == t) continue;
                if (CGRectContainsPoint(o.slot, p)) {
                    NSUInteger to = [_tiles indexOfObject:o];
                    [_tiles removeObject:t];
                    [_tiles insertObject:t atIndex:to];
                    [self relayoutAnimated:YES];
                    Tick();
                    break;
                }
            }
            break;
        }
        default: {
            _dragging = nil;
            _scroll.scrollEnabled = YES;
            [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.4 options:0 animations:^{
                t.transform = CGAffineTransformIdentity;
                t.alpha = 1;
            } completion:nil];
            t.editing = _editing;
            [self relayoutAnimated:YES];
            [self save];
            break;
        }
    }
}

/// Изменение размера: тянешь уголок пальцем, плитка «прилипает» к ближайшему допустимому размеру
- (void)resizePan:(UIPanGestureRecognizer *)g {
    SCCTile *t = (SCCTile *)g.view.superview;
    CGPoint p = [g locationInView:_scroll];
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            _resizing = t;
            _scroll.scrollEnabled = NO;
            [_scroll bringSubviewToFront:t];
            [t.layer removeAnimationForKey:@"wiggle"];
            Tick();
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!_resizing) break;
            CGFloat fw = (p.x - t.origin.x + _gap) / (_cellW + _gap);
            CGFloat fh = (p.y - t.origin.y + _vgap) / (_cellH + _vgap);
            int col = (int)lround((t.origin.x - _mx) / (_cellW + _gap));
            NSString *best = nil;
            CGFloat bd = 1e9;
            for (NSString *s in t.info[@"s"]) {
                NSArray *pp = [s componentsSeparatedByString:@"x"];
                CGFloat w = [pp[0] floatValue], h = [pp[1] floatValue];
                if (col + (int)w > 4) continue;
                CGFloat d = fabs(w - fw) + fabs(h - fh);
                if (d < bd) { bd = d; best = s; }
            }
            if (best) {
                NSArray *pp = [best componentsSeparatedByString:@"x"];
                int nw = [pp[0] intValue], nh = [pp[1] intValue];
                if (nw != t.w || nh != t.h) {
                    t.w = nw; t.h = nh;
                    [t setNeedsLayout];
                    [t refresh];
                    [self relayoutAnimated:YES];
                    Tick();
                }
            }
            break;
        }
        default: {
            _resizing = nil;
            _scroll.scrollEnabled = YES;
            t.editing = _editing;
            [self relayoutAnimated:YES];
            [self save];
            break;
        }
    }
}

- (void)removeTapped:(UIButton *)b {
    SCCTile *t = (SCCTile *)b.superview;
    [_tiles removeObject:t];
    [UIView animateWithDuration:0.22 animations:^{
        t.alpha = 0;
        t.transform = CGAffineTransformMakeScale(0.6, 0.6);
    } completion:^(BOOL f) { [t removeFromSuperview]; }];
    [self relayoutAnimated:YES];
    [self save];
}

- (void)addTapped {
    NSMutableSet *used = [NSMutableSet new];
    for (SCCTile *t in _tiles) [used addObject:t.tid];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Add tile" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *keys = [Cat().allKeys sortedArrayUsingSelector:@selector(compare:)];
    BOOL any = NO;
    for (NSString *k in keys) {
        if ([used containsObject:k]) continue;
        any = YES;
        [ac addAction:[UIAlertAction actionWithTitle:Cat()[k][@"n"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSArray *p = [Cat()[k][@"s"][0] componentsSeparatedByString:@"x"];
            SCCTile *nt = [self addTileId:k w:[p[0] intValue] h:[p[1] intValue]];
            nt.alpha = 0;
            [self relayoutAnimated:NO];
            [UIView animateWithDuration:0.3 animations:^{ nt.alpha = 1; }];
            [self relayoutAnimated:YES];
            [self save];
        }]];
    }
    if (!any) ac.message = @"All tiles are already added";
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self.presenter presentViewController:ac animated:YES completion:nil];
}

#pragma mark шапка

- (void)gearTapped {
    if (_editing) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Reset layout?" message:@"Restore the default One UI layout" preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [Prefs() removeObjectForKey:kLayoutKey];
            [self loadTiles];
            [self setEditing:YES];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self.presenter presentViewController:ac animated:YES completion:nil];
    } else {
        OpenTarget(@"com.apple.Preferences");
        [self dismissCC];
    }
}

- (void)powerTapped {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Power" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        id app = [UIApplication sharedApplication];
        SEL s = sel_registerName("_relaunchSpringBoardNow");
        if ([app respondsToSelector:s]) ((void (*)(id, SEL))objc_msgSend)(app, s); else exit(0);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Power off" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        id svc = Obj("FBSystemService", "sharedInstance");
        SEL s = sel_registerName("shutdownAndReboot:");
        if ([svc respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(svc, s, NO);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self.presenter presentViewController:ac animated:YES completion:nil];
}

#pragma mark уведомления

- (void)reloadNotifications {
    for (UIView *v in [_nScroll.subviews copy]) [v removeFromSuperview];
    CGFloat W = _nScroll.bounds.size.width;
    if (W <= 0) return;
    BOOL has = gNotes.count > 0;
    _empty.hidden = has;
    _clear.hidden = !has;
    CGFloat y = 0, m = 16;
    NSInteger idx = 0;
    for (SCCNote *n in gNotes) {
        UIView *c = [self cardForNote:n index:idx width:W - 2 * m];
        c.frame = CGRectMake(m, y, W - 2 * m, c.bounds.size.height);
        [_nScroll addSubview:c];
        y += c.bounds.size.height + 10;
        idx++;
    }
    _nScroll.contentSize = CGSizeMake(W, y + 20);
}

- (UIView *)cardForNote:(SCCNote *)n index:(NSInteger)idx width:(CGFloat)w {
    UIView *c = [UIView new];
    c.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
    c.layer.cornerRadius = 24;
    c.tag = idx;

    UIImageView *ic = [[UIImageView alloc] initWithFrame:CGRectMake(14, 14, 26, 26)];
    ic.layer.cornerRadius = 6;
    ic.clipsToBounds = YES;
    UIImage *img = nil;
    SEL isel = sel_registerName("_applicationIconImageForBundleIdentifier:format:scale:");
    if (n.bundle && [UIImage respondsToSelector:isel])
        img = ((UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend)([UIImage class], isel, n.bundle, 2, [UIScreen mainScreen].scale);
    ic.image = img ?: [UIImage systemImageNamed:@"app.fill"];
    ic.tintColor = [UIColor colorWithWhite:0.3 alpha:1];
    [c addSubview:ic];

    UILabel *app = [[UILabel alloc] initWithFrame:CGRectMake(48, 14, w - 48 - 100, 26)];
    app.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    app.textColor = [UIColor colorWithWhite:0.2 alpha:0.9];
    app.text = n.app ?: n.bundle ?: @"";
    [c addSubview:app];

    UILabel *tm = [[UILabel alloc] initWithFrame:CGRectMake(w - 44 - 64, 14, 60, 26)];
    tm.font = [UIFont systemFontOfSize:12];
    tm.textColor = [UIColor colorWithWhite:0.3 alpha:0.9];
    tm.textAlignment = NSTextAlignmentRight;
    tm.text = [_nf stringFromDate:n.date];
    [c addSubview:tm];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(w - 40, 14, 26, 26);
    [x setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    x.tintColor = [UIColor colorWithWhite:0.3 alpha:0.7];
    x.tag = idx;
    [x addTarget:self action:@selector(noteX:) forControlEvents:UIControlEventTouchUpInside];
    [c addSubview:x];

    CGFloat y = 46, tw = w - 28;
    if (n.title.length) {
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, y, tw, 20)];
        t.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        t.textColor = [UIColor colorWithWhite:0.1 alpha:1];
        t.text = n.title;
        [c addSubview:t];
        y += 22;
    }
    if (n.message.length) {
        UIFont *f = [UIFont systemFontOfSize:14];
        CGFloat bh = ceil([n.message boundingRectWithSize:CGSizeMake(tw, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: f} context:nil].size.height);
        bh = MIN(bh, ceil(f.lineHeight * 3) + 1);
        UILabel *m = [[UILabel alloc] initWithFrame:CGRectMake(14, y, tw, bh)];
        m.font = f;
        m.numberOfLines = 3;
        m.textColor = [UIColor colorWithWhite:0.15 alpha:0.95];
        m.text = n.message;
        [c addSubview:m];
        y += bh + 2;
    }
    c.bounds = CGRectMake(0, 0, w, y + 14);

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(noteTap:)];
    [c addGestureRecognizer:tap];
    return c;
}

- (void)noteTap:(UITapGestureRecognizer *)g {
    NSInteger i = g.view.tag;
    if (i < 0 || i >= (NSInteger)gNotes.count) return;
    OpenTarget(gNotes[i].bundle);
    [self dismissCC];
}

- (void)noteX:(UIButton *)b {
    NSInteger i = b.tag;
    if (i < 0 || i >= (NSInteger)gNotes.count) return;
    SCCNote *n = gNotes[i];
    UIView *card = b.superview;
    [UIView animateWithDuration:0.25 animations:^{
        card.alpha = 0;
        card.transform = CGAffineTransformMakeTranslation(card.bounds.size.width, 0);
    } completion:^(BOOL f) {
        RemoveFromSystem(n);
        [gNotes removeObject:n];
        [self reloadNotifications];
    }];
}

- (void)clearAll {
    NSArray *all = [gNotes copy];
    [UIView animateWithDuration:0.25 animations:^{ self->_nScroll.alpha = 0; } completion:^(BOOL f) {
        for (SCCNote *n in all) RemoveFromSystem(n);
        [gNotes removeAllObjects];
        [self reloadNotifications];
        self->_nScroll.alpha = 1;
    }];
}

#pragma mark открытие / закрытие / страницы

- (void)setProgress:(CGFloat)p {
    p = MAX(0, MIN(1, p));
    _progress = p;
    CGFloat H = self.bounds.size.height;
    _blur.alpha = p;
    _dim.alpha = p;
    _panel.alpha = MIN(1, p * 1.8);
    CGFloat s = 0.95 + 0.05 * p;
    _panel.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(s, s), CGAffineTransformMakeTranslation(0, -(1 - p) * H * 0.5));
}

- (void)animateOpen:(BOOL)open velocity:(CGFloat)v completion:(void (^)(void))completion {
    CGFloat H = MAX(1, self.bounds.size.height);
    CGFloat iv = MIN(6, MAX(0, fabs(v) / H));
    [UIView animateWithDuration:open ? 0.62 : 0.42 delay:0 usingSpringWithDamping:open ? 0.82 : 1.0 initialSpringVelocity:iv
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ [self setProgress:open ? 1 : 0]; }
                     completion:^(BOOL f) { if (completion) completion(); }];
}

- (void)prepareForPage:(NSInteger)p {
    _page = p;
    self.hidden = NO;
    [self layoutIfNeeded];
    _pager.contentOffset = CGPointMake(p * self.bounds.size.width, 0);
    [self scrollViewDidScroll:_pager];
    [self willShow];
    [self setProgress:0];
}

- (void)showPage:(NSInteger)p animated:(BOOL)a {
    [_pager setContentOffset:CGPointMake(p * self.bounds.size.width, 0) animated:a];
}

- (void)scrollViewDidScroll:(UIScrollView *)s {
    if (s != _pager) return;
    CGFloat W = self.bounds.size.width;
    if (W <= 0) return;
    CGFloat r = MAX(0, MIN(1, s.contentOffset.x / W));
    _page = r > 0.5 ? 1 : 0;
    _notif.alpha = 1 - 0.7 * r;
    CGFloat s0 = 1 - 0.06 * r, s1 = 0.94 + 0.06 * r;
    _notif.transform = CGAffineTransformMakeScale(s0, s0);
    _qs.alpha = 0.3 + 0.7 * r;
    _qs.transform = CGAffineTransformMakeScale(s1, s1);
}

- (void)closePanned:(UIPanGestureRecognizer *)g {
    CGFloat H = self.bounds.size.height;
    CGFloat ty = [g translationInView:self].y;
    CGFloat p = MAX(0, MIN(1, 1 + ty / (H * 0.5)));
    switch (g.state) {
        case UIGestureRecognizerStateChanged: {
            [self setProgress:p];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            CGFloat vy = [g velocityInView:self].y;
            if (p < 0.75 || vy < -500) [self dismissCC];
            else [self animateOpen:YES velocity:0 completion:nil];
            break;
        }
        default: break;
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g == _closePan) {
        if (_editing || _dragging || _resizing) return NO;
        CGPoint v = [_closePan velocityInView:self];
        if (!(v.y < 0 && fabs(v.y) > fabs(v.x))) return NO;
        UIScrollView *sv = (_page == 0) ? _nScroll : _scroll;
        return sv.contentOffset.y + sv.bounds.size.height >= sv.contentSize.height - 2;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return a == _closePan || b == _closePan;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    if (g == _closePan) return YES;
    if (_editing) return NO;
    UIView *v = touch.view;
    return v == self || v == _panel || v == _pager || v == _qs || v == _notif || v == _scroll || v == _nScroll || v == _blur.contentView || v == _dim;
}

- (void)bgTapped { [self dismissCC]; }
- (void)dismissCC { if (_closeBlock) _closeBlock(); }

- (void)tick {
    NSDate *d = [NSDate date];
    _time.text = [_tf stringFromDate:d];
    _date.text = [_df stringFromDate:d];
}

- (void)willShow {
    for (SCCTile *t in _tiles) [t refresh];
    [self tick];
    [self reloadNotifications];
    [_timer invalidate];
    __weak SCCView *ws = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        SCCView *s = ws;
        if (!s || s.hidden) { [t invalidate]; return; }
        [s tick];
        if (!s->_dragging && !s->_resizing) for (SCCTile *x in s->_tiles) [x refresh];
    }];
}

- (void)didHide {
    [_timer invalidate];
    _timer = nil;
    if (_editing) [self setEditing:NO];
}

@end

#pragma mark - Окно и жесты

#define kStripH 28.0

@interface SCCHostVC : UIViewController
@end
@implementation SCCHostVC
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
@end

@interface SCCWindow : UIWindow
@end
@implementation SCCWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)_canAffectStatusBarAppearance { return NO; }
@end

static void SCCPrefsCB(CFNotificationCenterRef c, void *obs, CFStringRef n, const void *o, CFDictionaryRef i) {
    dispatch_async(dispatch_get_main_queue(), ^{ ((void (*)(id, SEL))objc_msgSend)([SCCManager shared], NSSelectorFromString(@"applyEnabled")); });
}

@interface SCCManager () <UIGestureRecognizerDelegate>
@end

@implementation SCCManager {
    SCCWindow *_win;
    SCCHostVC *_vc;
    SCCView *_shade;
    UIView *_strip;
    BOOL _open, _tracking;
    CFTimeInterval _lastTouch;
}

+ (instancetype)shared {
    static SCCManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [SCCManager new]; });
    return m;
}

- (BOOL)isOpen { return _open; }
- (BOOL)topTouchRecent { return CACurrentMediaTime() - _lastTouch < 2.0; }

- (void)setup {
    if (_win) return;
    CGRect b = [UIScreen mainScreen].bounds;
    _win = [[SCCWindow alloc] initWithFrame:CGRectMake(0, 0, b.size.width, kStripH)];
    _win.windowLevel = UIWindowLevelAlert + 10000;
    _win.backgroundColor = [UIColor clearColor];
    _vc = [SCCHostVC new];
    _vc.view.backgroundColor = [UIColor clearColor];
    _win.rootViewController = _vc;

    _strip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, kStripH)];
    _strip.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(stripPan:)];
    pan.delegate = self;
    [_strip addGestureRecognizer:pan];
    [_vc.view addSubview:_strip];

    _shade = [[SCCView alloc] initWithFrame:b];
    _shade.hidden = YES;
    _shade.presenter = _vc;
    __weak SCCManager *ws = self;
    _shade.closeBlock = ^{ [ws closeAnimated:YES]; };
    [_vc.view addSubview:_shade];

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self,
        SCCPrefsCB, CFSTR("com.samsungcc.tweak/prefschanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    [self applyEnabled];
}

- (void)applyEnabled {
    BOOL en = SCCIsEnabled();
    _win.hidden = !en;
    if (!en && _open) [self closeAnimated:NO];
}

- (void)expandWindow {
    _win.frame = [UIScreen mainScreen].bounds;
    _vc.view.frame = _win.bounds;
    _shade.frame = _win.bounds;
}

- (void)finishClose {
    _shade.hidden = YES;
    [_shade didHide];
    _win.frame = CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, kStripH);
    _open = NO;
    _tracking = NO;
}

- (void)openPage:(NSInteger)page animated:(BOOL)animated {
    if (!_win) [self setup];
    if (!SCCIsEnabled()) return;
    if (_open) { [_shade showPage:page animated:YES]; return; }
    [self expandWindow];
    [_shade prepareForPage:page];
    _open = YES;
    if (animated) [_shade animateOpen:YES velocity:0 completion:nil];
    else [_shade setProgress:1];
}

- (void)closeAnimated:(BOOL)animated {
    if (!_win) return;
    if (!_open && !_tracking) return;
    if (animated) {
        [_shade animateOpen:NO velocity:0 completion:^{ [self finishClose]; }];
    } else {
        [_shade setProgress:0];
        [self finishClose];
    }
}

- (void)notesChanged {
    if (_shade && !_shade.hidden) [_shade reloadNotifications];
}

#pragma mark жесты верхней полосы

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    _lastTouch = CACurrentMediaTime();
    static int n = 0;
    if (n++ < 10) SCCLog(@"strip: touch received");
    return !_open && SCCIsEnabled();
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (_open || !SCCIsEnabled()) return NO;
    CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:_strip];
    return v.y > 0 && v.y >= fabs(v.x);
}

- (void)stripPan:(UIPanGestureRecognizer *)g {
    CGFloat W = _strip.bounds.size.width;
    CGFloat H = [UIScreen mainScreen].bounds.size.height;
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            CGPoint p = [g locationInView:_strip];
            // слева сверху = уведомления, справа сверху = быстрые настройки
            NSInteger page = p.x < W / 2 ? 0 : 1;
            [self expandWindow];
            [_shade prepareForPage:page];
            _tracking = YES;
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!_tracking) break;
            CGFloat ty = [g translationInView:_strip].y;
            [_shade setProgress:ty / (H * 0.4)];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (!_tracking) break;
            CGFloat ty = [g translationInView:_strip].y;
            CGFloat vy = [g velocityInView:_strip].y;
            CGFloat p = ty / (H * 0.4);
            BOOL open = (p > 0.3 || vy > 600) && g.state == UIGestureRecognizerStateEnded;
            if (open) {
                _open = YES;
                _tracking = NO;
                [_shade animateOpen:YES velocity:vy completion:nil];
            } else {
                [_shade animateOpen:NO velocity:vy completion:^{ [self finishClose]; }];
            }
            break;
        }
        default: break;
    }
}

@end
