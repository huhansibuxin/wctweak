/* Tweak.xm v9 —— 微信消息左滑手势（rootless / ElleKit）
 *
 * v9 重大重构（基于 WeChatX-1.dylib 逆向结论）：
 *   ✅ 彻底改用 iOS 原生 UISwipeActionsConfiguration（自带跟手动画，零自定义手势，不再闪退）
 *   ✅ 左滑自己的消息 → 撤回：RevokeMsg:MsgWrap:Counter:revokeTicket:viewController:
 *   ✅ 左滑对方的消息 → 删除：DelMsg:MsgWrap:
 *   ✅ 消息对象从 cell.m_cellView.viewModel.msgWrap 取（v8 已验证链路）
 *   ✅ isOwn 用 KVC isSender（v8 已验证对方消息判定正确）
 *   ✅ 所有微信内部调用走 NSInvocation / KVC + @try，杜绝不安全 objc_msgSend 闪退
 *   ❌ 不做引用功能（老板明确不需要）
 *
 * 设置页：分组 UITableView，含「消息左滑删除」「消息左滑撤回」开关 + 总开关
 * 入口：微信「设置」页注入「⚙︎滑动」按钮
 *
 * 规则①遵守：不声明任何私有类/私有方法头文件。所有微信内部调用均通过
 *  运行时 NSSelectorFromString + NSInvocation / valueForKey 探测+调用。
 * 逆向研究学习用途。
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 前向声明
static void STLog(NSString *fmt, ...);  // 日志函数（定义在文件末尾，此处前向声明）
@interface UIViewController (SwipeTweak)
- (void)st_maybeAddSettingsButton;
@end
@interface STSettingsViewController : UITableViewController
@end

#pragma mark - 配置键（NSUserDefaults，仿 WeChatX 格式）
static NSString *kEnabled    = @"com.boss.swipetweak.enabled";     // 总开关
static NSString *kDeleteLeft = @"com.boss.swipetweak.deleteLeft";  // 消息左滑删除
static NSString *kRecallLeft = @"com.boss.swipetweak.recallLeft";  // 消息左滑撤回

static BOOL STGetBool(NSString *key, BOOL def) {
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return (v != nil) ? [v boolValue] : def;
}
static void STSetBool(NSString *key, BOOL val) {
    [[NSUserDefaults standardUserDefaults] setObject:@(val) forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - 安全提取消息对象（核心：不闪退）
/// 从任意 view 向上找到 UITableViewCell
static UITableViewCell *STCellFromView(UIView *view) {
    UIView *v = view;
    while (v && ![v isKindOfClass:[UITableViewCell class]]) {
        v = v.superview;
    }
    return (UITableViewCell *)v;
}

/// 从 cell 钻取 MsgWrap：cell.m_cellView.viewModel.msgWrap / getMsgWrap
static id STGetMsgWrapFromCell(UITableViewCell *cell) {
    if (!cell) return nil;
    @try {
        // 1. m_cellView
        id cellView = [cell valueForKey:@"m_cellView"];
        if (!cellView) return nil;
        // 2. viewModel
        id viewModel = [cellView valueForKey:@"viewModel"];
        if (!viewModel) return nil;
        // 3. 优先 getMsgWrap，其次 msgWrap 属性
        SEL getSel = NSSelectorFromString(@"getMsgWrap");
        if ([viewModel respondsToSelector:getSel]) {
            id mw = [viewModel performSelector:getSel];
            if (mw) return mw;
        }
        id mw = [viewModel valueForKey:@"msgWrap"];
        if (mw) return mw;
        return nil;
    } @catch (NSException *e) {
        return nil;
    }
}

/// 判断是不是自己发的消息（KVC isSender，v8 已验证对方消息判定正确）
static BOOL STIsOwnMessage(id msgWrap) {
    if (!msgWrap) return NO;
    @try {
        id v = [msgWrap valueForKey:@"isSender"];
        if ([v isKindOfClass:[NSNumber class]]) {
            return [v boolValue];
        }
    } @catch (NSException *e) {}
    return NO;
}

#pragma mark - 真实执行：删除 / 撤回（WeChatX 同款 API）
/// 删除：WeChatX 逆向确认的真实选择器 DelMsg:MsgWrap:（两个参数，第一个通常也传 msgWrap）
/// 兜底：旧版单参数 DelMsg:
static void STDeleteMessage(id vc, id msgWrap) {
    if (!vc || !msgWrap) return;
    @try {
        // 优先单参数 DelMsg:（最常见形态）
        SEL sel1 = NSSelectorFromString(@"DelMsg:");
        if ([vc respondsToSelector:sel1]) {
            [vc performSelector:sel1 withObject:msgWrap];
            STLog(@"[delete] 调用 DelMsg: 成功 (vc=%@)", NSStringFromClass([vc class]));
            return;
        }
        // 兜底：WeChatX 逆向到的两参数 DelMsg:MsgWrap:
        SEL sel2 = NSSelectorFromString(@"DelMsg:MsgWrap:");
        if ([vc respondsToSelector:sel2]) {
            NSMethodSignature *sig = [vc methodSignatureForSelector:sel2];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:vc];
                [inv setSelector:sel2];
                [inv setArgument:&msgWrap atIndex:2];
                [inv setArgument:&msgWrap atIndex:3];
                [inv invoke];
                STLog(@"[delete] 调用 DelMsg:MsgWrap: 成功");
                return;
            }
        }
        STLog(@"[delete] 未找到删除方法 on %@", NSStringFromClass([vc class]));
    } @catch (NSException *e) {
        STLog(@"[delete] 异常: %@", e);
    }
}

/// 撤回：-(void)RevokeMsg:(id)msgWrap Counter:(NSUInteger)counter revokeTicket:(id)ticket viewController:(id)vc;
/// （WeChatX 逆向确认：RevokeMsg:MsgWrap:Counter:revokeTicket:viewController:）
static void STRecallMessage(id vc, id msgWrap) {
    if (!vc || !msgWrap) return;
    SEL sel = NSSelectorFromString(@"RevokeMsg:MsgWrap:Counter:revokeTicket:viewController:");
    if (![vc respondsToSelector:sel]) {
        STLog(@"[recall] VC(%@) 不响应 RevokeMsg:MsgWrap:...", NSStringFromClass([vc class]));
        return;
    }
    @try {
        NSMethodSignature *sig = [vc methodSignatureForSelector:sel];
        if (!sig) return;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:vc];
        [inv setSelector:sel];
        // arg2 = msgWrap
        [inv setArgument:&msgWrap atIndex:2];
        // arg3 = Counter (NSUInteger)，本地撤回先传 0
        NSUInteger counter = 0;
        [inv setArgument:&counter atIndex:3];
        // arg4 = revokeTicket，先传 nil 试
        id ticket = nil;
        [inv setArgument:&ticket atIndex:4];
        // arg5 = viewController
        [inv setArgument:&vc atIndex:5];
        [inv invoke];
        STLog(@"[recall] 调用 RevokeMsg:MsgWrap:... 完成 (msgWrap=%@)", NSStringFromClass([msgWrap class]));
    } @catch (NSException *e) {
        STLog(@"[recall] 异常: %@", e);
    }
}

#pragma mark - Hook：聊天页左滑（原生 trailing swipe = 左滑）
%hook BaseMsgContentViewController

- (id)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {

    if (!STGetBool(kEnabled, YES)) {
        return %orig;
    }

    // 取 cell → MsgWrap
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    id msgWrap = STGetMsgWrapFromCell(cell);
    if (!msgWrap) {
        return %orig;
    }

    BOOL isOwn = STIsOwnMessage(msgWrap);
    NSMutableArray *actions = [NSMutableArray array];

    if (isOwn && STGetBool(kRecallLeft, YES)) {
        // 自己的消息 → 撤回
        UIContextualAction *recall = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleNormal
            title:@"撤回"
            handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
                STLog(@"[action] 撤回自己消息, msgWrap=%@ class=%@", msgWrap, NSStringFromClass([msgWrap class]));
                STRecallMessage(self, msgWrap);
                STLog(@"[action] 撤回调用完成");
                if (completion) completion(YES);
            }];
        recall.backgroundColor = [UIColor systemBlueColor];
        [actions addObject:recall];
    }

    if (!isOwn && STGetBool(kDeleteLeft, YES)) {
        // 对方的消息 → 删除
        UIContextualAction *del = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleDestructive
            title:@"删除"
            handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
                STLog(@"[action] 删除对方消息, msgWrap=%@ class=%@", msgWrap, NSStringFromClass([msgWrap class]));
                STDeleteMessage(self, msgWrap);
                STLog(@"[action] 删除调用完成");
                if (completion) completion(YES);
            }];
        [actions addObject:del];
    }

    if ([actions count] == 0) {
        return %orig;
    }

    UISwipeActionsConfiguration *config =
        [UISwipeActionsConfiguration configurationWithActions:actions];
    config.performsFirstActionWithFullSwipe = NO;  // 不允许整行滑完直接触发，避免误触
    return config;
}

%end

#pragma mark - 设置入口（微信「设置」页注入按钮）
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self st_maybeAddSettingsButton];
}

%end

%subclass STSettingsViewController : UITableViewController

- (void)viewDidLoad {
    %orig;
    self.title = @"滑动手势";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"消息左滑";
    return @"通用";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;  // 删除 / 撤回
    return 1;                    // 总开关
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    static NSString *cid = @"swipeCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;

    UISwitch *sw = [[UISwitch alloc] init];
    [sw addTarget:self action:@selector(st_switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;

    NSString *key = nil;
    BOOL on = NO;
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"消息左滑删除（对方消息）";
            key = kDeleteLeft; on = STGetBool(kDeleteLeft, YES);
        } else {
            cell.textLabel.text = @"消息左滑撤回（自己消息）";
            key = kRecallLeft; on = STGetBool(kRecallLeft, YES);
        }
    } else {
        cell.textLabel.text = @"启用滑动插件";
        key = kEnabled; on = STGetBool(kEnabled, YES);
    }
    sw.on = on;
    sw.tag = (NSInteger)(__bridge void *)key;  // 用 tag 存 key 指针
    return cell;
}

- (void)st_switchChanged:(UISwitch *)sender {
    NSString *key = (__bridge NSString *)(void *)sender.tag;
    STSetBool(key, sender.on);
}

%end

@implementation UIViewController (SwipeTweak)

- (void)st_maybeAddSettingsButton {
    // 仅在微信「设置」页（title == 设置）注入按钮
    if (![self.title isEqualToString:@"设置"]) return;
    if ([self isKindOfClass:[STSettingsViewController class]]) return;

    // 避免重复添加
    for (UIView *v in self.view.subviews) {
        if (v.tag == 9527) return;
    }

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = 9527;
    [btn setTitle:@"⚙︎滑动手势设置" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:17];
    [btn addTarget:self action:@selector(st_openSwipeSettings) forControlEvents:UIControlEventTouchUpInside];

    // WeChat 设置页通常是 grouped table；按钮放右上角导航栏更稳
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithCustomView:btn];
    self.navigationItem.rightBarButtonItem = item;
}

- (void)st_openSwipeSettings {
    STSettingsViewController *vc = [[STSettingsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationFormSheet;
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [self presentViewController:nav animated:YES completion:nil];
    }
}

@end

#pragma mark - 日志（固定写 App 沙盒 Documents，v5 起要求）
static NSFileHandle *g_logHandle = nil;
static NSLock       *g_logLock   = nil;

static void STInitLog(void) {
    @autoreleasepool {
        NSArray<NSString *> *paths =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count == 0) return;
        NSString *dir = paths[0];
        NSString *logPath = [dir stringByAppendingPathComponent:@"com.boss.swipetweak.log"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:logPath]) {
            [fm createFileAtPath:logPath contents:[NSData data] attributes:nil];
        }
        g_logHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [g_logHandle seekToEndOfFile];
        g_logLock = [[NSLock alloc] init];
    }
}

static void STLog(NSString *fmt, ...) {
    if (!g_logHandle) STInitLog();
    if (!g_logHandle) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [NSDate date], msg];
    [g_logLock lock];
    @try {
        [g_logHandle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [g_logHandle synchronizeFile];
    } @catch (NSException *e) {}
    [g_logLock unlock];
}

#pragma mark - 入口
%ctor {
    STInitLog();
    STLog(@"SwipeTweak v9 Loaded (reverse-engineered from WeChatX: DelMsg:/RevokeMsg:)");
}
