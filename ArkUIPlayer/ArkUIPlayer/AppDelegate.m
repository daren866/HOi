#import "AppDelegate.h"
#import "HAPManager.h"
#import "HAPViewController.h"
#import "HAPPlayerViewController.h"
#import "LogFloatingButton.h"
#import <SafariServices/SafariServices.h>

@interface AppDelegate ()

@property (nonatomic, strong) HAPManager *hapManager;
// 待处理的 URL(在 app 冷启动时 URL 先于 rootViewController 加载,需延迟到 rootVC 就绪后处理)
@property (nonatomic, copy) NSURL *pendingURL;
@property (nonatomic, assign) BOOL isHandlingURL;

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor whiteColor];

    // 必须使用 sharedManager 单例,因为 applicationDidBecomeActive 等生命周期回调
    // 也是通过 [HAPManager sharedManager] 调用的;如果这里 [[HAPManager alloc] init]
    // 创建了另一个实例,会导致两个实例各自维护状态,而 ArkUI 的 StageApplication 又是
    // 全局单例,二次 launchApplication 会让运行时状态错乱,启动即闪退。
    self.hapManager = [HAPManager sharedManager];

    // 尽早安装崩溃防护(在任何 StageApplication 调用之前)。
    // 安装:
    // - NSSetUncaughtExceptionHandler 拦截 ObjC 未捕获异常
    // - sigaction 拦截 SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP/SIGPIPE(C++ abort/段错误等)
    // 一旦触发,进程不会 abort,改为弹出独立 UIWindow 显示"报错"红色居中文本,
    // 点击文本可复制完整错误(含信号名+callstack)到剪贴板。
    [self.hapManager installCrashGuard];

    HAPViewController *vc = [[HAPViewController alloc] initWithHAPManager:self.hapManager];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self setupNavigationBarAppearance:nav];

    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    // 显示悬浮日志按钮:正圆形绿色,可拖动,点击复制应用日志到剪贴板。
    // 在所有初始化完成后启动,确保能捕获到后续所有 NSLog 输出。
    [[LogFloatingButton sharedButton] show];

    // 冷启动 URL:用户点击 hoi://... 时系统传入 launchOptions。
    // 如果 rootViewController 此时已设置好,立即处理;否则延迟到 applicationDidBecomeActive。
    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if (launchURL) {
        NSLog(@"[AppDelegate] 冷启动 URL: %@", launchURL);
        self.pendingURL = launchURL;
        // 延迟 0.5 秒:让 rootVC.view 加载完成 + HAPList 列表刷新完毕
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self processPendingURLIfNeeded];
        });
    }

    return YES;
}

// ===== hoi://{bundleName}/ URL Scheme 处理 =====
// 用户点击外部 hoi://{bundleName}/ 链接时:
//   1) 从 URL 中提取 bundleName (host 部分)
//   2) 在 Documents 目录下查找该 bundleName 对应的 hap 文件
//   3) 加载 hap 并 push 到播放页
//
// 入口函数:iOS 4.2+ application:openURL:options:
- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    NSLog(@"[AppDelegate] openURL: %@ (options=%@)", url, options);
    // 同样延迟处理,确保此时 rootViewController 已就绪(热启动时也可能正在切换视图)
    self.pendingURL = url;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self processPendingURLIfNeeded];
    });
    return YES;
}

// 真实的 URL 处理逻辑(抽出来便于 didFinishLaunching 和 openURL 复用)
- (void)processPendingURLIfNeeded {
    if (self.isHandlingURL) return;
    NSURL *url = self.pendingURL;
    if (!url) return;
    self.pendingURL = nil;
    self.isHandlingURL = YES;

    @try {
        [self handleDeepLinkURL:url];
    } @catch (NSException *e) {
        NSLog(@"[AppDelegate] handleDeepLinkURL crashed: %@\n%@", e, e.callStackSymbols);
    } @finally {
        self.isHandlingURL = NO;
    }
}

- (void)handleDeepLinkURL:(NSURL *)url {
    // 只处理 hoi:// scheme
    if (![[url.scheme lowercaseString] isEqualToString:@"hoi"]) {
        NSLog(@"[AppDelegate] URL scheme 不是 hoi: %@, 忽略", url.scheme);
        return;
    }

    // 提取 bundleName:
    //   hoi://com.example.foo/  → host = "com.example.foo"
    //   hoi:///com.example.foo  → path = "/com.example.foo" (备用兜底)
    NSString *bundleName = url.host;
    if (bundleName.length == 0) {
        NSString *path = url.path;
        if (path.length > 1) {
            bundleName = [path substringFromIndex:1];  // 去掉开头的 /
        }
    }
    // 去掉末尾可能的 /
    while ([bundleName hasSuffix:@"/"]) {
        bundleName = [bundleName substringToIndex:bundleName.length - 1];
    }
    if (bundleName.length == 0) {
        NSLog(@"[AppDelegate] hoi URL 缺少 bundleName: %@", url);
        return;
    }
    NSLog(@"[AppDelegate] 提取 bundleName = %@ (from URL %@)", bundleName, url);

    // 1. 找到当前列表页,读取 hap 列表
    UIViewController *rootVC = self.window.rootViewController;
    UINavigationController *nav = nil;
    HAPViewController *hapListVC = nil;
    if ([rootVC isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)rootVC;
        for (UIViewController *c in nav.viewControllers) {
            if ([c isKindOfClass:[HAPViewController class]]) {
                hapListVC = (HAPViewController *)c;
                break;
            }
        }
    } else if ([rootVC isKindOfClass:[HAPViewController class]]) {
        hapListVC = (HAPViewController *)rootVC;
        nav = [[UINavigationController alloc] initWithRootViewController:hapListVC];
        self.window.rootViewController = nav;
    }
    if (!hapListVC) {
        NSLog(@"[AppDelegate] ⚠️ 找不到 HAPViewController,无法跳转");
        return;
    }

    // 2. 在 hapInfoList 里按 bundleName 查找
    NSInteger matchIndex = -1;
    NSDictionary *matchInfo = nil;
    for (NSInteger i = 0; i < hapListVC.hapInfoList.count; i++) {
        NSDictionary *info = hapListVC.hapInfoList[i];
        NSString *b = info[@"bundleName"] ?: @"";
        if ([b isEqualToString:bundleName]) {
            matchIndex = i;
            matchInfo = info;
            break;
        }
    }

    // 如果列表里找不到,尝试重新扫描一次(可能是刚安装还没刷出来)
    if (!matchInfo) {
        NSLog(@"[AppDelegate] bundleName %@ 不在当前列表,重新扫描 Documents 目录", bundleName);
        [hapListVC loadHAPList];  // 重新加载列表
        for (NSInteger i = 0; i < hapListVC.hapInfoList.count; i++) {
            NSDictionary *info = hapListVC.hapInfoList[i];
            NSString *b = info[@"bundleName"] ?: @"";
            if ([b isEqualToString:bundleName]) {
                matchIndex = i;
                matchInfo = info;
                break;
            }
        }
    }

    if (!matchInfo) {
        NSLog(@"[AppDelegate] ❌ 未找到 bundleName=%@ 对应的 hap 文件", bundleName);
        // 轻量提示
        NSString *msg = [NSString stringWithFormat:@"未安装 %@ 对应的 hap 应用\n请先安装后再跳转", bundleName];
        [self.hapManager showGlobalError:msg shortText:@"跳转失败"];
        // 5 秒后自动隐藏(比崩溃后永久显示的报错要温和)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self.hapManager hideGlobalError];
        });
        return;
    }

    NSString *hapPath = matchInfo[@"path"];
    NSString *appName = matchInfo[@"appName"] ?: bundleName;
    NSLog(@"[AppDelegate] ✅ 找到 hap: %@, path=%@", appName, hapPath);

    // 3. 如果当前已经在播放某个 hap,先 pop 回列表页
    if (nav.topViewController != hapListVC) {
        [nav popToViewController:hapListVC animated:NO];
    }
    [self.hapManager unloadCurrentHAP];

    // 4. 加载 hap → 成功后 push 播放页
    [hapListVC.loadingIndicator startAnimating];
    __weak typeof(self) weakSelf = self;
    [self.hapManager loadHAPAtPath:hapPath completion:^(BOOL success, NSString *errorMessage) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [hapListVC.loadingIndicator stopAnimating];
        if (!success) {
            NSLog(@"[AppDelegate] ❌ URL 跳转加载 hap 失败: %@", errorMessage);
            [strongSelf.hapManager showGlobalError:errorMessage shortText:@"加载失败"];
            return;
        }
        NSLog(@"[AppDelegate] ✅ URL 跳转加载 hap 成功,创建播放页");
        HAPPlayerViewController *playerVC =
            [[HAPPlayerViewController alloc] initWithHAPManager:strongSelf.hapManager
                                                     bundleName:strongSelf.hapManager.currentBundleName
                                                      moduleName:strongSelf.hapManager.currentModuleName
                                                     abilityName:strongSelf.hapManager.currentAbilityName
                                                        appName:strongSelf.hapManager.currentAppName
                                                       pageName:strongSelf.hapManager.currentPageName];
        if (!playerVC) {
            [strongSelf.hapManager showGlobalError:@"创建播放页失败" shortText:@"跳转失败"];
            return;
        }
        [nav pushViewController:playerVC animated:YES];
    }];
}

- (void)setupNavigationBarAppearance:(UINavigationController *)nav {
    if (@available(iOS 15.0, *)) {
        UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = [UIColor systemBlueColor];
        appearance.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
        nav.navigationBar.standardAppearance = appearance;
        nav.navigationBar.scrollEdgeAppearance = appearance;
    }
    nav.navigationBar.tintColor = [UIColor whiteColor];
}

- (void)applicationWillResignActive:(UIApplication *)application {
    // ArkUI 运行时由用户点击 hap 后才会启动;启动前调用 callCurrentAbilityOnBackground
    // 会让 StageApplication 在 getApplicationTopViewController 返回 nil 或非 StageViewController
    // 时打日志返回(已加保护),但若此时正好处于 hap 加载中途,会破坏状态机。
    // 这里只在 ArkUI 已启动后才转发生命周期。
    if (self.hapManager.isArkUIRunning) {
        [self.hapManager callCurrentAbilityOnBackground];
    }
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // 启动后第一次 applicationDidBecomeActive 会在 viewDidLoad 之前触发,
    // 此时还没有任何 StageViewController,转发下去会让 StageApplication 空转或崩。
    if (self.hapManager.isArkUIRunning) {
        [self.hapManager callCurrentAbilityOnForeground];
    }
}

@end