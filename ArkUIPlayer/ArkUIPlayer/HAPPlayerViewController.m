#import "HAPPlayerViewController.h"

@interface HAPPlayerViewController ()

// 标记 viewDidLoad 是否已经成功执行过(防止生命周期内多次重复 try)。
@property (nonatomic, assign) BOOL didLoadViewSucceed;
// 一旦有错误,后续生命周期不再转发给 super,避免递归崩溃。
@property (nonatomic, assign) BOOL errorOccurred;
// 已展示过的错误消息字符串(供日志/调试用,真正的 UI 由 HAPManager.crashErrorWindow 负责)。
@property (nonatomic, copy) NSString *lastErrorMessage;

@end

@implementation HAPPlayerViewController

- (instancetype)initWithHAPManager:(HAPManager *)manager
                        bundleName:(NSString *)bundleName
                        moduleName:(NSString *)moduleName
                       abilityName:(NSString *)abilityName
                          appName:(NSString *)appName
                         pageName:(NSString *)pageName {
    // instanceName 格式为 "bundleName:moduleName:abilityName",
    // StageViewController 内部据此定位 hap 解压后 {moduleName}/ 目录里的 abc 字节码与渲染入口。
    NSString *safeBundleName = bundleName.length ? bundleName : @"com.example.hap";
    NSString *safeModuleName = moduleName.length ? moduleName : @"entry";
    NSString *safeAbilityName = abilityName.length ? abilityName : @"EntryAbility";

    // 先清理上一次崩溃可能残留的错误 UI(用户重新点另一个 hap 的时候)。
    if (manager) {
        [manager hideGlobalError];
    }

    @try {
#if HAS_ARKUI_X
        NSString *instanceName = [NSString stringWithFormat:@"%@:%@:%@", safeBundleName, safeModuleName, safeAbilityName];
        self = [super initWithInstanceName:instanceName];
#else
        // HAS_ARKUI_X 未开启时,父类 StageViewController.init 也是 NS_UNAVAILABLE,
        // 无法创建父类实例。直接返回 nil,由调用方(HAPViewController)判断 nil 并展示报错。
        NSLog(@"[HAPPlayer] ❌ HAS_ARKUI_X disabled, cannot create StageViewController");
        if (manager) {
            [manager showGlobalError:@"HAS_ARKUI_X 编译宏未开启,无法加载 HAP。请在 Xcode Build Settings 中启用 ArkUI-X 框架。" shortText:@"报错"];
        }
        return nil;
#endif
    } @catch (NSException *e) {
        NSLog(@"[HAPPlayer] ❌ initWithInstanceName crashed: %@\n%@", e, e.callStackSymbols);
        // 注意:StageViewController 的 init 被 NS_UNAVAILABLE 标记,不能 [super init] 回退。
        // 直接返回 nil,由调用方判断 nil 并走 showGlobalError(我们这里也调一次,双保险)。
        NSString *msg = [NSString stringWithFormat:@"initWithInstanceName: %@\nReason: %@\n\nCallstack:\n%@",
                         e.name ?: @"NSException",
                         e.reason ?: @"unknown",
                         [e.callStackSymbols componentsJoinedByString:@"\n"]];
        if (manager) {
            [manager showGlobalError:msg shortText:@"报错"];
        }
        return nil;
    }

    if (self) {
        self.hapManager = manager;
        self.bundleName = safeBundleName;
        self.moduleName = safeModuleName;
        self.abilityName = safeAbilityName;
        self.appName = appName.length ? appName : safeModuleName;
        self.pageName = pageName ?: @"";
        // 注意:不要再在这里调用 hapManager.initializeArkUI。
        // ArkUI 运行时已经在 loadHAPAtPath 的 completion 触发前启动完毕(由 HAPManager 内部
        // 调用 StageApplication launchApplication 完成),此时 VC 才被创建。
    }
    return self;
}

- (void)viewDidLoad {
    if (self.errorOccurred) {
        // initWithInstanceName 已经失败,super 是 UIViewController,可以安全调 viewDidLoad
        [super viewDidLoad];
        return;
    }

    // StageViewController.viewDidLoad 会创建 Surface、调用 AppMain::DispatchOnCreate/DispatchOnForeground,
    // 这两个 C++ 调用如果 abc 字节码缺失/损坏,或 instanceName 不匹配 hap 实际入口,
    // 会抛出 ObjC 异常或直接 abort。这里用 @try/@catch 拦截 ObjC 异常,
    // C++ abort 由 HAPManager 的全局信号处理器(sigaction SIGABRT)拦截,一样弹出独立 Window 报错。
    @try {
        [super viewDidLoad];
        self.didLoadViewSucceed = YES;
    } @catch (NSException *e) {
        NSLog(@"[HAPPlayer] ❌ viewDidLoad crashed: %@\n%@", e, e.callStackSymbols);
        self.didLoadViewSucceed = NO;
        self.errorOccurred = YES;
        NSString *msg = [NSString stringWithFormat:@"viewDidLoad: %@\n\nCallstack:\n%@",
                         e.reason ?: e.name ?: @"unknown",
                         [e.callStackSymbols componentsJoinedByString:@"\n"]];
        self.lastErrorMessage = msg;
        [self showErrorMessage:msg];
        return;
    }

    self.title = self.appName.length ? self.appName : @"ArkUI Player";
    self.view.backgroundColor = [UIColor whiteColor];
}

- (void)viewDidAppear:(BOOL)animated {
    // 页面真正展示出来且没有报错,说明 hap 渲染成功,把上一次崩溃可能残留的错误 Window 清掉。
    if (!self.errorOccurred && self.didLoadViewSucceed) {
        [self.hapManager hideGlobalError];
    }

    if (self.errorOccurred) {
        [super viewDidAppear:animated];
        return;
    }
    @try {
        [super viewDidAppear:animated];
    } @catch (NSException *e) {
        NSLog(@"[HAPPlayer] ❌ viewDidAppear crashed: %@\n%@", e, e.callStackSymbols);
        self.errorOccurred = YES;
        NSString *msg = [NSString stringWithFormat:@"viewDidAppear: %@\n%@",
                         e.reason ?: e.name, [e.callStackSymbols componentsJoinedByString:@"\n"]];
        self.lastErrorMessage = msg;
        [self showErrorMessage:msg];
        return;
    }

    // ===== viewDidAppear 后诊断 & 尺寸强制刷新 =====
    // StageViewController.viewDidLoad 在 view 还没布局时就创建 windowView 并设置 frame=self.view.bounds,
    // 此时 view.bounds 可能是 (0,0,0,0)(取决于容器什么时候约束好),导致 windowView 尺寸为 0,
    // layoutSubviews 里的 notifySurfaceChangedWithWidth 传 0x0,渲染 surface 没初始化 → 白屏。
    // 这里在 viewDidAppear 时(确定 view 已经有尺寸了)诊断并强制刷新布局和 frame。
    @try {
        UIView *rootView = self.view;
        CGRect rootBounds = rootView.bounds;
        CGRect rootFrame = rootView.frame;
        NSLog(@"[HAPPlayer] 📐 viewDidAppear post-diagnose: rootView.bounds=%@ rootView.frame=%@ subviews=%lu",
              NSStringFromCGRect(rootBounds), NSStringFromCGRect(rootFrame),
              (unsigned long)rootView.subviews.count);

        // 递归查找 WindowView / AccessibilityWindowView 并诊断
        __block UIView *windowView = nil;
        void (^findWindowView)(UIView *) = ^(UIView *parent) {
            for (UIView *sub in parent.subviews) {
                NSString *cls = NSStringFromClass([sub class]);
                BOOL isWindowView = [cls containsString:@"WindowView"];
                NSLog(@"[HAPPlayer]   subview: %@  frame=%@  bounds=%@",
                      cls, NSStringFromCGRect(sub.frame), NSStringFromCGRect(sub.bounds));
                if (isWindowView && !windowView) {
                    windowView = sub;
                }
                // 递归查找(StageContainerView 会把 WindowView 包一层)
                if (sub.subviews.count > 0) {
                    for (UIView *ss in sub.subviews) {
                        NSString *scls = NSStringFromClass([ss class]);
                        BOOL isSW = [scls containsString:@"WindowView"];
                        NSLog(@"[HAPPlayer]     sub-subview: %@  frame=%@  bounds=%@",
                              scls, NSStringFromCGRect(ss.frame), NSStringFromCGRect(ss.bounds));
                        if (isSW && !windowView) {
                            windowView = ss;
                        }
                    }
                }
            }
        };
        findWindowView(rootView);

        // 如果找到 WindowView 且 frame 为 0x0(或与 root 不一致),强制重设 + layout
        if (windowView) {
            BOOL sizeIsZero = (windowView.bounds.size.width <= 1 || windowView.bounds.size.height <= 1);
            BOOL mismatch = (fabs(windowView.bounds.size.width - rootBounds.size.width) > 1 ||
                             fabs(windowView.bounds.size.height - rootBounds.size.height) > 1);
            if (sizeIsZero || mismatch) {
                NSLog(@"[HAPPlayer] 🔧 Fixing windowView size: was %@ -> applying rootBounds %@",
                      NSStringFromCGRect(windowView.bounds), NSStringFromCGRect(rootBounds));
                // 1) 重设 frame(autoresizingMask 在 StageVC 里已经设置了)
                windowView.frame = rootBounds;
                // 2) 强制 setNeedsLayout + layoutIfNeeded → 触发 WindowView.layoutSubviews
                //    → notifySurfaceChangedWithWidth 会以正确尺寸通知 native 创建渲染 surface
                [windowView setNeedsLayout];
                [rootView setNeedsLayout];
                [windowView layoutIfNeeded];
                [rootView layoutIfNeeded];
                NSLog(@"[HAPPlayer] ✅ After fix: windowView.frame=%@ bounds=%@",
                      NSStringFromCGRect(windowView.frame), NSStringFromCGRect(windowView.bounds));

                // 3) 如果 ArkUI 运行着,额外触发一次 foreground (有些 ArkUI-X 版本需要前台通知才会
                //    真正绑定 surface 并启动渲染循环)
                if (self.hapManager.isArkUIRunning) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        @try {
                            NSLog(@"[HAPPlayer] 🔄 Post-fix: re-dispatching OnForeground to ability");
                            [self.hapManager callCurrentAbilityOnForeground];
                        } @catch (NSException *ex) {
                            NSLog(@"[HAPPlayer] ⚠️ Post-fix onForeground non-fatal: %@", ex);
                        }
                    });
                }
            } else {
                NSLog(@"[HAPPlayer] ✅ windowView size already correct: %@",
                      NSStringFromCGRect(windowView.bounds));
            }
        } else {
            NSLog(@"[HAPPlayer] ⚠️ Could not find WindowView in view hierarchy after viewDidAppear");
        }
    } @catch (NSException *diagEx) {
        NSLog(@"[HAPPlayer] ⚠️ Post-diagnose non-fatal exception: %@", diagEx);
    }
}

- (void)viewWillAppear:(BOOL)animated {
    // hap 运行时隐藏蓝色导航栏,避免遮挡 ArkUI-X 渲染界面。
    // 列表页(HAPViewController)会在 viewWillDisappear 时恢复导航栏。
    [self.navigationController setNavigationBarHidden:YES animated:animated];

    // 已经处于错误展示状态时,不再转发任何生命周期给 StageVC,避免二次触发同一异常。
    if (self.errorOccurred) {
        [super viewWillAppear:animated];
        return;
    }

    @try {
        [super viewWillAppear:animated];
    } @catch (NSException *e) {
        NSLog(@"[HAPPlayer] ❌ viewWillAppear crashed: %@\n%@", e, e.callStackSymbols);
        self.errorOccurred = YES;
        NSString *msg = [NSString stringWithFormat:@"viewWillAppear: %@\n%@",
                         e.reason ?: e.name, [e.callStackSymbols componentsJoinedByString:@"\n"]];
        self.lastErrorMessage = msg;
        [self showErrorMessage:msg];
        return;
    }

    // ArkUI 未启动时不要转发 foreground,否则 StageApplication 取到的 topViewController
    // 不是 StageViewController,会触发空指针/状态机错乱崩溃。
    if (self.hapManager.isArkUIRunning) {
        @try {
            [self.hapManager callCurrentAbilityOnForeground];
        } @catch (NSException *e) {
            NSLog(@"[HAPPlayer] ❌ callCurrentAbilityOnForeground crashed: %@\n%@", e, e.callStackSymbols);
            self.errorOccurred = YES;
            NSString *msg = [NSString stringWithFormat:@"onForeground: %@\n%@",
                             e.reason ?: e.name, [e.callStackSymbols componentsJoinedByString:@"\n"]];
            self.lastErrorMessage = msg;
            [self showErrorMessage:msg];
        }
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    // 离开 hap 播放页时恢复导航栏,让列表页的蓝色标题栏正常显示。
    [self.navigationController setNavigationBarHidden:NO animated:animated];

    if (!self.didLoadViewSucceed) {
        [super viewWillDisappear:animated];
        return;
    }
    if (self.errorOccurred) {
        [super viewWillDisappear:animated];
        return;
    }

    @try {
        [super viewWillDisappear:animated];
    } @catch (NSException *e) {
        NSLog(@"[HAPPlayer] ❌ viewWillDisappear crashed: %@", e);
    }

    if (self.hapManager.isArkUIRunning) {
        @try {
            [self.hapManager callCurrentAbilityOnBackground];
        } @catch (NSException *e) {
            NSLog(@"[HAPPlayer] ❌ callCurrentAbilityOnBackground crashed: %@", e);
        }
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    if (self.errorOccurred) {
        [super viewDidDisappear:animated];
        return;
    }
    @try {
        [super viewDidDisappear:animated];
    } @catch (NSException *e) {
        NSLog(@"[HAPPlayer] ❌ viewDidDisappear crashed: %@", e);
    }
}

#pragma mark - Error UI(转发到 HAPManager 的全局独立 Window)

// 错误 UI 统一交给 HAPManager 用独立 UIWindow(windowLevel = UIWindowLevelAlert + 1000) 渲染,
// 保证 StageVC 的渲染层(windowView / Metal layer)不会把红色报错文本覆盖;
// 也保证即使 StageVC 的 view 没加载成功(例如 initWithInstanceName 就 abort 了),也能显示报错。
- (void)showErrorMessage:(NSString *)message {
    if (!message || message.length == 0) {
        message = @"Unknown error";
    }
    self.lastErrorMessage = message;
    self.errorOccurred = YES;
    NSLog(@"[HAPPlayer] Show error message (via global window): %@", message);
    [self.hapManager showGlobalError:message shortText:@"报错"];
}

@end
