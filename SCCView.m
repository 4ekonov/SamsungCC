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

#pragma mark - Плитка

@class SCCView;

@interface SCCTile : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSString *tid;
@property (nonatomic) int w, h;
@property (nonatomic, readonly) NSDictionary *info;
@property (nonatomic) BOOL editing;
@property (nonatomic) CGRect slot;
@property (nonatomic, weak) SCCView *host;
@property (nonatomic, strong) UILongPressGestureRecognizer *dragLP;
@property (nonatomic, strong) UIButton *minus, *handle;
- (instancetype)initWithId:(NSString *)tid w:(int)w h:(int)h host:(SCCView *)host;
- (void)refresh;
@end

@implementation SCCTile {
    UIView *_bg, *_fill;
    UIImageView *_icon, *_art;
    UILabel *_label, *_title, *_artist;
    UIButton *_prev, *_play, *_next;
    CAShapeLayer *_dash;
    float _val;
    BOOL _playing;
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

    if ([k isEqual:@"s"]) { _fill = [UIView new]; _fill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.95]; [_bg addSubview:_fill]; }

    _icon = [UIImageView new];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_icon];

    _label = [UILabel new];
    _label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _label.numberOfLines = 2;
    [self addSubview:_label];

    if ([k isEqual:@"m"]) {
        _art = [UIImageView new]; _art.contentMode = UIViewContentModeScaleAspectFill; _art.alpha = 0.45; _art.clipsToBounds = YES;
        [_bg addSubview:_art];
        _title = [UILabel new]; _title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; _title.textColor = [UIColor blackColor];
        _artist = [UILabel new]; _artist.font = [UIFont systemFontOfSize:13]; _artist.textColor = [UIColor colorWithWhite:0.2 alpha:1];
        [self addSubview:_title]; [self addSubview:_artist];
        _prev = [self mediaBtn:@"backward.fill" action:@selector(prevTapped)];
        _play = [self mediaBtn:@"play.fill" action:@selector(playTapped)];
        _next = [self mediaBtn:@"forward.fill" action:@selector(nextTapped)];
    }

    // жесты
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    tap.delegate = self; [self addGestureRecognizer:tap];
    UILongPressGestureRecognizer *open = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longOpen:)];
    open.minimumPressDuration = 0.5; open.delegate = self; [self addGestureRecognizer:open];
    if ([k isEqual:@"s"]) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(slide:)];
        pan.delegate = self; [self addGestureRecognizer:pan];
    }
    _dragLP = [[UILongPressGestureRecognizer alloc] initWithTarget:nil action:nil];
    _dragLP.minimumPressDuration = 0.12; _dragLP.delegate = self;
    [self addGestureRecognizer:_dragLP];

    // элементы режима редактирования
    _dash = [CAShapeLayer layer];
    _dash.fillColor = nil; _dash.strokeColor = [UIColor colorWithWhite:0.25 alpha:0.8].CGColor;
    _dash.lineWidth = 1.5; _dash.lineDashPattern = @[@6, @4]; _dash.hidden = YES;
    [self.layer addSublayer:_dash];

    _minus = [self chromeBtn:@"minus"];
    _handle = [self chromeBtn:@"arrow.up.left.and.arrow.down.right"];
    _minus.hidden = _handle.hidden = YES;
    [self addSubview:_minus]; [self addSubview:_handle];

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

- (UIButton *)chromeBtn:(NSString *)sym {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.9];
    b.tintColor = [UIColor whiteColor];
    [b setImage:[UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    b.layer.cornerRadius = 13;
    return b;
}

- (void)setEditing:(BOOL)e {
    _editing = e;
    _dash.hidden = !e;
    BOOL canResize = [self.info[@"s"] count] > 1;
    _minus.hidden = !e;
    _handle.hidden = !(e && canResize);
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
    _bg.layer.cornerRadius = (_h == 1) ? H / 2 : 30;
    NSString *k = self.kind;
    CGFloat pad = 18;

    if ([k isEqual:@"t"]) {
        _label.hidden = (_w == 1 && _h == 1);
        if (_w == 1 && _h == 1) {
            _icon.frame = CGRectMake((W - 26) / 2, (H - 26) / 2, 26, 26);
        } else if (_h >= 2) {
            _icon.frame = CGRectMake(pad, pad, 30, 30);
            _label.frame = CGRectMake(pad, H - 56, W - 2 * pad, 40);
        } else {
            _icon.frame = CGRectMake(pad, (H - 26) / 2, 26, 26);
            _label.frame = CGRectMake(CGRectGetMaxX(_icon.frame) + 10, 0, W - CGRectGetMaxX(_icon.frame) - 10 - 12, H);
        }
    } else if ([k isEqual:@"s"]) {
        _label.hidden = YES;
        _icon.frame = CGRectMake(pad, (H - 26) / 2, 26, 26);
        _fill.frame = CGRectMake(0, 0, MAX(H, W * _val), H);
    } else { // media
        _label.hidden = YES; _icon.hidden = YES;
        _art.frame = _bg.bounds;
        BOOL big = _h >= 2;
        _title.frame = CGRectMake(pad, 14, W - 2 * pad, 22);
        _artist.frame = CGRectMake(pad, 36, W - 2 * pad, 18);
        CGFloat by = big ? H - 54 : (H - 44) / 2;
        if (!big) { _title.frame = CGRectMake(pad, 8, W / 2 - pad, 22); _artist.frame = CGRectMake(pad, 28, W / 2 - pad, 18); }
        CGFloat bw = 44, cx = big ? W / 2 : W * 0.75;
        _prev.frame = CGRectMake(cx - bw * 1.5, by, bw, bw);
        _play.frame = CGRectMake(cx - bw / 2, by, bw, bw);
        _next.frame = CGRectMake(cx + bw / 2, by, bw, bw);
    }

    _dash.frame = self.bounds;
    _dash.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 1, 1) cornerRadius:_bg.layer.cornerRadius].CGPath;
    _minus.frame = CGRectMake(-6, -6, 26, 26);
    _handle.frame = CGRectMake(W - 24, H - 24, 26, 26);
}

- (void)refresh {
    NSDictionary *i = self.info;
    NSString *k = self.kind;
    UIColor *dark = [UIColor colorWithWhite:0.12 alpha:1];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];
    _icon.image = [UIImage systemImageNamed:i[@"i"] withConfiguration:cfg];
    _label.text = i[@"n"];

    if ([k isEqual:@"t"]) {
        BOOL on = TileState(_tid);
        _bg.backgroundColor = on ? [UIColor colorWithWhite:1 alpha:0.95] : [UIColor colorWithWhite:0.4 alpha:0.20];
        _icon.tintColor = on ? [UIColor colorWithRed:0.10 green:0.30 blue:0.85 alpha:1] : dark;
        if ([_tid isEqual:@"flashlight"] || [_tid isEqual:@"airplane"] || [_tid isEqual:@"dark"]) _icon.tintColor = dark;
        _label.textColor = dark;
    } else if ([k isEqual:@"s"]) {
        _bg.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.20];
        _icon.tintColor = dark;
        _val = [_tid isEqual:@"brightness"] ? [UIScreen mainScreen].brightness : GetVolume();
        [self setNeedsLayout];
    } else {
        _bg.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.20];
        MRInit();
        if (MRGetInfo) {
            __weak SCCTile *ws = self;
            MRGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef d) {
                SCCTile *s = ws; if (!s) return;
                NSDictionary *n = (__bridge NSDictionary *)d;
                NSString *t = n[@"kMRMediaRemoteNowPlayingInfoTitle"];
                NSString *a = n[@"kMRMediaRemoteNowPlayingInfoArtist"];
                NSData *art = n[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                s->_title.text = t.length ? t : @"Not playing";
                s->_artist.text = a ?: @"";
                s->_art.image = art ? [UIImage imageWithData:art] : nil;
                s->_playing = [n[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] floatValue] > 0;
                [s->_play setImage:[UIImage systemImageNamed:s->_playing ? @"pause.fill" : @"play.fill"
                                          withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightBold]]
                          forState:UIControlStateNormal];
            });
        }
    }
}

#pragma mark действия

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g == _dragLP) return _editing;
    if (_editing) return NO;
    if ([g isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:self];
        return fabs(v.x) > fabs(v.y);
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return NO; }

- (void)tapped:(UITapGestureRecognizer *)g {
    NSString *k = self.kind;
    if ([k isEqual:@"m"]) return;
    if ([k isEqual:@"s"]) { [self setValueFromPoint:[g locationInView:self]]; return; }
    id hv = [[[NSUserDefaults alloc] initWithSuiteName:@"com.samsungcc.tweak"] objectForKey:@"haptics"];
    if (!hv || [hv boolValue]) {
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [fb impactOccurred];
    }
    NSString *o = self.info[@"o"];
    if (o) { OpenTarget(o); [self.host dismissCC]; return; }
    TileToggle(_tid);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refresh]; });
    [self refresh];
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

#pragma mark - Главный вид

@interface SCCView () <UIGestureRecognizerDelegate>
@end

static void SCCResetCB(CFNotificationCenterRef c, void *obs, CFStringRef n, const void *o, CFDictionaryRef i) {
    SCCView *v = (__bridge SCCView *)obs;
    dispatch_async(dispatch_get_main_queue(), ^{ [v performSelector:@selector(loadTiles)]; });
}

@implementation SCCView {
    UIVisualEffectView *_blur;
    UIView *_tint;
    UIScrollView *_scroll;
    UILabel *_time, *_date;
    UIButton *_edit, *_power, *_gear, *_add;
    NSMutableArray<SCCTile *> *_tiles;
    BOOL _editing;
    SCCTile *_dragging;
    NSTimer *_timer;
    NSDateFormatter *_tf, *_df;
}

- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight]];
    [self addSubview:_blur];
    _tint = [UIView new];
    _tint.backgroundColor = [UIColor colorWithRed:0.62 green:0.72 blue:0.88 alpha:0.35];
    [self addSubview:_tint];

    _scroll = [UIScrollView new];
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = YES;
    [self addSubview:_scroll];

    _tf = [NSDateFormatter new]; _tf.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"jm" options:0 locale:[NSLocale currentLocale]];
    _df = [NSDateFormatter new]; _df.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEEdMMM" options:0 locale:[NSLocale currentLocale]];

    _time = [UILabel new]; _time.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold]; _time.textColor = [UIColor colorWithWhite:0.1 alpha:1];
    _date = [UILabel new]; _date.font = [UIFont systemFontOfSize:15]; _date.textColor = [UIColor colorWithWhite:0.2 alpha:1];
    [self addSubview:_time]; [self addSubview:_date];

    _edit = [self headerBtn:@"pencil" action:@selector(toggleEdit)];
    _power = [self headerBtn:@"power" action:@selector(powerTapped)];
    _gear = [self headerBtn:@"gearshape.fill" action:@selector(gearTapped)];

    _add = [UIButton buttonWithType:UIButtonTypeSystem];
    [_add setTitle:@"  Add tile" forState:UIControlStateNormal];
    [_add setImage:[UIImage systemImageNamed:@"plus"] forState:UIControlStateNormal];
    _add.tintColor = [UIColor colorWithWhite:0.1 alpha:1];
    _add.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.2];
    _add.layer.cornerRadius = 22; _add.hidden = YES;
    [_add addTarget:self action:@selector(addTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:_add];

    UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTapped)];
    bgTap.delegate = self; [self addGestureRecognizer:bgTap];

    [self loadTiles];
    [self tick];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self,
        SCCResetCB, CFSTR("com.samsungcc.tweak/reset"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    return self;
}

- (UIButton *)headerBtn:(NSString *)sym action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium]] forState:UIControlStateNormal];
    b.tintColor = [UIColor colorWithWhite:0.1 alpha:1];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

#pragma mark layout

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    _blur.frame = _tint.frame = self.bounds;
    CGFloat top = self.safeAreaInsets.top > 0 ? self.safeAreaInsets.top : 20;
    _time.frame = CGRectMake(20, top + 6, 90, 28);
    _date.frame = CGRectMake(CGRectGetMaxX(_time.frame) + 4, top + 9, 160, 22);
    CGFloat bx = W - 16 - 38;
    _gear.frame = CGRectMake(bx, top + 3, 38, 36);
    _power.frame = CGRectMake(bx - 38, top + 3, 38, 36);
    _edit.frame = CGRectMake(bx - 76, top + 3, 38, 36);
    CGFloat sy = top + 50;
    _scroll.frame = CGRectMake(0, sy, W, H - sy);
    [self relayoutAnimated:NO];
}

static BOOL Fits(BOOL occ[][4], int r, int c, int w, int h) {
    for (int dr = 0; dr < h; dr++) for (int dc = 0; dc < w; dc++) if (occ[r + dr][c + dc]) return NO;
    return YES;
}

- (void)relayoutAnimated:(BOOL)anim {
    CGFloat W = _scroll.bounds.size.width;
    if (W <= 0) return;
    CGFloat m = 16, g = 10, cw = (W - 2 * m - 3 * g) / 4, ch = 64, vg = 12;
    BOOL occ[90][4];
    memset(occ, 0, sizeof(occ));
    int maxRow = 0;

    void (^apply)(void) = ^{
        BOOL occ2[90][4]; memset(occ2, 0, sizeof(occ2));
        int mr = 0;
        for (SCCTile *t in self->_tiles) {
            int w = t.w, h = t.h, pr = 0, pc = 0; BOOL found = NO;
            for (int r = 0; r < 80 && !found; r++)
                for (int c = 0; c + w <= 4; c++)
                    if (Fits(occ2, r, c, w, h)) { pr = r; pc = c; found = YES; break; }
            for (int dr = 0; dr < h; dr++) for (int dc = 0; dc < w; dc++) occ2[pr + dr][pc + dc] = YES;
            mr = MAX(mr, pr + h);
            CGFloat x = m + pc * (cw + g), y = pr * (ch + vg);
            CGFloat tw = w * cw + (w - 1) * g, th = h * ch + (h - 1) * vg;
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
        self->_scroll.contentSize = CGSizeMake(W, endY + 44 + 60);
    };
    (void)occ; (void)maxRow;
    if (anim) [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:apply completion:nil];
    else apply();
}

#pragma mark плитки

- (void)loadTiles {
    for (SCCTile *t in _tiles) [t removeFromSuperview];
    _tiles = [NSMutableArray new];
    NSArray *saved = [[[NSUserDefaults alloc] initWithSuiteName:@"com.samsungcc.tweak"] arrayForKey:kLayoutKey] ?: DefaultLayout();
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
    [t.handle addTarget:self action:@selector(resizeTapped:) forControlEvents:UIControlEventTouchUpInside];
    t.editing = _editing;
    [_scroll insertSubview:t belowSubview:_add];
    [_tiles addObject:t];
    return t;
}

- (void)save {
    NSMutableArray *a = [NSMutableArray new];
    for (SCCTile *t in _tiles) [a addObject:[NSString stringWithFormat:@"%@:%dx%d", t.tid, t.w, t.h]];
    [[[NSUserDefaults alloc] initWithSuiteName:@"com.samsungcc.tweak"] setObject:a forKey:kLayoutKey];
}

#pragma mark редактирование

- (void)toggleEdit { [self setEditing:!_editing]; }

- (void)setEditing:(BOOL)e {
    _editing = e;
    for (SCCTile *t in _tiles) t.editing = e;
    _add.hidden = !e;
    UIImage *img = [UIImage systemImageNamed:e ? @"checkmark" : @"pencil" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold]];
    [_edit setImage:img forState:UIControlStateNormal];
    if (!e) [self save];
}

- (void)drag:(UILongPressGestureRecognizer *)g {
    SCCTile *t = (SCCTile *)g.view;
    CGPoint p = [g locationInView:_scroll];
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            _dragging = t;
            [_scroll bringSubviewToFront:t];
            [t.layer removeAnimationForKey:@"wiggle"];
            [UIView animateWithDuration:0.15 animations:^{ t.transform = CGAffineTransformMakeScale(1.06, 1.06); t.alpha = 0.9; }];
            _scroll.scrollEnabled = NO;
            break;
        case UIGestureRecognizerStateChanged: {
            t.center = p;
            // автоскролл у краёв
            CGPoint inView = [g locationInView:_scroll.superview];
            if (inView.y > self.bounds.size.height - 80) [_scroll setContentOffset:CGPointMake(0, MIN(_scroll.contentSize.height - _scroll.bounds.size.height, _scroll.contentOffset.y + 8)) animated:NO];
            else if (inView.y < _scroll.frame.origin.y + 40) [_scroll setContentOffset:CGPointMake(0, MAX(0, _scroll.contentOffset.y - 8)) animated:NO];
            for (SCCTile *o in _tiles) {
                if (o == t) continue;
                if (CGRectContainsPoint(o.slot, p)) {
                    NSUInteger to = [_tiles indexOfObject:o];
                    [_tiles removeObject:t];
                    [_tiles insertObject:t atIndex:to];
                    [self relayoutAnimated:YES];
                    break;
                }
            }
            break;
        }
        default: {
            _dragging = nil;
            _scroll.scrollEnabled = YES;
            [UIView animateWithDuration:0.2 animations:^{ t.transform = CGAffineTransformIdentity; t.alpha = 1; }];
            t.editing = _editing; // вернуть wiggle
            [self relayoutAnimated:YES];
            [self save];
        }
    }
}

- (void)removeTapped:(UIButton *)b {
    SCCTile *t = (SCCTile *)b.superview;
    [_tiles removeObject:t];
    [UIView animateWithDuration:0.2 animations:^{ t.alpha = 0; t.transform = CGAffineTransformMakeScale(0.7, 0.7); } completion:^(BOOL f) { [t removeFromSuperview]; }];
    [self relayoutAnimated:YES];
    [self save];
}

- (void)resizeTapped:(UIButton *)b {
    SCCTile *t = (SCCTile *)b.superview;
    NSArray *sizes = t.info[@"s"];
    NSString *cur = [NSString stringWithFormat:@"%dx%d", t.w, t.h];
    NSUInteger i = [sizes indexOfObject:cur];
    NSString *next = sizes[(i == NSNotFound ? 0 : i + 1) % sizes.count];
    NSArray *p = [next componentsSeparatedByString:@"x"];
    t.w = [p[0] intValue]; t.h = [p[1] intValue];
    [UIView animateWithDuration:0.28 animations:^{ [t layoutIfNeeded]; }];
    [t setNeedsLayout];
    [self relayoutAnimated:YES];
    [t refresh];
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
        NSString *title = Cat()[k][@"n"];
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSArray *p = [Cat()[k][@"s"][0] componentsSeparatedByString:@"x"];
            [self addTileId:k w:[p[0] intValue] h:[p[1] intValue]];
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
            [[[NSUserDefaults alloc] initWithSuiteName:@"com.samsungcc.tweak"] removeObjectForKey:kLayoutKey];
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

#pragma mark служебное

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    return !_editing && (touch.view == self || touch.view == _scroll || touch.view == _blur.contentView || touch.view == _tint);
}
- (void)bgTapped { [self dismissCC]; }
- (void)dismissCC { if (_dismissBlock) _dismissBlock(); }

- (void)tick {
    NSDate *d = [NSDate date];
    _time.text = [_tf stringFromDate:d];
    _date.text = [_df stringFromDate:d];
}

- (void)willShow {
    for (SCCTile *t in _tiles) [t refresh];
    [self tick];
}
- (void)dealloc { CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self); }

- (void)didHide { if (_editing) [self setEditing:NO]; }

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_timer invalidate]; _timer = nil;
    if (!self.window) return;
    __weak SCCView *ws = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        SCCView *s = ws; if (!s) { [t invalidate]; return; }
        [s tick];
        if (!s->_dragging) for (SCCTile *x in s->_tiles) [x refresh];
    }];
}

@end
