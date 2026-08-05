#import <UIKit/UIKit.h>
#import "HAPManager.h"

@interface HAPViewController : UIViewController

@property (nonatomic, strong) HAPManager *hapManager;
// 已安装 hap 列表,AppDelegate 处理 hoi:// URL Scheme 时需要按 bundleName 查找对应 hap。
// 元素为 NSDictionary,字段包括: path / bundleName / appName / moduleName / abilityName 等。
@property (nonatomic, strong, readonly) NSMutableArray<NSDictionary *> *hapInfoList;
// 列表顶部的加载指示器,URL 跳转加载 hap 时需要动画显示加载中。
@property (nonatomic, strong, readonly) UIActivityIndicatorView *loadingIndicator;

- (instancetype)initWithHAPManager:(HAPManager *)manager;
// 重新扫描 Documents 目录刷新 hap 列表(URL 跳转找不到 bundleName 时会调用以处理刚安装的 hap)。
- (void)loadHAPList;

@end