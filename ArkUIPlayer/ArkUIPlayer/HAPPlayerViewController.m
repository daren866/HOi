#import "HAPPlayerViewController.h"

@interface HAPPlayerViewController ()

@end

@implementation HAPPlayerViewController

- (instancetype)initWithHAPManager:(HAPManager *)manager bundleName:(NSString *)bundleName {
    NSString *instanceName = [NSString stringWithFormat:@"%@:entry:MainAbility", bundleName ?: @"com.example.hap"];
    self = [super initWithInstanceName:instanceName];
    if (self) {
        self.hapManager = manager;
        self.bundleName = bundleName ?: @"com.example.hap";
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
