#import <UIKit/UIKit.h>
#import "HAPManager.h"

@interface HAPViewController : UIViewController

@property (nonatomic, strong) HAPManager *hapManager;

- (instancetype)initWithHAPManager:(HAPManager *)manager;

@end