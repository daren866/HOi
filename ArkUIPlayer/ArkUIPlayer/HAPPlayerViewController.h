#import <UIKit/UIKit.h>
#import "../../stage/ability/StageViewController.h"
#import "HAPManager.h"

@interface HAPPlayerViewController : StageViewController

@property (nonatomic, strong) HAPManager *hapManager;

- (instancetype)initWithHAPManager:(HAPManager *)manager bundleName:(NSString *)bundleName;

@end