#import "SCC.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define CALL_B(o, s)        (((BOOL (*)(id, SEL))objc_msgSend)((o), sel_registerName(s)))
#define CALL_V_B(o, s, a)   (((void (*)(id, SEL, BOOL))objc_msgSend)((o), sel_registerName(s), (a)))
#define CALL_V(o, s)        (((void (*)(id, SEL))objc_msgSend)((o), sel_registerName(s)))
#define HAS(o, s)           ([(o) respondsToSelector:sel_registerName(s)])

static NSString *const kLayoutKey = @"SCC.layout.v1";

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
            @"airplane":   E(@"Airplane", @"airplane", @"t", @"1x1", @"2x1"),
            @"cellular":   @{@"n":@"Mobile data", @"i":@"arrow.up.arrow.down", @"k":@"t", @"o":@"prefs:root=MOBILE_DATA_SETTINGS_ID", @"s":@[@"1x1", @"2x1"]},
            @"flashlight": E(@"Flashlight", @"flashlight.on.fill", @"t", @"1x1", @"2x1"),
            @"rotation":   E(@"Rotation lock", @"lock.rotation", @"t", @"1x1", @"2x1"),
            @"dark":       @{@"n":@"Dark mode", @"i":@"moon.fill", @"k":@"t", @"p":@"prefs:root=DISPLAY", @"s":@[@"1x1", @"2x1"]},
            @"lowpower":   @{@"n":@"Power saving", @"i":@"battery.25", @"k":@"t", @"p":@"prefs:root=BATTERY_USAGE", @"s":@[@"1x1", @"2x1"]},
            @"mute":       E(@"Mute", @"speaker.slash.fill", @"t", @"1x1", @"2x1"),
            @"location":   EO(@"Location", @"mappin.and.ellipse", @"t", @"prefs:root=Privacy&path=LOCATION", @"1x1", @"2x1"),
            @"modes":      EO(@"Modes", @"bed.double.fill", @"t", @"prefs:root=DO_NOT_DISTURB", @"2x1", @"1x1"),
            @"smartview":  EO(@"Smart View", @"rectangle.on.rectangle", @"t", @"prefs:root=DISPLAY", @"2x1", @"1x1"),
            @"nearby":     EO(@"Nearby devices", @"dot.radiowaves.left.and.right", @"t", @"prefs:root=Bluetooth", @"2x1", @"1x1"),
            @"camera":     EO(@"Camera", @"camera.fill", @"t", @"com.apple.camera", @"1x1", @"2x1"),
            @"calculator": EO(@"Calculator", @"plus.forwardslash.minus", @"t", @"com.apple.calculator", @"1x1", @"2x1"),
            @"timer":      EO(@"Timer", @"timer", @"t", @"com.apple.mobiletimer", @"1x1", @"2x1"),
            @"notes":      EO(@"Notes", @"note.text", @"t", @"com.apple.mobilenotes", @"1x1", @"2x1"),
            @"magnifier":  EO(@"Magnifier", @"magnifyingglass", @"t", @"com.apple.Magnifier", @"1x1", @"2x1"),
            @"settings":   EO(@"Settings", @"gearshape.fill", @"t", @"com.apple.Preferences", @"1x1", @"2x1"),
            @"brightness": E(@"Brightness", @"sun.max.fill", @"s", @"4x1", @"3x1", @"2x1"),
            @"volume":     E(@"Volume", @"speaker.wave.2.fill", @"s", @"4x1", @"3x1", @"2x1"),
            @"media":      E(@"Media", @"music.note", @"m", @"4x2", @"4x1", @"2x2"),
        };
    });
    return c;
}

static NSArray *DefaultLayout(void) {
    return @[@"wifi:2x1", @"bluetooth:2x1",
             @"airplane:1x1", @"flashlight:1x1", @"cellular:1x1", @"rotation:1x1",
             @"brightness:3x1", @"dark:1x1",
             @"volume:3x1", @"mute:1x1",
             @"media:4x2",
             @"modes:2x1", @"smartview:2x1",
             @"lowpower:1x1", @"camera:1x1", @"calculator:1x1", @"timer:1x1"];
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
    UIView *_bg, *_fill, *_plate;
    UIImageView *_icon, *_art;
    UILabel *_label, *_sub, *_title, *_artist;
    UIButton *_prev, *_play, *_next;
    CAShapeLayer *_dash;
    float _val;
    BOOL _playing, _on;
}

- (NSDictionary *)info { return Cat()[_tid]; }
- (NSString *)kind { return self.info[@"k"]; }

- (instancetype)initWithId:(NSString *)tid w:(int)w h:(int)h host:(SCCView *)host {
    self = [super initWithFrame:CGRectZero];
    _tid = tid; _w = w; _h = h; _host = host;
    NSString *k = self.kind;

    _bg = [UIView new];
    _bg.layer.masksToBounds = YES;
    [self addSubview:_bg];

    if ([k isEqual:@"s"]) {
        _fill = [UIView new];
        _fill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.96];
        [_bg addSubview:_fill];
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
    _sub.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    [self addSubview:_sub];

    if ([k isEqual:@"m"]) {
        _art = [UIImageView new];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.alpha = 0.45;
        _art.clipsToBounds = YES;
        [_bg addSubview:_art];
        _title = [UILabel new];
        _title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        _title.textColor = [UIColor blackColor];
        _artist = [UILabel new];
        _artist.font = [UIFont systemFontOfSize:13];
        _artist.textColor = [UIColor colorWithWhite:0.2 alpha:1];
        [self addSubview:_title];
        [self addSubview:_artist];
        _prev = [self mediaBtn:@"backward.fill" action:@selector(prevTapped)];
        _play = [self mediaBtn:@"play.fill" action:@selector(playTapped)];
        _next = [self mediaBtn:@"forward.fill" action:@selector(nextTapped)];
    }

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    tap.delegate = self;
    [self addGestureRecognizer:tap];
    UILongPressGestureRecognizer *open = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longOpen:)];
    open.minimumPressDuration = 0.5;
    open.delegate = self;
    [self addGestureRecognizer:open];
    if ([k isEqual:@"s"]) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(slide:)];
        pan.delegate = self;
        [self addGestureRecognizer:pan];
    }
    _dragLP = [[UILongPressGestureRecognizer alloc] initWithTarget:nil action:nil];
    _dragLP.minimumPressDuration = 0.12;
    _dragLP.delegate = self;
    [self addGestureRecognizer:_dragLP];

    _dash = [CAShapeLayer layer];
    _dash.fillColor = nil;
    _dash.strokeColor = [UIColor colorWithWhite:0.15 alpha:0.75].CGColor;
    _dash.lineWidth = 1.5;
    _dash.lineDashPattern = @[@6, @4];
    _dash.hidden = YES;
    [self.layer addSublayer:_dash];

    _minus = [UIButton buttonWithType:UIButtonTypeSystem];
    _minus.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    _minus.tintColor = [UIColor whiteColor];
    [_minus setImage:[UIImage systemImageNamed:@"minus" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    _minus.layer.cornerRadius = 13;
    _minus.hidden = YES;
    [self addSubview:_minus];

    _handle = [UIView new];
    _handle.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    _handle.layer.cornerRadius = 14;
    UIImageView *hi = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold]]];
    hi.tintColor = [UIColor whiteColor];
    hi.frame = CGRectMake(7, 7, 14, 14);
    hi.contentMode = UIViewContentModeScaleAspectFit;
    [_handle addSubview:hi];
    _handle.hidden = YES;
    [self addSubview:_handle];

    [self refresh];
    return self;
}

- (UIButton *)mediaBtn:(NSString *)sym action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    b.tintColor = [UIColor blackColor];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e {
    if (_editing) {
        if (CGRectContainsPoint(CGRectInset(_minus.frame, -6, -6), p)) return YES;
        if (!_handle.hidden && CGRectContainsPoint(CGRectInset(_handle.frame, -8, -8), p)) return YES;
    }
    return [super pointInside:p withEvent:e];
}

- (void)setEditing:(BOOL)e {
    _editing = e;
    _dash.hidden = !e;
    _minus.hidden = !e;
    _handle.hidden = !(e && [self.info[@"s"] count] > 1);
    _prev.userInteractionEnabled = _play.userInteractionEnabled = _next.userInteractionEnabled = !e;
    [self.layer removeAnimationForKey:@"wiggle"];
    if (e) {
        CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
        a.values = @[@(-0.008), @(0.008), @(-0.008)];
        a.duration = 0.25 + (arc4random_uniform(100) / 1000.0);
        a.repeatCount = HUGE_VALF;
        [self.layer addAnimation:a forKey:@"wiggle"];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    _bg.frame = self.bounds;
    _bg.layer.cornerRadius = (_h == 1) ? H / 2 : 32;
    NSString *k = self.kind;

    if ([k isEqual:@"t"]) {
        BOOL round = (_w == 1 && _h == 1);
        BOOL wide = (_h == 1 && _w >= 2);
        _plate.hidden = round;
        _label.hidden = _sub.hidden = round;
        if (round) {
            _icon.frame = CGRectMake((W - 26) / 2, (H - 26) / 2, 26, 26);
        } else if (wide) {
            CGFloat d = H - 16;
            _plate.frame = CGRectMake(8, 8, d, d);
            _plate.layer.cornerRadius = d / 2;
            _icon.frame = CGRectMake(8 + (d - 22) / 2, 8 + (d - 22) / 2, 22, 22);
            CGFloat x = 8 + d + 10, tw = W - x - 12;
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
                _label.frame = CGRectMake(16, H - 58, W - 32, 22);
                _sub.frame = CGRectMake(16, H - 36, W - 32, 18);
            } else {
                _label.frame = CGRectMake(16, H - 50, W - 32, 36);
            }
        }
    } else if ([k isEqual:@"s"]) {
        _plate.hidden = YES; _label.hidden = _sub.hidden = YES;
        _icon.frame = CGRectMake(18, (H - 26) / 2, 26, 26);
        _fill.frame = CGRectMake(0, 0, MAX(H, W * _val), H);
    } else {
        _plate.hidden = YES; _label.hidden = _sub.hidden = YES; _icon.hidden = YES;
        _art.frame = _bg.bounds;
        BOOL big = _h >= 2;
        CGFloat pad = 18;
        if (big) {
            _title.frame = CGRectMake(pad, 16, W - 2 * pad, 22);
            _artist.frame = CGRectMake(pad, 38, W - 2 * pad, 18);
        } else {
            _title.frame = CGRectMake(pad, 12, W / 2 - pad, 22);
            _artist.frame = CGRectMake(pad, 34, W / 2 - pad, 18);
        }
        CGFloat bw = 44, by = big ? H - 56 : (H - bw) / 2, cx = big ? W / 2 : W * 0.75;
        _prev.frame = CGRectMake(cx - bw * 1.5, by, bw, bw);
        _play.frame = CGRectMake(cx - bw / 2, by, bw, bw);
        _next.frame = CGRectMake(cx + bw / 2, by, bw, bw);
    }

    _dash.frame = self.bounds;
    _dash.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 1, 1) cornerRadius:_bg.layer.cornerRadius].CGPath;
    _minus.frame = CGRectMake(-6, -6, 26, 26);
    _handle.frame = CGRectMake(W - 22, H - 22, 28, 28);
}

- (void)refresh {
    NSDictionary *i = self.info;
    NSString *k = self.kind;
    UIColor *ink = [UIColor colorWithWhite:0.12 alpha:1];
    UIColor *glass = [UIColor colorWithWhite:1 alpha:0.30];
    UIColor *white = [UIColor colorWithWhite:1 alpha:0.96];
    _icon.image = [UIImage systemImageNamed:i[@"i"] withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium]];
    _label.text = i[@"n"];
    _label.textColor = ink;
    _sub.textColor = [UIColor colorWithWhite:0.25 alpha:0.9];

    if ([k isEqual:@"t"]) {
        BOOL stateful = (i[@"o"] == nil);
        _on = stateful && TileState(_tid);
        BOOL round = (_w == 1 && _h == 1);
        _bg.backgroundColor = _on ? white : glass;
        if (round) {
            _icon.tintColor = ink;
        } else {
            _plate.backgroundColor = _on ? [UIColor colorWithWhite:0.12 alpha:0.92] : [UIColor colorWithWhite:1 alpha:0.38];
            _icon.tintColor = _on ? [UIColor whiteColor] : ink;
        }
        NSString *st = stateful ? (_on ? @"On" : @"Off") : nil;
        if (![st isEqual:_sub.text]) { _sub.text = st; [self setNeedsLayout]; }
    } else if ([k isEqual:@"s"]) {
        _bg.backgroundColor = glass;
        _icon.tintColor = ink;
        _val = [_tid isEqual:@"brightness"] ? [UIScreen mainScreen].brightness : GetVolume();
        [self setNeedsLayout];
    } else {
        _bg.backgroundColor = glass;
        MRInit();
        if (MRGetInfo) {
            __weak SCCTile *ws = self;
            MRGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef d) {
                SCCTile *s = ws;
                if (!s) return;
                NSDictionary *n = (__bridge NSDictionary *)d;
                NSString *t = n[@"kMRMediaRemoteNowPlayingInfoTitle"];
                NSString *a = n[@"kMRMediaRemoteNowPlayingInfoArtist"];
                NSData *art = n[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                s->_title.text = t.length ? t : @"Not playing";
                s->_artist.text = a ?: @"";
                s->_art.image = art ? [UIImage imageWithData:art] : nil;
                s->_playing = [n[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] floatValue] > 0;
                UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightBold];
                [s->_play setImage:[UIImage systemImageNamed:s->_playing ? @"pause.fill" : @"play.fill" withConfiguration:cfg] forState:UIControlStateNormal];
            });
        }
    }
}

#pragma mark действия

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g == _dragLP) {
        if (!_editing) return NO;
        CGPoint p = [g locationInView:self];
        if (!_handle.hidden && CGRectContainsPoint(CGRectInset(_handle.frame, -10, -10), p)) return NO;
        if (CGRectContainsPoint(CGRectInset(_minus.frame, -8, -8), p)) return NO;
        return YES;
    }
    if (_editing) return NO;
    if ([g isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:self];
        return fabs(v.x) > fabs(v.y);
    }
    return YES;
}

- (void)tapped:(UITapGestureRecognizer *)g {
    NSString *k = self.kind;
    if ([k isEqual:@"m"]) return;
    if ([k isEqual:@"s"]) { [self setValueFromPoint:[g locationInView:self]]; return; }
    id hv = [Prefs() objectForKey:@"haptics"];
    if (!hv || [hv boolValue]) {
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [fb impactOccurred];
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
    OpenTarget(p);
    [self.host dismissCC];
}

- (void)slide:(UIPanGestureRecognizer *)g { [self setValueFromPoint:[g locationInView:self]]; }

- (void)setValueFromPoint:(CGPoint)p {
    float v = MAX(0, MIN(1, p.x / self.bounds.size.width));
    _val = v;
    if ([_tid isEqual:@"brightness"]) SetBrightness(v); else SetVolume(v);
    [self setNeedsLayout];
}

- (void)prevTapped { if (MRSend) MRSend(5, nil); [self performSelector:@selector(refresh) withObject:nil afterDelay:0.4]; }
- (void)nextTapped { if (MRSend) MRSend(4, nil); [self performSelector:@selector(refresh) withObject:nil afterDelay:0.4]; }
- (void)playTapped { if (MRSend) MRSend(2, nil); [self performSelector:@selector(refresh) withObject:nil afterDelay:0.3]; }

@end

#pragma mark - Шторка

static void SCCResetCB(CFNotificationCenterRef c, void *obs, CFStringRef n, const void *o, CFDictionaryRef i) {
    SCCView *v = (__bridge SCCView *)obs;
    dispatch_async(dispatch_get_main_queue(), ^{ [v performSelector:NSSelectorFromString(@"loadTiles")]; });
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
            if (t != self->_dragging) t.frame = fr;
        }
        CGFloat endY = mr * (ch + vg);
        self->_add.frame = CGRectMake(m, endY, W - 2 * m, 44);
        self->_scroll.contentSize = CGSizeMake(W, endY + 44 + 40);
    };
    if (anim) {
        [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.4
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
    dispatch_async(dispatch_get_main_queue(), ^{ [[SCCManager shared] performSelector:NSSelectorFromString(@"applyEnabled")]; });
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
