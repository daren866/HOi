#import <Foundation/Foundation.h>
#import <libarkui_ios/StageApplication.h>

typedef void (^HAPLoadCompletion)(BOOL success, NSString *errorMessage);
typedef void (^HAPListCompletion)(NSArray<NSDictionary *> *hapInfoList, NSError *error);
typedef void (^HAPInfoCompletion)(NSString *appName, NSString *bundleName, NSError *error);

@interface HAPManager : NSObject

@property (nonatomic, strong, readonly) NSString *currentHAPPath;
@property (nonatomic, strong, readonly) NSString *arkuiXDirectory;

+ (instancetype)sharedManager;

- (void)initializeArkUI;

- (void)loadHAPAtPath:(NSString *)hapPath completion:(HAPLoadCompletion)completion;

- (void)listAvailableHAPsInDirectory:(NSString *)directory completion:(HAPListCompletion)completion;

- (void)getHAPInfoFromPath:(NSString *)hapPath completion:(HAPInfoCompletion)completion;

- (void)callCurrentAbilityOnForeground;
- (void)callCurrentAbilityOnBackground;

- (void)unloadCurrentHAP;

@end