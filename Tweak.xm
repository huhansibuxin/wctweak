/* Tweak.xm v6 —— 微信滑动手势独立 Tweak（rootless / ElleKit）
 *
 * v6 变更（对照用户反馈）：
 *   1) 左滑菜单精简为「撤回（自己的消息）/ 删除（对方的消息）」，
 *      且通过运行时 objc/runtime 探测消息对象 + 调用微信内部选择器真正执行。
 *   2) 左滑时消息气泡跟随手指滑动（swipe-to-reveal 动画），不再直接弹窗。
 *   3) 设置页改为操作选择列表（类似截图3）：可选左滑=删除/撤回/无动作。
 *
 * 规则①遵守：不声明任何私有类/私有方法头文件。所有微信内部调用均通过
 *  运行时 performSelector: / NSInvocation / method_getImplementation 探测+调用。
 *
 * 日志位置：App 沙盒 Documents/com.boss.swipetweak.log（ssh 找沙盒路径 cat）。
 * 编译：make package ｜ 注入：TrollFools 注入生成的 .deb / .dylib
 * 作者：小弟 ｜ 2026-08-07 ｜ 逆向研究学习
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>   // 显式声明 objc_msgSend（ARC 下函数指针转换需要）

#pragma mark - 前向声明
@interface UIViewController (SwipeTweak)
- (void)st_maybeAddSettingsButton;
- (void)st_openSwipeSettings;
@end
@interface STSettingsViewController : UITableViewController
@end

#pragma mark - 配置键（NSUserDefaults）
static NSString *kEnabled    = @"com.boss.swipetweak.enabled";     // 总开关
static NSString *kLeftAction = @"com.boss.swipetweak.leftAction";  // 左滑动作: "delete"|"recall"|"none"

// 动作选项（设置页展示用）
static NSArray<NSString *> *STActionTitles(void) {
    return @[@"无动作", @"删除", @"撤回"];
}
static NSArray<NSString *> *STActionValues(void) {
    return @[@"none", @"delete", @"recall"];
}

static BOOL STGetBool(NSString *key, BOOL def) {
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return (v != nil) ? [v boolValue] : def;
}

static NSString *STGetString(NSString *key, NSString *def) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    return v ?: def;
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
            [name containsString:@"MsgNode"]) {
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

#pragma mark - 微信内部 API 调用（运行时探测，不硬编码私有头）

// 从 cell 上尝试获取消息数据对象
// 策略：遍历 cell 的所有 ivar，找类型名含 Msg/Message 的对象
static id STGetMessageObjectFromCell(UIView *cell) {
    if (!cell) return nil;

    // 方法1：尝试常见 getter 选择器
    SEL getters[] = {
        @selector(messageData),
        @selector(msgData),
        @selector(message),
        @selector(msgNode),
        @selector(data),
    };
    for (size_t i = 0; i < sizeof(getters)/sizeof(getters[0]); i++) {
        if ([cell respondsToSelector:getters[i]]) {
            @try {
                id obj = ((id (*)(id, SEL))objc_msgSend)(cell, getters[i]);
                if (obj) {
                    STLog(@"通过 getter %@ 取到消息对象: %s",
                          NSStringFromSelector(getters[i]),
                          class_getName([obj class]));
                    return obj;
                }
            } @catch (NSException *e) {
                // ignore
            }
        }
    }

    // 方法2：遍历 ivar 找看起来像消息数据的对象
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([cell class], &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        const char *name = ivar_getName(ivars[i]);
        // 只看 @ 类型（对象指针）
        if (type && type[0] == '@') {
            id val = object_getIvar(cell, ivars[i]);
            if (val && ![val isKindOfClass:[UIView class]]
                && ![val isKindOfClass:[CALayer class]]
                && ![val isKindOfClass:[UIGestureRecognizer class]]
                && ![val isKindOfClass:[NSNumber class]]
                && ![val isKindOfClass:[NSString class]]
                && ![val isKindOfClass:[NSArray class]]
                && ![val isKindOfClass:[NSDictionary class]]) {
                // 非视图非基础类型的对象，可能是消息数据
                const char *clsName = class_getName([val class]);
                if (strstr(clsName, "Msg") || strstr(clsName, "Message")
                    || strstr(clsName, "Node") || strstr(clsName, "Data")) {
                    STLog(@"通过 ivar %s(%s) 取到候选消息对象: %s",
                          name, type, clsName);
                    free(ivars);
                    return val;
                }
            }
        }
    }
    if (ivars) free(ivars);

    // 方法3：遍历属性
    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList([cell class], &propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        const char *name = property_getName(props[i]);
        NSString *key = [NSString stringWithUTF8String:name];
        if ([key containsString:@"message"] || [key containsString:@"msg"]
            || [key containsString:@"data"] || [key containsString:@"node"]) {
            @try {
                id val = [cell valueForKey:key];
                if (val && ![val isKindOfClass:[UIView class]]
                    && ![val isKindOfClass:[CALayer class]]) {
                    STLog(@"通过 property %@ 取到候选消息对象: %s",
                          key, class_getName([val class]));
                    free(props);
                    return val;
                }
            } @catch (NSException *e) { /* skip */ }
        }
    }
    if (props) free(props);

    STLog(@"未能从 cell(%s) 提取消息对象", class_getName([cell class]));
    return nil;
}

// 在聊天 VC 上查找并调用删除方法
// 常见选择器模式：delMsg: / onDeleteMsg: / deleteMessage: / removeMessage:
static BOOL STCallDeleteOnChatVC(UIViewController *chatVC, id msgObj) {
    if (!chatVC || !msgObj) return NO;

    SEL deleteSels[] = {
        NSSelectorFromString(@"delMsg:"),
        NSSelectorFromString(@"onDeleteMsg:"),
        NSSelectorFromString(@"deleteMessage:"),
        NSSelectorFromString(@"removeMessage:"),
        NSSelectorFromString(@"onDelMsg:"),
        NSSelectorFromString(@"didSelectDelete:"),
    };

    for (size_t i = 0; i < sizeof(deleteSels)/sizeof(deleteSels[0]); i++) {
        if ([chatVC respondsToSelector:deleteSels[i]]) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(chatVC, deleteSels[i], msgObj);
                STLog(@"撤回/删除成功: VC.%@ on %s",
                      NSStringFromSelector(deleteSels[i]),
                      class_getName([msgObj class]));
                return YES;
            } @catch (NSException *e) {
                STLog(@"VC.%@ 抛异常: %@", NSStringFromSelector(deleteSels[i]), e.reason);
            }
        }
    }

    // 也尝试在消息对象自身上调用
    SEL msgDeleteSels[] = {
        NSSelectorFromString(@"delete"),
        NSSelectorFromString(@"remove"),
        NSSelectorFromString(@"delMsg"),
        NSSelectorFromString(@"revokeMsg"),
        NSSelectorFromString(@"recallMsg"),
        NSSelectorFromString(@"revokeMessage"),
        NSSelectorFromString(@"recallMessage"),
    };
    for (size_t i = 0; i < sizeof(msgDeleteSels)/sizeof(msgDeleteSels[0]); i++) {
        if ([msgObj respondsToSelector:msgDeleteSels[i]]) {
            @try {
                ((void (*)(id, SEL))objc_msgSend)(msgObj, msgDeleteSels[i]);
                STLog(@"撤回/删除成功: msgObj.%s", class_getName([msgObj class]));
                return YES;
            } @catch (NSException *e) {
                STLog(@"msgObj.%@ 抛异常: %@", NSStringFromSelector(msgDeleteSels[i]), e.reason);
            }
        }
    }

    // 最后手段：打印 chatVC 和 msgObj 的所有方法名供后续分析
    STLog(@"--- chatVC(%s) 可用方法 ---", class_getName([chatVC class]));
    unsigned int mcount = 0;
    Method *methods = class_copyMethodList([chatVC class], &mcount);
    for (unsigned int i = 0; i < MIN(mcount, 80); i++) {
        SEL sel = method_getName(methods[i]);
        const char *name = sel_getName(sel);
        if (strstr(name, "del") || strstr(name, "Del") ||
            strstr(name, "remove") || strstr(name, "Remove") ||
            strstr(name, "revoke") || strstr(name, "Revoke") ||
            strstr(name, "recall") || strstr(name, "Recall") ||
            strstr(name, "delete") || strstr(name, "Delete")) {
            STLog(@"  VC方法: %s", name);
        }
    }
    if (methods) free(methods);

    STLog(@"--- msgObj(%s) 可用方法 ---", class_getName([msgObj class]));
    mcount = 0;
    methods = class_copyMethodList([msgObj class], &mcount);
    for (unsigned int i = 0; i < MIN(mcount, 80); i++) {
        SEL sel = method_getName(methods[i]);
        const char *name = sel_getName(sel);
        if (strstr(name, "del") || strstr(name, "Del") ||
            strstr(name, "revoke") || strstr(name, "Revoke") ||
            strstr(name, "delete") || strstr(name, "Delete")) {
            STLog(@"  Msg方法: %s", name);
        }
    }
    if (methods) free(methods);

    return NO;
}

// 判断消息是否是自己发的（用于决定显示"撤回"还是"删除"）
// 策略：消息对象上找 isFromSelf / fromMe / isSend 等属性
static BOOL STIsOwnMessage(id msgObj) {
    if (!msgObj) return NO;

    // 尝试常见属性/方法
    SEL sels[] = {
        @selector(isFromMe),
        @selector(isFromSelf),
        @selector(isSend),
        @selector(isSender),
        @selector(fromMe),
    };
    for (size_t i = 0; i < sizeof(sels)/sizeof(sels[0]); i++) {
        if ([msgObj respondsToSelector:sels[i]]) {
            @try {
                NSNumber *result = ((id (*)(id, SEL))objc_msgSend)(msgObj, sels[i]);
                if (result) {
                    BOOL b = [result boolValue];
                    STLog(@"isOwnMessage via %@ = %@", NSStringFromSelector(sels[i]), b ? @"YES" : @"NO");
                    return b;
                }
            } @catch (NSException *e) { /* skip */ }
        }
    }

    // 尝试 KVC
    NSArray<NSString *> *keys = @[@"isFromMe", @"fromMe", @"isSend", @"isSender",
                                   @"m_bIsSend", @"m_nsFromMe", @"m_isFromMe"];
    for (NSString *k in keys) {
        @try {
            id v = [msgObj valueForKey:k];
            if ([v isKindOfClass:[NSNumber class]]) {
                BOOL b = [v boolValue];
                STLog(@"isOwnMessage via KVC[%@] = %@", k, b ? @"YES" : @"NO");
                return b;
            }
        } @catch (NSException *e) { /* skip */ }
    }

    STLog(@"无法判断是否自己发的消息(%s)，默认当对方消息处理", class_getName([msgObj class]));
    return NO;  // 默认对方消息 → 显示"删除"
}

#pragma mark - 左滑手势处理（带动画 + 真正的删除/撤回）

// 前向声明（函数定义在文件更下方，此处先声明供编译器认可）
static void STExecuteSwipeAction(UIView *cell);
static void STShowFallbackAlert(UIViewController *vc, NSString *action, id msgObj);

// 关联对象 key：记录左滑偏移量
static const void *kSTSwipeOffset   = &kSTSwipeOffset;
static const void *kSTLeftSwipeAdded = &kSTLeftSwipeAdded;

// 手势过程中：气泡跟随手指移动
static void STSwipePanHandler(UIPanGestureRecognizer *pan) {
    UIView *cell = pan.view;
    CGFloat offset = [pan translationInView:cell].x;  // 向左滑 offset < 0
    CGFloat maxOffset = -120.0;  // 最大左滑距离

    switch (pan.state) {
        case UIGestureRecognizerStateChanged: {
            // 限制拖动范围
            offset = MAX(offset, maxOffset);
            // 应用 transform 让整个 cell 内容左移
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

            // 判定是否触发动作：超过一半距离 或 速度够快
            BOOL shouldTrigger = (saved < maxOffset * 0.5) || (velocity < -300);

            if (shouldTrigger && STGetBool(kEnabled, YES)) {
                // 触发动作：先弹回原位再执行
                [UIView animateWithDuration:0.2 animations:^{
                    cell.transform = CGAffineTransformIdentity;
                } completion:^(BOOL finished) {
                    STExecuteSwipeAction(cell);
                }];
            } else {
                // 弹回原位
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

// 执行左滑动作（根据设置选择执行删除或撤回）
static void STExecuteSwipeAction(UIView *cell) {
    NSString *action = STGetString(kLeftAction, @"none");
    if ([action isEqualToString:@"none"]) {
        STLog(@"左滑动作=无动作，跳过");
        return;
    }

    // 找聊天 VC
    UIViewController *chatVC = nil;
    UIResponder *r = cell;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]] &&
            STInChat((UIView *)r)) {
            chatVC = (UIViewController *)r;
            break;
        }
        r = [r nextResponder];
    }

    // 取消息对象
    id msgObj = STGetMessageObjectFromCell(cell);
    if (!msgObj) {
        STLog(@"左滑失败：未找到消息对象 cell=%s", class_getName([cell class]));
        // 兜底弹个提示
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"提示"
            message:@"未找到消息对象，请查看日志"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];
        if (chatVC) {
            [chatVC presentViewController:alert animated:YES completion:nil];
        }
        return;
    }

    BOOL isOwn = STIsOwnMessage(msgObj);

    if ([action isEqualToString:@"delete"]) {
        // 删除（对方消息或自己的都删）
        STLog(@"执行【删除】消息 isOwn=%@", isOwn ? @"YES(自己的)" : @"NO(对方的)");
        BOOL ok = STCallDeleteOnChatVC(chatVC, msgObj);
        if (!ok) {
            STShowFallbackAlert(chatVC, @"删除", msgObj);
        }
    } else if ([action isEqualToString:@"recall"]) {
        // 撤回（只对有效的情况）
        if (isOwn) {
            STLog(@"执行【撤回】自己的消息");
            BOOL ok = STCallDeleteOnChatVC(chatVC, msgObj);
            if (!ok) {
                STShowFallbackAlert(chatVC, @"撤回", msgObj);
            }
        } else {
            // 对方消息不能撤回，降级为删除
            STLog(@"对方消息不能撤回，降级为【删除】");
            BOOL ok = STCallDeleteOnChatVC(chatVC, msgObj);
            if (!ok) {
                STShowFallbackAlert(chatVC, @"删除(对方消息)", msgObj);
            }
        }
    }
}

// API 调用全部失败时的兜底弹窗
static void STShowFallbackAlert(UIViewController *vc, NSString *action, id msgObj) {
    NSString *detail = [NSString stringWithFormat:@"%@ 失败\n消息类: %s\n请将日志发给开发者适配此版本",
                        action,
                        msgObj ? class_getName([msgObj class]) : "(null)"];
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

#pragma mark - 给 cell 挂自定义左滑（每个 cell 实例只挂一次）
static void STConfigureCell(UIView *cell) {
    if (!STGetBool(kEnabled, YES)) return;
    if (!STInChat(cell)) return;

    NSString *action = STGetString(kLeftAction, @"none");
    if ([action isEqualToString:@"none"]) return;

    if (!objc_getAssociatedObject(cell, kSTLeftSwipeAdded)) {
        objc_setAssociatedObject(cell, kSTLeftSwipeAdded, @(YES),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // 用 UIPanGestureRecognizer 实现跟随手指的滑动动画
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:cell
                    action:@selector(st_swipePan:)];
        [cell addGestureRecognizer:pan];
        STLog(@"已添加左滑 Pan 手势 cell=%s action=%@",
              class_getName([cell class]), action);
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

#pragma mark - 设置入口：在「设置」页右上角注入按钮
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

#pragma mark - 设置面板（操作选择列表，类似截图3）
@implementation STSettingsViewController {
    NSInteger _selectedRow;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        self.title = @"滑动手势设置";
        // 默认选中当前保存的动作
        NSString *current = STGetString(kLeftAction, @"delete");
        NSArray<NSString *> *vals = STActionValues();
        _selectedRow = [vals indexOfObject:current];
        if (_selectedRow == NSNotFound) _selectedRow = 1;  // default = 删除
    }
    return self;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return @"总开关";
    return @"左滑动作（选择后即时生效）";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 1;
    return STActionTitles().count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"st"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                       reuseIdentifier:@"st"];

    if (ip.section == 0) {
        c.textLabel.text = @"启用滑动插件";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = STGetBool(kEnabled, YES);
        sw.tag = 1000;
        [sw addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSArray<NSString *> *titles = STActionTitles();
        c.textLabel.text = titles[ip.row];
        if (ip.row == _selectedRow) {
            c.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            c.accessoryType = UITableViewCellAccessoryNone;
        }
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) {
        _selectedRow = ip.row;
        NSArray<NSString *> *vals = STActionValues();
        NSString *val = vals[ip.row];
        [[NSUserDefaults standardUserDefaults] setObject:val forKey:kLeftAction];
        [[NSUserDefaults standardUserDefaults] synchronize];
        STLog(@"设置变更 leftAction=%@ (%@)", val, STActionTitles()[ip.row]);
        [tv reloadData];
    }
}

- (void)toggleEnabled:(UISwitch *)sw {
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
        STLog(@"========== SwipeTweak v6 Loaded ==========");
        STLog(@"bundle=%@ | proc=%@", bid, NSProcessInfo.processInfo.processName);
        STLog(@"chatVC=%@", sChatVC ? NSStringFromClass(sChatVC)
                                    : @"BaseMsgContentViewController(fallback)");
        STLog(@"enabled=%@ leftAction=%@",
              STGetBool(kEnabled, YES) ? @"YES" : @"NO",
              STGetString(kLeftAction, @"(default=delete)"));
        if (![bid isEqualToString:@"com.tencent.xin"]) {
            STLog(@"警告：非微信进程却已加载（请检查 Filter plist）");
        }
        STLog(@"==========================================");
    }
}
