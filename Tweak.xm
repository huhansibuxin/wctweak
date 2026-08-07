/* Tweak.xm v4 —— 微信滑动手势独立 Tweak（rootless / ElleKit）
 *
 * 复盘 v3 为何“左右滑完全没反应”：
 *   v3 写死了 hook MMMultiMenuTableViewCell（来自【新版微信】公开 class-dump）。
 *   目标机微信是 8.0.37（2021 年底旧版），该版本聊天消息 cell 很可能不叫这个名字 /
 *   不是该基类，于是 Logos 对“不存在的类”静默 no-op —— 原生菜单没禁、自定义左滑也没挂。
 *   别的插件能滑，是因为它们 hook 了自己支持版本里真实存在的类。
 *
 * v4 改法（不靠猜类名，规则①：不虚构私有类/私有方法）：
 *   1) 直接 hook 公开的 UITableViewCell / UICollectionViewCell（聊天消息 cell 必是二者
 *      子类，layoutSubviews 必然触发），保证自定义左滑一定能挂上，跨版本稳定。
 *   2) 启动时用 runtime 枚举所有类，自动定位“聊天页 VC”（类名含 BaseMsgContent /
 *      MsgContentViewController），并记录候选菜单类，写入日志便于核验。
 *   3) 在微信「设置」页（按 self.title == @"设置" 判定，中文微信稳定，不依赖类名）
 *      右上角注入「⚙︎滑动」按钮，打开开关面板，存 NSUserDefaults 即时生效。
 *
 * 日志位置：/var/jb/tmp/com.boss.swipetweak.log（rootless 可写，ssh 上手机直接 cat 看）。
 * 编译：make package ｜ 注入：TrollFools 注入生成的 .deb / .dylib
 * 作者：小弟 ｜ 2026-08-07 ｜ 逆向研究学习
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 前向声明（供注入的新方法与设置面板引用，避免“未声明选择器/类型”编译错误）
// 给 UIViewController 注入的新方法，先声明选择器让编译器认可
@interface UIViewController (SwipeTweak)
- (void)st_maybeAddSettingsButton;
- (void)st_openSwipeSettings;
@end
// 设置面板类前向声明（具体 @implementation 在文件末尾）
@interface STSettingsViewController : UITableViewController
@end

#pragma mark - 配置键（NSUserDefaults，设置面板与手势逻辑共用）
static NSString *kEnabled       = @"com.boss.swipetweak.enabled";        // 总开关
static NSString *kDisableNative = @"com.boss.swipetweak.disableNative";  // 禁用原生侧滑菜单
static NSString *kCustomLeft    = @"com.boss.swipetweak.customLeft";     // 启用自定义左滑动作

// 读取开关；未设置时给默认值 def
static BOOL STGetBool(NSString *key, BOOL def) {
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return (v != nil) ? [v boolValue] : def;
}

#pragma mark - 日志（优先写 /var/jb/tmp，便于 ssh cat；失败回退沙盒 Documents）
static NSFileHandle *g_logHandle = nil;
static NSLock       *g_logLock   = nil;

static void STInitLog(void) {
    @autoreleasepool {
        // 1) 尝试 rootless 可写目录
        NSString *path = @"/var/jb/tmp/com.boss.swipetweak.log";
        NSString *dir  = @"/var/jb/tmp";
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:nil];
        }
        if ([[NSFileManager defaultManager] createFileAtPath:path
                                                    contents:nil
                                                  attributes:nil]) {
            g_logHandle = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        // 2) 失败则回退到 App 沙盒 Documents
        if (!g_logHandle) {
            NSArray<NSString *> *paths =
                NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            NSString *d = (paths.count > 0) ? paths.firstObject : @"/var/mobile/Documents";
            path = [d stringByAppendingPathComponent:@"com.boss.swipetweak.log"];
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            g_logHandle = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        [g_logHandle seekToEndOfFile];
        g_logLock = [[NSLock alloc] init];
    }
}

static void STLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    if (g_logHandle && g_logLock) {
        [g_logLock lock];
        [g_logHandle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [g_logHandle synchronizeFile];
        [g_logLock unlock];
    }
    NSLog(@"[SwipeTweak] %@", msg);   // 注入 dylib 的 NSLog 抓不到，仅作兜底
}

#pragma mark - 运行时类探测（规则①：不写死私有类，运行时按名解析 + 自适应）
static Class sChatVC = nil;  // 探测到的“聊天内容页”VC

static void STDiscoverClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    if (!classes) return;
    objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        NSString *name = [NSString stringWithUTF8String:class_getName(c)];
        // 聊天页 VC：优先 BaseMsgContent（最精确），退而求其次含 MsgContentViewController
        if ([name containsString:@"BaseMsgContent"]) {
            sChatVC = c;
        } else if (!sChatVC && [name containsString:@"MsgContentViewController"]) {
            sChatVC = c;
        }
        // 记录候选“菜单/侧滑”类，供后续版本精细化禁用原生菜单时参考
        if ([name containsString:@"MultiMenu"] ||
            [name containsString:@"Swipe"]    ||
            [name containsString:@"MenuTableViewCell"] ||
            [name containsString:@"NewSettingViewController"] ||
            [name containsString:@"SettingViewController"] ||
            [name containsString:@"MMSettingsController"]) {
            STLog(@"候选类: %@", name);
        }
    }
    free(classes);
}

// 判断某 view 是否处在聊天内容页（沿 responder 链向上找探测到的聊天 VC）
static BOOL STInChat(UIView *view) {
    if (!view) return NO;
    Class chat = sChatVC;
    if (!chat) chat = NSClassFromString(@"BaseMsgContentViewController"); // 兜底旧名
    if (!chat) return NO;
    UIResponder *r = view;
    while (r) {
        if ([r isKindOfClass:chat]) return YES;
        r = [r nextResponder];
    }
    return NO;
}

#pragma mark - 自定义左滑动作（弹窗，可后续扩展）
static void STHandleLeftSwipe(UISwipeGestureRecognizer *g) {
    if (g.state != UIGestureRecognizerStateEnded) return;

    UIViewController *vc = nil;
    UIResponder *r = g.view;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) { vc = (UIViewController *)r; break; }
        r = [r nextResponder];
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"👈 左滑自定义"
        message:@"左滑手势已捕获！\n（可在「设置 → ⚙︎滑动」里开关；后续可扩展复制/标记已读/快速回复）"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];

    if (vc) {
        [vc presentViewController:alert animated:YES completion:nil];
    } else {
        UIWindow *win = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (win.rootViewController) {
            [win.rootViewController presentViewController:alert animated:YES completion:nil];
        }
    }
    STLog(@"左滑触发 on %@", NSStringFromClass([g.view class]));
}

#pragma mark - 给 cell 挂自定义左滑（每个 cell 实例只挂一次）
static const void *kSTLeftSwipeAdded = &kSTLeftSwipeAdded;

static void STConfigureCell(UIView *cell) {
    if (!STGetBool(kEnabled, YES)) return;
    if (STGetBool(kCustomLeft, YES) && STInChat(cell)) {
        if (!objc_getAssociatedObject(cell, kSTLeftSwipeAdded)) {
            objc_setAssociatedObject(cell, kSTLeftSwipeAdded, @(YES),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UISwipeGestureRecognizer *g = [[UISwipeGestureRecognizer alloc]
                initWithTarget:cell
                        action:@selector(st_leftSwipe:)];
            g.direction = UISwipeGestureRecognizerDirectionLeft;
            [cell addGestureRecognizer:g];
            STLog(@"已添加自定义左滑手势 cell=%@", NSStringFromClass([cell class]));
        }
    }
}

// 原生侧滑菜单通常是 cell 上的 UIPanGestureRecognizer；在聊天页内直接拦掉
static BOOL STShouldBlockNativePan(UIView *cell, id gesture) {
    if (STGetBool(kEnabled, YES) && STGetBool(kDisableNative, YES) &&
        [gesture isKindOfClass:[UIPanGestureRecognizer class]] &&
        STInChat(cell)) {
        STLog(@"禁用原生侧滑 pan cell=%@", NSStringFromClass([cell class]));
        return YES;
    }
    return NO;
}

#pragma mark - 核心 Hook：UITableViewCell（聊天消息 cell 的公开基类，跨版本稳定）
%hook UITableViewCell

- (void)layoutSubviews {
    %orig;
    STConfigureCell((UIView *)self);
}

- (BOOL)gestureRecognizerShouldBegin:(id)gesture {
    if (STShouldBlockNativePan((UIView *)self, gesture)) return NO;
    return %orig;
}

%new
- (void)st_leftSwipe:(UISwipeGestureRecognizer *)g {
    STHandleLeftSwipe(g);
}

%end

#pragma mark - 核心 Hook：UICollectionViewCell（部分版本/界面用 collection 兜底）
%hook UICollectionViewCell

- (void)layoutSubviews {
    %orig;
    STConfigureCell((UIView *)self);
}

- (BOOL)gestureRecognizerShouldBegin:(id)gesture {
    if (STShouldBlockNativePan((UIView *)self, gesture)) return NO;
    return %orig;
}

%new
- (void)st_leftSwipe:(UISwipeGestureRecognizer *)g {
    STHandleLeftSwipe(g);
}

%end

#pragma mark - 设置入口：在「设置」页右上角注入按钮（按 title 判定，不依赖类名）
static const void *kSTSettingsAdded = &kSTSettingsAdded;

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self st_maybeAddSettingsButton];
}

%new
- (void)st_maybeAddSettingsButton {
    // 只在本页标题为“设置”时注入（中文微信稳定；其它语言请改此字符串）
    NSString *title = self.title;
    if (!title && self.navigationItem.title) title = self.navigationItem.title;
    if (![title isEqualToString:@"设置"]) return;
    if (objc_getAssociatedObject(self, kSTSettingsAdded)) return;  // 每实例只加一次
    objc_setAssociatedObject(self, kSTSettingsAdded, @(YES),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIBarButtonItem *item = [[UIBarButtonItem alloc]
        initWithTitle:@"⚙︎滑动"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(st_openSwipeSettings)];
    self.navigationItem.rightBarButtonItem = item;
    STLog(@"已在「设置」页注入滑动设置按钮");
}

%new
- (void)st_openSwipeSettings {
    STSettingsViewController *vc = [[STSettingsViewController alloc] init];
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

%end

#pragma mark - 设置面板（我们自己的 VC，公开 API 实现）
@implementation STSettingsViewController {
    NSArray<NSDictionary *> *_rows;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        self.title = @"滑动手势设置";
        _rows = @[
            @{@"key": kEnabled,       @"title": @"启用滑动插件"},
            @{@"key": kDisableNative, @"title": @"禁用原生侧滑菜单"},
            @{@"key": kCustomLeft,    @"title": @"启用自定义左滑动作"},
        ];
    }
    return self;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"st"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:@"st"];
    NSDictionary *r = _rows[ip.row];
    c.textLabel.text = r[@"title"];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = STGetBool(r[@"key"], YES);
    sw.tag = ip.row;
    [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (void)toggle:(UISwitch *)sw {
    NSDictionary *r = _rows[sw.tag];
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:r[@"key"]];
    [[NSUserDefaults standardUserDefaults] synchronize];
    STLog(@"设置变更 %@ = %@", r[@"key"], sw.on ? @"YES" : @"NO");
}

@end

#pragma mark - Constructor：加载时记录环境 + 类探测
%ctor {
    @autoreleasepool {
        STInitLog();
        STDiscoverClasses();

        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        STLog(@"========== SwipeTweak v4 Loaded ==========");
        STLog(@"bundle=%@ | proc=%@", bid, NSProcessInfo.processInfo.processName);
        STLog(@"chatVC=%@", sChatVC ? NSStringFromClass(sChatVC)
                                    : @"BaseMsgContentViewController(fallback)");
        STLog(@"enabled=%@ disableNative=%@ customLeft=%@",
              STGetBool(kEnabled, YES) ? @"YES" : @"NO",
              STGetBool(kDisableNative, YES) ? @"YES" : @"NO",
              STGetBool(kCustomLeft, YES) ? @"YES" : @"NO");
        if (![bid isEqualToString:@"com.tencent.xin"]) {
            STLog(@"警告：非微信进程却已加载（请检查 Filter plist）");
        }
        STLog(@"==========================================");
    }
}
