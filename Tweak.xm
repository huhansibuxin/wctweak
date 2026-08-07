/* Tweak.xm
 * 微信滑动手势独立 Tweak：右滑禁用 + 左滑自定义动作
 *
 * 目标进程：WeChat（com.tencent.xin）
 * 注入方式：TrollFools / ElleKit 均可
 *
 * 设计思路：
 *   不依赖 WCRefine 的内部配置系统（避免猜编码、避免版本更新失效）。
 *   通过 ObjC runtime 在运行时拦截手势，分两层：
 *     Layer 1: 尝试 hook WCRefine 已知的选择器名（runtime 解析，不依赖静态偏移）
 *     Layer 2: 兜底 —— 拦截 UISwipeGestureRecognizer 添加到消息类 cell 时，
 *             根据方向决定放行/吃掉/替换。
 *
 * 功能：
 *   ✅ 右滑完全禁用（吃掉手势，像没装插件一样）
 *   ✅ 左滑可扩展自定义动作（v1 先弹 toast 确认生效，后续加复制/标记已读等）
 *   ✅ 不影响 WCRefine 设置界面的正常操作（不再锁死 UI）
 *   ✅ OSLog 调试日志（写文件，设备上 cat 即可查看）
 *
 * 编译：make package
 * 安装：TrollFools 注入生成的 .deb 或直接放 dylib
 *
 * 作者：小弟 | 日期：2026-08-07 | 用途：逆向研究学习
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==================== 配置区（可按需修改）====================

static BOOL kDisableRightSwipe = YES;       // 是否禁用右滑
static BOOL kEnableCustomLeftSwipe = YES;   // 是否启用左滑自定义动作
static NSString *kLogFilePath = @"/var/mobile/Library/Preferences/com.boss.swipetweak.log";

// ==================== 日志工具 ====================

static void SwipeTweakLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss.SSS"];
    NSString *timestamp = [fmt stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timestamp, msg];

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kLogFilePath]) {
        [fm createFileAtPath:kLogFilePath contents:data attributes:nil];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFilePath];
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    }

    // 控制台也输出（oslog 可抓）
    NSLog(@"[SwipeTweak] %@", msg);
}

// ==================== 左滑自定义动作 ====================

// v1: 弹一个简短提示确认左滑生效
// 后续可扩展为：复制文字 / 标记已读 / 快速回复 / 收藏 等
static void handleCustomLeftSwipe(UISwipeGestureRecognizer *gesture) {
    UIView *view = gesture.view;
    if (!view) return;

    SwipeTweakLog(@"左滑触发! view=%@ class=%@", view, NSStringFromClass([view class]));

    // 找到最近的 UIViewController 来显示提示
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            break;
        }
        responder = [responder nextResponder];
    }

    UIViewController *vc = (UIViewController *)responder;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"👈 左滑自定义"
        message:@"左滑手势已捕获！\n后续可在此添加：复制/标记已读/快速回复等"
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"好的"
        style:UIAlertActionStyleDefault handler:nil]];

    if (vc) {
        [vc presentViewController:animated:YES completion:nil];
    } else {
        // 兜底：用 window 显示
        [alert show];
    }
}

// ==================== Layer 1: Hook WCRefine 手势设置方法 ====================
// WCRefine 通过以下选择器名在 cell 上设置滑动手势（从逆向分析确认的选择器池）。
// 这些选择器在 ObjC runtime 中注册后可通过 %hook 按名拦截。

// 尝试 hook WCRefine 的手势初始化方法
// 注意：WCRefine 可能将此方法挂在 UIView / UITableViewCell 的 category 上
%hook NSObject

// wcrefine_setupSwipeGestureIfNeeded — WCRefine 内部方法，用于给消息 cell 添加滑动手势
// 如果 runtime 中存在这个方法，我们就能拦截它
- (void)wcrefine_setupSwipeGestureIfNeeded {
    %orig; // 先让 WCRefine 正常设置好所有手势

    // 然后我们来做"后处理"：遍历当前 view 的手势，调整右滑和左滑
    if (![self isKindOfClass:[UIView class]]) return;

    UIView *targetView = (UIView *)self;
    NSArray<__kindof UIGestureRecognizer *> *gestures = [targetView gestureRecognizers];

    if (!gestures || gestures.count == 0) return;

    BOOL modified = NO;
    for (UIGestureRecognizer *g in gestures) {
        if (![g isKindOfClass:[UISwipeGestureRecognizer class]]) continue;

        UISwipeGestureRecognizer *swipe = (UISwipeGestureRecognizer *)g;
        UISwipeGestureRecognizerDirection dir = swipe.direction;

        if (kDisableRightSwipe && (dir & UISwipeGestureRecognizerDirectionRight)) {
            SwipeTweakLog(@"Layer1: 禁用右滑 gesture=%@ on view=%@",
                swipe, NSStringFromClass([targetView class]));
            swipe.enabled = NO;  // 禁用而非移除（避免 WCRefine 内部状态异常）
            modified = YES;
        }

        if (kEnableCustomLeftSwipe && (dir & UISwipeGestureRecognizerDirectionLeft)) {
            SwipeTweakLog(@"Layer1: 替换左滑动作 gesture=%@ on view=%@",
                swipe, NSStringFromClass([targetView class]));
            // 移除原有 targets，添加我们的自定义 action
            NSArray<UITargetedAction *> *targets = [swipe valueForKey:@"targets"];
            for (id target in targets) {
                [swipe removeTarget:[target target] action:[target action]];
            }
            [swipe addTarget:self action:@selector(swipeTweak_leftSwipeFired:)];
            modified = YES;
        }
    }

    if (modified) {
        SwipeTweakLog(@"Layer1: 已处理 view=%@ (%lu gestures total)",
            NSStringFromClass([targetView class]), (unsigned long)gestures.count);
    }
}

// 我们的自定义左滑回调（通过 addTarget 注册）
- (void)swipeTweak_leftSwipeFired:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded) {
        handleCustomLeftSwipe(gesture);
    }
}

%end


// ==================== Layer 2: 兜底 —— 全局手势拦截器 ====================
// 如果 Layer 1 没命中（WCRefine 改了方法名或架构），这层确保右滑仍被禁用。
// 通过 hook UIView 的 addGestureRecognizer: 来实现。

%hook UIView

- (void)addGestureRecognizer:(UIGestureRecognizer *)gesture {
    if ([gesture isKindOfClass:[UISwipeGestureRecognizer class]]) {
        UISwipeGestureRecognizer *swipe = (UISwipeGestureRecognizer *)gesture;
        UISwipeGestureRecognizerDirection dir = swipe.direction;

        // 判断是否在聊天消息上下文中（简单启发：view 在 UITableView/UICollectionView 内）
        BOOL isInMessageContext = NO;
        UIView *superview = self.superview;
        int depth = 0;
        while (superview && depth < 5) {
            if ([NSStringFromClass([superview class]) containsString:@"TableView"] ||
                [NSStringFromClass([superview class]) containsString:@"CollectionView"] ||
                [NSStringFromClass([superview class]) containsString:@"Message"] ||
                [NSStringFromClass([superview class]) containsString:@"Chat"]) {
                isInMessageContext = YES;
                break;
            }
            superview = superview.superview;
            depth++;
        }

        if (isInMessageContext || [NSStringFromClass([self class]) containsString:@"Cell"]) {
            if (kDisableRightSwipe && (dir & UISwipeGestureRecognizerDirectionRight)) {
                SwipeTweakLog(@"Layer2: 拦截右滑添加 view=%@ class=%@ direction=%ld",
                    self, NSStringFromClass([self class]), (long)dir);
                // 不调用 %orig —— 右滑手势根本不会被添加到 view 上
                return;
            }

            if (kEnableCustomLeftSwipe && (dir & UISwipeGestureRecognizerDirectionLeft)) {
                SwipeTweakLog(@"Layer2: 拦截并替换左滑 view=%@ class=%@",
                    self, NSStringFromClass([self class]));
                // 先让原始手势添加上去（保持 WCRefine 的内部一致性）
                %orig;
                // 然后替换 action 为我们的
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        NSArray<UITargetedAction *> *targets = [swipe valueForKey:@"targets"];
                        for (id t in targets) {
                            [swipe removeTarget:[t target] action:[t action]];
                        }
                        [swipe addTarget:self action:@selector(swipeTweak_layer2LeftSwipe:)];
                    });
                return;
            }
        }
    }

    %orig;
}

// Layer 2 左滑回调
- (void)swipeTweak_layer2LeftSwipe:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded) {
        handleCustomLeftSwipe(gesture);
    }
}

%end


// ==================== Constructor: 加载时输出信息 ====================

%ctor {
    @autoreleasepool {
        SwipeTweakLog("========== SwipeTweak Loaded ==========");
        SwipeTweakLog("禁用右滑: %@ | 自定义左滑: %@",
            kDisableRightSwipe ? @"YES" : @"NO",
            kEnableCustomLeftSwipe ? @"YES" : @"NO");

        // 检测运行环境
        SwipeTweakLog("进程: %@", [[NSProcessInfo processInfo] processName]);
        SwipeTweakLog("BundleID: %@", [[NSBundle mainBundle] bundleIdentifier]);

        // 检查 WCRefine 是否已加载（通过类是否存在判断）
        Class wcConfig = NSClassFromString(@"WCRefineConfig");
        if (wcConfig) {
            SwipeTweakLog("WCRefine: 已检测到 (WCRefineConfig 存在)");
        } else {
            SwipeTweakLog("WCRefine: 未检测到 (独立模式运行)");
        }

        SwipeTweakLog("========================================");
    }
}
