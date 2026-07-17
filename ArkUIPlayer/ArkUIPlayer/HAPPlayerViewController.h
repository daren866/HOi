#import <UIKit/UIKit.h>
#import "HAPManager.h"
#import "StageViewController.h"

@interface HAPPlayerViewController : StageViewController

@property (nonatomic, strong) HAPManager *hapManager;
@property (nonatomic, strong) NSString *bundleName;

- (instancetype)initWithHAPManager:(HAPManager *)manager bundleName:(NSString *)bundleName;

@end
