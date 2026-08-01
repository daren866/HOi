#import <UIKit/UIKit.h>
#import "HAPManager.h"

#if HAS_ARKUI_X
#import "StageViewController.h"
#endif

#if HAS_ARKUI_X
// 继承自 ArkUI-X 的 StageViewController,其 viewDidLoad 会创建渲染 Surface 并
// 调用 AppMain::DispatchOnCreate,从而把 hap 中 abc 字节码渲染出的 ArkUI 页面挂载到该 VC 的视图上。
@interface HAPPlayerViewController : StageViewController
#else
@interface HAPPlayerViewController : UIViewController
#endif

@property (nonatomic, strong) HAPManager *hapManager;
@property (nonatomic, strong) NSString *bundleName;
@property (nonatomic, strong) NSString *moduleName;
@property (nonatomic, strong) NSString *abilityName;

- (instancetype)initWithHAPManager:(HAPManager *)manager
                        bundleName:(NSString *)bundleName
                        moduleName:(NSString *)moduleName
                       abilityName:(NSString *)abilityName;

@end
