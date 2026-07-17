#import <UIKit/UIKit.h>
#import "HAPManager.h"

#if HAS_ARKUI_X
#import <libarkui_ios/StageViewController.h>
#endif

#if HAS_ARKUI_X
@interface HAPPlayerViewController : StageViewController
#else
@interface HAPPlayerViewController : UIViewController
#endif

@property (nonatomic, strong) HAPManager *hapManager;
@property (nonatomic, strong) NSString *bundleName;

- (instancetype)initWithHAPManager:(HAPManager *)manager bundleName:(NSString *)bundleName;

@end
