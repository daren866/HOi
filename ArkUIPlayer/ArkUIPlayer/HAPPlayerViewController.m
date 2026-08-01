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
        [self.hapManager initializeArkUI];
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
    [self.hapManager callCurrentAbilityOnForeground];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.hapManager callCurrentAbilityOnBackground];
}

@end
