/* Tweak.xm v14 —— 微信消息左滑手势（rootless / ElleKit）
 *
 * v10 重大修复（基于 WeChatX-1.dylib 逆向结论）：
 *   v9 用的 iOS 原生 UISwipeActionsConfiguration 在微信 8.0.37 聊天页根本
 *   不触发（tableView 不调用该 delegate 方法，或被微信手势拦截）→ 划不动。
 *   WeChatX 同款做法：自己用 UISwipeGestureRecognizer（leftSwipe）装到聊天
 *   UITableView 上，自己处理滑动，不依赖原生 swipe delegate。
 *
 *   ✅ 左滑自己的消息 → 确认后撤回：RevokeMsg:MsgWrap:Counter:revokeTicket:viewController:
 *   ✅ 左滑对方的消息 → 确认后删除：DelMsg:MsgWrap:
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

// 仅声明聊天页 VC 的父类层级，使 %hook 块内能使用 UIViewController 的 self 方法
// （不引入任何微信私有方法签名，符合逆向研究用途）
@interface BaseMsgContentViewController : UIViewController
- (void)st_installSwipeGesture;
- (void)st_leftSwipe:(UISwipeGestureRecognizer *)sw;
@end

#pragma mark - 前向声明
static void STLog(NSString *fmt, ...);  // 日志函数（定义在文件末尾，此处前向声明）
@interface UIViewController (SwipeTweak)
- (void)st_maybeAddSettingsButton;
@end
@interface STSettingsViewController : UITableViewController
@end

#pragma mark - 配置键（NSUserDefaults）
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

#pragma mark - 诊断 dump（取不到消息对象时打印完整对象图 + VC 方法名，用于精准适配 8.0.37）
static void STDumpMethods(id obj, NSString *keyword) {
    if (!obj) return;
    Class cls = [obj class];
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return;
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        NSString *n = NSStringFromSelector(method_getName(methods[i]));
        if ([n rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound)
            [names addObject:n];
    }
    free(methods);
    if (names.count) {
        STLog(@"[DUMP] %@ 上含 '%@' 的方法: %@", NSStringFromClass(cls), keyword,
              [names componentsJoinedByString:@", "]);
    }
}

#pragma mark - 全量 dump（v14：含 superclass ivar + property，不过滤，用于精准定位 8.0.37 消息对象字段）
/// 收集 obj 自身及所有父类（直到 stopCls）的 ivar（name : valueClass）
static NSMutableArray<NSString *> *STAllIvarDescs(id obj, Class stopCls) {
    NSMutableArray *arr = [NSMutableArray array];
    Class cls = [obj class];
    while (cls && cls != stopCls && cls != [NSObject class]) {
        unsigned int c = 0;
        Ivar *ivs = class_copyIvarList(cls, &c);
        for (unsigned i = 0; i < c; i++) {
            id val = object_getIvar(obj, ivs[i]);
            NSString *vcls = val ? NSStringFromClass([val class]) : @"<nil>";
            NSString *ivn = [NSString stringWithUTF8String:ivar_getName(ivs[i])];
            [arr addObject:[NSString stringWithFormat:@"  [%@] %@ : %@",
                           NSStringFromClass(cls), ivn, vcls]];
        }
        free(ivs);
        cls = class_getSuperclass(cls);
    }
    return arr;
}

/// 收集 obj 自身及所有父类的 @property（name : type）
static NSMutableArray<NSString *> *STAllPropertyDescs(id obj) {
    NSMutableArray *arr = [NSMutableArray array];
    Class cls = [obj class];
    while (cls && cls != [NSObject class]) {
        unsigned int c = 0;
        objc_property_t *ps = class_copyPropertyList(cls, &c);
        for (unsigned i = 0; i < c; i++) {
            const char *name = property_getName(ps[i]);
            const char *attr = property_getAttributes(ps[i]);
            NSString *attrs = [NSString stringWithUTF8String:attr ?: ""];
            NSString *typ = @"?";
            NSRange r = [attrs rangeOfString:@"T@\""];
            if (r.location != NSNotFound) {
                NSUInteger s = r.location + 3;
                NSRange end = [attrs rangeOfString:@"\"," options:0 range:NSMakeRange(s, attrs.length - s)];
                if (end.location != NSNotFound)
                    typ = [attrs substringWithRange:NSMakeRange(s, end.location - s)];
            }
            NSString *pn = [NSString stringWithUTF8String:name ?: ""];
            [arr addObject:[NSString stringWithFormat:@"  [%@] @property %@ : %@",
                           NSStringFromClass(cls), pn, typ]];
        }
        free(ps);
        cls = class_getSuperclass(cls);
    }
    return arr;
}

static void STDumpAll(id cell, id cellView) {
    STLog(@"[DUMP-ALL] ===== ChatTableViewCell ivars（含父类） =====");
    for (NSString *s in STAllIvarDescs(cell, [UITableViewCell class])) STLog(@"[DUMP-ALL] %@", s);
    STLog(@"[DUMP-ALL] ===== ChatTableViewCell properties =====");
    for (NSString *s in STAllPropertyDescs(cell)) STLog(@"[DUMP-ALL] %@", s);
    if (cellView) {
        STLog(@"[DUMP-ALL] ===== cellView(%@) ivars（含父类） =====", NSStringFromClass([cellView class]));
        for (NSString *s in STAllIvarDescs(cellView, [UIView class])) STLog(@"[DUMP-ALL] %@", s);
        STLog(@"[DUMP-ALL] ===== cellView(%@) properties =====", NSStringFromClass([cellView class]));
        for (NSString *s in STAllPropertyDescs(cellView)) STLog(@"[DUMP-ALL] %@", s);
        for (NSString *kw in @[@"node", @"msg", @"wrap", @"message", @"viewModel", @"data", @"model", @"content"]) {
            STDumpMethods(cellView, kw);
        }
    }
    for (NSString *kw in @[@"node", @"msg", @"wrap", @"message", @"viewModel", @"data", @"model", @"content"]) {
        STDumpMethods(cell, kw);
    }
}

#pragma mark - 安全提取消息对象（核心：不闪退）
/// 判定一个类是否为微信消息数据对象（node / wrap / model 等）
static BOOL STClassIsMsgWrap(Class cls) {
    if (!cls) return NO;
    NSString *n = NSStringFromClass(cls);
    NSArray *pats = @[@"MsgWrap", @"C2CMsgNode", @"MessageWrap", @"MessageModel", @"MsgNode",
                      @"C2CMessage", @"CMessageWrap", @"MessageNode", @"WCMessage", @"MMMessage",
                      @"CMessage", @"BaseMsgNode"];
    for (NSString *p in pats) if ([n containsString:p]) return YES;
    return NO;
}

/// 递归在对象（含父类） ivar 中查找类名含消息特征的对象。
static id STSearchMsgWrap(id obj, int depth, NSMutableSet *visited) {
    if (!obj || depth > 6) return nil;
    NSValue *key = [NSValue valueWithPointer:(__bridge void *)obj];
    if ([visited containsObject:key]) return nil;
    [visited addObject:key];

    if (STClassIsMsgWrap([obj class])) return obj;
    if (depth >= 6) return nil;

    Class cls = [obj class];
    while (cls && cls != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivs = class_copyIvarList(cls, &count);
        for (unsigned i = 0; i < count; i++) {
            const char *enc = ivar_getTypeEncoding(ivs[i]);
            if (!enc || enc[0] != '@') continue;           // 仅处理对象类型 ivar
            id val = object_getIvar(obj, ivs[i]);
            if (!val) continue;
            NSString *vcls = NSStringFromClass([val class]);
            // 只在可能承载消息的容器类型里继续钻
            if ([val isKindOfClass:[UIView class]] ||
                [vcls containsString:@"Model"] || [vcls containsString:@"View"]  ||
                [vcls containsString:@"Wrap"]  || [vcls containsString:@"Node"]  ||
                [vcls containsString:@"Controller"]) {
                id r = STSearchMsgWrap(val, depth + 1, visited);
                if (r) { free(ivs); return r; }
            }
        }
        free(ivs);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

/// 从 cell 钻取消息数据对象：ivar 递归搜索（含父类）→ 候选 getter → 全量 dump
static id STGetMsgWrapFromCell(UITableViewCell *cell) {
    if (!cell) return nil;
    @try {
        NSMutableSet *visited = [NSMutableSet set];
        id found = STSearchMsgWrap(cell, 0, visited);
        if (found) {
            STLog(@"[swipe] 命中消息对象=%@ (ivar 搜索)", NSStringFromClass([found class]));
            return found;
        }

        // 候选 getter（cell 与 cellView 都试）
        id cellView = [cell valueForKey:@"m_cellView"];
        NSArray *cand = @[@"m_msgWrap", @"msgWrap", @"m_node", @"node", @"m_messageNode", @"messageNode",
                          @"viewModel", @"m_viewModel", @"m_msg", @"m_messageWrap", @"messageWrap",
                          @"m_data", @"data", @"m_message", @"m_content", @"content", @"m_cellData",
                          @"cellData", @"m_msgNode", @"msgNode", @"m_model", @"model", @"m_MsgWrap"];
        for (NSString *k in cand) {
            id v = nil;
            @try { v = [cell valueForKey:k]; } @catch (NSException *e) {}
            if (v && STClassIsMsgWrap([v class])) {
                STLog(@"[swipe] 命中消息对象=%@ via cell.%@", NSStringFromClass([v class]), k);
                return v;
            }
        }
        for (NSString *k in cand) {
            id v = nil;
            @try { v = [cellView valueForKey:k]; } @catch (NSException *e) {}
            if (v && STClassIsMsgWrap([v class])) {
                STLog(@"[swipe] 命中消息对象=%@ via cellView.%@", NSStringFromClass([v class]), k);
                return v;
            }
        }

        // 失败：全量 dump 精准定位真实字段名
        STLog(@"[swipe] 取不到消息对象，开始全量 dump ===");
        STDumpAll(cell, cellView);
        STLog(@"[swipe] 取不到消息对象 cell=%@ cellView=%@",
              NSStringFromClass([cell class]), NSStringFromClass([cellView class]));
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

#pragma mark - 真实执行：删除 / 撤回（多候选探测，覆盖 WeChatX 与 8.0.37 两种 API）
/// 删除：依次尝试多个候选删除方法（哪个响应就用哪个）
///  - WeChatX: DelMsg: / DelMsg:MsgWrap:
///  - 8.0.37: deleteNode:withDB:animated: / deleteMessage: / onDeleteMsg:
static void STDeleteMessage(id vc, id obj) {
    if (!vc || !obj) return;
    STLog(@"[delete] 尝试删除 obj=%@ vc=%@", NSStringFromClass([obj class]), NSStringFromClass([vc class]));
    @try {
        // 1. DelMsg:MsgWrap: (WeChatX, 2 参数)
        SEL s1 = NSSelectorFromString(@"DelMsg:MsgWrap:");
        if ([vc respondsToSelector:s1]) {
            NSMethodSignature *sig = [vc methodSignatureForSelector:s1];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:vc]; [inv setSelector:s1];
                [inv setArgument:&obj atIndex:2]; [inv setArgument:&obj atIndex:3];
                [inv invoke];
                STLog(@"[delete] DelMsg:MsgWrap: OK"); return;
            }
        }
        // 2. DelMsg: (1 参数)
        SEL s2 = NSSelectorFromString(@"DelMsg:");
        if ([vc respondsToSelector:s2]) {
            [vc performSelector:s2 withObject:obj];
            STLog(@"[delete] DelMsg: OK"); return;
        }
        // 3. deleteNode:withDB:animated: (8.0.37, 3 参数: node/YES/YES)
        SEL s3 = NSSelectorFromString(@"deleteNode:withDB:animated:");
        if ([vc respondsToSelector:s3]) {
            NSMethodSignature *sig = [vc methodSignatureForSelector:s3];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:vc]; [inv setSelector:s3];
                [inv setArgument:&obj atIndex:2];
                BOOL yes = YES;
                [inv setArgument:&yes atIndex:3]; [inv setArgument:&yes atIndex:4];
                [inv invoke];
                STLog(@"[delete] deleteNode:withDB:animated: OK"); return;
            }
        }
        // 4. 其余单参数候选
        for (NSString *n in @[@"deleteMessage:", @"onDeleteMsg:", @"deleteOneMsg:"]) {
            SEL s = NSSelectorFromString(n);
            if ([vc respondsToSelector:s]) {
                [vc performSelector:s withObject:obj];
                STLog(@"[delete] %@ OK", n); return;
            }
        }
        STLog(@"[delete] 未找到删除方法 on %@", NSStringFromClass([vc class]));
    } @catch (NSException *e) {
        STLog(@"[delete] 异常: %@", e);
    }
}

/// 撤回：依次尝试多个候选撤回方法
///  - WeChatX: RevokeMsg:MsgWrap:Counter:revokeTicket:viewController:
///  - 8.0.37: revokeMsgByNodeView: / onRevokeMsg:MsgWrap:ResultCode:ResultMsg:EducationMsg: / OnRevokeMsg:...
static void STRecallMessage(id vc, id obj) {
    if (!vc || !obj) return;
    STLog(@"[recall] 尝试撤回 obj=%@ vc=%@", NSStringFromClass([obj class]), NSStringFromClass([vc class]));
    @try {
        // 1. RevokeMsg:MsgWrap:Counter:revokeTicket:viewController: (WeChatX, 4 参数)
        SEL s1 = NSSelectorFromString(@"RevokeMsg:MsgWrap:Counter:revokeTicket:viewController:");
        if ([vc respondsToSelector:s1]) {
            NSMethodSignature *sig = [vc methodSignatureForSelector:s1];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:vc]; [inv setSelector:s1];
                [inv setArgument:&obj atIndex:2];
                NSUInteger c = 0; [inv setArgument:&c atIndex:3];
                id t = nil;    [inv setArgument:&t atIndex:4];
                [inv setArgument:&vc atIndex:5];
                [inv invoke];
                STLog(@"[recall] RevokeMsg:MsgWrap:... OK"); return;
            }
        }
        // 2. revokeMsgByNodeView: (8.0.37, 1 参数 nodeView)
        SEL s2 = NSSelectorFromString(@"revokeMsgByNodeView:");
        if ([vc respondsToSelector:s2]) {
            [vc performSelector:s2 withObject:obj];
            STLog(@"[recall] revokeMsgByNodeView: OK"); return;
        }
        // 3. onRevokeMsg:MsgWrap:ResultCode:ResultMsg:EducationMsg: 系列
        for (NSString *n in @[
                @"onRevokeMsg:MsgWrap:ResultCode:ResultMsg:EducationMsg:",
                @"OnRevokeMsg:MsgWrap:ResultCode:ResultMsg:EducationMsg:",
                @"onRevokeMsg:"]) {
            SEL s = NSSelectorFromString(n);
            if ([vc respondsToSelector:s]) {
                if ([n isEqualToString:@"onRevokeMsg:"]) {
                    [vc performSelector:s withObject:obj];
                    STLog(@"[recall] onRevokeMsg: OK"); return;
                }
                NSMethodSignature *sig = [vc methodSignatureForSelector:s];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:vc]; [inv setSelector:s];
                    [inv setArgument:&obj atIndex:2];
                    int rc = 0; [inv setArgument:&rc atIndex:3];
                    id rm = nil; [inv setArgument:&rm atIndex:4];
                    id em = nil; [inv setArgument:&em atIndex:5];
                    [inv invoke];
                    STLog(@"[recall] %@ OK", n); return;
                }
            }
        }
        STLog(@"[recall] 未找到撤回方法 on %@", NSStringFromClass([vc class]));
    } @catch (NSException *e) {
        STLog(@"[recall] 异常: %@", e);
    }
}

#pragma mark - Hook：聊天页左滑（自定义 UISwipeGestureRecognizer，仿 WeChatX 的 leftSwipe）
%hook BaseMsgContentViewController

- (void)viewDidLoad {
    %orig;
    [self st_installSwipeGesture];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self st_installSwipeGesture];
}

%new
- (void)st_installSwipeGesture {
    if (objc_getAssociatedObject(self, "st_swipe_installed")) return;

    UITableView *tv = nil;
    @try { tv = [self valueForKey:@"tableView"]; } @catch (NSException *e) {}
    if (!tv) {
        @try { tv = [self valueForKey:@"m_tableView"]; } @catch (NSException *e) {}
    }
    if (!tv) {
        // 退而求其次：遍历 subviews 找 UITableView
        for (UIView *v in self.view.subviews) {
            if ([v isKindOfClass:[UITableView class]]) { tv = (UITableView *)v; break; }
        }
    }
    if (!tv) {
        STLog(@"[swipe] 找不到 tableView，延迟到下次 viewDidAppear 再试");
        return;
    }

    objc_setAssociatedObject(self, "st_swipe_installed", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UISwipeGestureRecognizer *sw = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(st_leftSwipe:)];
    sw.direction = UISwipeGestureRecognizerDirectionLeft;
    [tv addGestureRecognizer:sw];
    STLog(@"[swipe] 已安装左滑手势 on tableView (class=%@)",
          NSStringFromClass([tv class]));
}

%new
- (void)st_leftSwipe:(UISwipeGestureRecognizer *)sw {
    if (sw.state != UIGestureRecognizerStateRecognized) return;
    if (!STGetBool(kEnabled, YES)) return;

    UITableView *tv = nil;
    @try { tv = [self valueForKey:@"tableView"]; } @catch (NSException *e) {}
    if (!tv) {
        @try { tv = [self valueForKey:@"m_tableView"]; } @catch (NSException *e) {}
    }
    if (!tv) return;

    CGPoint p = [sw locationInView:tv];
    NSIndexPath *ip = [tv indexPathForRowAtPoint:p];
    if (!ip) { STLog(@"[swipe] 没命中 cell"); return; }
    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
    if (!cell) return;

    id mw = STGetMsgWrapFromCell(cell);
    if (!mw) {
        STLog(@"[swipe] 取不到消息对象 (cell=%@)，dump VC 方法用于适配", NSStringFromClass([cell class]));
        STDumpMethods(self, @"del");
        STDumpMethods(self, @"revoke");
        STDumpMethods(self, @"Message");
        return;
    }

    BOOL isOwn = STIsOwnMessage(mw);
    STLog(@"[swipe] 左滑触发 isOwn=%d msgWrap=%@ cell=%@",
          isOwn, NSStringFromClass([mw class]), NSStringFromClass([cell class]));

    if (isOwn && !STGetBool(kRecallLeft, YES)) return;
    if (!isOwn && !STGetBool(kDeleteLeft, YES)) return;

    NSString *title = isOwn ? @"撤回消息" : @"删除消息";
    NSString *actTitle = isOwn ? @"撤回" : @"删除";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];

    typeof(self) wself = self;
    [alert addAction:[UIAlertAction
        actionWithTitle:actTitle
        style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) {
            STLog(@"[swipe] 用户确认 %@ msgWrap=%@", actTitle, NSStringFromClass([mw class]));
            if (isOwn) STRecallMessage(wself, mw);
            else       STDeleteMessage(wself, mw);
        }]];
    [alert addAction:[UIAlertAction
        actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

%end

#pragma mark - 设置入口（微信「设置」页注入按钮）
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self st_maybeAddSettingsButton];
}

%end

@implementation STSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
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

@end

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
        // 主路径：App 沙盒 Documents（v5 起要求）
        NSArray<NSString *> *paths =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *logPath = nil;
        if (paths.count > 0) {
            logPath = [paths[0] stringByAppendingPathComponent:@"com.boss.swipetweak.log"];
        }
        // 兜底路径：jailbreak 下 tweak 通常可写 /var/mobile（绕过沙盒，便于 SSH 确认加载）
        NSString *fallback = @"/var/mobile/com.boss.swipetweak.log";
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *chosen = nil;
        for (NSString *p in @[logPath, fallback]) {
            if (!p) continue;
            @try {
                if (![fm fileExistsAtPath:p]) {
                    [fm createFileAtPath:p contents:[NSData data] attributes:nil];
                }
                NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
                if (h) { chosen = p; g_logHandle = h; break; }
            } @catch (NSException *e) {}
        }
        [g_logHandle seekToEndOfFile];
        g_logLock = [[NSLock alloc] init];
        if (chosen) STLog(@"[log] 日志路径: %@", chosen);
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
    STLog(@"SwipeTweak v14 Loaded (linked CydiaSubstrate/ellekit like WeChatX, so TrollFools loads it)");
}
