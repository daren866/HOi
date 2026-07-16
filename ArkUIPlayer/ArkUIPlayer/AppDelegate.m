#import "AppDelegate.h"
#import "HAPManager.h"
#import "HAPViewController.h"

@interface AppDelegate ()

@property (nonatomic, strong) HAPManager *hapManager;

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor whiteColor];
    
    self.hapManager = [[HAPManager alloc] init];
    
    HAPViewController *vc = [[HAPViewController alloc] initWithHAPManager:self.hapManager];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self setupNavigationBarAppearance:nav];
    
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    
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
    [[HAPManager sharedManager] callCurrentAbilityOnBackground];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [[HAPManager sharedManager] callCurrentAbilityOnForeground];
}

@end