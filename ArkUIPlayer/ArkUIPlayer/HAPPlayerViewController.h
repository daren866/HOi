#import <UIKit/UIKit.h>
#import "HAPManager.h"

@interface HAPPlayerViewController : UIViewController

@property (nonatomic, strong) HAPManager *hapManager;

- (instancetype)initWithHAPManager:(HAPManager *)manager bundleName:(NSString *)bundleName;

@end
