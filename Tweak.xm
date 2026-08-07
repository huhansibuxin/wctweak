/* Tweak.xm v7 —— 微信滑动手势独立 Tweak（rootless / ElleKit）
 *
 * v7 变更（对照用户反馈 + v6 日志诊断）：
 *   1) 消息对象探测增强：全量打印 ChatTableViewCell 所有 ivar/property，
 *      不再只匹配 Msg/Message 关键字；同时尝试更多 getter 模式。
 *   2) 左滑菜单改为动态：自己的消息→「删除+撤回」；对方的消息→仅「删除」。
 *      不再有全局"选一个动作"的设置，而是根据消息归属自动显示对应选项。
 *   3) UIPan 跟随动画保留；设置页简化为总开关（动作由消息归属决定）。
 *
 * 规则①遵守：不声明任何私有类/私有方法头文件。所有微信内部调用均通过
 *  运行时 performSelector: / NSInvocation / method_getImplementation 探测+调用。
 *
 * 日志位置：App 沙盒 Documents/com.boss.swipetweak.log
 * 编译：make package ｜ 注入：TrollFools 注入生成的 .deb / .dylib
 * 作者：小弟 ｜ 2026-08-07 ｜ 逆向研究学习
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 前向声明
@interface UIViewController (SwipeTweak)
- (void)st_maybeAddSettingsButton;
- (void)st_openSwipeSettings;
@end
@interface STSettingsViewController : UITableViewController
@end

// C 函数前向声明（函数定义在文件更下方）
static void STExecuteSwipeAction(UIView *cell);
static void STShowFallbackAlert(UIViewController *vc, NSString *action, id msgObj);
static void STDumpViewRec(UIView *v, int depth, int maxDepth);

#pragma mark - 配置键（NSUserDefaults）
static NSString *kEnabled = @"com.boss.swipetweak.enabled";  // 总开关

static BOOL STGetBool(NSString *key, BOOL def) {
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return (v != nil) ? [v boolValue] : def;
}

#pragma mark - 日志（固定写 App 沙盒 Documents）
static NSFileHandle *g_logHandle = nil;
static NSLock       *g_logLock   = nil;

static void STInitLog(void) {
    @autoreleasepool {
        NSArray<NSString *> *paths =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *d = (paths.count > 0) ? paths.firstObject : @"/var/mobile/Documents";
        NSString *path = [d stringByAppendingPathComponent:@"com.boss.swipetweak.log"];
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        g_logHandle = [NSFileHandle fileHandleForWritingAtPath:path];
        [g_logHandle seekToEndOfFile];
        g_logLock = [[NSLock alloc] init];
    }
}

static void STLog(NSString *fmt, ...) __attribute__((format(NSString, 1, 2)));
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
}

#pragma mark - 运行时类探测
static Class sChatVC = nil;

static void STDiscoverClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    if (!classes) return;
    objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        NSString *name = [NSString stringWithUTF8String:class_getName(c)];
        if ([name containsString:@"BaseMsgContent"]) {
            sChatVC = c;
        } else if (!sChatVC && [name containsString:@"MsgContentViewController"]) {
            sChatVC = c;
        }
        // 记录可能相关的类
        if ([name containsString:@"MultiMenu"] ||
            [name containsString:@"MenuTableViewCell"] ||
            [name containsString:@"MessageCell"] ||
            [name containsString:@"MsgNode"] ||
            [name containsString:@"C2CMsgNode"]) {
            STLog(@"候选类: %@", name);
        }
    }
    free(classes);
}

static BOOL STInChat(UIView *view) {
    if (!view) return NO;
    Class chat = sChatVC;
    if (!chat) chat = NSClassFromString(@"BaseMsgContentViewController");
    if (!chat) return NO;
    UIResponder *r = view;
    while (r) {
        if ([r isKindOfClass:chat]) return YES;
        r = [r nextResponder];
    }
    return NO;
}

#pragma mark - 微信内部 API 调用（运行时探测）

// 全量 dump cell 的 ivar 和 property（首次失败时调用，只打一次）
static BOOL g_dumpedCellIvars = NO;
static void STDumpCellIvars(UIView *cell) {
    if (g_dumpedCellIvars) return;
    g_dumpedCellIvars = YES;

    Class cls = [cell class];
    STLog(@"=== 全量 ivar dump: %s ===", class_getName(cls));

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        const char *name = ivar_getName(ivars[i]);
        id val = nil;
        @try { val = object_getIvar(cell, ivars[i]); } @catch (NSException *e) {}
        const char *valCls = val ? class_getName([val class]) : "(nil)";
        STLog(@"  ivar[%u] %s %s = <%s>", i, type, name, valCls);
    }
    if (ivars) free(ivars);

    // 也打 property
    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &propCount);
    STLog(@"=== 全量 property dump (%u) ===", propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        const char *name = property_getName(props[i]);
        const char *attrs = property_getAttributes(props[i]);
        STLog(@"  prop[%u] %s | %s", i, name, attrs);
    }
    if (props) free(props);

    // 打 cell 的 contentView 子视图层级（前2层）
    STLog(@"=== cell 子视图(前2层) ===");
    UIView *cv = nil;
    if ([cell respondsToSelector:@selector(contentView)]) {
        @try { cv = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(contentView)); }
        @catch (NSException *e) { cv = nil; }
    }
    if (cv) {
        STDumpViewRec(cv, 0, 2);
    }
}

// 递归打印视图层级（纯 C 函数）
static void STDumpViewRec(UIView *v, int depth, int maxDepth) {
    if (!v || depth > maxDepth) return;
    NSMutableString *indent = [NSMutableString string];
    for (int i = 0; i < depth; i++) [indent appendString:@"  "];
    STLog(@"%@%s", indent, class_getName([v class]));
    for (UIView *sub in v.subviews) {
        STDumpViewRec(sub, depth + 1, maxDepth);
    }
}

// 从 cell 上尝试获取消息数据对象（v7 增强版）
static id STGetMessageObjectFromCell(UIView *cell) {
    if (!cell) return nil;

    // 方法1：大量常见 getter 选择器（微信各版本用过的方法名）
    SEL getters[] = {
        @selector(messageData), @selector(msgData), @selector(message),
        @selector(msgNode),     @selector(data),
        @selector(viewModel),   @selector(cellViewModel),
        @selector(model),       @selector(itemModel),
        @selector(msgContent),  @selector(messageContent),
        @selector(wrapModel),  @selector(node),
        @selector(innerData),  @selector(rawData),
        @selector(chatMsg),     @selector(chatMessage),
    };
    for (size_t i = 0; i < sizeof(getters)/sizeof(getters[0]); i++) {
        if ([cell respondsToSelector:getters[i]]) {
            @try {
                id obj = ((id (*)(id, SEL))objc_msgSend)(cell, getters[i]);
                if (obj && ![obj isKindOfClass:[UIView class]]
                    && ![obj isKindOfClass:[CALayer class]]) {
                    STLog(@"通过 getter %@ 取到候选: %s",
                          NSStringFromSelector(getters[i]),
                          class_getName([obj class]));
                    return obj;
                }
            } @catch (NSException *e) { /* skip */ }
        }
    }

    // 方法2：遍历 ALL ivar（不做类型过滤，全部记录非 nil 的非视图对象）
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([cell class], &ivarCount);
    NSMutableArray<id> *candidates = [NSMutableArray array];
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        const char *name = ivar_getName(ivars[i]);
        if (!type || type[0] != '@') continue;
        id val = nil;
        @try { val = object_getIvar(cell, ivars[i]); } @catch (NSException *e) { continue; }
        if (!val) continue;
        // 排除视图层和基础类型
        if ([val isKindOfClass:[UIView class]] ||
            [val isKindOfClass:[CALayer class]] ||
            [val isKindOfClass:[UIGestureRecognizer class]] ||
            [val isKindOfClass:[UIColor class]] ||
            [val isKindOfClass:[UIFont class]] ||
            [val isKindOfClass:[NSNumber class]] ||
            [val isKindOfClass:[NSString class]] ||
            [val isKindOfClass:[NSArray class]] ||
            [val isKindOfClass:[NSDictionary class]] ||
            [val isKindOfClass:[NSData class]]) {
            continue;
        }
        // 剩下的都是"有可能是数据模型"的对象
        STLog(@"ivar 候选: %s(%s) -> %s", name, type, class_getName([val class]));
        [candidates addObject:val];
    }
    if (ivars) free(ivars);

    // 如果恰好只有一个候选，直接用它
    if (candidates.count == 1) {
        id found = candidates.firstObject;
        STLog(@"唯一候选(采用): %s", class_getName([found class]));
        return found;
    }
    if (candidates.count > 1) {
        // 多个候选：优先选名字含 Msg/Message/Node/Data/C2C 的
        for (id c in candidates) {
            const char *cls = class_getName([c class]);
            if (strstr(cls, "C2C") || strstr(cls, "Msg") ||
                strstr(cls, "Message") || strstr(cls, "Node")) {
                STLog(@"多候选中匹配到: %s", cls);
                return c;
            }
        }
        // 都不匹配就取第一个
        id first = candidates.firstObject;
        STLog(@"多候选无精确匹配，取第一个: %s", class_getName([first class]));
        return first;
    }

    // 方法3：遍历 property（同样放宽过滤）
    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList([cell class], &propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        const char *name = property_getName(props[i]);
        NSString *key = [NSString stringWithUTF8String:name];
        @try {
            id val = [cell valueForKey:key];
            if (val && ![val isKindOfClass:[UIView class]]
                && ![val isKindOfClass:[CALayer class]]
                && ![val isKindOfClass:[UIGestureRecognizer class]]
                && ![val isKindOfClass:[NSNumber class]]
                && ![val isKindOfClass:[NSString class]]
                && ![val isKindOfClass:[NSArray class]]) {
                STLog(@"property 候选: %@ -> %s", key, class_getName([val class]));
                if (!candidates.count) return val;  // property 找到了就直接用
            }
        } @catch (NSException *e) { /* skip */ }
    }
    if (props) free(props);

    // 首次失败：全量 dump 供分析
    STDumpCellIvars(cell);

    STLog(@"未能从 cell(%s) 提取消息对象", class_getName([cell class]));
    return nil;
}

// 在聊天 VC 上查找并调用删除/撤回方法
static BOOL STCallActionOnChatVC(UIViewController *chatVC, id msgObj, NSString *action) {
    if (!chatVC || !msgObj) return NO;

    BOOL isRecall = [action isEqualToString:@"recall"];

    // VC 级别的选择器
    NSArray<NSString *> *selNames;
    if (isRecall) {
        selNames = @[
            @"revokeMsg:", @"recallMsg:", @"revokeMessage:",
            @"recallMessage:", @"onRevokeMsg:", @"onRecallMsg:",
            @"doRevokeMsg:", @"doRecallMsg:",
        ];
    } else {
        selNames = @[
            @"delMsg:", @"deleteMessage:", @"removeMessage:",
            @"onDeleteMsg:", @"onDelMsg:", @"didSelectDelete:",
            @"doDeleteMsg:", @"removeMsg:",
        ];
    }

    for (NSString *selName in selNames) {
        SEL sel = NSSelectorFromString(selName);
        if ([chatVC respondsToSelector:sel]) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(chatVC, sel, msgObj);
                STLog(@"成功: VC.%@ on %s", selName, class_getName([msgObj class]));
                return YES;
            } @catch (NSException *e) {
                STLog(@"VC.%@ 异常: %@", selName, e.reason);
            }
        }
    }

    // 消息对象自身的选择器
    NSArray<NSString *> *msgSelNames;
    if (isRecall) {
        msgSelNames = @[@"revoke", @"recall", @"revokeMsg", @"recallMsg",
                         @"revokeMessage", @"recallMessage"];
    } else {
        msgSelNames = @[@"delete", @"remove", @"delMsg", @"removeMsg"];
    }
    for (NSString *selName in msgSelNames) {
        SEL sel = NSSelectorFromString(selName);
        if ([msgObj respondsToSelector:sel]) {
            @try {
                ((void (*)(id, SEL))objc_msgSend)(msgObj, sel);
                STLog(@"成功: msgObj.%@ (%s)", selName, class_getName([msgObj class]));
                return YES;
            } @catch (NSException *e) {
                STLog(@"msgObj.%@ 异常: %@", selName, e.reason);
            }
        }
    }

    // 打印可用方法供适配
    STLog(@"--- chatVC(%s) 含 del/revoke/delete 方法 ---", class_getName([chatVC class]));
    unsigned int mcount = 0;
    Method *methods = class_copyMethodList([chatVC class], &mcount);
    for (unsigned int i = 0; i < MIN(mcount, 120); i++) {
        SEL sel = method_getName(methods[i]);
        const char *n = sel_getName(sel);
        if (strstr(n, "del") || strstr(n, "Del") || strstr(n, "Del")
            || strstr(n, "revoke") || strstr(n, "Revoke")
            || strstr(n, "recall") || strstr(n, "Recall")
            || strstr(n, "delete") || strstr(n, "Delete")
            || strstr(n, "remove") || strstr(n, "Remove")) {
            STLog(@"  VC: %s", n);
        }
    }
    if (methods) free(methods);

    STLog(@"--- msgObj(%s) 含 del/revoke/delete 方法 ---", class_getName([msgObj class]));
    mcount = 0;
    methods = class_copyMethodList([msgObj class], &mcount);
    for (unsigned int i = 0; i < MIN(mcount, 120); i++) {
        SEL sel = method_getName(methods[i]);
        const char *n = sel_getName(sel);
        if (strstr(n, "del") || strstr(n, "Del")
            || strstr(n, "revoke") || strstr(n, "Revoke")
            || strstr(n, "recall") || strstr(n, "Recall")
            || strstr(n, "delete") || strstr(n, "Delete")
            || strstr(n, "remove") || strstr(n, "Remove")) {
            STLog(@"  Msg: %s", n);
        }
    }
    if (methods) free(methods);

    return NO;
}

// 判断消息是否是自己发的
static BOOL STIsOwnMessage(id msgObj) {
    if (!msgObj) return NO;

    SEL sels[] = {
        @selector(isFromMe), @selector(isFromSelf), @selector(isSend),
        @selector(isSender), @selector(fromMe), @selector(isMyMsg),
    };
    for (size_t i = 0; i < sizeof(sels)/sizeof(sels[0]); i++) {
        if ([msgObj respondsToSelector:sels[i]]) {
            @try {
                id result = ((id (*)(id, SEL))objc_msgSend)(msgObj, sels[i]);
                if (result) {
                    if ([result isKindOfClass:[NSNumber class]]) {
                        BOOL b = [result boolValue];
                        STLog(@"isOwn via %@ = %@", NSStringFromSelector(sels[i]), b ? @"YES" : @"NO");
                        return b;
                    }
                }
            } @catch (NSException *e) { /* skip */ }
        }
    }

    // KVC
    NSArray<NSString *> *keys = @[@"isFromMe", @"fromMe", @"isSend", @"isSender",
                                   @"m_bIsSend", @"m_nsFromMe", @"m_isFromMe",
                                   @"m_bIsSelf", @"isSelf"];
    for (NSString *k in keys) {
        @try {
            id v = [msgObj valueForKey:k];
            if ([v isKindOfClass:[NSNumber class]]) {
                BOOL b = [v boolValue];
                STLog(@"isOwn via KVC[%@] = %@", k, b ? @"YES" : @"NO");
                return b;
            }
        } @catch (NSException *e) { /* skip */ }
    }

    STLog(@"无法判断是否自己发的(%s)，默认=NO(对方)", class_getName([msgObj class]));
    return NO;
}

#pragma mark - 左滑手势处理（UIPan 跟随动画 + 动态菜单）

static void STExecuteSwipeAction(UIView *cell);

static const void *kSTSwipeOffset    = &kSTSwipeOffset;
static const void *kSTLeftSwipeAdded = &kSTLeftSwipeAdded;

// Pan 手势处理：气泡跟随手指
static void STSwipePanHandler(UIPanGestureRecognizer *pan) {
    UIView *cell = pan.view;
    CGFloat offset = [pan translationInView:cell].x;
    CGFloat maxOffset = -120.0;

    switch (pan.state) {
        case UIGestureRecognizerStateChanged: {
            offset = MAX(offset, maxOffset);
            cell.transform = CGAffineTransformMakeTranslation(offset, 0);
            objc_setAssociatedObject(cell, kSTSwipeOffset,
                                     @(offset), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGFloat velocity = [pan velocityInView:cell].x;
            NSNumber *savedNum = objc_getAssociatedObject(cell, kSTSwipeOffset);
            CGFloat saved = savedNum ? [savedNum doubleValue] : 0;

            BOOL shouldTrigger = (saved < maxOffset * 0.5) || (velocity < -300);

            if (shouldTrigger && STGetBool(kEnabled, YES)) {
                [UIView animateWithDuration:0.2 animations:^{
                    cell.transform = CGAffineTransformIdentity;
                } completion:^(BOOL finished) {
                    STExecuteSwipeAction(cell);
                }];
            } else {
                [UIView animateWithDuration:0.25 animations:^{
                    cell.transform = CGAffineTransformIdentity;
                }];
            }
            objc_setAssociatedObject(cell, kSTSwipeOffset,
                                     @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            break;
        }
        default:
            break;
    }
}

// 弹出操作菜单（自己的消息：删除+撤回；对方的：仅删除）
static void STExecuteSwipeAction(UIView *cell) {
    // 找聊天 VC
    UIViewController *chatVC = nil;
    UIResponder *r = cell;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]] && STInChat((UIView *)r)) {
            chatVC = (UIViewController *)r;
            break;
        }
        r = [r nextResponder];
    }

    // 取消息对象
    id msgObj = STGetMessageObjectFromCell(cell);

    // 判断是否自己发的
    BOOL isOwn = msgObj ? STIsOwnMessage(msgObj) : NO;

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:nil
        message:isOwn ? @"自己的消息" : @"对方的消息"
        preferredStyle:UIAlertControllerStyleActionSheet];

    // 自己的消息：两个选项
    if (isOwn) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"🗑 删除"
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *a) {
            STLog(@"用户选择: 删除(自己的)");
            if (msgObj) {
                BOOL ok = STCallActionOnChatVC(chatVC, msgObj, @"delete");
                if (!ok) STShowFallbackAlert(chatVC, @"删除", msgObj);
            } else {
                STShowFallbackAlert(chatVC, @"删除", nil);
            }
        }]];

        [sheet addAction:[UIAlertAction actionWithTitle:@"↩️ 撤回"
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *a) {
            STLog(@"用户选择: 撤回");
            if (msgObj) {
                BOOL ok = STCallActionOnChatVC(chatVC, msgObj, @"recall");
                if (!ok) STShowFallbackAlert(chatVC, @"撤回", msgObj);
            } else {
                STShowFallbackAlert(chatVC, @"撤回", nil);
            }
        }]];
    } else {
        // 对方的消息：只有删除
        [sheet addAction:[UIAlertAction actionWithTitle:@"🗑 删除"
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *a) {
            STLog(@"用户选择: 删除(对方的)");
            if (msgObj) {
                BOOL ok = STCallActionOnChatVC(chatVC, msgObj, @"delete");
                if (!ok) STShowFallbackAlert(chatVC, @"删除", msgObj);
            } else {
                STShowFallbackAlert(chatVC, @"删除", nil);
            }
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    // iPad 兼容
    if (chatVC) {
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
            sheet.popoverPresentationController.sourceView = cell;
            sheet.popoverPresentationController.sourceRect = cell.bounds;
        }
        [chatVC presentViewController:sheet animated:YES completion:nil];
    } else {
        UIWindow *win = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (win.rootViewController) {
            [win.rootViewController presentViewController:sheet animated:YES completion:nil];
        }
    }
    STLog(@"左滑弹出菜单 isOwn=%@ hasMsgObj=%@",
          isOwn ? @"YES" : @"NO", msgObj ? @"YES" : @"NO");
}

static void STShowFallbackAlert(UIViewController *vc, NSString *action, id msgObj) {
    NSString *detail = [NSString stringWithFormat:@"%@ 失败\n消息类: %@\n请查看日志",
                        action,
                        msgObj ? NSStringFromClass([msgObj class]) : @"(未找到)"];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"提示"
        message:detail
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    if (vc) {
        [vc presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - 给 cell 挂左滑手势
static void STConfigureCell(UIView *cell) {
    if (!STGetBool(kEnabled, YES)) return;
    if (!STInChat(cell)) return;

    if (!objc_getAssociatedObject(cell, kSTLeftSwipeAdded)) {
        objc_setAssociatedObject(cell, kSTLeftSwipeAdded, @(YES),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:cell action:@selector(st_swipePan:)];
        [cell addGestureRecognizer:pan];
        STLog(@"已添加左滑 Pan 手势 cell=%s", class_getName([cell class]));
    }
}

#pragma mark - 核心 Hook：UITableViewCell
%hook UITableViewCell

- (void)layoutSubviews {
    %orig;
    STConfigureCell((UIView *)self);
}

%new
- (void)st_swipePan:(UIPanGestureRecognizer *)pan {
    STSwipePanHandler(pan);
}

%end

#pragma mark - 核心 Hook：UICollectionViewCell
%hook UICollectionViewCell

- (void)layoutSubviews {
    %orig;
    STConfigureCell((UIView *)self);
}

%new
- (void)st_swipePan:(UIPanGestureRecognizer *)pan {
    STSwipePanHandler(pan);
}

%end

#pragma mark - 设置入口
static const void *kSTSettingsAdded = &kSTSettingsAdded;

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self st_maybeAddSettingsButton];
}

%new
- (void)st_maybeAddSettingsButton {
    NSString *title = self.title;
    if (!title && self.navigationItem.title) title = self.navigationItem.title;
    if (![title isEqualToString:@"设置"]) return;
    if (objc_getAssociatedObject(self, kSTSettingsAdded)) return;
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

#pragma mark - 设置面板（v7 简化：只有总开关）
@implementation STSettingsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) self.title = @"滑动手势设置";
    return self;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return 1;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @"左滑自己的消息 → 「删除」+「撤回」\n左滑对方的消息 → 仅「删除」";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"st"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:@"st"];
    c.textLabel.text = @"启用滑动插件";
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = STGetBool(kEnabled, YES);
    [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (void)toggle:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:kEnabled];
    [[NSUserDefaults standardUserDefaults] synchronize];
    STLog(@"设置变更 enabled=%@", sw.on ? @"YES" : @"NO");
}

@end

#pragma mark - Constructor
%ctor {
    @autoreleasepool {
        STInitLog();
        STDiscoverClasses();

        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        STLog(@"========== SwipeTweak v7 Loaded ==========");
        STLog(@"bundle=%@ | proc=%@", bid, NSProcessInfo.processInfo.processName);
        STLog(@"chatVC=%@", sChatVC ? NSStringFromClass(sChatVC)
                                    : @"BaseMsgContentViewController(fallback)");
        STLog(@"enabled=%@", STGetBool(kEnabled, YES) ? @"YES" : @"NO");
        if (![bid isEqualToString:@"com.tencent.xin"]) {
            STLog(@"警告：非微信进程却已加载（请检查 Filter plist）");
        }
        STLog(@"==========================================");
    }
}
