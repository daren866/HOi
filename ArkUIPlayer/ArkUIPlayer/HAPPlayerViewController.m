#import "HAPPlayerViewController.h"

@interface HAPPlayerViewController ()

@end

@implementation HAPPlayerViewController

- (instancetype)initWithHAPManager:(HAPManager *)manager bundleName:(NSString *)bundleName {
    self = [super init];
    if (self) {
        self.hapManager = manager;
        [self.hapManager initializeArkUI];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"ArkUI Player";
    self.view.backgroundColor = [UIColor whiteColor];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.extendedLayoutIncludesOpaqueBars = YES;
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
