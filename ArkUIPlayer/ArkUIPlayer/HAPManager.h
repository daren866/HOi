#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef void (^HAPLoadCompletion)(BOOL success, NSString *errorMessage);
typedef void (^HAPListCompletion)(NSArray<NSDictionary *> *hapInfoList, NSError *error);
typedef void (^HAPInfoCompletion)(NSString *appName, NSString *bundleName, NSError *error);
typedef void (^HAPModuleInfoCompletion)(NSString *appName, NSString *bundleName,
                                        NSString *moduleName, NSString *abilityName, NSError *error);

// HAS_ARKUI_X:由 CI 在下载 ArkUI-X SDK 后置为 1;本地源码默认 1 以便走 StageApplication 路径。
#define HAS_ARKUI_X 1

@interface HAPManager : NSObject

@property (nonatomic, strong, readonly) NSString *currentHAPPath;
@property (nonatomic, strong, readonly) NSString *arkuiXDirectory;
// 当前已加载 hap 的关键信息(由 module.json/module.json5 解析得到),供 HAPPlayerViewController 拼接 instanceName 使用。
@property (nonatomic, copy, readonly) NSString *currentBundleName;
@property (nonatomic, copy, readonly) NSString *currentModuleName;
@property (nonatomic, copy, readonly) NSString *currentAbilityName;
// 从 module.json5/module.json 中读取的应用展示名(优先级:abilities[0].label > module.name > bundleName)。
@property (nonatomic, copy, readonly) NSString *currentAppName;
// 从 module.json5/module.json 中读取的入口界面名(abilities[0].srcEntry 末尾的文件名,如 "Index"),
// 用于在播放界面顶部展示当前渲染的 ArkTS 页面,帮助确认 hap 是否成功解析到入口界面。
@property (nonatomic, copy, readonly) NSString *currentPageName;
// ArkUI 运行时是否已通过 StageApplication launchApplication 启动。
// AppDelegate 的前后台回调、HAPPlayerViewController 的 viewWillAppear 都需要先检查这个标志,
// 否则在 hap 加载完成前调用 DispatchOnForeground 会触发空指针/状态机错乱崩溃。
@property (nonatomic, assign, readonly) BOOL isArkUIRunning;
// 崩溃防护的全局错误 UI Window(独立于导航栈,level 最高,保证任何崩溃后都能覆盖到最上层显示)。
@property (nonatomic, strong, readonly) UIWindow *crashErrorWindow;

+ (instancetype)sharedManager;

- (void)loadHAPAtPath:(NSString *)hapPath completion:(HAPLoadCompletion)completion;

- (void)listAvailableHAPsInDirectory:(NSString *)directory completion:(HAPListCompletion)completion;

- (void)getHAPInfoFromPath:(NSString *)hapPath completion:(HAPInfoCompletion)completion;

// 读取 hap 内的 module.json/module.json5,解析出 bundleName/moduleName/abilityName,
// 用于驱动 abc 运行与渲染。
- (void)getHAPModuleInfoFromPath:(NSString *)hapPath completion:(HAPModuleInfoCompletion)completion;

- (void)callCurrentAbilityOnForeground;
- (void)callCurrentAbilityOnBackground;

- (void)unloadCurrentHAP;

#pragma mark - 全局崩溃防护

// 在 AppDelegate didFinishLaunching 时尽早调用(先于任何 StageApplication 调用)。
// 安装 UncaughtException Handler + 致命信号处理器(SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE),
// 拦截 ObjC 未捕获异常和 C++ abort/SIG* 崩溃,改为弹出独立 UIWindow 展示红色居中报错文本,
// 点击文本可复制完整错误(含 callstack/信号名)到剪贴板。
// 这是 hap 打开后闪退时依然能显示"报错"的关键手段 —— 因为 @try/@catch 拦不住 C++ abort。
- (void)installCrashGuard;

// 同 installCrashGuard,但 force=YES 时强制重新安装(忽略 g_crashGuardArmed 去重标志)。
// 用于在 StageApplication configModule/launchApplication 调用前后重装,
// 防止 ArkUI-X 内部 sigaction 把我们的 signal handler 覆盖掉。
- (void)installCrashGuardForce:(BOOL)force;

// 显式展示一个全局错误 UI(独立 Window,覆盖在整个 app 之上,不依赖任何 VC 的 view 层级)。
// HAPPlayerViewController 的 showErrorMessage 内部也会通过该接口,保证错误 UI 不被 StageVC 覆盖。
// message:详细错误信息(含 callstack);shortText:屏幕上简短显示的文字(默认"报错")。
- (void)showGlobalError:(NSString *)message shortText:(NSString *)shortText;

// 隐藏全局错误 UI(成功渲染 hap 后调用,清理上一次崩溃的残留窗口)。
- (void)hideGlobalError;

@end
