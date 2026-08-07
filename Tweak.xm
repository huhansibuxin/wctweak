/* Tweak.xm
 * 微信滑动手势独立 Tweak（rootless / ElleKit）
 * 目标进程：com.tencent.xin (WeChat)
 *
 * 功能：
 *   1) 右滑完全禁用（在消息上下文中，拦截 UISwipeGestureRecognizer 右滑，使其不被添加到 view）
 *   2) 左滑替换为自定义动作（v1 弹窗确认，后续可扩展为复制/标记已读/快速回复等）
 *
 * 设计原则（对照老板硬性规则）：
 *   - ① 不虚构任何 OC 私有类 / 私有方法 / selector。
 *       本插件仅使用公开 API（UIKit / runtime）做手势拦截与替换，
 *       不依赖 WCRefine 内部类名或任何硬编码偏移，版本更新不会因偏移失效。
 *   - 替换左滑的做法是：不添加微信原左滑手势，改为给同一 view 添加我们自己的
 *       UISwipeGestureRecognizer（公开 API），从而彻底接管左滑行为。
 *   - 日志写文件到 App 沙盒 Documents（rootless 下唯一稳妥可写路径，
 *       注入 dylib 的 NSLog 无法被 oslog 捕获，故写文件；设备端用 scp 或
 *       TrollFools 文件管理取 /var/mobile/Containers/Data/.../Documents/com.boss.swipetweak.log）。
 *
 * 已知局限（如实说明，规则⑧）：
 *   - 拦截基于 UISwipeGestureRecognizer。若新版微信改用 UIPanGestureRecognizer
 *       实现侧滑菜单，则本插件对该菜单无效（右滑禁用/左滑自定义都依赖 swipe 手势）。
 *   - “消息上下文”靠类名启发式判定（Cell/TableView/CollectionView/Message/Chat/Bubble），
 *       覆盖常见聊天列表，但极端自定义类名可能漏判。可在 STIsMessageContext 增删关键字。
 *
 * 编译：make package
 * 注入：TrollFools 注入生成的 .deb / dylib 即可（Filter 限定微信）
 *
 * 作者：小弟 | 2026-08-07 | 用途：逆向研究学习
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 配置（按需修改后重新编译）

static BOOL kDisableRightSwipe     = YES;  // 是否禁用右滑（消息上下文内）
static BOOL kEnableCustomLeftSwipe = YES;  // 是否用自定义动作替换左滑

#pragma mark - 日志工具（公开 API，写 App 沙盒 Documents）

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

// 注意：所有调用必须传 @"" 字符串字面量（本函数形参为 NSString *，规则：不混用 C 字符串）
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
    // 控制台也输出（oslog 抓不到注入 dylib 的 NSLog，但保留无害）
    NSLog(@"[SwipeTweak] %@", msg);
}

#pragma mark - 判断是否处于“消息上下文”

// 仅靠类名关键字判定，纯 NSString 操作，不触碰任何私有类。
static BOOL STIsMessageContext(UIView *view) {
    UIView *v = view;
    int depth = 0;
    while (v && depth < 6) {
        NSString *cn = NSStringFromClass([v class]);
        if ([cn containsString:@"Cell"]          ||
            [cn containsString:@"TableView"]     ||
            [cn containsString:@"CollectionView"] ||
            [cn containsString:@"Message"]       ||
            [cn containsString:@"Chat"]          ||
            [cn containsString:@"Bubble"]) {
            return YES;
        }
        v = v.superview;
        depth++;
    }
    return NO;
}

#pragma mark - 自定义左滑动作（v1：弹窗确认）

static void STHandleLeftSwipe(UISwipeGestureRecognizer *g) {
    if (g.state != UIGestureRecognizerStateEnded) return;

    // 找最近的 UIViewController 来 present 弹窗（公开 API 链）
    UIViewController *vc = nil;
    UIResponder *r = g.view;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) {
            vc = (UIViewController *)r;
            break;
        }
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
        // 正确用法：presentViewController:alert animated:completion:
        [vc presentViewController:alert animated:YES completion:nil];
    } else {
        // 兜底：通过 keyWindow 的 rootViewController 弹
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

#pragma mark - 手势标记（区分“我们自己的手势”）

static const void *kSTOwnGesture = &kSTOwnGesture;

#pragma mark - 核心 Hook：UIView addGestureRecognizer:

%hook UIView

- (void)addGestureRecognizer:(UIGestureRecognizer *)gesture {
    if ([gesture isKindOfClass:[UISwipeGestureRecognizer class]]) {
        // 我们自己添加的手势：直接放行，避免无限递归
        if (objc_getAssociatedObject(gesture, kSTOwnGesture)) {
            %orig;
            return;
        }

        UISwipeGestureRecognizer *swipe = (UISwipeGestureRecognizer *)gesture;

        if (STIsMessageContext(self)) {
            UISwipeGestureRecognizerDirection dir = swipe.direction;

            // —— 右滑：直接不添加，达到“禁用”效果 ——
            if (kDisableRightSwipe && (dir & UISwipeGestureRecognizerDirectionRight)) {
                STLog(@"拦截右滑（不添加）on %@", NSStringFromClass([self class]));
                return;
            }

            // —— 左滑：不添加微信原手势，改为添加我们自己的左滑手势 ——
            if (kEnableCustomLeftSwipe && (dir & UISwipeGestureRecognizerDirectionLeft)) {
                // 防重复：同一 view 若已有我们的左滑手势则跳过（兼容 cell 复用）
                BOOL hasOurs = NO;
                for (UIGestureRecognizer *g in [self gestureRecognizers]) {
                    if (objc_getAssociatedObject(g, kSTOwnGesture)) { hasOurs = YES; break; }
                }
                if (!hasOurs) {
                    STLog(@"替换左滑（添加自定义）on %@", NSStringFromClass([self class]));
                    UISwipeGestureRecognizer *ours =
                        [[UISwipeGestureRecognizer alloc]
                            initWithTarget:self
                                    action:@selector(st_leftSwipeFired:)];
                    ours.direction = UISwipeGestureRecognizerDirectionLeft;
                    // 标记为我们自己的手势，重入 hook 时直接放行
                    objc_setAssociatedObject(ours, kSTOwnGesture, @(YES),
                                            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    // 这里会重入 addGestureRecognizer:，被上面的 own-gesture 分支放行
                    [self addGestureRecognizer:ours];
                }
                return; // 始终不添加微信原左滑手势
            }
        }
    }

    %orig;
}

// 我们自定义左滑手势的回调（%new 给 UIView 动态添加方法，公开 API 调用）
%new
- (void)st_leftSwipeFired:(UISwipeGestureRecognizer *)g {
    STHandleLeftSwipe(g);
}

%end

#pragma mark - Constructor：加载时记录环境

%ctor {
    @autoreleasepool {
        STInitLog();

        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        STLog(@"========== SwipeTweak Loaded ==========");
        STLog(@"bundle=%@ | proc=%@", bid, NSProcessInfo.processInfo.processName);
        STLog(@"disableRight=%@ | customLeft=%@",
              kDisableRightSwipe ? @"YES" : @"NO",
              kEnableCustomLeftSwipe ? @"YES" : @"NO");
        if (![bid isEqualToString:@"com.tencent.xin"]) {
            STLog(@"警告：非微信进程却已加载（请检查 Filter plist）");
        }
        STLog(@"========================================");
    }
}
