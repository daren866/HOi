#import "HAPPlayerViewController.h"

@interface HAPPlayerViewController ()

@end

@implementation HAPPlayerViewController

- (instancetype)initWithHAPManager:(HAPManager *)manager
                        bundleName:(NSString *)bundleName
                        moduleName:(NSString *)moduleName
                       abilityName:(NSString *)abilityName {
    // instanceName 格式为 "bundleName:moduleName:abilityName",
    // StageViewController 内部据此定位 hap 解压后 {moduleName}/ 目录里的 abc 字节码与渲染入口。
    NSString *safeBundleName = bundleName.length ? bundleName : @"com.example.hap";
    NSString *safeModuleName = moduleName.length ? moduleName : @"entry";
    NSString *safeAbilityName = abilityName.length ? abilityName : @"EntryAbility";

#if HAS_ARKUI_X
    NSString *instanceName = [NSString stringWithFormat:@"%@:%@:%@", safeBundleName, safeModuleName, safeAbilityName];
    self = [super initWithInstanceName:instanceName];
#else
    self = [super init];
#endif
    if (self) {
        self.hapManager = manager;
        self.bundleName = safeBundleName;
        self.moduleName = safeModuleName;
        self.abilityName = safeAbilityName;
        // 注意:不要再在这里调用 hapManager.initializeArkUI。
        // ArkUI 运行时已经在 loadHAPAtPath 的 completion 触发前启动完毕(由 HAPManager 内部
        // 调用 StageApplication launchApplication 完成),此时 VC 才被创建。
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"ArkUI Player";
    self.view.backgroundColor = [UIColor whiteColor];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // ArkUI 未启动时不要转发 foreground,否则 StageApplication 取到的 topViewController
    // 不是 StageViewController,会触发空指针/状态机错乱崩溃。
    if (self.hapManager.isArkUIRunning) {
        [self.hapManager callCurrentAbilityOnForeground];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.hapManager.isArkUIRunning) {
        [self.hapManager callCurrentAbilityOnBackground];
    }
}

@end
