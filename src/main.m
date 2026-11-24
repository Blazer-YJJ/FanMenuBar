//
//  main.m  —  FanMenuBar（风扇管家）菜单栏温度监控
//  路线 A：只读 CPU 温度，不写任何硬件。
//

#import <Cocoa/Cocoa.h>
#import "SMCReader.h"

static NSString *const kAppID = @"local.tools.fanmenubar";
static const NSTimeInterval kRefreshInterval = 2.0;
static const NSInteger kSparkMaxSamples = 150;   // 150 * 2s = 5 分钟

#pragma mark - Sparkline

@interface SparklineView : NSView
@property (nonatomic, strong) NSArray<NSNumber *> *samples;
@property (nonatomic, strong) NSColor *lineColor;
@end

@implementation SparklineView

- (BOOL)isFlipped { return YES; }

- (void)setSamples:(NSArray<NSNumber *> *)samples {
    _samples = [samples copy];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor clearColor] setFill];
    NSRectFill(dirtyRect);

    NSRect b = NSInsetRect(self.bounds, 1, 3);
    if (b.size.height <= 4) return;

    // 基线
    [[NSColor.separatorColor colorWithAlphaComponent:0.6] setStroke];
    NSBezierPath *base = [NSBezierPath bezierPath];
    [base moveToPoint:NSMakePoint(NSMinX(b), NSMaxY(b))];
    [base lineToPoint:NSMakePoint(NSMaxX(b), NSMaxY(b))];
    base.lineWidth = 1;
    [base stroke];

    NSArray<NSNumber *> *s = self.samples;
    if (s.count == 0) return;
    if (s.count < 2) {
        double v0 = (s.firstObject.doubleValue - 40) / 60.0;
        v0 = MAX(0, MIN(1, v0));
        NSPoint pt = NSMakePoint(NSMaxX(b) - 2, NSMaxY(b) - v0 * NSHeight(b));
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(pt.x - 2, pt.y - 2, 4, 4)];
        [(self.lineColor ?: NSColor.systemBlueColor) setFill];
        [dot fill];
        return;
    }

    // 自适应纵轴：围绕数据本身收窄，让 1~2°C 的波动也看得出趋势
    double lo = s.firstObject.doubleValue, hi = lo;
    for (NSNumber *n in s) {
        lo = MIN(lo, n.doubleValue);
        hi = MAX(hi, n.doubleValue);
    }
    lo -= 2.0;
    hi += 2.0;
    if (hi - lo < 6.0) {
        double mid = (hi + lo) / 2.0;
        lo = mid - 3.0;
        hi = mid + 3.0;
    }

    double stepX = NSWidth(b) / (double)(kSparkMaxSamples - 1);
    double offset = (double)(kSparkMaxSamples - (NSInteger)s.count);

    NSMutableArray<NSValue *> *pts = [NSMutableArray arrayWithCapacity:s.count];
    for (NSUInteger i = 0; i < s.count; i++) {
        double v = (s[i].doubleValue - lo) / (hi - lo);
        double x = NSMinX(b) + (offset + (double)i) * stepX;
        double y = NSMaxY(b) - v * NSHeight(b);
        [pts addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
    }

    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:pts.firstObject.pointValue];
    for (NSUInteger i = 1; i < pts.count; i++) [path lineToPoint:pts[i].pointValue];
    path.lineWidth = 1.6;
    path.lineJoinStyle = NSLineJoinStyleRound;
    [(self.lineColor ?: NSColor.systemBlueColor) setStroke];
    [path stroke];

    // 渐变填充：只在曲线下方，从第一个点开始，避免左侧出现三角形
    NSPoint first = pts.firstObject.pointValue;
    NSPoint last = pts.lastObject.pointValue;
    NSBezierPath *fill = [NSBezierPath bezierPath];
    [fill moveToPoint:NSMakePoint(first.x, NSMaxY(b))];
    for (NSValue *pv in pts) [fill lineToPoint:pv.pointValue];
    [fill lineToPoint:NSMakePoint(last.x, NSMaxY(b))];
    [fill closePath];
    NSColor *c = self.lineColor ?: NSColor.systemBlueColor;
    NSGradient *g = [[NSGradient alloc] initWithColors:@[
        [c colorWithAlphaComponent:0.28], [c colorWithAlphaComponent:0.02]
    ]];
    [g drawInBezierPath:fill angle:90];
}

@end

#pragma mark - AppDelegate

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSPopover *popover;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *samples;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *rowValues;
@property (nonatomic, strong) NSStackView *rowsStack;
@property (nonatomic, strong) NSTextField *bigLabel;
@property (nonatomic, strong) NSTextField *subLabel;
@property (nonatomic, strong) SparklineView *spark;
@property (nonatomic, strong) NSButton *loginCheckbox;
@property (nonatomic, strong) NSMenu *contextMenu;
@property (nonatomic, strong) NSString *rowsSignature;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    // 单实例：launchd 与手动启动同时存在时，只保留最早的一个，避免菜单栏出现两个图标
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    for (NSRunningApplication *other in [NSRunningApplication runningApplicationsWithBundleIdentifier:bid]) {
        if (other.processIdentifier != [NSProcessInfo processInfo].processIdentifier) {
            NSLog(@"[FanMenuBar] 已有实例在运行(pid=%d)，本次退出", other.processIdentifier);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
            return;
        }
    }

    self.samples = [NSMutableArray array];
    self.rowValues = [NSMutableDictionary dictionary];

    [self buildStatusItem];
    [self buildPopover];
    [self buildContextMenu];

    [self refresh:nil];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:kRefreshInterval
                                                  target:self
                                                selector:@selector(refresh:)
                                                userInfo:nil
                                                 repeats:YES];
    self.timer.tolerance = 0.6;

    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self selector:@selector(systemDidWake:)
               name:NSWorkspaceDidWakeNotification object:nil];

    [self setupAutostartOnFirstLaunch];

    if (NSProcessInfo.processInfo.environment[@"FANMENUBAR_SNAPSHOT"]) {
        [self snapshotAndExit];
    }
}

/// 调试用：把面板渲染成 PNG，便于无鼠标环境下检查布局
- (void)snapshotAndExit {
    [self refresh:nil];
    NSView *v = self.popover.contentViewController.view;
    [v layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:@"/tmp/fanmenubar-panel.png" atomically:YES];
    NSLog(@"[FanMenuBar] snapshot written");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [self.timer invalidate];
}

- (void)systemDidWake:(NSNotification *)note {
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:kRefreshInterval
                                                  target:self
                                                selector:@selector(refresh:)
                                                userInfo:nil
                                                 repeats:YES];
    [self refresh:nil];
}

#pragma mark UI 构建

- (void)buildStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    button.target = self;
    button.action = @selector(statusItemClicked:);
    [button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];

    NSImage *img = [NSImage imageWithSystemSymbolName:@"thermometer.medium" accessibilityDescription:@"温度"];
    img.template = YES;
    button.image = img;
    button.imagePosition = NSImageLeft;
    [self updateStatusTitle:@"--°" color:NSColor.labelColor];
}

- (void)updateStatusTitle:(NSString *)text color:(NSColor *)color {
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
    }];
    self.statusItem.button.attributedTitle = as;
}

- (NSTextField *)labelWithFont:(NSFont *)font color:(NSColor *)color {
    NSTextField *t = [NSTextField labelWithString:@""];
    t.font = font;
    t.textColor = color;
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    return t;
}

- (void)buildPopover {
    NSViewController *vc = [NSViewController new];
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 380)];
    vc.view = root;

    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:root.topAnchor constant:14],
    ]];

    self.bigLabel = [self labelWithFont:[NSFont monospacedDigitSystemFontOfSize:34 weight:NSFontWeightMedium]
                                  color:NSColor.labelColor];
    self.subLabel = [self labelWithFont:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor];
    self.subLabel.stringValue = @"CPU 温度 · 每 2 秒刷新";
    for (NSTextField *f in @[self.bigLabel, self.subLabel]) {
        [f setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationVertical];
        [f setContentHuggingPriority:NSLayoutPriorityRequired
                      forOrientation:NSLayoutConstraintOrientationVertical];
    }

    self.spark = [[SparklineView alloc] initWithFrame:NSMakeRect(0, 0, 268, 62)];
    self.spark.translatesAutoresizingMaskIntoConstraints = NO;
    [self.spark.heightAnchor constraintEqualToConstant:62].active = YES;

    [stack addArrangedSubview:self.bigLabel];
    [stack addArrangedSubview:self.subLabel];
    [stack addArrangedSubview:self.spark];
    [stack setCustomSpacing:12 afterView:self.spark];

    NSBox *sep1 = [self separator];
    [stack addArrangedSubview:sep1];
    [sep1.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    self.rowsStack = [[NSStackView alloc] init];
    self.rowsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.rowsStack.alignment = NSLayoutAttributeLeading;
    self.rowsStack.spacing = 5;
    [stack addArrangedSubview:self.rowsStack];
    [self.rowsStack.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    [stack setCustomSpacing:12 afterView:self.rowsStack];

    NSBox *sep2 = [self separator];
    [stack addArrangedSubview:sep2];
    [sep2.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    // 底部：开机自启 + 退出
    NSStackView *footer = [[NSStackView alloc] init];
    footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    footer.spacing = 8;
    footer.distribution = NSStackViewDistributionFill;

    self.loginCheckbox = [NSButton checkboxWithTitle:@"开机自启" target:self action:@selector(toggleLogin:)];
    self.loginCheckbox.font = [NSFont systemFontOfSize:12];
    self.loginCheckbox.state = [self isLoginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;

    NSButton *quit = [NSButton buttonWithTitle:@"退出" target:self action:@selector(quit:)];
    quit.bezelStyle = NSBezelStyleRounded;
    quit.controlSize = NSControlSizeSmall;
    quit.font = [NSFont systemFontOfSize:12];

    [footer addArrangedSubview:self.loginCheckbox];
    [footer addArrangedSubview:quit];
    [stack addArrangedSubview:footer];
    [footer.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    NSLayoutConstraint *bottom = [root.bottomAnchor constraintEqualToAnchor:stack.bottomAnchor constant:14];
    bottom.priority = 750;
    bottom.active = YES;
    [root.bottomAnchor constraintGreaterThanOrEqualToAnchor:stack.bottomAnchor constant:14].active = YES;

    self.popover = [NSPopover new];
    self.popover.contentViewController = vc;
    self.popover.behavior = NSPopoverBehaviorTransient;
}

- (NSBox *)separator {
    NSBox *b = [[NSBox alloc] init];
    b.boxType = NSBoxSeparator;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

- (void)buildContextMenu {
    NSMenu *m = [[NSMenu alloc] init];
    [m addItemWithTitle:@"显示面板" action:@selector(showPanelFromMenu:) keyEquivalent:@""].target = self;
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:@"退出" action:@selector(quit:) keyEquivalent:@""].target = self;
    self.contextMenu = m;
}

#pragma mark 交互

- (void)statusItemClicked:(id)sender {
    if (NSApp.currentEvent.type == NSEventTypeRightMouseUp) {
        self.statusItem.menu = self.contextMenu;
        [self.statusItem.button performClick:nil];
        self.statusItem.menu = nil;
        return;
    }
    if (self.popover.shown) {
        [self.popover performClose:nil];
    } else {
        self.loginCheckbox.state = [self isLoginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
        [self refresh:nil];
        [self sizePopoverToFit];
        [self.popover showRelativeToRect:self.statusItem.button.bounds
                                  ofView:self.statusItem.button
                           preferredEdge:NSRectEdgeMinY];
        [NSApp activateIgnoringOtherApps:YES];
    }
}

- (void)showPanelFromMenu:(id)sender {
    self.loginCheckbox.state = [self isLoginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [self sizePopoverToFit];
    [self.popover showRelativeToRect:self.statusItem.button.bounds
                              ofView:self.statusItem.button
                       preferredEdge:NSRectEdgeMinY];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)sizePopoverToFit {
    NSView *v = self.popover.contentViewController.view;
    [v layoutSubtreeIfNeeded];
    NSSize fit = [v fittingSize];
    if (fit.height > 100) {
        self.popover.contentSize = NSMakeSize(MAX(300, fit.width), fit.height);
        [v setFrameSize:self.popover.contentSize];
        [v layoutSubtreeIfNeeded];
    }
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

#pragma mark 刷新

- (void)refresh:(NSTimer *)t {
    NSArray<SMCSensor *> *sensors = [[SMCReader shared] readTemperatures];

    double cpu = -1;
    BOOL hasGPU = NO;
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (SMCSensor *s in sensors) {
        BOOL isCPU = [s.key hasPrefix:@"TC"];
        if (isCPU && s.available) cpu = MAX(cpu, s.value);
        if (!isCPU) hasGPU = YES;
        [rows addObject:@{@"name": s.name, @"key": s.key, @"value": @(s.available ? s.value : -1.0),
                          @"available": @(s.available), @"cpu": @(isCPU)}];
    }
    if (!hasGPU) {
        // 本机 dGPU 被禁用、核显无 SMC 温度键：显式展示"不可用"，不隐藏也不造假
        [rows addObject:@{@"name": @"GPU 温度", @"key": @"GPU0",
                          @"value": @(-1.0), @"available": @NO, @"cpu": @NO}];
    }

    // 风扇
    NSInteger fanCount = [[SMCReader shared] fanCount];
    NSNumber *rpm = fanCount > 0 ? [[SMCReader shared] fanRPMAt:0] : nil;
    if (fanCount > 0) {
        [rows addObject:@{@"name": [NSString stringWithFormat:@"风扇 0（共 %ld）", (long)fanCount],
                          @"key": @"F0Ac", @"value": rpm ?: @(-1),
                          @"available": @(rpm != nil), @"cpu": @NO, @"fan": @YES}];
    } else {
        [rows addObject:@{@"name": @"风扇", @"key": @"FAN", @"value": @(-1),
                          @"available": @NO, @"cpu": @NO, @"fan": @YES}];
    }

    if (cpu < 0) {
        [self updateStatusTitle:@"--°" color:NSColor.secondaryLabelColor];
        self.bigLabel.stringValue = @"--";
        self.subLabel.stringValue = @"传感器不可用";
    } else {
        NSString *t = [NSString stringWithFormat:@"%.0f°", cpu];
        NSColor *color = NSColor.labelColor;
        if (cpu >= 85) color = NSColor.systemRedColor;
        else if (cpu >= 70) color = NSColor.systemOrangeColor;
        [self updateStatusTitle:t color:color];

        self.bigLabel.stringValue = t;
        self.bigLabel.textColor = color;
        self.subLabel.stringValue = @"CPU 温度 · 每 2 秒刷新";
    for (NSTextField *f in @[self.bigLabel, self.subLabel]) {
        [f setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationVertical];
        [f setContentHuggingPriority:NSLayoutPriorityRequired
                      forOrientation:NSLayoutConstraintOrientationVertical];
    }

        [self.samples addObject:@(cpu)];
        if ((NSInteger)self.samples.count > kSparkMaxSamples) {
            [self.samples removeObjectAtIndex:0];
        }
        self.spark.lineColor = color;
        self.spark.samples = self.samples;
    }

    [self updateRows:rows];
}

- (void)updateRows:(NSArray<NSDictionary *> *)rows {
    NSMutableString *sig = [NSMutableString string];
    for (NSDictionary *r in rows) [sig appendFormat:@"%@|", r[@"key"]];

    if (![sig isEqualToString:self.rowsSignature]) {
        self.rowsSignature = sig;
        for (NSView *v in self.rowsStack.arrangedSubviews) {
            [self.rowsStack removeArrangedSubview:v];
            [v removeFromSuperview];
        }
        [self.rowValues removeAllObjects];

        for (NSDictionary *r in rows) {
            NSStackView *row = [[NSStackView alloc] init];
            row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            row.distribution = NSStackViewDistributionFill;

            NSTextField *name = [self labelWithFont:[NSFont systemFontOfSize:12] color:NSColor.secondaryLabelColor];
            name.stringValue = r[@"name"];

            NSTextField *value = [self labelWithFont:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular]
                                               color:NSColor.labelColor];
            value.alignment = NSTextAlignmentRight;

            [row addArrangedSubview:name];
            [row addArrangedSubview:value];
            [name setContentHuggingPriority:NSLayoutPriorityDefaultHigh - 1
                             forOrientation:NSLayoutConstraintOrientationHorizontal];
            [value setContentHuggingPriority:NSLayoutPriorityRequired
                              forOrientation:NSLayoutConstraintOrientationHorizontal];

            [self.rowsStack addArrangedSubview:row];
            [row.widthAnchor constraintEqualToAnchor:self.rowsStack.widthAnchor].active = YES;
            self.rowValues[r[@"key"]] = value;
        }
    }

    for (NSDictionary *r in rows) {
        NSTextField *value = self.rowValues[r[@"key"]];
        if (!value) continue;
        BOOL available = [r[@"available"] boolValue];
        if (!available) {
            value.stringValue = @"不可用";
            value.textColor = NSColor.tertiaryLabelColor;
        } else if ([r[@"fan"] boolValue]) {
            value.stringValue = [NSString stringWithFormat:@"%.0f rpm", [r[@"value"] doubleValue]];
            value.textColor = NSColor.labelColor;
        } else {
            value.stringValue = [NSString stringWithFormat:@"%.1f °C", [r[@"value"] doubleValue]];
            value.textColor = NSColor.labelColor;
        }
    }
}

#pragma mark 开机自启

- (BOOL)isLoginItemEnabled {
    // 统一用 LaunchAgent 判断：ad-hoc 签名的本地 App 走 SMAppService 状态不可靠
    // （系统会把 /Applications 里启动过的 App 自动登记进 BTM，status 直接报 enabled）。
    return [[NSFileManager defaultManager] fileExistsAtPath:[self launchAgentPath].path];
}

- (NSURL *)launchAgentPath {
    NSURL *dir = [[[NSFileManager defaultManager] homeDirectoryForCurrentUser]
                  URLByAppendingPathComponent:@"Library/LaunchAgents"];
    return [dir URLByAppendingPathComponent:[kAppID stringByAppendingString:@".plist"]];
}

- (void)setupAutostartOnFirstLaunch {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d boolForKey:@"didSetupAutostart"]) return;
    [d setBool:YES forKey:@"didSetupAutostart"];
    [d synchronize];
    if (![self isLoginItemEnabled]) {
        BOOL ok = [self installLaunchAgent];
        NSLog(@"[FanMenuBar] 首次启动自动安装开机自启: %@", ok ? @"ok" : @"failed");
    }
}

- (void)toggleLogin:(NSButton *)sender {
    BOOL enable = sender.state == NSControlStateValueOn;
    BOOL ok = [self setLoginItemEnabled:enable];
    if (!ok) {
        sender.state = enable ? NSControlStateValueOff : NSControlStateValueOn;
        NSAlert *a = [NSAlert new];
        a.messageText = @"设置开机自启失败";
        a.informativeText = @"无法写入 ~/Library/LaunchAgents。请检查磁盘权限后重试。";
        [a runModal];
    }
}

- (BOOL)setLoginItemEnabled:(BOOL)enable {
    return enable ? [self installLaunchAgent] : [self removeLaunchAgent];
}

- (NSString *)bundleExecutablePath {
    return [[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@"Contents/MacOS/FanMenuBar"];
}

- (BOOL)installLaunchAgent {
    NSURL *path = [self launchAgentPath];
    NSDictionary *plist = @{
        @"Label": kAppID,
        @"ProgramArguments": @[ [self bundleExecutablePath] ],
        @"RunAtLoad": @YES,
        @"ProcessType": @"Interactive",
        @"LimitLoadToSessionType": @"Aqua",
    };
    [[NSFileManager defaultManager] createDirectoryAtURL:[path URLByDeletingLastPathComponent]
                             withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL written = [plist writeToURL:path error:nil];
    if (!written) return NO;

    // 不在安装时 bootstrap：~/.Library/LaunchAgents 里的 plist 会在下次登录时由 launchd 自动加载，
    // 现在就 bootstrap 会立刻再拉起一个实例，出现两个菜单栏图标。
    return written;
}

- (BOOL)removeLaunchAgent {
    NSURL *path = [self launchAgentPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path.path]) {
        NSTask *task = [NSTask new];
        task.launchPath = @"/bin/launchctl";
        task.arguments = @[ @"bootout", @"gui", @(getuid()).stringValue, path.path ];
        @try { [task launch]; [task waitUntilExit]; } @catch (NSException *e) {}
        [[NSFileManager defaultManager] removeItemAtURL:path error:nil];
    }
    return YES;
}

@end

#pragma mark - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
