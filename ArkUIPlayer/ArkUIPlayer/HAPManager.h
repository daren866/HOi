#import <Foundation/Foundation.h>

typedef void (^HAPLoadCompletion)(BOOL success, NSString *errorMessage);
typedef void (^HAPListCompletion)(NSArray<NSDictionary *> *hapInfoList, NSError *error);
typedef void (^HAPInfoCompletion)(NSString *appName, NSString *bundleName, NSError *error);
typedef void (^HAPModuleInfoCompletion)(NSString *appName, NSString *bundleName,
                                        NSString *moduleName, NSString *abilityName, NSError *error);

// HAS_ARKUI_X:由 CI 在下载 ArkUI-X SDK 后置为 1;本地源码默认 1 以便走 StageApplication 路径。
#define HAS_ARKUI_X 1

@interface HAPManager : NSObject

@property (nonatomic, strong, readonly) NSString *currentHAPPath;
@property (nonatomic, strong, readonly) NSString *arkuiXDirectory;
// 当前已加载 hap 的关键信息(由 module.json 解析得到),供 HAPPlayerViewController 拼接 instanceName 使用。
@property (nonatomic, copy, readonly) NSString *currentBundleName;
@property (nonatomic, copy, readonly) NSString *currentModuleName;
@property (nonatomic, copy, readonly) NSString *currentAbilityName;
// ArkUI 运行时是否已通过 StageApplication launchApplication 启动。
// AppDelegate 的前后台回调、HAPPlayerViewController 的 viewWillAppear 都需要先检查这个标志,
// 否则在 hap 加载完成前调用 DispatchOnForeground 会触发空指针/状态机错乱崩溃。
@property (nonatomic, assign, readonly) BOOL isArkUIRunning;

+ (instancetype)sharedManager;

- (void)loadHAPAtPath:(NSString *)hapPath completion:(HAPLoadCompletion)completion;

- (void)listAvailableHAPsInDirectory:(NSString *)directory completion:(HAPListCompletion)completion;

- (void)getHAPInfoFromPath:(NSString *)hapPath completion:(HAPInfoCompletion)completion;

// 读取 hap 内的 module.json,解析出 bundleName/moduleName/abilityName,用于驱动 abc 运行与渲染。
- (void)getHAPModuleInfoFromPath:(NSString *)hapPath completion:(HAPModuleInfoCompletion)completion;

- (void)callCurrentAbilityOnForeground;
- (void)callCurrentAbilityOnBackground;

- (void)unloadCurrentHAP;

@end
