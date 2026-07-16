#import <UIKit/UIKit.h>
#import <libarkui_ios/StageViewController.h>
#import "HAPManager.h"

@interface HAPPlayerViewController : StageViewController

@property (nonatomic, strong) HAPManager *hapManager;

- (instancetype)initWithHAPManager:(HAPManager *)manager bundleName:(NSString *)bundleName;

@end