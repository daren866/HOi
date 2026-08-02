#import "HAPManager.h"
#import "HAPPlayerViewController.h"

#if HAS_ARKUI_X
// 仅 StageApplication.h 是 ArkUI-X framework 公开导出的头文件,
// StageAssetManager.h 属于内部实现,在预编译 framework 中不可见,故不引入。
#import "StageApplication.h"
#endif

#import <spawn.h>
#import <sys/wait.h>
#import <signal.h>
#import <execinfo.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <zlib.h>

// ArkUI-X 运行时内部通过 getApplicationTopViewController 获取导航栈顶 VC,
// 然后异步调用 instanceName。当栈顶是非 StageViewController(如 HAPViewController、
// UINavigationController 等)时,会触发 unrecognized selector 崩溃。
// 通过 +load 在 UIViewController 基类注入默认 instanceName 实现(返回 nil),
// StageViewController 子类自己的 instanceName 会覆盖此默认实现,不受影响。
@interface UIViewController (ArkUISafe)
@end

@implementation UIViewController (ArkUISafe)
+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEL sel = @selector(instanceName);
        // class_getInstanceMethod 只搜索当前类及其父类,不会搜索子类。
        // UIViewController 本身没有 instanceName(只有 StageViewController 子类有),
        // 所以这里返回 NULL,然后 class_addMethod 添加默认实现。
        Method m = class_getInstanceMethod(self, sel);
        if (!m) {
            IMP imp = imp_implementationWithBlock(^NSString *(id _self) {
                return nil;
            });
            class_addMethod(self, sel, imp, "@@:");
            NSLog(@"[HAPManager] UIViewController+ArkUISafe: added default instanceName to UIViewController base class");
        }
    });
}
@end

// module.json 中常见字段名常量,用于解析 hap 的运行时入口信息。
static NSString *const kDefaultModuleName = @"entry";
static NSString *const kDefaultAbilityName = @"EntryAbility";
static NSString *const kDefaultBundleName = @"com.example.hap";
static NSString *const kArkuiXDirName = @"arkui-x";
// StageAssetProvider::GetAppDataModuleDir() 内部返回的路径是
// Documents/files/arkui-x(见 stage_asset_provider.mm),hap 必须解压到这个目录下,
// 否则 GetModuleBuffer / GetModuleAbilityBuffer 在 StageAssetManager 数组里找不到
// abc 时走回退路径 GetAppDataModuleDir()+moduleName 会落空,返回空 buffer 让 AppMain 崩溃。
static NSString *const kFilesSubdirName = @"files";

// ---- 全局崩溃防护:静态变量 + C 级别的 handler ----
// 保存之前的 UncaughtException handler / signal handler,崩溃后优先调用我们的,
// 再交给原 handler(如果有的话)做最后清理。不过为了避免 abort 二次触发闪退,
// 我们在自己的 handler 里不再转发。
static NSUncaughtExceptionHandler *g_prevExceptionHandler = NULL;
static struct sigaction g_prevSigAction[NSIG];
static volatile sig_atomic_t g_crashGuardArmed = 0;
static void *g_hapManagerSelf = NULL;  // 弱引用,只在崩溃时用来 showGlobalError

// 信号号 -> 可读名称,方便报错信息
static const char *_SignalName(int sig) {
    switch (sig) {
        case SIGABRT: return "SIGABRT";
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGFPE:  return "SIGFPE";
        case SIGPIPE: return "SIGPIPE";
        case SIGTRAP: return "SIGTRAP";
        default: {
            static char buf[16];
            snprintf(buf, sizeof(buf), "SIG%d", sig);
            return buf;
        }
    }
}

// 崩溃错误信息缓存(信号安全写入,主线程读取展示)
static volatile char g_crashMessage[8192];
static volatile sig_atomic_t g_crashPending = 0;

// 在主线程上直接同步展示全局错误 UI。
// 由 signal handler / uncaught exception handler 调用。
// 注意:严格说 ObjC 调用在 async signal handler 里不是 async-signal-safe,
// 但 SIGABRT 通常由 abort() 同步触发,栈是好的,实际能跑通;
// SIGSEGV/SIGBUS 等异步信号可能栈已损坏,但我们也只能尽力而为,总比直接闪退好。
static void _ShowCrashUIOnCurrentThread(NSString *message) {
    @autoreleasepool {
        HAPManager *mgr = (__bridge HAPManager *)g_hapManagerSelf;
        if (!mgr) {
            NSLog(@"[HAPManager] Crash UI: HAPManager already released, cannot show.");
            return;
        }
        NSLog(@"[HAPManager] Crash UI: showing error (%lu chars)", (unsigned long)message.length);
        // showGlobalError 内部会判断是否在主线程,主线程则同步执行,否则 dispatch_async
        [mgr showGlobalError:message shortText:@"报错"];
    }
}

// 真实的信号 handler(信号安全级别,但我们破例调用 ObjC)
static void _SignalCrashHandler(int sig, siginfo_t *info, void *ucontext) {
    if (g_crashPending) {
        // 已经在处理中,可能是二次崩溃。直接死循环,避免再 abort。
        // 不能 return,因为 SIGABRT return 后内核会再次触发(abort 内部会再 raise)。
        while (1) {
            sleep(1);
        }
    }
    g_crashPending = 1;

    // 构建错误信息:用 C sprintf(信号安全)
    char *buf = (char *)g_crashMessage;
    size_t n = 0;
    n += (size_t)snprintf(buf + n, sizeof(g_crashMessage) - n,
                          "Signal: %s (code=%d, addr=%p)\n\n"
                          "ArkUI-X 触发了致命信号,应用不会继续退出,已切换到错误展示模式。\n"
                          "点击红色文本可复制完整错误。\n\n"
                          "Backtrace:\n",
                          _SignalName(sig), info ? info->si_code : 0,
                          info ? info->si_addr : NULL);

    // 追加 backtrace(backtrace_symbols 不是严格信号安全,但崩溃时通常能跑)
    void *frames[40];
    int count = backtrace(frames, 40);
    if (count > 0) {
        char **syms = backtrace_symbols(frames, count);
        if (syms) {
            for (int i = 0; i < count && n < sizeof(g_crashMessage) - 2; i++) {
                n += (size_t)snprintf(buf + n, sizeof(g_crashMessage) - n, "%s\n", syms[i]);
            }
            free(syms);
        }
    }

    // 直接同步调用 ObjC showGlobalError。
    // SIGABRT 由 abort() 同步触发,调用线程的栈是好的,ObjC 能跑;
    // SIGSEGV 等异步信号栈可能损坏,但我们尽力而为。
    // 不用 dispatch_async 是因为:崩溃线程如果是主线程,主线程栈被卡住,dispatch 的 block 永远不会执行。
    NSString *message = @(buf);
    _ShowCrashUIOnCurrentThread(message);

    // 不 return(return 后 SIGABRT 会被内核再次触发)。
    // 在当前线程跑 RunLoop,让 UIWindow 能渲染、用户能点击复制。
    // 用 @autoreleasepool 包住每次 RunLoop 循环,避免内存累积。
    while (1) {
        @autoreleasepool {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                                  beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }
}

// Uncaught NSException handler:ObjC 层 @throw 没有 @catch 时触发
static void _UncaughtExceptionHandler(NSException *exception) {
    if (g_crashPending) {
        while (1) { sleep(1); }
    }
    g_crashPending = 1;

    NSString *bt = exception.callStackSymbols.count > 0
        ? [exception.callStackSymbols componentsJoinedByString:@"\n"] : @"";
    NSString *message = [NSString stringWithFormat:
        @"NSException: %@\nReason: %@\nUserInfo: %@\n\n"
        @"Backtrace:\n%@",
        exception.name,
        exception.reason ?: @"(null)",
        exception.userInfo ?: @{},
        bt ?: @""
    ];
    NSLog(@"[HAPManager] Uncaught exception: %@", message);

    // 直接同步展示 UI
    _ShowCrashUIOnCurrentThread(message);

    // 不 return,跑 RunLoop 让 UI 响应
    while (1) {
        @autoreleasepool {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                                  beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }
}

@interface HAPManager ()

@property (nonatomic, strong) NSString *currentHAPPath;
@property (nonatomic, strong) NSString *arkuiXDirectory;
@property (nonatomic, assign) BOOL isArkUIRunning;
@property (nonatomic, copy) NSString *currentBundleName;
@property (nonatomic, copy) NSString *currentModuleName;
@property (nonatomic, copy) NSString *currentAbilityName;
@property (nonatomic, copy) NSString *currentAppName;
@property (nonatomic, copy) NSString *currentPageName;
// crashErrorWindow 属性实现(readonly 对外,readwrite 对内)
@property (nonatomic, strong) UIWindow *crashErrorWindow;
// 详细错误信息(点击复制用)
@property (nonatomic, copy) NSString *lastGlobalErrorMessage;

@end

static HAPManager *_sharedInstance = nil;

@implementation HAPManager

+ (instancetype)sharedManager {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[self alloc] init];
    });
    return _sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 必须用 Documents/files/arkui-x,与 StageAssetProvider::GetAppDataModuleDir() 对齐。
        // StageAssetProvider 在 StageAssetManager 数组里找不到 abc 时,会回退到
        // GetAppDataModuleDir()+moduleName 查找,如果 hap 没解压到这个目录,回退路径会落空。
        NSString *documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *filesDir = [documentsDir stringByAppendingPathComponent:kFilesSubdirName];
        self.arkuiXDirectory = [filesDir stringByAppendingPathComponent:kArkuiXDirName];

        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:self.arkuiXDirectory]) {
            [fm createDirectoryAtPath:self.arkuiXDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        }

        // 清理旧版本残留在 Documents/arkui-x 的数据(早期版本用 Documents/arkui-x,
        // 与 GetAppDataModuleDir() 的 Documents/files/arkui-x 不一致,留着会干扰扫描)。
        NSString *legacyDir = [documentsDir stringByAppendingPathComponent:kArkuiXDirName];
        if ([fm fileExistsAtPath:legacyDir]) {
            NSLog(@"[HAPManager] Cleaning legacy arkui-x directory at %@", legacyDir);
            [fm removeItemAtPath:legacyDir error:nil];
        }

        g_hapManagerSelf = (__bridge void *)self;
    }
    return self;
}

#pragma mark - 全局崩溃防护

- (void)installCrashGuard {
    [self installCrashGuardForce:NO];
}

- (void)installCrashGuardForce:(BOOL)force {
    if (!force && g_crashGuardArmed) return;
    g_crashGuardArmed = 1;

    // 1. 注册 UncaughtException handler(每次都重装,因为可能被覆盖)
    g_prevExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&_UncaughtExceptionHandler);

    // 2. 为致命信号注册 sigaction(force=YES 时即使之前装过也重装)
    const int handledSignals[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGPIPE };
    const size_t numHandled = sizeof(handledSignals) / sizeof(handledSignals[0]);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = &_SignalCrashHandler;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < numHandled; i++) {
        int sig = handledSignals[i];
        struct sigaction prev;
        memset(&prev, 0, sizeof(prev));
        if (sigaction(sig, &action, &prev) == 0) {
            g_prevSigAction[sig] = prev;
            if (force) {
                NSLog(@"[HAPManager] Crash guard (force reinstall): sigaction %s", _SignalName(sig));
            } else {
                NSLog(@"[HAPManager] Crash guard: sigaction installed for %s", _SignalName(sig));
            }
        }
    }
}

// showGlobalError 的实际 UI 构建逻辑(必须在主线程执行)。
// 抽出来是为了让 showGlobalError 能根据当前线程选择同步执行还是 dispatch_async。
- (void)_buildAndShowCrashWindow:(NSString *)shortText {
    // 如果 errorWindow 已经存在且可见,只更新 label 文本(避免重复创建)
    if (self.crashErrorWindow) {
        UIView *rootView = self.crashErrorWindow.rootViewController.view;
        UILabel *lbl = [rootView viewWithTag:99999];
        if ([lbl isKindOfClass:[UILabel class]]) {
            lbl.text = shortText.length ? shortText : @"报错";
        }
        self.crashErrorWindow.hidden = NO;
        return;
    }

    // 独立 UIWindow:windowLevel 设为最高,保证覆盖在导航栏、alert、StageVC 渲染 surface 之上。
    // C++ abort / ObjC NSException 崩溃后,原 main window 的 VC 可能已经处于半损坏状态,
    // 用独立 window 完全不依赖原有 VC 层级。
    UIWindowScene *scene = nil;
    for (UIWindowScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
            scene = s;
            break;
        }
    }
    UIWindow *win;
    if (scene) {
        win = [[UIWindow alloc] initWithWindowScene:scene];
    } else {
        win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    }
    win.windowLevel = UIWindowLevelAlert + 1000.0;  // 最高级别,覆盖所有 alert 和渲染层
    win.backgroundColor = UIColor.whiteColor;
    win.userInteractionEnabled = YES;
    win.hidden = NO;
    self.crashErrorWindow = win;

    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = UIColor.whiteColor;
    win.rootViewController = rootVC;
    [win makeKeyAndVisible];

    // ScrollView + Label 布局:短文本居中显示,长文本可滚动。
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.backgroundColor = UIColor.whiteColor;
    scrollView.alwaysBounceVertical = YES;
    scrollView.showsVerticalScrollIndicator = YES;
    [rootVC.view addSubview:scrollView];

    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:container];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.tag = 99999;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.systemRedColor;
    label.font = [UIFont systemFontOfSize:16];
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.adjustsFontSizeToFitWidth = NO;
    label.userInteractionEnabled = YES;
    label.text = shortText.length ? shortText : @"报错";
    [container addSubview:label];

    // 点击复制
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_handleGlobalErrorTap)];
    tap.numberOfTapsRequired = 1;
    [label addGestureRecognizer:tap];

    // 布局:
    // ScrollView 占满整个 window.rootVC.view;
    // Container 撑满 contentLayoutGuide,宽度 = frameLayoutGuide,高度 >= 可视高度(保证短文本居中);
    // Label 在 Container 中水平居中(留边),垂直居中(留 >=24pt 上下边距)。
    UILayoutGuide *content = scrollView.contentLayoutGuide;
    UILayoutGuide *frame = scrollView.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:rootVC.view.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:rootVC.view.bottomAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:rootVC.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:rootVC.view.trailingAnchor],

        [container.topAnchor constraintEqualToAnchor:content.topAnchor],
        [container.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [container.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [container.widthAnchor constraintEqualToAnchor:frame.widthAnchor],
        [container.heightAnchor constraintGreaterThanOrEqualToAnchor:frame.heightAnchor],

        [label.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [label.topAnchor constraintGreaterThanOrEqualToAnchor:container.topAnchor constant:24],
        [label.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-24],
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
    ]];

    // 强制立即布局一次,让 label 马上显示出来(不等下一个 RunLoop cycle)
    [rootVC.view layoutIfNeeded];
}

- (void)showGlobalError:(NSString *)message shortText:(NSString *)shortText {
    self.lastGlobalErrorMessage = message ?: shortText ?: @"报错";

    NSLog(@"[HAPManager] showGlobalError (short=%@): %@", shortText, message);

    NSString *safeShortText = shortText.length ? shortText : @"报错";

    // 关键:如果当前已经在主线程(比如 signal handler 直接调用),同步执行 UI 构建,
    // 不用 dispatch_async。因为 dispatch_async 会把 block 排到主队列,
    // 但如果主线程栈被卡在崩溃函数里(比如 SIGABRT 后跑 RunLoop),dispatch 的 block 不一定能及时跑。
    // 同步执行能保证 UIWindow 立即创建并显示。
    if ([NSThread isMainThread]) {
        [self _buildAndShowCrashWindow:safeShortText];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _buildAndShowCrashWindow:safeShortText];
        });
    }
}

- (void)_handleGlobalErrorTap {
    NSString *msg = self.lastGlobalErrorMessage ?: @"(no error message)";
    UIPasteboard *pb = UIPasteboard.generalPasteboard;
    pb.string = msg;
    NSLog(@"[HAPManager] Global error copied (%lu chars)", (unsigned long)msg.length);

    // 闪烁反馈
    UIView *rootView = self.crashErrorWindow.rootViewController.view;
    UILabel *lbl = [rootView viewWithTag:99999];
    if ([lbl isKindOfClass:[UILabel class]]) {
        [UIView animateWithDuration:0.1 animations:^{
            lbl.alpha = 0.4;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.2 animations:^{
                lbl.alpha = 1.0;
            }];
        }];
    }
}

- (void)hideGlobalError {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.crashErrorWindow) {
            self.crashErrorWindow.hidden = YES;
            self.crashErrorWindow = nil;
        }
        self.lastGlobalErrorMessage = nil;
    });
}

#pragma mark - Load HAP and run abc bytecode

- (void)loadHAPAtPath:(NSString *)hapPath completion:(HAPLoadCompletion)completion {
    if (!hapPath || ![hapPath hasSuffix:@".hap"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, @"Invalid HAP file path");
        });
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:hapPath]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, @"HAP file not found");
        });
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 先在主线程清理上一个 hap 的运行时状态(StageApplication 必须在主线程操作)。
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self unloadCurrentHAP];
        });

        // 解压 hap 到临时目录,hap 本质是 zip。
        NSString *tempDir = NSTemporaryDirectory();
        NSString *extractDir = [tempDir stringByAppendingPathComponent:@"hap_extract"];

        if ([fm fileExistsAtPath:extractDir]) {
            [fm removeItemAtPath:extractDir error:nil];
        }

        if (![self extractZIPFileAtPath:hapPath toDirectory:extractDir]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"Failed to extract HAP file");
            });
            return;
        }

        // 打印 hap 解压后的目录结构(前 30 个条目),便于排查 hap 真实产物结构。
        NSLog(@"[HAPManager] HAP extracted to %@, top-level entries:", extractDir);
        NSArray *extractTopEntries = [fm contentsOfDirectoryAtPath:extractDir error:nil];
        for (NSString *entry in extractTopEntries) {
            BOOL isDir = NO;
            [fm fileExistsAtPath:[extractDir stringByAppendingPathComponent:entry] isDirectory:&isDir];
            NSLog(@"[HAPManager]   %@%@", entry, isDir ? @"/" : @"");
        }
        NSUInteger totalSubpaths = [[fm subpathsOfDirectoryAtPath:extractDir error:nil] count];
        NSLog(@"[HAPManager] Total subpaths under extract dir: %lu", (unsigned long)totalSubpaths);

        // 从解压目录中读取 module.json/module.json5,解析出运行 abc 所需的 bundleName/moduleName/abilityName,
        // 同时提取 appName(展示名)和 pageName(入口界面名)。
        NSString *appName = [hapPath lastPathComponent];
        appName = [appName stringByReplacingOccurrencesOfString:@".hap" withString:@""];
        NSString *bundleName = kDefaultBundleName;
        NSString *moduleName = kDefaultModuleName;
        NSString *abilityName = kDefaultAbilityName;
        NSString *pageName = @"";

        NSDictionary *moduleInfo = [self parseModuleJsonInDirectory:extractDir];
        if (moduleInfo) {
            if (moduleInfo[@"appName"]) {
                appName = moduleInfo[@"appName"];
            }
            if (moduleInfo[@"bundleName"]) {
                bundleName = moduleInfo[@"bundleName"];
            }
            if (moduleInfo[@"moduleName"]) {
                moduleName = moduleInfo[@"moduleName"];
            }
            if (moduleInfo[@"abilityName"]) {
                abilityName = moduleInfo[@"abilityName"];
            }
            if (moduleInfo[@"pageName"]) {
                pageName = moduleInfo[@"pageName"];
            }
        } else {
            // module.json/json5 都没找到,hap 损坏或不是 ArkTS 产物,直接报错而不是继续走下去闪退。
            [fm removeItemAtPath:extractDir error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"module.json/module.json5 not found or invalid in HAP");
            });
            return;
        }

        // hap 内容根目录:module.json5 所在目录。
        // 标准 hap 解压后内容在根目录,但某些 hap(如 Windows 构建工具打包)会把内容
        // 放在顶层目录(如 entry-default-unsigned/)下,这里用 parseModuleJsonInDirectory
        // 返回的 _contentRoot 确保后续 abc 校验和安装都指向正确的内容目录。
        NSString *contentRoot = moduleInfo[@"_contentRoot"] ?: extractDir;
        NSLog(@"[HAPManager] Content root: %@ (extractDir: %@)", contentRoot, extractDir);

        // 校验解压结果中确实存在 abc 字节码文件,否则没必要继续。
        if (![self containsAbcBytecodeInDirectory:contentRoot]) {
            [fm removeItemAtPath:extractDir error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"No ArkTS abc bytecode found in HAP");
            });
            return;
        }

        // 把 hap 解压内容安置到 Documents/arkui-x/{moduleName}/ 下。
        //
        // 真实未签名 hap 解压后根目录直接是 ets/modules.abc、module.json、resources/、resources.index、
        // pack.info、pkgContextInfo.json(没有 entry/ 子目录)。而 ArkUI-X iOS 工程期望的 arkui-x/ 目录
        // 结构是 {moduleName}/ 子目录 + AppScope/(可选) + systemres/(SDK 提供)。
        // 所以这里把 hap 解压根目录的所有条目整体拷贝到 {moduleName}/ 下,目录名用纯 moduleName(如 entry),
        // 与 ArkUI-X 官方文档的 iOS 工程产物结构对齐:
        //   arkui-x/entry/ets/modules.abc
        //   arkui-x/entry/module.json
        //   arkui-x/entry/resources/...
        //
        // 注意:不要把目录名改成 bundleName.moduleName(如 com.example.entry)!
        // a) ArkUI-X 官方文档明确 iOS 工程产物目录名就是纯 moduleName。
        // b) StageViewController.initWithInstanceName 中的 ExistDir 会搜索 "/bundleName.moduleName/",
        //    标准产物路径里只有 "/entry/",所以 ExistDir 返回 NO,StageVC 保持 moduleName="entry" 不重写,
        //    这与 AppMain 从 module.json 读到的 module.name="entry" 一致,DispatchOnCreate 能正确匹配 abc。
        // c) abc 字节码中模块名由 ArkTS 编译器决定(通常是 "entry"),改写 module.json 不会影响 abc 内部
        //    的模块名注册,反而会导致 module.name 与 abc 模块名错位 → AppMain 找不到 abc 入口 → 闪退或白屏。
        // d) SDK 内部的 updateModuleNameWithJsonData: 也只在路径包含 bundleName.moduleName 时才改写
        //    module.name,标准产物路径不包含,所以不改写是预期行为。
        if (![self installExtractedFilesFrom:contentRoot
                                  moduleName:moduleName
                           toArkuiXDirectory:self.arkuiXDirectory]) {
            [fm removeItemAtPath:extractDir error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"Failed to install abc bytecode into arkui-x directory");
            });
            return;
        }

        [fm removeItemAtPath:extractDir error:nil];

        self.currentHAPPath = hapPath;
        self.currentBundleName = bundleName;
        self.currentModuleName = moduleName;
        self.currentAbilityName = abilityName;
        self.currentAppName = appName;
        self.currentPageName = pageName;

        // 在主线程调用 StageApplication 配置 bundle 目录并启动 ArkUI 运行时,
        // 这一步会把 hap 中的 modules.abc 等 abc 字节码加载进 ArkUI-X 虚拟机并执行入口逻辑。
        // 注意:block 内使用 moduleInfo 局部变量(在 NSOperationQueue 后台线程创建),
        // 其生命周期和主队列 block 一样长,所以 _appObj 等字段不会被释放。
        NSDictionary *moduleInfoCopy = moduleInfo;
        dispatch_async(dispatch_get_main_queue(), ^{
            // 整个 StageApplication 调用序列可能触发 ObjC 异常 / C++ abort。
            // 这里用最外层 @try/@catch 兜底,任何 ObjC 异常都不会让 completion 不被调用,
            // 也不会让 app 直接闪退。C++ abort 由全局 signal handler(sigaction SIGABRT)拦截。
            //
            // 注意:ArkUI-X 内部 launchApplication 时可能会自己 sigaction 覆盖我们的 signal handler,
            // 所以在每次 StageApplication 调用前都用 installCrashGuard 重新安装一遍。
            // installCrashGuard 内部用 g_crashGuardArmed 标志位去重,但这里加 force 参数强制重装。
            @try {
#if HAS_ARKUI_X
                // configModule 之前:跑一遍 postInstallSetup
                // - 合成缺失的 AppScope/app.json (某些 SDK 版本缺失该文件会导致白屏)
                // - 打印 resources.index/pack.info 等关键文件存在性诊断
                // - 列出 main_pages.json 等 profile 内容,方便定位白屏原因
                NSDictionary *appObj = moduleInfoCopy[@"_appObj"];
                [self postInstallSetupForBundleName:bundleName
                                         moduleName:moduleName
                                            appName:appName
                                   arkuiXDirectory:self.arkuiXDirectory
                                      parsedAppObj:appObj];

                // 在 configModule 之前重新安装 crash guard,防止上一次或本次 ArkUI-X 内部覆盖。
                [self installCrashGuardForce:YES];

                // StageAssetManager 的 moduleFilesWithbundleDirectory: 会把传入的 directory
                // 拼接到 [[NSBundle mainBundle] bundlePath] 后面。如果传入绝对路径(以 / 开头),
                // 拼接结果为 "app.app//var/mobile/..." 是无效路径,导致 all files count : 0。
                // 必须传入相对于 main bundle 的相对路径,利用 .. 回溯到根目录再进入 Data 容器。
                NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
                NSString *resolvedBundle = [bundlePath stringByResolvingSymlinksInPath];
                NSString *resolvedTarget = [self.arkuiXDirectory stringByResolvingSymlinksInPath];
                NSArray *bundleComps = [resolvedBundle pathComponents];
                NSArray *targetComps = [resolvedTarget pathComponents];

                NSUInteger commonCount = 0;
                while (commonCount < bundleComps.count && commonCount < targetComps.count
                       && [bundleComps[commonCount] isEqualToString:targetComps[commonCount]]) {
                    commonCount++;
                }

                NSUInteger upCount = bundleComps.count - commonCount;
                NSMutableArray *relativeParts = [NSMutableArray arrayWithCapacity:upCount + (targetComps.count - commonCount)];
                for (NSUInteger i = 0; i < upCount; i++) {
                    [relativeParts addObject:@".."];
                }
                for (NSUInteger i = commonCount; i < targetComps.count; i++) {
                    [relativeParts addObject:targetComps[i]];
                }
                NSString *relativeDir = [relativeParts componentsJoinedByString:@"/"];

                NSLog(@"[HAPManager] configModuleWithBundleDirectory: %@ (relative: %@)", self.arkuiXDirectory, relativeDir);
                [StageApplication configModuleWithBundleDirectory:relativeDir];

                // configModule 内部可能也注册了自己的 signal handler,再次重装确保我们的在最上层。
                [self installCrashGuardForce:YES];

                // 打印已安装到 arkui-x 下的 module.json 内容,确认 hap 中的 module.json 被原样拷贝
                // (未做改写),module.name 仍是 ArkTS 编译器写入的原始值(通常是 "entry")。
                NSString *installedModuleJson = [self.arkuiXDirectory
                    stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/module.json", moduleName]];
                NSData *installedJsonData = [NSData dataWithContentsOfFile:installedModuleJson];
                if (installedJsonData) {
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:installedJsonData
                                                                         options:0
                                                                           error:nil];
                    NSLog(@"[HAPManager] Installed module.json: app.bundleName=%@, module.name=%@, module.mainElement=%@",
                          json[@"app"][@"bundleName"],
                          json[@"module"][@"name"],
                          json[@"module"][@"mainElement"]);
                } else {
                    NSLog(@"[HAPManager] ⚠️ module.json not found at %@", installedModuleJson);
                }

                // 确认 abc 文件确实存在于安装目录下。
                NSString *abcPath = [self.arkuiXDirectory
                    stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/ets/modules.abc", moduleName]];
                BOOL abcExists = [[NSFileManager defaultManager] fileExistsAtPath:abcPath];
                NSLog(@"[HAPManager] abc file at %@ exists=%d", abcPath, abcExists);
                if (!abcExists) {
                    // 退而检查 ets 目录下其他 .abc 文件(AbilityStage.abc 等)。
                    NSString *etsDir = [self.arkuiXDirectory
                        stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/ets", moduleName]];
                    NSArray *etsFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:etsDir error:nil];
                    NSLog(@"[HAPManager] ets dir contents: %@", etsFiles);
                    // abc 字节码缺失会让 AppMain::DispatchOnCreate 在 StageViewController.viewDidLoad 里崩,
                    // 提前拦截,把错误用红色文本展示而不是让 app 闪退。
                    completion(NO, [NSString stringWithFormat:@"abc bytecode not found at %@", abcPath]);
                    return;
                }

                // launchApplication 内部会注册 NSNotificationCenter observer、初始化 AppMain 单例、
                // 启动 ArkUI 虚拟机等全局副作用。重复调用会重复注册 observer 并二次初始化已存在的
                // 全局对象,直接崩溃。所以只在第一次加载 hap 时调用一次,后续 hap 切换只 configModule。
                if (!self.isArkUIRunning) {
                    NSLog(@"[HAPManager] First launchApplication, calling StageApplication.launchApplication...");
                    // launchApplication 最容易触发 abort,再装一次,确保我们的 handler 在最上层。
                    [self installCrashGuardForce:YES];

                    [StageApplication launchApplication];
                    self.isArkUIRunning = YES;
                    NSLog(@"[HAPManager] ArkUI runtime launched OK for bundle=%@ module=%@ ability=%@",
                          bundleName, moduleName, abilityName);

                    // 启动后立即重装,因为 launchApplication 内部初始化几乎肯定会覆盖 signal handler。
                    [self installCrashGuardForce:YES];
                } else {
                    NSLog(@"[HAPManager] ArkUI runtime already running, re-configured module only");
                }
#else
                NSLog(@"[HAPManager] HAS_ARKUI_X disabled, abc bytecode cannot be executed.");
#endif
                completion(YES, nil);
            } @catch (NSException *e) {
                NSLog(@"[HAPManager] ❌ loadHAP main-queue block crashed: %@\n%@", e, e.callStackSymbols);
                NSString *errMsg = [NSString stringWithFormat:@"loadHAP: %@\nReason: %@\n\nCallstack:\n%@",
                                    e.name ?: @"NSException",
                                    e.reason ?: @"(no reason)",
                                    [e.callStackSymbols componentsJoinedByString:@"\n"]];
                // 用全局独立 Window 展示红色报错(不闪退,点击复制)
                [self showGlobalError:errMsg shortText:@"报错"];
                completion(NO, errMsg);
            }
        });
    });
}

- (void)getHAPInfoFromPath:(NSString *)hapPath completion:(HAPInfoCompletion)completion {
    [self getHAPModuleInfoFromPath:hapPath completion:^(NSString *appName, NSString *bundleName,
                                                       NSString *moduleName, NSString *abilityName, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(appName, bundleName, error);
        });
    }];
}

- (void)getHAPModuleInfoFromPath:(NSString *)hapPath completion:(HAPModuleInfoCompletion)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *appName = [hapPath lastPathComponent];
        appName = [appName stringByReplacingOccurrencesOfString:@".hap" withString:@""];

        NSString *bundleName = kDefaultBundleName;
        NSString *moduleName = kDefaultModuleName;
        NSString *abilityName = kDefaultAbilityName;

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *tempDir = NSTemporaryDirectory();
        NSString *extractDir = [tempDir stringByAppendingPathComponent:@"hap_info_extract"];

        if ([fm fileExistsAtPath:extractDir]) {
            [fm removeItemAtPath:extractDir error:nil];
        }

        if ([self extractZIPFileAtPath:hapPath toDirectory:extractDir]) {
            NSDictionary *moduleInfo = [self parseModuleJsonInDirectory:extractDir];
            if (moduleInfo) {
                if (moduleInfo[@"appName"]) {
                    appName = moduleInfo[@"appName"];
                }
                if (moduleInfo[@"bundleName"]) {
                    bundleName = moduleInfo[@"bundleName"];
                }
                if (moduleInfo[@"moduleName"]) {
                    moduleName = moduleInfo[@"moduleName"];
                }
                if (moduleInfo[@"abilityName"]) {
                    abilityName = moduleInfo[@"abilityName"];
                }
            }
            [fm removeItemAtPath:extractDir error:nil];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(appName, bundleName, moduleName, abilityName, nil);
        });
    });
}

- (void)listAvailableHAPsInDirectory:(NSString *)directory completion:(HAPListCompletion)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *hapInfoList = [NSMutableArray array];
        NSFileManager *fm = [NSFileManager defaultManager];

        NSError *error = nil;
        NSArray *contents = [fm contentsOfDirectoryAtPath:directory error:&error];
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }

        for (NSString *item in contents) {
            if ([item hasSuffix:@".hap"]) {
                NSString *hapPath = [directory stringByAppendingPathComponent:item];

                NSString *appName = [item stringByReplacingOccurrencesOfString:@".hap" withString:@""];
                NSString *bundleName = kDefaultBundleName;
                NSString *moduleName = kDefaultModuleName;
                NSString *abilityName = kDefaultAbilityName;
                NSString *pageName = @"";

                NSString *tempDir = NSTemporaryDirectory();
                NSString *extractDir = [tempDir stringByAppendingPathComponent:@"hap_list_extract"];

                if ([fm fileExistsAtPath:extractDir]) {
                    [fm removeItemAtPath:extractDir error:nil];
                }

                if ([self extractZIPFileAtPath:hapPath toDirectory:extractDir]) {
                    NSDictionary *moduleInfo = [self parseModuleJsonInDirectory:extractDir];
                    if (moduleInfo) {
                        if (moduleInfo[@"appName"]) {
                            appName = moduleInfo[@"appName"];
                        }
                        if (moduleInfo[@"bundleName"]) {
                            bundleName = moduleInfo[@"bundleName"];
                        }
                        if (moduleInfo[@"moduleName"]) {
                            moduleName = moduleInfo[@"moduleName"];
                        }
                        if (moduleInfo[@"abilityName"]) {
                            abilityName = moduleInfo[@"abilityName"];
                        }
                        if ([moduleInfo[@"pageName"] length] > 0) {
                            pageName = moduleInfo[@"pageName"];
                        }
                    }
                    [fm removeItemAtPath:extractDir error:nil];
                }

                NSMutableDictionary *hapInfo = [@{
                    @"path": hapPath,
                    @"appName": appName,
                    @"bundleName": bundleName,
                    @"moduleName": moduleName,
                    @"abilityName": abilityName
                } mutableCopy];
                // pageName 可选,只在解析到 srcEntry 时存在,用于在列表副标题展示入口界面名。
                if (pageName.length > 0) {
                    hapInfo[@"pageName"] = pageName;
                }
                [hapInfoList addObject:hapInfo];
            }
        }

        NSArray *sortedList = [hapInfoList sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
            NSString *name1 = obj1[@"appName"];
            NSString *name2 = obj2[@"appName"];
            return [name1 localizedStandardCompare:name2];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(sortedList, nil);
        });
    });
}

#pragma mark - Foreground / Background

// 检查当前导航栈顶部的 VC 是否是 HAPPlayerViewController(StageViewController 子类)。
// StageApplication callCurrentAbilityOnForeground/Background 内部会取 topVC 并调用 instanceName,
// 如果 topVC 不是 StageViewController(比如列表页 HAPViewController),会触发
// unrecognized selector instanceName 崩溃。这里提前拦截。
// 注意:不能用 respondsToSelector:@selector(instanceName) 判断,因为 HAPViewController
// 也实现了 instanceName(返回 nil)来防止 ArkUI-X 内部异步调用的崩溃,所以改用 isKindOfClass。
- (BOOL)_isStageViewControllerOnTop {
    UIWindow *keyWindow = nil;
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *win in scene.windows) {
            if (win.isKeyWindow) { keyWindow = win; break; }
        }
        if (keyWindow) break;
    }
    if (!keyWindow) return NO;

    UIViewController *topVC = keyWindow.rootViewController;
    if ([topVC isKindOfClass:[UINavigationController class]]) {
        topVC = ((UINavigationController *)topVC).topViewController;
    }
    return [topVC isKindOfClass:[HAPPlayerViewController class]];
}

- (void)callCurrentAbilityOnForeground {
#if HAS_ARKUI_X
    if (![self _isStageViewControllerOnTop]) {
        NSLog(@"[HAPManager] skip callCurrentAbilityOnForeground: topVC is not StageViewController");
        return;
    }
    [StageApplication callCurrentAbilityOnForeground];
#endif
}

- (void)callCurrentAbilityOnBackground {
#if HAS_ARKUI_X
    if (![self _isStageViewControllerOnTop]) {
        NSLog(@"[HAPManager] skip callCurrentAbilityOnBackground: topVC is not StageViewController");
        return;
    }
    [StageApplication callCurrentAbilityOnBackground];
#endif
}

- (void)unloadCurrentHAP {
#if HAS_ARKUI_X
    // 销毁当前所有 StageViewController 关联的 ability,以便下一次加载 hap 时
    // 新的 abc 字节码可以干净地加载。
    //
    // 注意 1:这里不调用 destroyVm。destroyVm 会销毁 ArkTS 虚拟机,但 StageApplication
    // 的 launchApplication 只能调一次(内部会重复注册 NotificationCenter observer 并二次
    // 初始化 AppMain 单例导致崩溃)。VM 销毁后无法重建,新 hap 的 abc 就无法运行。
    // 因此 hap 切换的正确做法是:保留 VM,只 releaseViewControllers + configModule 重载 abc。
    //
    // 注意 2:releaseViewControllers 这个 selector 虽然在 StageApplication.h 源码里声明了,
    // 但官方 SDK(libarkui_ios.xcframework)的公开导出 Headers 中并未包含它。为了保证 CI
    // 使用预编译 framework 时也能编过,这里改为 performSelector 动态调用,并通过
    // respondsToSelector 做运行时保护。
    StageApplication *shared = [StageApplication class];
    if ([shared respondsToSelector:@selector(releaseViewControllers)]) {
        [shared performSelector:@selector(releaseViewControllers)];
    }
#endif

    NSFileManager *fm = [NSFileManager defaultManager];

    NSError *error = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:self.arkuiXDirectory error:&error];
    if (contents) {
        for (NSString *item in contents) {
            NSString *path = [self.arkuiXDirectory stringByAppendingPathComponent:item];
            [fm removeItemAtPath:path error:nil];
        }
    }

    self.currentHAPPath = nil;
    self.currentBundleName = nil;
    self.currentModuleName = nil;
    self.currentAbilityName = nil;
    self.currentAppName = nil;
    self.currentPageName = nil;
    // 注意:这里不重置 isArkUIRunning=NO。因为 StageApplication launchApplication 只能调一次,
    // 重复调用会重复注册 NotificationCenter observer 并二次初始化 AppMain 单例导致崩溃。
    // isArkUIRunning 保持 YES,后续 loadHAP 只走 configModule 路径重载新 hap 的 abc 字节码。
}

#pragma mark - ZIP extract helpers

// ---- 纯 C ZIP 解压(libz),不依赖 /usr/bin/unzip(iOS 真机不存在该命令) ----
// ZIP 文件格式:
//   - Local File Header(0x04034b50)+ 压缩数据,每个文件一个
//   - Central Directory(0x02014b50),每个文件一个条目
//   - End of Central Directory Record(0x06054b50),文件末尾
// 压缩方式:0=Stored(无压缩),8=Deflate( zlib inflate 解压)

#define ZIP_LOCAL_HEADER_SIG  0x04034b50
#define ZIP_CENTRAL_DIR_SIG   0x02014b50
#define ZIP_END_CENTRAL_SIG   0x06054b50

// 读取小端 32 位整数
static uint32_t zip_read32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// 读取小端 16 位整数
static uint16_t zip_read16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

// 用 libz 解压 deflate 数据到输出 buffer
static BOOL zip_inflate_data(const uint8_t *src, size_t srcLen, NSMutableData *dest) {
    z_stream strm;
    memset(&strm, 0, sizeof(strm));

    // -15: raw deflate(无 zlib header),MAX_WBITS
    if (inflateInit2(&strm, -15) != Z_OK) {
        return NO;
    }

    strm.next_in = (Bytef *)src;
    strm.avail_in = (uInt)srcLen;

    // 分块解压
    uint8_t buf[16384];
    int ret;
    do {
        strm.next_out = buf;
        strm.avail_out = sizeof(buf);
        ret = inflate(&strm, Z_NO_FLUSH);
        if (ret != Z_OK && ret != Z_STREAM_END) {
            inflateEnd(&strm);
            return NO;
        }
        size_t written = sizeof(buf) - strm.avail_out;
        [dest appendBytes:buf length:written];
    } while (ret != Z_STREAM_END);

    inflateEnd(&strm);
    return YES;
}

// 纯 C ZIP 解压:从 NSData 解压所有文件到 destDir
static BOOL zip_extract_nsdata(NSData *zipData, NSString *destDir) {
    const uint8_t *bytes = (const uint8_t *)zipData.bytes;
    size_t totalLen = zipData.length;
    if (totalLen < 22) return NO; // EOCD 最小 22 字节

    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. 从文件末尾查找 EOCD(End of Central Directory Record)
    //    签名 0x06054b50,从末尾往前搜索(最多搜索 64KB + 22 字节)
    size_t scanStart = totalLen > 65557 ? totalLen - 65557 : 0;
    size_t eocdOffset = 0;
    BOOL foundEOCD = NO;
    for (size_t i = totalLen - 22; i >= scanStart; i--) {
        if (zip_read32(bytes + i) == ZIP_END_CENTRAL_SIG) {
            eocdOffset = i;
            foundEOCD = YES;
            break;
        }
    }
    if (!foundEOCD) {
        NSLog(@"[HAPManager] ZIP extract: EOCD not found");
        return NO;
    }

    // 2. 从 EOCD 读取 Central Directory 偏移和条目数
    const uint8_t *eocd = bytes + eocdOffset;
    uint16_t numEntries = zip_read16(eocd + 10);
    uint32_t cdOffset = zip_read32(eocd + 16);

    if (cdOffset >= totalLen) {
        NSLog(@"[HAPManager] ZIP extract: invalid CD offset %u", cdOffset);
        return NO;
    }

    // 3. 遍历 Central Directory 条目
    size_t offset = cdOffset;
    for (uint16_t i = 0; i < numEntries; i++) {
        if (offset + 46 > totalLen) break;
        const uint8_t *cd = bytes + offset;
        if (zip_read32(cd) != ZIP_CENTRAL_DIR_SIG) break;

        uint16_t compressionMethod = zip_read16(cd + 10);
        uint32_t compressedSize = zip_read32(cd + 20);
        uint32_t uncompressedSize = zip_read32(cd + 24);
        uint16_t fileNameLen = zip_read16(cd + 28);
        uint16_t extraFieldLen = zip_read16(cd + 30);
        uint16_t fileCommentLen = zip_read16(cd + 32);
        uint32_t localHeaderOffset = zip_read32(cd + 42);

        // 文件名
        char fileName[1024];
        size_t nameLen = fileNameLen < sizeof(fileName) - 1 ? fileNameLen : sizeof(fileName) - 1;
        memcpy(fileName, cd + 46, nameLen);
        fileName[nameLen] = '\0';

        // 跳到下一个 CD 条目
        offset += 46 + fileNameLen + extraFieldLen + fileCommentLen;

        // 跳过目录条目(以 / 结尾)
        if (nameLen > 0 && fileName[nameLen - 1] == '/') continue;

        // 构建输出路径(防止路径穿越)
        NSString *entryName = [NSString stringWithUTF8String:fileName];
        if ([entryName containsString:@".."]) continue; // 安全:跳过路径穿越
        NSString *outPath = [destDir stringByAppendingPathComponent:entryName];

        // 创建父目录
        NSString *parentDir = [outPath stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:nil];

        // 4. 读取 Local File Header 获取数据偏移
        if (localHeaderOffset + 30 > totalLen) continue;
        const uint8_t *lh = bytes + localHeaderOffset;
        if (zip_read32(lh) != ZIP_LOCAL_HEADER_SIG) continue;

        uint16_t lhFileNameLen = zip_read16(lh + 26);
        uint16_t lhExtraFieldLen = zip_read16(lh + 28);
        size_t dataOffset = localHeaderOffset + 30 + lhFileNameLen + lhExtraFieldLen;

        if (dataOffset + compressedSize > totalLen) continue;

        // 5. 解压数据
        const uint8_t *compData = bytes + dataOffset;
        if (compressionMethod == 0) {
            // Stored(无压缩)
            [fm createFileAtPath:outPath contents:nil attributes:nil];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:outPath];
            if (fh) {
                [fh writeData:[NSData dataWithBytes:compData length:compressedSize]];
                [fh closeFile];
            }
        } else if (compressionMethod == 8) {
            // Deflate
            NSMutableData *dest = [NSMutableData dataWithCapacity:uncompressedSize > 0 ? uncompressedSize : 4096];
            if (zip_inflate_data(compData, compressedSize, dest)) {
                [fm createFileAtPath:outPath contents:dest attributes:nil];
            } else {
                NSLog(@"[HAPManager] ZIP extract: inflate failed for %s", fileName);
            }
        } else {
            NSLog(@"[HAPManager] ZIP extract: unsupported compression method %d for %s", compressionMethod, fileName);
        }
    }

    NSLog(@"[HAPManager] ZIP extract: completed, %u entries processed", numEntries);
    return YES;
}

- (BOOL)extractZIPFileAtPath:(NSString *)zipPath toDirectory:(NSString *)destDir {
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil]) {
        return NO;
    }

    // 优先用 /usr/bin/unzip(模拟器上更快,且能处理一些边缘情况)。
    // 失败或不可用时回退到纯 C libz 解压(真机兼容)。
    BOOL useUnzip = NO;
    if ([fm fileExistsAtPath:@"/usr/bin/unzip"]) {
        NSString *unzipPath = [destDir stringByAppendingPathComponent:@"unzip_tmp"];
        [fm createDirectoryAtPath:unzipPath withIntermediateDirectories:YES attributes:nil error:nil];

        const char *args[] = {"/usr/bin/unzip", "-q", "-o", [zipPath UTF8String], "-d", [unzipPath UTF8String], NULL};
        pid_t pid;
        int status = 0;
        int spawnRet = posix_spawn(&pid, "/usr/bin/unzip", NULL, NULL, (char * const *)args, NULL);
        if (spawnRet == 0) {
            waitpid(pid, &status, 0);
            if (WEXITSTATUS(status) == 0) {
                // unzip 成功,把内容移到 destDir
                if ([self moveExtractedContentsFrom:unzipPath to:destDir]) {
                    [fm removeItemAtPath:unzipPath error:nil];
                    useUnzip = YES;
                }
            }
        }
        [fm removeItemAtPath:unzipPath error:nil];
    }

    if (useUnzip) {
        NSLog(@"[HAPManager] ZIP extracted via /usr/bin/unzip");
        return YES;
    }

    // 回退:纯 C libz 解压(真机或 unzip 不可用时)
    NSLog(@"[HAPManager] Falling back to libz ZIP extraction");
    NSData *zipData = [NSData dataWithContentsOfFile:zipPath];
    if (!zipData) {
        NSLog(@"[HAPManager] Failed to read ZIP file at %@", zipPath);
        return NO;
    }

    BOOL ok = zip_extract_nsdata(zipData, destDir);
    if (!ok) {
        NSLog(@"[HAPManager] libz ZIP extraction failed for %@", zipPath);
    }
    return ok;
}

- (BOOL)moveExtractedContentsFrom:(NSString *)sourceDir to:(NSString *)destDir {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSError *error = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:sourceDir error:&error];
    if (!contents || error) {
        return NO;
    }

    for (NSString *item in contents) {
        NSString *sourcePath = [sourceDir stringByAppendingPathComponent:item];
        NSString *destPath = [destDir stringByAppendingPathComponent:item];

        if ([fm fileExistsAtPath:destPath]) {
            [fm removeItemAtPath:destPath error:nil];
        }

        if (![fm moveItemAtPath:sourcePath toPath:destPath error:&error]) {
            return NO;
        }
    }

    return YES;
}

#pragma mark - module.json / module.json5 parsing

// 在 hap 解压目录中定位 module.json 或 module.json5(优先 module.json,因为它是 ArkTS 编译产物;
// module.json5 是源码格式,可能含注释、尾随逗号等 JSON5 扩展语法,某些 hap 解压后只保留 module.json5)。
// 文件可能在根目录,也可能在 entry/ 子目录下。解析出:
//   bundleName(来自 app.bundleName)
//   moduleName(来自 module.name)
//   abilityName(取 module.abilities[0].name 或 module.mainElement)
//   appName(展示名,优先级:abilities[0].label 字符串 > module.name > bundleName)
//   pageName(入口界面名,取 abilities[0].srcEntry 末尾文件名,如 "Index")
- (NSDictionary *)parseModuleJsonInDirectory:(NSString *)extractDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    // 候选路径:依次尝试 根目录/module.json、根目录/module.json5、entry/module.json、entry/module.json5。
    NSArray<NSString *> *candidates = @[
        [extractDir stringByAppendingPathComponent:@"module.json"],
        [extractDir stringByAppendingPathComponent:@"module.json5"],
        [[extractDir stringByAppendingPathComponent:@"entry"] stringByAppendingPathComponent:@"module.json"],
        [[extractDir stringByAppendingPathComponent:@"entry"] stringByAppendingPathComponent:@"module.json5"],
    ];

    NSString *moduleJsonPath = nil;
    BOOL isJson5 = NO;
    for (NSString *candidate in candidates) {
        if ([fm fileExistsAtPath:candidate]) {
            moduleJsonPath = candidate;
            isJson5 = [candidate hasSuffix:@".json5"];
            break;
        }
    }

    // 兜底:某些 hap 打包时把内容放在顶层目录下(如 entry-default-unsigned/),
    // 解压后 module.json5 不在根目录也不在 entry/ 下,而是在该顶层目录内。
    // 递归搜索整个解压目录,找到第一个 module.json 或 module.json5。
    if (!moduleJsonPath) {
        NSArray<NSString *> *allSubpaths = [fm subpathsOfDirectoryAtPath:extractDir error:nil];
        for (NSString *subpath in allSubpaths) {
            if ([subpath hasSuffix:@"/module.json"] || [subpath hasSuffix:@"/module.json5"]
                || [subpath isEqualToString:@"module.json"] || [subpath isEqualToString:@"module.json5"]) {
                // 排除 resources/ 下的同名文件(如 resources/base/profile/module.json)
                if ([subpath containsString:@"resources/"]) continue;
                moduleJsonPath = [extractDir stringByAppendingPathComponent:subpath];
                isJson5 = [moduleJsonPath hasSuffix:@".json5"];
                NSLog(@"[HAPManager] Found module config via recursive search: %@", moduleJsonPath);
                break;
            }
        }
    }

    if (!moduleJsonPath) {
        NSLog(@"[HAPManager] module.json/module.json5 not found in any candidate path or recursively under %@", extractDir);
        return nil;
    }

    NSData *rawData = [NSData dataWithContentsOfFile:moduleJsonPath];
    if (!rawData) {
        NSLog(@"[HAPManager] Failed to read data from %@", moduleJsonPath);
        return nil;
    }

    // module.json5 是 JSON5 格式,可能含 // 行注释、/* */ 块注释、尾随逗号,
    // NSJSONSerialization 不支持,需要先剥离这些扩展语法再解析。
    NSData *jsonData = rawData;
    if (isJson5) {
        // 优先尝试 UTF-8,失败则尝试 UTF-16(某些 Windows 构建工具可能输出 UTF-16 BOM)。
        NSString *json5String = [[NSString alloc] initWithData:rawData encoding:NSUTF8StringEncoding];
        if (!json5String) {
            json5String = [[NSString alloc] initWithData:rawData encoding:NSUTF16StringEncoding];
            NSLog(@"[HAPManager] module.json5 was not UTF-8, retrying with UTF-16");
        }
        if (!json5String) {
            NSLog(@"[HAPManager] Failed to decode module.json5 as UTF-8 or UTF-16");
            return nil;
        }
        NSString *stripped = [self stripJson5Comments:json5String];
        if (stripped.length == 0) {
            NSLog(@"[HAPManager] stripJson5Comments returned empty string for %@", moduleJsonPath);
            return nil;
        }
        jsonData = [stripped dataUsingEncoding:NSUTF8StringEncoding];
        if (!jsonData) {
            NSLog(@"[HAPManager] Failed to encode stripped JSON5 to UTF-8");
            return nil;
        }
    }

    NSError *error = nil;
    NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    if (error || ![jsonDict isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[HAPManager] Failed to parse %@: %@", moduleJsonPath, error.localizedDescription);
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    // 记录 module.json5 所在目录,作为 hap 内容根目录,
    // 供 loadHAPAtPath 用于 installExtractedFilesFrom 和 containsAbcBytecodeInDirectory。
    NSString *contentRoot = [moduleJsonPath stringByDeletingLastPathComponent];
    result[@"_contentRoot"] = contentRoot;

    NSDictionary *appObj = jsonDict[@"app"];
    NSDictionary *moduleObj = jsonDict[@"module"];
    if (![moduleObj isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    if ([appObj isKindOfClass:[NSDictionary class]]) {
        NSString *bundleName = appObj[@"bundleName"];
        if ([bundleName isKindOfClass:[NSString class]] && bundleName.length > 0) {
            result[@"bundleName"] = bundleName;
        }
    }

    NSString *moduleName = moduleObj[@"name"];
    if ([moduleName isKindOfClass:[NSString class]] && moduleName.length > 0) {
        result[@"moduleName"] = moduleName;
    }

    NSString *mainElement = moduleObj[@"mainElement"];
    if ([mainElement isKindOfClass:[NSString class]] && mainElement.length > 0) {
        result[@"abilityName"] = mainElement;
    }

    // 优先从 abilities 数组中取第一个 ability 名,作为运行 abc 的真实入口;
    // 同时从中提取 label(应用展示名)和 srcEntry(入口界面文件路径)。
    NSArray *abilities = moduleObj[@"abilities"];
    if ([abilities isKindOfClass:[NSArray class]] && abilities.count > 0) {
        NSDictionary *firstAbility = abilities[0];
        if ([firstAbility isKindOfClass:[NSDictionary class]]) {
            NSString *abilityName = firstAbility[@"name"];
            if ([abilityName isKindOfClass:[NSString class]] && abilityName.length > 0) {
                result[@"abilityName"] = abilityName;
            }

            // 应用展示名:优先取 label(若为 $string:xxx 资源引用,无法解析则回退到 moduleName)。
            // 这里只接受纯字符串 label,$string:app_name 这种引用资源无法在 iOS 侧解析资源表,
            // 直接保留为字符串透传给上层,上层可选择性展示。
            NSString *label = firstAbility[@"label"];
            if ([label isKindOfClass:[NSString class]] && label.length > 0) {
                result[@"appName"] = label;
            }

            // 入口界面文件路径(如 "./ets/pages/Index.ets"),取末尾文件名作为 pageName。
            // 这是 hap 编译时 ArkTS 编译器写入的真实页面入口,用于在播放界面顶部展示当前渲染的页面。
            NSString *srcEntry = firstAbility[@"srcEntry"];
            if ([srcEntry isKindOfClass:[NSString class]] && srcEntry.length > 0) {
                NSString *pageName = [self pageNameFromSrcEntry:srcEntry];
                if (pageName.length > 0) {
                    result[@"pageName"] = pageName;
                }
            }
        }
    }

    // appName 兜底:如果 abilities 里没取到 label,用 moduleName 作为展示名。
    if (!result[@"appName"]) {
        if (result[@"moduleName"]) {
            result[@"appName"] = result[@"moduleName"];
        } else if (result[@"bundleName"]) {
            result[@"appName"] = result[@"bundleName"];
        }
    }

    // 兜底默认值,保证后续拼接 instanceName 不会因为缺字段而失败。
    if (!result[@"bundleName"]) {
        result[@"bundleName"] = kDefaultBundleName;
    }
    if (!result[@"moduleName"]) {
        result[@"moduleName"] = kDefaultModuleName;
    }
    if (!result[@"abilityName"]) {
        result[@"abilityName"] = kDefaultAbilityName;
    }

    // 保存原始解析对象,供 postInstallSetup 合成 AppScope/app.json 等辅助用途。
    if (appObj) result[@"_appObj"]    = appObj;
    if (moduleObj) result[@"_moduleObj"] = moduleObj;

    NSLog(@"[HAPManager] Parsed %@: bundleName=%@ moduleName=%@ abilityName=%@ appName=%@ pageName=%@",
          moduleJsonPath.lastPathComponent,
          result[@"bundleName"], result[@"moduleName"], result[@"abilityName"],
          result[@"appName"], result[@"pageName"] ?: @"(none)");

    return result;
}

// 剥离 JSON5 扩展语法:行注释 //、块注释 /* */、尾随逗号(},] 前的多余逗号)。
// 同时保留字符串字面量内的注释标记不被误删。这是 JSON5 → JSON 的最小可行转换,
// 不处理十六进制/Inf/NaN 等更激进的扩展(hap 内 module.json5 一般不会用到)。
- (NSString *)stripJson5Comments:(NSString *)json5 {
    if (json5.length == 0) {
        return json5;
    }

    NSUInteger length = json5.length;
    NSMutableString *result = [NSMutableString stringWithCapacity:length];

    // 用 unichar 逐字符扫描,状态机区分:普通、字符串内、行注释、块注释。
    enum { StateNormal, StateString, StateLineComment, StateBlockComment } state = StateNormal;
    unichar prev = 0;
    BOOL stringEscape = NO;

    for (NSUInteger i = 0; i < length; i++) {
        unichar ch = [json5 characterAtIndex:i];
        unichar next = (i + 1 < length) ? [json5 characterAtIndex:i + 1] : 0;

        switch (state) {
            case StateNormal:
                if (ch == '"') {
                    [result appendFormat:@"%C", ch];
                    state = StateString;
                    stringEscape = NO;
                } else if (ch == '/' && next == '/') {
                    state = StateLineComment;
                    i++; // 跳过下一个 '/'
                } else if (ch == '/' && next == '*') {
                    state = StateBlockComment;
                    i++; // 跳过 '*'
                } else {
                    [result appendFormat:@"%C", ch];
                }
                break;
            case StateString:
                [result appendFormat:@"%C", ch];
                if (stringEscape) {
                    stringEscape = NO;
                } else if (ch == '\\') {
                    stringEscape = YES;
                } else if (ch == '"') {
                    state = StateNormal;
                }
                break;
            case StateLineComment:
                // 行注释直到 \n,保留换行符避免行号变化影响报错信息。
                if (ch == '\n') {
                    [result appendFormat:@"%C", ch];
                    state = StateNormal;
                }
                break;
            case StateBlockComment:
                // 块注释到 */ 结束,块注释整体替换为一个空格避免 token 粘连。
                if (prev == '*' && ch == '/') {
                    [result appendString:@" "];
                    state = StateNormal;
                }
                break;
        }
        prev = ch;
    }

    // 移除尾随逗号:}, ] 前的多余逗号,NSJSONSerialization 在严格模式下不接受。
    // 用正则把 ",\s*}" 替换为 "}",",\s*]" 替换为 "]"。
    NSError *regexError = nil;
    NSRegularExpression *trailingCommaObj =
        [NSRegularExpression regularExpressionWithPattern:@",\\s*\\}" options:0 error:&regexError];
    if (!regexError) {
        result = [[trailingCommaObj stringByReplacingMatchesInString:result
                                                              options:0
                                                                range:NSMakeRange(0, result.length)
                                                         withTemplate:@"}"] mutableCopy];
    }
    NSRegularExpression *trailingCommaArr =
        [NSRegularExpression regularExpressionWithPattern:@",\\s*\\]" options:0 error:&regexError];
    if (!regexError) {
        result = [[trailingCommaArr stringByReplacingMatchesInString:result
                                                              options:0
                                                                range:NSMakeRange(0, result.length)
                                                         withTemplate:@"]"] mutableCopy];
    }

    return result;
}

// 从 srcEntry(如 "./ets/pages/Index.ets" 或 "./ets/pages/Index")提取页面名 "Index"。
// 取最后一段路径,再去掉扩展名。
- (NSString *)pageNameFromSrcEntry:(NSString *)srcEntry {
    if (srcEntry.length == 0) {
        return @"";
    }
    NSString *lastComponent = [srcEntry lastPathComponent];
    // 去掉扩展名(如果有)。
    NSString *ext = [lastComponent pathExtension];
    if (ext.length > 0) {
        lastComponent = [lastComponent stringByDeletingPathExtension];
    }
    return lastComponent ?: @"";
}

// 检查解压目录中是否包含 ArkTS 编译产物 abc 字节码文件,这是 hap 能否被运行的关键依据。
- (BOOL)containsAbcBytecodeInDirectory:(NSString *)directory {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:directory];
    for (NSString *file in enumerator) {
        if ([file hasSuffix:@".abc"]) {
            return YES;
        }
    }
    return NO;
}

// 安装后执行:合成 AppScope/app.json(若缺失)、检查 resources.index 等关键文件、打印完整诊断。
// 注:AppScope/app.json 是 ArkUI-X SDK 的 LaunchApplication 期望读取的应用信息文件,
// 缺失时 SDK 可能不报错但无法正常解析 Ability 入口,导致白屏。
- (void)postInstallSetupForBundleName:(NSString *)bundleName
                           moduleName:(NSString *)moduleName
                              appName:(NSString *)appName
                     arkuiXDirectory:(NSString *)arkuiXDirectory
                        parsedAppObj:(NSDictionary *)parsedAppObj {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *moduleDir = [arkuiXDirectory stringByAppendingPathComponent:moduleName];

    // ---- 1. 关键文件存在性诊断 ----
    NSString *resourcesIndexPath = [moduleDir stringByAppendingPathComponent:@"resources.index"];
    NSString *packInfoPath       = [moduleDir stringByAppendingPathComponent:@"pack.info"];
    NSString *pkgContextInfoPath = [moduleDir stringByAppendingPathComponent:@"pkgContextInfo.json"];
    NSString *resourcesDir       = [moduleDir stringByAppendingPathComponent:@"resources"];

    BOOL hasResourcesIndex = [fm fileExistsAtPath:resourcesIndexPath];
    BOOL hasPackInfo       = [fm fileExistsAtPath:packInfoPath];
    BOOL hasPkgContextInfo = [fm fileExistsAtPath:pkgContextInfoPath];
    BOOL hasResourcesDir   = [fm fileExistsAtPath:resourcesDir];

    NSLog(@"[HAPManager] ========== Post-Install Diagnostics ==========");
    NSLog(@"[HAPManager] bundleName=%@ moduleName=%@ abilityName=%@", bundleName, moduleName, appName);
    NSLog(@"[HAPManager] moduleDir=%@", moduleDir);
    NSLog(@"[HAPManager] resources.index exists=%d path=%@", hasResourcesIndex, resourcesIndexPath);
    NSLog(@"[HAPManager] pack.info       exists=%d path=%@", hasPackInfo, packInfoPath);
    NSLog(@"[HAPManager] pkgContextInfo  exists=%d path=%@", hasPkgContextInfo, pkgContextInfoPath);
    NSLog(@"[HAPManager] resources/ dir  exists=%d path=%@", hasResourcesDir, resourcesDir);

    if (!hasResourcesIndex) {
        NSLog(@"[HAPManager] ⚠️  WARNING: resources.index 缺失!");
        NSLog(@"[HAPManager]    module.json 中 pages=\"$profile:main_pages\" 需要通过 resources.index 做资源索引,");
        NSLog(@"[HAPManager]    没有该文件 SDK 内部 AssetResolver 无法将 $profile:main_pages 解析为 resources/base/profile/main_pages.json,");
        NSLog(@"[HAPManager]    最终 EntryAbility 启动后找不到页面 → 白屏不渲染。");
        NSLog(@"[HAPManager]    修复:请使用真正打包出的 .hap (运行 DevEco Build HAP / hvigor assembleHap),");
        NSLog(@"[HAPManager]    而不是将 entry-default-unsigned/ 中间产物目录直接打包。");
    }

    // ---- 1b. 跨平台模块兼容性 shim ----
    //
    // 用户在 HarmonyOS(华为手机)上的 hap 常常引用:
    //   - @hms:hds.* 系列 (HMS 设计系统 HDS 组件,仅 HarmonyOS 端闭源实现)
    //   - @ohos:arkui.node 等 (某些 OHOS 专有模块,iOS/Android 端未编译进 SDK)
    // 这些模块在 ArkUI-X iOS runtime 中:
    //   - 要么完全没注册 NAPI 模块 (ModuleResolver 返回 undefined)
    //   - 要么注册了但 abc 字节目录为空 (export objects of native so is undefined)
    // 最终引发 SyntaxError: "the requested module '@hms:hds.hdsBaseComponent' does not provide an
    // export name 'HdsNavigation' which imported by '&entry/src/main/ets/pages/Index&'"
    // 这是 ES Module 的静态 import 校验失败, 属于 abc 解析阶段的 SyntaxError, 发生在任何
    // 运行时代码之前, 无法通过 try/catch 捕获, 必须从模块层面让 import 解析到正确的导出。
    //
    // 处理方法:
    //   1. 扫描所有 abc 文件中 import 的字符串明文 (abc 字节码中的 import specifier 和
    //      imported binding 名都是 UTF-8 明文存储), 找出需要的模块和每个模块下需要导出
    //      的标识符名。
    //   2. 对 @hms:* / @ohos:* (非 @ohos:arkui 等基础模块) 这些在 iOS 端常见未实现的模块,
    //      生成一个 JS shim, 用 export const/class/function 把所有被 import 的名字全部
    //      导出为空占位, 然后写到 <moduleDir>/ets/modules/@hms/hds/hdsBaseComponent.ets
    //      (命名空间冒号后部分转换为路径, "." 作为路径分隔)。
    //   3. ArkUI-X 的 ModuleResolver 解析 @hms:hds.hdsBaseComponent 时, 会先在
    //      ets/modules/ 下按路径查找本地模块文件, 命中后用该文件替换 native module,
    //      import 校验通过, SyntaxError 消失。
    //   4. UI 运行时 HDS 组件会渲染成空视图(占位), 但不会崩溃。
    {
        NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *moduleToImports =
            [NSMutableDictionary dictionary];
        // 遍历 module 下所有 .abc 文件
        NSString *etsDir = [moduleDir stringByAppendingPathComponent:@"ets"];
        NSArray *allSubpaths = [fm subpathsOfDirectoryAtPath:moduleDir error:nil];
        NSMutableArray<NSString *> *abcPaths = [NSMutableArray array];
        for (NSString *rel in allSubpaths) {
            if ([rel.pathExtension isEqualToString:@"abc"]) {
                [abcPaths addObject:[moduleDir stringByAppendingPathComponent:rel]];
            }
        }
        NSLog(@"[HAPManager] Shim: scanning %lu abc files for imports", (unsigned long)abcPaths.count);

        for (NSString *abcPath in abcPaths) {
            NSData *abcData = [NSData dataWithContentsOfFile:abcPath options:0 error:nil];
            if (abcData.length < 16) { continue; }
            const unsigned char *bytes = (const unsigned char *)abcData.bytes;
            const NSUInteger len = abcData.length;
            // 滑动窗口扫字符串: 在 PANDA 文件中, 字符串是 \0 结尾的 UTF-8。
            // 我们需要提取形如 "@hms:hds.hdsBaseComponent"、"@ohos:xxx" 的模块名,
            // 以及紧跟在这些模块 import 记录中的绑定名 (HdsNavigation 等标识符)。
            NSUInteger i = 0;
            while (i < len) {
                // 找模块 specifier 前缀 "@"
                if (bytes[i] != '@') { i++; continue; }
                NSUInteger start = i;
                NSUInteger j = i;
                while (j < len &&
                       bytes[j] >= 0x20 && bytes[j] < 0x7F &&
                       bytes[j] != '\0' && bytes[j] != '"' && bytes[j] != '\'' &&
                       bytes[j] != ' '  && bytes[j] != '\n' && bytes[j] != '\r' &&
                       bytes[j] != '\t') {
                    j++;
                }
                if (j == start) { i++; continue; }
                NSData *strData = [NSData dataWithBytesNoCopy:(void *)(bytes + start)
                                                       length:j - start freeWhenDone:NO];
                NSString *s = [[NSString alloc] initWithData:strData encoding:NSUTF8StringEncoding];
                if (s.length == 0) { i = j + 1; continue; }
                i = j + 1;
                // 过滤有效模块名: 必须是 "@hms:" 或 "@ohos:" 前缀,且包含 ":" (命名空间分隔符)
                if (!([s hasPrefix:@"@hms:"] || [s hasPrefix:@"@ohos:"]) || ![s containsString:@":"]) {
                    continue;
                }
                // 忽略内部模块前缀 "@ohos.abilityAccessCtrl" 等非命名空间格式
                NSRange colon = [s rangeOfString:@":"];
                if (colon.location == NSNotFound) { continue; }
                NSString *nsPart = [s substringToIndex:colon.location + 1]; // "@hms:" / "@ohos:"
                NSString *modPart = [s substringFromIndex:colon.location + 1];
                if (modPart.length == 0) { continue; }

                // 基本白名单: 这些基础模块 iOS SDK 的 NAPI 模块都实现完整,不生成 shim,避免覆盖正确实现。
                // 其他比如 "@ohos:arkui.node"、所有 "@hms:*" 都是有问题的候选。
                static NSArray<NSString *> *whitelistPrefixes = nil;
                static dispatch_once_t onceTok;
                dispatch_once(&onceTok, ^{
                    whitelistPrefixes = @[
                        // hilog / resourceManager / i18n 等常见 API, SDK 插件已完整实现
                        @"@ohos:hilog",
                        @"@ohos:resourceManager",
                        @"@ohos:i18n",
                        @"@ohos:util",
                        @"@ohos:file.fs",
                        @"@ohos:data_preferences",
                        @"@ohos:buffer",
                        @"@ohos:url",
                        @"@ohos:uri",
                        @"@ohos:timer",
                        @"@ohos:deviceInfo",
                        @"@ohos:convertxml",
                        @"@ohos:xml",
                        @"@ohos:zlib",
                        @"@ohos:web.webview",
                        @"@ohos:worker",
                        @"@ohos:net.http",
                        @"@ohos:net.socket",
                        @"@ohos:nfc.cardEmulation",
                        // 跨平台 UI 组件
                        @"@arkui-x",
                    ];
                });
                BOOL skip = NO;
                for (NSString *pref in whitelistPrefixes) {
                    if ([s hasPrefix:pref]) { skip = YES; break; }
                }
                if (skip) { continue; }

                // 为该模块在 moduleToImports 中创建条目
                if (!moduleToImports[s]) {
                    moduleToImports[s] = [NSMutableSet set];
                }

                // 向后(从 j 开始)扫附近的字符串,收集与这个模块 import 相关的标识符名。
                // 在 PANDA abc 的 literal/string sections 里, import specifier 后紧跟着 import binding。
                // 做一个窗口 512 字节内的字符串收集, 合法标识符 ([A-Za-z_$][A-Za-z0-9_$]*).
                NSMutableString *tok = [NSMutableString string];
                for (NSUInteger k = j + 1; k < MIN(len, j + 1024); k++) {
                    unsigned char c = bytes[k];
                    if (c == '\0') {
                        if (tok.length >= 1) {
                            // 过滤掉关键字和常见非 binding 名
                            if (![tok isEqualToString:@"default"] &&
                                ![tok isEqualToString:@"null"] &&
                                ![tok isEqualToString:@"true"] &&
                                ![tok isEqualToString:@"false"] &&
                                ![tok hasPrefix:@"__PANDA"]) {
                                unichar first = [tok characterAtIndex:0];
                                if ((first >= 'A' && first <= 'Z') || first == '_' || first == '$') {
                                    // 大写开头的标识符 → 通常是 class/namespace/const import binding
                                    [moduleToImports[s] addObject:tok.copy];
                                } else if (first >= 'a' && first <= 'z') {
                                    // 小写开头的函数名/常量也加入 (import { foo } from)
                                    [moduleToImports[s] addObject:tok.copy];
                                }
                            }
                        }
                        tok = [NSMutableString string];
                        continue;
                    }
                    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                        (c >= '0' && c <= '9') || c == '_' || c == '$') {
                        [tok appendFormat:@"%c", (char)c];
                    } else {
                        if (tok.length >= 1) {
                            unichar first = [tok characterAtIndex:0];
                            if ((first >= 'A' && first <= 'Z') || first == '_' || first == '$' ||
                                (first >= 'a' && first <= 'z')) {
                                [moduleToImports[s] addObject:tok.copy];
                            }
                        }
                        tok = [NSMutableString string];
                    }
                }
                // 确保至少有一个 HdsNavigation 级别的兜底 (从前面的错误看最常见)
                if ([s containsString:@"hds"]) {
                    NSArray<NSString *> *knownHds = @[
                        @"HdsNavigation", @"HdsNavigationBar", @"HdsTabs", @"HdsButton",
                        @"HdsTextField", @"HdsText", @"HdsIcon", @"HdsSearchBar",
                        @"HdsList", @"HdsListItem", @"HdsDialog", @"HdsSheet",
                        @"HdsCard", @"HdsTag", @"HdsBadge", @"HdsAvatar",
                        @"HdsProgress", @"HdsSlider", @"HdsSwitch", @"HdsStepper",
                        @"HdsCheckbox", @"HdsRadio", @"HdsPicker", @"HdsDatePicker",
                        @"HdsTimePicker", @"HdsNavBar", @"HdsToolbar", @"HdsSwiper",
                        @"HdsGrid", @"HdsGridItem", @"HdsWaterFlow", @"HdsIndexer",
                        @"HdsDivider", @"HdsImage", @"HdsTextArea", @"HdsSearch",
                    ];
                    for (NSString *k in knownHds) {
                        [moduleToImports[s] addObject:k];
                    }
                }
                // arkui.node 常见导出
                if ([s isEqualToString:@"@ohos:arkui.node"]) {
                    NSArray<NSString *> *knownNode = @[
                        @"NodeController", @"NodeRenderType", @"Node", @"BuilderNode",
                        @"FrameNode", @"ComponentContent", @"NodeType",
                    ];
                    for (NSString *k in knownNode) {
                        [moduleToImports[s] addObject:k];
                    }
                }
            }
        }

        if (moduleToImports.count == 0) {
            NSLog(@"[HAPManager] Shim: no cross-platform missing modules detected");
        } else {
            NSLog(@"[HAPManager] Shim: generating shims for %lu missing modules",
                  (unsigned long)moduleToImports.count);
        }

        // 生成 shim 文件
        NSString *shimRoot = [etsDir stringByAppendingPathComponent:@"modules"];
        for (NSString *modSpec in moduleToImports.allKeys) {
            NSSet<NSString *> *imports = moduleToImports[modSpec];
            if (imports.count == 0) { continue; }
            // "@hms:hds.hdsBaseComponent" → ns="@hms", pathTail="hds.hdsBaseComponent"
            NSRange colon = [modSpec rangeOfString:@":"];
            NSString *ns = [modSpec substringToIndex:colon.location];
            NSString *pathTail = [modSpec substringFromIndex:colon.location + 1];

            // hds.hdsBaseComponent → hds/hdsBaseComponent
            NSArray<NSString *> *parts = [pathTail componentsSeparatedByString:@"."];
            NSMutableArray<NSString *> *pathComps = [NSMutableArray array];
            [pathComps addObject:[ns stringByReplacingOccurrencesOfString:@"@" withString:@""]];
            for (NSString *p in parts) {
                if (p.length > 0) { [pathComps addObject:p]; }
            }
            NSString *fileName = pathComps.lastObject;
            NSMutableArray<NSString *> *dirComps = [pathComps mutableCopy];
            [dirComps removeLastObject];
            NSString *shimDir = shimRoot;
            for (NSString *d in dirComps) {
                shimDir = [shimDir stringByAppendingPathComponent:d];
            }
            NSString *shimPath = [[shimDir stringByAppendingPathComponent:fileName]
                                  stringByAppendingPathExtension:@"ets"];
            NSError *mkErr = nil;
            [fm createDirectoryAtPath:shimDir withIntermediateDirectories:YES attributes:nil error:&mkErr];

            NSMutableString *content = [NSMutableString string];
            [content appendString:@"// Auto-generated compatibility shim by HAPManager.\n"];
            [content appendFormat:@"// Module: %@\n", modSpec];
            [content appendString:@"// NOTE: HDS/HarmonyOS-only components are not available on iOS;\n"];
            [content appendString:@"// this shim provides empty export placeholders so that ES module\n"];
            [content appendString:@"// static import validation passes. Components render as empty views\n"];
            [content appendString:@"// and will not crash the app.\n\n"];
            for (NSString *name in imports) {
                // 为每个 import 名生成占位。优先按命名约定判断。
                unichar first = [name characterAtIndex:0];
                if (first >= 'A' && first <= 'Z') {
                    // 大写开头 → class 或 namespace
                    if ([name hasSuffix:@"Controller"] ||
                        [name isEqualToString:@"Node"] ||
                        [name isEqualToString:@"BuilderNode"] ||
                        [name isEqualToString:@"FrameNode"] ||
                        [name isEqualToString:@"ComponentContent"]) {
                        // class 导出
                        [content appendFormat:@"export class %@ { constructor() {} }\n", name];
                    } else if ([name hasSuffix:@"Type"] ||
                               [name isEqualToString:@"NodeRenderType"]) {
                        // enum 导出 → 对象字面量
                        [content appendFormat:@"export const %@ = Object.freeze({});\n", name];
                    } else {
                        // UI 组件 (HdsNavigation/HdsTabs/...) 导出空 class (会被当成自定义组件渲染成空)
                        [content appendFormat:@"export class %@ { constructor() {} build() {} }\n", name];
                    }
                } else {
                    // 小写开头 → 函数或常量
                    [content appendFormat:@"export const %@ = function() {}; // eslint-disable-line\n", name];
                }
            }
            // 总是额外导出 default 兜底
            [content appendString:@"\nexport default undefined;\n"];

            NSError *wrErr = nil;
            BOOL ok = [content writeToFile:shimPath atomically:YES
                                    encoding:NSUTF8StringEncoding error:&wrErr];
            NSLog(@"[HAPManager] Shim: %@ → %@ (%lu exports) %@",
                  modSpec, shimPath, (unsigned long)imports.count,
                  ok ? @"✅ written" : [NSString stringWithFormat:@"❌ %@", wrErr]);
        }
        if (moduleToImports.count > 0) {
            NSLog(@"[HAPManager] Shim: directory contents of %@", shimRoot);
            NSArray *shimFiles = [fm subpathsOfDirectoryAtPath:shimRoot error:nil];
            for (NSString *f in shimFiles) {
                NSLog(@"[HAPManager] Shim:   %@", f);
            }
        }
    }

    // 如果 resources 目录存在但 resources.index 缺失,尝试兜底:列出 resources/base/profile/ 下有什么,
    // 帮用户确认 main_pages.json 之类的配置文件是否在。
    if (hasResourcesDir) {
        NSString *profileDir = [resourcesDir stringByAppendingPathComponent:@"base/profile"];
        NSArray *profileFiles = [fm contentsOfDirectoryAtPath:profileDir error:nil];
        NSLog(@"[HAPManager] resources/base/profile/ files: %@", profileFiles);

        // 找 main_pages 或其他 *pages*.json
        for (NSString *f in profileFiles) {
            if ([f.lowercaseString containsString:@"page"] || [f.pathExtension isEqualToString:@"json"]) {
                NSString *fullPath = [profileDir stringByAppendingPathComponent:f];
                NSData *d = [NSData dataWithContentsOfFile:fullPath];
                if (d.length > 0 && d.length < 65536) {
                    NSString *txt = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                    if (txt) {
                        NSLog(@"[HAPManager] profile %@ content:\n%@", f, txt);
                    }
                }
            }
        }
    }

    // ets 目录下 abc 文件完整列表 + Panda 字节码版本检查。
    NSString *etsDir = [moduleDir stringByAppendingPathComponent:@"ets"];
    NSDirectoryEnumerator *etsEnum = [fm enumeratorAtPath:etsDir];
    NSMutableArray<NSString *> *abcFiles = [NSMutableArray array];
    for (NSString *p in etsEnum) {
        if ([p.pathExtension isEqualToString:@"abc"]) {
            [abcFiles addObject:p];
        }
    }
    NSLog(@"[HAPManager] ets/*.abc files (%lu): %@", (unsigned long)abcFiles.count, abcFiles);

    // 检测每个 abc 的 Panda bytecode 版本。
    // ⚠️ 不再硬编码 max supported version 并 showGlobalError 阻止启动:
    //   不同版本的 libarkui_ios.xcframework 内嵌的 panda_file::File::MAX_SUPPORTED_VERSION
    //   是编译期常量,以字符串以外的形式存在,无法从外部可靠探测。为了兼容升级 5.0.x SDK
    //   后支持 bytecode 12.x 的情况,这里只打印检测到的版本并提醒用户:如果后续 runtime
    //   报 "Maximum supported version is X.X.X.X" 错误,则把 iOS 壳工程内的 ArkUI-X SDK
    //   (libarkui_ios.xcframework + libhilog/libresourcemanager/... 等全部 framework)
    //   升级到与打包 hap 同一 SDK 版本即可。
    // Panda abc 头格式:magic("PANDA" 5 bytes)+version(major.minor.patch.build,4 uint8,通常大端)。
    for (NSString *abcRel in abcFiles) {
        NSString *abcFull = [etsDir stringByAppendingPathComponent:abcRel];
        NSData *header = [NSData dataWithContentsOfFile:abcFull options:0 error:nil];
        if (header.length < 9) continue;

        const unsigned char *bytes = (const unsigned char *)header.bytes;
        if (!(bytes[0]=='P' && bytes[1]=='A' && bytes[2]=='N' && bytes[3]=='D' && bytes[4]=='A')) {
            continue;
        }
        int major = bytes[5];
        int minor = bytes[6];
        int patch = bytes[7];
        int build = bytes[8];
        NSLog(@"[HAPManager] abc %@ panda bytecode version=%d.%d.%d.%d",
              abcRel, major, minor, patch, build);

        // 只在检测到 bytecode 主版本 >= 10(即 API 11+,12.0.6.0 对应的 Restool 6.1)时,
        // 打印一条显眼的提醒:若 ArkUI-X SDK 尚未升级,运行时将无法加载并输出
        // "Maximum supported version is X"。用户点悬浮日志按钮可复制查看完整日志。
        if (major >= 10) {
            NSLog(@"[HAPManager] ⚠️ abc bytecode 版本=%d.x (API 12+ 对应 12.x 很常见)", major);
            NSLog(@"[HAPManager] ⚠️ 如后续出现 'Unable to open file ... with bytecode version %d.%d.%d.%d'",
                  major, minor, patch, build);
            NSLog(@"[HAPManager] ⚠️ 和 'Maximum supported version is X.0.0.0' 报错:");
            NSLog(@"[HAPManager] ⚠️ 请将 iOS 壳工程的 ArkUI-X SDK (libarkui_ios.xcframework 以及"
                  @" libhilog/libresourcemanager/libcrypto/libcurl 等全部 framework) 升级到与打包"
                  @" hap 时相同的 SDK 版本,以便 runtime 支持 bytecode %d.x。", major);
        }
    }
    NSLog(@"[HAPManager] =====================================================");

    // ---- 2. 合成 AppScope/app.json (若缺失) ----
    NSString *appScopeDir = [arkuiXDirectory stringByAppendingPathComponent:@"AppScope"];
    NSString *appJsonPath = [appScopeDir stringByAppendingPathComponent:@"app.json"];

    if (![fm fileExistsAtPath:appJsonPath]) {
        [fm createDirectoryAtPath:appScopeDir withIntermediateDirectories:YES attributes:nil error:nil];

        // 用解析到的 appObj 优先,兜底用传入的参数
        NSString *finalBundleName = parsedAppObj[@"bundleName"] ?: bundleName;
        NSString *finalVendor     = parsedAppObj[@"vendor"] ?: @"";
        id versionNameObj         = parsedAppObj[@"versionName"];
        id versionCodeObj         = parsedAppObj[@"versionCode"];
        id minApiObj              = parsedAppObj[@"minAPIVersion"];
        id targetApiObj           = parsedAppObj[@"targetAPIVersion"];
        id iconObj                = parsedAppObj[@"icon"];
        id labelObj               = parsedAppObj[@"label"];
        NSString *displayName     = appName.length ? appName : (labelObj ?: finalBundleName);

        NSMutableDictionary *appJson = [NSMutableDictionary dictionary];
        NSMutableDictionary *app     = [NSMutableDictionary dictionary];
        app[@"bundleName"]           = finalBundleName;
        app[@"vendor"]               = finalVendor;
        if (versionNameObj)  app[@"versionName"]  = versionNameObj;
        if (versionCodeObj)  app[@"versionCode"]  = versionCodeObj;
        if (minApiObj)       app[@"minAPIVersion"]  = minApiObj;
        if (targetApiObj)    app[@"targetAPIVersion"] = targetApiObj;
        if (iconObj)         app[@"icon"]         = iconObj;
        if (labelObj)        app[@"label"]        = labelObj;
        if (displayName && !labelObj) app[@"label"] = displayName;

        appJson[@"app"] = app;

        NSError *err = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:appJson options:NSJSONWritingPrettyPrinted error:&err];
        if (jsonData) {
            [fm createFileAtPath:appJsonPath contents:jsonData attributes:nil];
            NSLog(@"[HAPManager] AppScope/app.json generated (bundle=%@ label=%@)", finalBundleName, displayName);
        } else {
            NSLog(@"[HAPManager] Failed to generate AppScope/app.json: %@", err);
        }
    }
}

// 把 hap 解压内容安置到 Documents/arkui-x/{moduleName}/ 下。
//
// 真实未签名 hap 解压后根目录直接是 ets/modules.abc、module.json、resources/、resources.index、
// pack.info、pkgContextInfo.json 等(没有 entry/ 子目录)。ArkUI-X iOS 工程期望的 arkui-x/ 目录
// 结构是 {moduleName}/ 子目录 + systemres/(SDK 提供)。所以这里把 hap 解压根目录的所有
// 条目整体拷贝到 {moduleName}/ 下,目录名用纯 moduleName(如 entry),与官方产物结构对齐。
//
// 关键:不要改写 module.json,不要生成 AppScope/app.json!
// - module.json 的 module.name 字段在 hap 编译时就由 ArkTS 编译器决定(通常是 "entry"),
//   与 abc 字节码中注册的模块名一致。手动改写 module.name 会导致 module.name 与 abc 模块名错位,
//   AppMain 找不到 abc 入口 → 闪退或白屏。
// - StageAssetManager 的 updateModuleNameWithJsonData: 也只在路径包含 bundleName.moduleName
//   时才改写 module.name。标准产物路径只含 "/entry/",不含 "/bundleName.entry/",所以 SDK
//   不会改写 module.name,这是预期行为。
// - AppMain::LaunchApplication 会从 module.json 自身的 app.bundleName 字段读取 app 信息,
//   不需要额外的 AppScope/app.json。手动合成格式不正确的 app.json 反而会干扰 AppMain。
- (BOOL)installExtractedFilesFrom:(NSString *)extractDir
                       moduleName:(NSString *)moduleName
                toArkuiXDirectory:(NSString *)arkuiXDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:arkuiXDirectory]) {
        [fm createDirectoryAtPath:arkuiXDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // 目录名用纯 moduleName(如 "entry"),对齐 ArkUI-X 官方 iOS 工程产物结构。
    NSString *moduleDestDir = [arkuiXDirectory stringByAppendingPathComponent:moduleName];
    if ([fm fileExistsAtPath:moduleDestDir]) {
        [fm removeItemAtPath:moduleDestDir error:nil];
    }
    if (![fm createDirectoryAtPath:moduleDestDir withIntermediateDirectories:YES attributes:nil error:nil]) {
        return NO;
    }

    NSError *error = nil;
    NSArray *entries = [fm contentsOfDirectoryAtPath:extractDir error:&error];
    if (!entries) {
        return NO;
    }

    NSLog(@"[HAPManager] Installing hap contents into %@ (entries=%lu)",
          moduleDestDir, (unsigned long)entries.count);

    // 把 hap 解压根目录的所有条目整体拷贝到 {moduleName}/ 下。
    // hap 内容里若已自带与 moduleName 同名的子目录(某些 hap 把内容打包在 entry/ 子目录里),
    // 直接展开避免嵌套。
    for (NSString *entry in entries) {
        if ([entry isEqualToString:moduleName]) {
            NSString *nestedDir = [extractDir stringByAppendingPathComponent:entry];
            NSArray *nestedEntries = [fm contentsOfDirectoryAtPath:nestedDir error:nil];
            if (!nestedEntries) {
                continue;
            }
            for (NSString *nestedEntry in nestedEntries) {
                NSString *sourcePath = [nestedDir stringByAppendingPathComponent:nestedEntry];
                NSString *destPath = [moduleDestDir stringByAppendingPathComponent:nestedEntry];
                if ([fm fileExistsAtPath:destPath]) {
                    [fm removeItemAtPath:destPath error:nil];
                }
                if (![fm copyItemAtPath:sourcePath toPath:destPath error:&error]) {
                    NSLog(@"[HAPManager] Failed to copy %@ -> %@ : %@", sourcePath, destPath, error);
                    return NO;
                }
            }
            continue;
        }

        NSString *sourcePath = [extractDir stringByAppendingPathComponent:entry];
        NSString *destPath = [moduleDestDir stringByAppendingPathComponent:entry];
        if ([fm fileExistsAtPath:destPath]) {
            [fm removeItemAtPath:destPath error:nil];
        }
        if (![fm copyItemAtPath:sourcePath toPath:destPath error:&error]) {
            NSLog(@"[HAPManager] Failed to copy %@ -> %@ : %@", sourcePath, destPath, error);
            return NO;
        }
    }

    // 打印安装后的目录结构(只列前 30 个条目,递归扫描),便于在 CI 日志中排查 hap 结构问题。
    NSLog(@"[HAPManager] Installed directory tree under %@:", moduleDestDir);
    NSArray *installedSubpaths = [fm subpathsOfDirectoryAtPath:moduleDestDir error:nil];
    NSUInteger printCount = MIN(installedSubpaths.count, 30);
    for (NSUInteger i = 0; i < printCount; i++) {
        NSLog(@"[HAPManager]   %@", [moduleDestDir stringByAppendingPathComponent:installedSubpaths[i]]);
    }
    if (installedSubpaths.count > printCount) {
        NSLog(@"[HAPManager]   ... and %lu more entries", (unsigned long)(installedSubpaths.count - printCount));
    }

    return YES;
}

@end
