/* Tweak.xm v3 —— 微信滑动手势独立 Tweak（rootless / ElleKit）
 *
 * 为什么 v2 完全无效（复盘）：
 *   微信的消息侧滑菜单不是 UISwipeGestureRecognizer，而是
 *   MMMultiMenuTableViewCell 上的 UIPanGestureRecognizer（实例变量 _panGestureRecognizer）
 *   + handlePan: 自实现（来自公开 class-dump 头文件确认）。
 *   所以 v2 只拦截 UISwipeGestureRecognizer 的 hook 全部落空，左右滑都没反应。
 *
 * 本版做法（hook 真正的侧滑 cell 基类）：
 *   1) MMMultiMenuTableViewCell 是微信所有“可侧滑菜单” cell 的基类（聊天消息 cell 也继承它）。
 *      - gestureRecognizerShouldBegin: 对 pan 手势返回 NO
 *        ⇒ 彻底禁用原生左右滑菜单（仅在聊天页 BaseMsgContentViewController 内生效，
 *           不影响“微信”首页的会话列表等其他列表的侧滑）。
 *   2) 给该 cell 自己 add 一个左滑 UISwipeGestureRecognizer ⇒ 自定义动作（v1 弹窗确认）。
 *   3) 不添加右滑手势 ⇒ 右滑无动作（满足“右滑完全禁用”）。
 *
 * 规则遵循：
 *   - ① 不虚构私有类/私有方法：MMMultiMenuTableViewCell / BaseMsgContentViewController
 *       仅以 NSClassFromString 在运行时按名解析，未声明任何私有头；拦截只用公开
 *       gestureRecognizerShouldBegin: 与 UISwipeGestureRecognizer 公开 API。
 *   - 日志写 App 沙盒 Documents/com.boss.swipetweak.log（注入 dylib 的 NSLog 抓不到，故写文件）。
 *
 * 已知局限（如实说明，规则⑧）：
 *   - 依赖类名 MMMultiMenuTableViewCell / BaseMsgContentViewController 在目标微信版本中存在。
 *     已在 %ctor 与运行中写日志自检；若某版微信改名，日志会显示 NOT FOUND，据此替换类名即可。
 *   - 禁用 pan 是“连坐”式：聊天页内所有 MMMultiMenuTableViewCell 的原生侧滑菜单都不再出现
 *     （含原生左滑的 引用/回复/删除 等），统一由我们的左滑接管。若只想在聊天页禁用、保留其他
 *     列表原生菜单，已用 STInChat 限定聊天页；如仍不满意可放宽/收紧。
 *
 * 编译：make package ｜ 注入：TrollFools 注入生成的 .deb / dylib
 * 作者：小弟 ｜ 2026-08-07 ｜ 逆向研究学习
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 配置（按需修改后重新编译）
static BOOL kDisableNativeSwipeMenu = YES;  // 禁用原生左右滑菜单（聊天页内）
static BOOL kEnableCustomLeftSwipe    = YES; // 启用自定义左滑动作

#pragma mark - 日志（公开 API，写 App 沙盒 Documents）
static NSString     *g_logPath   = nil;
static NSFileHandle *g_logHandle = nil;
static NSLock       *g_logLock   = nil;

static void STInitLog(void) {
    @autoreleasepool {
        NSArray<NSString *> *paths =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *dir = (paths.count > 0) ? paths.firstObject : @"/var/mobile/Documents";
        g_logPath = [dir stringByAppendingPathComponent:@"com.boss.swipetweak.log"];
        [[NSFileManager defaultManager] createFileAtPath:g_logPath
                                                contents:nil
                                              attributes:nil];
        g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
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
    NSLog(@"[SwipeTweak] %@", msg);
}

#pragma mark - 判断 view 是否处于“聊天页”上下文
// 沿 responder 链向上找 BaseMsgContentViewController（聊天内容页，类名长期稳定）。
static BOOL STInChat(UIView *view) {
    static Class sChatVC = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sChatVC = NSClassFromString(@"BaseMsgContentViewController");
    });
    if (!sChatVC) return NO;
    UIResponder *r = view;
    while (r) {
        if ([r isKindOfClass:sChatVC]) return YES;
        r = [r nextResponder];
    }
    return NO;
}

#pragma mark - 自定义左滑动作（v1：弹窗确认）
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
        message:@"左滑手势已捕获！\n后续可扩展：复制 / 标记已读 / 快速回复"
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

#pragma mark - 标记（区分“我们自己的手势”，防重复添加）
static const void *kSTLeftSwipeAdded = &kSTLeftSwipeAdded;

#pragma mark - 核心 Hook：MMMultiMenuTableViewCell（所有可侧滑 cell 的基类）
%hook MMMultiMenuTableViewCell

// 禁用原生侧滑菜单：让 cell 自带的 pan 手势无法开始（聊天页内）
- (BOOL)gestureRecognizerShouldBegin:(id)gesture {
    if (kDisableNativeSwipeMenu &&
        [gesture isKindOfClass:[UIPanGestureRecognizer class]] &&
        STInChat((UIView *)self)) {
        STLog(@"禁用原生侧滑菜单(cell=%@)", NSStringFromClass([self class]));
        return NO;
    }
    return %orig;
}

// 给 cell 添加我们自己的左滑手势（仅聊天页，每 cell 实例一次）
- (void)layoutSubviews {
    %orig;
    if (kEnableCustomLeftSwipe && STInChat((UIView *)self)) {
        if (!objc_getAssociatedObject(self, kSTLeftSwipeAdded)) {
            objc_setAssociatedObject(self, kSTLeftSwipeAdded, @(YES),
                                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UISwipeGestureRecognizer *sw = [[UISwipeGestureRecognizer alloc]
                initWithTarget:self
                        action:@selector(st_leftSwipe:)];
            sw.direction = UISwipeGestureRecognizerDirectionLeft;
            [self addGestureRecognizer:sw];
            STLog(@"已添加自定义左滑手势 cell=%@", NSStringFromClass([self class]));
        }
    }
}

// 自定义左滑回调（%new 给 cell 动态加方法，公开 API 调用）
%new
- (void)st_leftSwipe:(UISwipeGestureRecognizer *)g {
    STHandleLeftSwipe(g);
}

%end

#pragma mark - Constructor：加载时记录环境 + 类名自检
%ctor {
    @autoreleasepool {
        STInitLog();

        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        STLog(@"========== SwipeTweak v3 Loaded ==========");
        STLog(@"bundle=%@ | proc=%@", bid, NSProcessInfo.processInfo.processName);
        STLog(@"MMMultiMenuTableViewCell = %@",
              NSClassFromString(@"MMMultiMenuTableViewCell") ? @"found" : @"NOT FOUND");
        STLog(@"BaseMsgContentViewController = %@",
              NSClassFromString(@"BaseMsgContentViewController") ? @"found" : @"NOT FOUND");
        STLog(@"disableNative=%@ | customLeft=%@",
              kDisableNativeSwipeMenu ? @"YES" : @"NO",
              kEnableCustomLeftSwipe ? @"YES" : @"NO");
        if (![bid isEqualToString:@"com.tencent.xin"]) {
            STLog(@"警告：非微信进程却已加载（请检查 Filter plist）");
        }
        STLog(@"===========================================");
    }
}
