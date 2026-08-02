#import "AppDelegate.h"
#import "HAPManager.h"
#import "HAPViewController.h"
#import "LogFloatingButton.h"

@interface AppDelegate ()

@property (nonatomic, strong) HAPManager *hapManager;

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

    return YES;
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