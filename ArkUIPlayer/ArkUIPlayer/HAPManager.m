#import "HAPManager.h"

#if HAS_ARKUI_X
// 仅 StageApplication.h 是 ArkUI-X framework 公开导出的头文件,
// StageAssetManager.h 属于内部实现,在预编译 framework 中不可见,故不引入。
#import "StageApplication.h"
#endif

#import <spawn.h>
#import <sys/wait.h>

// module.json 中常见字段名常量,用于解析 hap 的运行时入口信息。
static NSString *const kDefaultModuleName = @"entry";
static NSString *const kDefaultAbilityName = @"EntryAbility";
static NSString *const kDefaultBundleName = @"com.example.hap";
static NSString *const kArkuiXDirName = @"arkui-x";

@interface HAPManager ()

@property (nonatomic, strong) NSString *currentHAPPath;
@property (nonatomic, strong) NSString *arkuiXDirectory;
@property (nonatomic, assign) BOOL isArkUIRunning;
@property (nonatomic, copy) NSString *currentBundleName;
@property (nonatomic, copy) NSString *currentModuleName;
@property (nonatomic, copy) NSString *currentAbilityName;

@end

static HAPManager *_sharedInstance = nil;

@implementation HAPManager

+ (instancetype)sharedManager {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[self alloc] init];
    });
    return _sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        self.arkuiXDirectory = [documentsDir stringByAppendingPathComponent:kArkuiXDirName];

        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:self.arkuiXDirectory]) {
            [fm createDirectoryAtPath:self.arkuiXDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }
    return self;
}

#pragma mark - Load HAP and run abc bytecode

- (void)loadHAPAtPath:(NSString *)hapPath completion:(HAPLoadCompletion)completion {
    if (!hapPath || ![hapPath hasSuffix:@".hap"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, @"Invalid HAP file path");
        });
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:hapPath]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, @"HAP file not found");
        });
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 先在主线程清理上一个 hap 的运行时状态(StageApplication 必须在主线程操作)。
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self unloadCurrentHAP];
        });

        // 解压 hap 到临时目录,hap 本质是 zip。
        NSString *tempDir = NSTemporaryDirectory();
        NSString *extractDir = [tempDir stringByAppendingPathComponent:@"hap_extract"];

        if ([fm fileExistsAtPath:extractDir]) {
            [fm removeItemAtPath:extractDir error:nil];
        }

        if (![self extractZIPFileAtPath:hapPath toDirectory:extractDir]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"Failed to extract HAP file");
            });
            return;
        }

        // 从解压目录中读取 module.json,解析出运行 abc 所需的 bundleName/moduleName/abilityName。
        NSString *appName = [hapPath lastPathComponent];
        appName = [appName stringByReplacingOccurrencesOfString:@".hap" withString:@""];
        NSString *bundleName = kDefaultBundleName;
        NSString *moduleName = kDefaultModuleName;
        NSString *abilityName = kDefaultAbilityName;

        NSDictionary *moduleInfo = [self parseModuleJsonInDirectory:extractDir];
        if (moduleInfo) {
            if (moduleInfo[@"appName"]) {
                appName = moduleInfo[@"appName"];
            }
            if (moduleInfo[@"bundleName"]) {
                bundleName = moduleInfo[@"bundleName"];
            }
            if (moduleInfo[@"moduleName"]) {
                moduleName = moduleInfo[@"moduleName"];
            }
            if (moduleInfo[@"abilityName"]) {
                abilityName = moduleInfo[@"abilityName"];
            }
        }

        // 校验解压结果中确实存在 abc 字节码文件,否则没必要继续。
        if (![self containsAbcBytecodeInDirectory:extractDir]) {
            [fm removeItemAtPath:extractDir error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"No ArkTS abc bytecode found in HAP");
            });
            return;
        }

        // 把 hap 解压内容安置到 Documents/arkui-x/{bundleName}.{moduleName}/ 下。
        // StageViewController initWithInstanceName 内部 ExistDir 会按 "/{bundleName}.{moduleName}/"
        // 搜索 StageAssetManager 中的路径(见 StageAssetManager+moduleNamePath 拼接逻辑),只有路径匹配,
        // StageViewController 才会把 self.moduleName 重写成 bundleName.moduleName,把 instanceName 改写成
        // 4 段式 bundleName : bundleName.moduleName : abilityName : instanceId。AppMain 读取 abc 时,也需要
        // 目录名与 module.json 中重写后的 module.name 一致,否则找不到 abc 入口。
        if (![self installExtractedFilesFrom:extractDir
                                  bundleName:bundleName
                                  moduleName:moduleName
                               abilityName:abilityName
                           toArkuiXDirectory:self.arkuiXDirectory]) {
            [fm removeItemAtPath:extractDir error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"Failed to install abc bytecode into arkui-x directory");
            });
            return;
        }

        [fm removeItemAtPath:extractDir error:nil];

        self.currentHAPPath = hapPath;
        self.currentBundleName = bundleName;
        self.currentModuleName = moduleName;
        self.currentAbilityName = abilityName;

        // 在主线程调用 StageApplication 配置 bundle 目录并启动 ArkUI 运行时,
        // 这一步会把 hap 中的 modules.abc 等 abc 字节码加载进 ArkUI-X 虚拟机并执行入口逻辑。
        dispatch_async(dispatch_get_main_queue(), ^{
#if HAS_ARKUI_X
            // 传入绝对路径(Documents/arkui-x),StageAssetManager 会扫描其下所有文件,
            // 包括 {moduleName}/ets/modules.abc 与 {moduleName}/module.json 等。
            [StageApplication configModuleWithBundleDirectory:self.arkuiXDirectory];

            // launchApplication 内部会注册 NSNotificationCenter observer、初始化 AppMain 单例、
            // 启动 ArkUI 虚拟机等全局副作用。重复调用会重复注册 observer 并二次初始化已存在的
            // 全局对象,直接崩溃。所以只在第一次加载 hap 时调用一次,后续 hap 切换只 configModule。
            if (!self.isArkUIRunning) {
                [StageApplication launchApplication];
                self.isArkUIRunning = YES;
                NSLog(@"[HAPManager] ArkUI runtime launched for bundle=%@ module=%@ ability=%@",
                      bundleName, moduleName, abilityName);
            } else {
                NSLog(@"[HAPManager] ArkUI runtime already running, re-configured module only");
            }
#else
            NSLog(@"[HAPManager] HAS_ARKUI_X disabled, abc bytecode cannot be executed.");
#endif
            completion(YES, nil);
        });
    });
}

- (void)getHAPInfoFromPath:(NSString *)hapPath completion:(HAPInfoCompletion)completion {
    [self getHAPModuleInfoFromPath:hapPath completion:^(NSString *appName, NSString *bundleName,
                                                       NSString *moduleName, NSString *abilityName, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(appName, bundleName, error);
        });
    }];
}

- (void)getHAPModuleInfoFromPath:(NSString *)hapPath completion:(HAPModuleInfoCompletion)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *appName = [hapPath lastPathComponent];
        appName = [appName stringByReplacingOccurrencesOfString:@".hap" withString:@""];

        NSString *bundleName = kDefaultBundleName;
        NSString *moduleName = kDefaultModuleName;
        NSString *abilityName = kDefaultAbilityName;

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *tempDir = NSTemporaryDirectory();
        NSString *extractDir = [tempDir stringByAppendingPathComponent:@"hap_info_extract"];

        if ([fm fileExistsAtPath:extractDir]) {
            [fm removeItemAtPath:extractDir error:nil];
        }

        if ([self extractZIPFileAtPath:hapPath toDirectory:extractDir]) {
            NSDictionary *moduleInfo = [self parseModuleJsonInDirectory:extractDir];
            if (moduleInfo) {
                if (moduleInfo[@"appName"]) {
                    appName = moduleInfo[@"appName"];
                }
                if (moduleInfo[@"bundleName"]) {
                    bundleName = moduleInfo[@"bundleName"];
                }
                if (moduleInfo[@"moduleName"]) {
                    moduleName = moduleInfo[@"moduleName"];
                }
                if (moduleInfo[@"abilityName"]) {
                    abilityName = moduleInfo[@"abilityName"];
                }
            }
            [fm removeItemAtPath:extractDir error:nil];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(appName, bundleName, moduleName, abilityName, nil);
        });
    });
}

- (void)listAvailableHAPsInDirectory:(NSString *)directory completion:(HAPListCompletion)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *hapInfoList = [NSMutableArray array];
        NSFileManager *fm = [NSFileManager defaultManager];

        NSError *error = nil;
        NSArray *contents = [fm contentsOfDirectoryAtPath:directory error:&error];
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }

        for (NSString *item in contents) {
            if ([item hasSuffix:@".hap"]) {
                NSString *hapPath = [directory stringByAppendingPathComponent:item];

                NSString *appName = [item stringByReplacingOccurrencesOfString:@".hap" withString:@""];
                NSString *bundleName = kDefaultBundleName;
                NSString *moduleName = kDefaultModuleName;
                NSString *abilityName = kDefaultAbilityName;

                NSString *tempDir = NSTemporaryDirectory();
                NSString *extractDir = [tempDir stringByAppendingPathComponent:@"hap_list_extract"];

                if ([fm fileExistsAtPath:extractDir]) {
                    [fm removeItemAtPath:extractDir error:nil];
                }

                if ([self extractZIPFileAtPath:hapPath toDirectory:extractDir]) {
                    NSDictionary *moduleInfo = [self parseModuleJsonInDirectory:extractDir];
                    if (moduleInfo) {
                        if (moduleInfo[@"appName"]) {
                            appName = moduleInfo[@"appName"];
                        }
                        if (moduleInfo[@"bundleName"]) {
                            bundleName = moduleInfo[@"bundleName"];
                        }
                        if (moduleInfo[@"moduleName"]) {
                            moduleName = moduleInfo[@"moduleName"];
                        }
                        if (moduleInfo[@"abilityName"]) {
                            abilityName = moduleInfo[@"abilityName"];
                        }
                    }
                    [fm removeItemAtPath:extractDir error:nil];
                }

                NSDictionary *hapInfo = @{
                    @"path": hapPath,
                    @"appName": appName,
                    @"bundleName": bundleName,
                    @"moduleName": moduleName,
                    @"abilityName": abilityName
                };
                [hapInfoList addObject:hapInfo];
            }
        }

        NSArray *sortedList = [hapInfoList sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
            NSString *name1 = obj1[@"appName"];
            NSString *name2 = obj2[@"appName"];
            return [name1 localizedStandardCompare:name2];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(sortedList, nil);
        });
    });
}

#pragma mark - Foreground / Background

- (void)callCurrentAbilityOnForeground {
#if HAS_ARKUI_X
    [StageApplication callCurrentAbilityOnForeground];
#endif
}

- (void)callCurrentAbilityOnBackground {
#if HAS_ARKUI_X
    [StageApplication callCurrentAbilityOnBackground];
#endif
}

- (void)unloadCurrentHAP {
#if HAS_ARKUI_X
    // 销毁当前所有 StageViewController 关联的 ability,以便下一次加载 hap 时
    // 新的 abc 字节码可以干净地加载。
    //
    // 注意 1:这里不调用 destroyVm。destroyVm 会销毁 ArkTS 虚拟机,但 StageApplication
    // 的 launchApplication 只能调一次(内部会重复注册 NotificationCenter observer 并二次
    // 初始化 AppMain 单例导致崩溃)。VM 销毁后无法重建,新 hap 的 abc 就无法运行。
    // 因此 hap 切换的正确做法是:保留 VM,只 releaseViewControllers + configModule 重载 abc。
    //
    // 注意 2:releaseViewControllers 这个 selector 虽然在 StageApplication.h 源码里声明了,
    // 但官方 SDK(libarkui_ios.xcframework)的公开导出 Headers 中并未包含它。为了保证 CI
    // 使用预编译 framework 时也能编过,这里改为 performSelector 动态调用,并通过
    // respondsToSelector 做运行时保护。
    StageApplication *shared = [StageApplication class];
    if ([shared respondsToSelector:@selector(releaseViewControllers)]) {
        [shared performSelector:@selector(releaseViewControllers)];
    }
#endif

    NSFileManager *fm = [NSFileManager defaultManager];

    NSError *error = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:self.arkuiXDirectory error:&error];
    if (contents) {
        for (NSString *item in contents) {
            NSString *path = [self.arkuiXDirectory stringByAppendingPathComponent:item];
            [fm removeItemAtPath:path error:nil];
        }
    }

    self.currentHAPPath = nil;
    self.currentBundleName = nil;
    self.currentModuleName = nil;
    self.currentAbilityName = nil;
    // 注意:这里不重置 isArkUIRunning=NO。因为 StageApplication launchApplication 只能调一次,
    // 重复调用会重复注册 NotificationCenter observer 并二次初始化 AppMain 单例导致崩溃。
    // isArkUIRunning 保持 YES,后续 loadHAP 只走 configModule 路径重载新 hap 的 abc 字节码。
}

#pragma mark - ZIP extract helpers

- (BOOL)extractZIPFileAtPath:(NSString *)zipPath toDirectory:(NSString *)destDir {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *unzipPath = [destDir stringByAppendingPathComponent:@"unzip"];
    if (![fm createDirectoryAtPath:unzipPath withIntermediateDirectories:YES attributes:nil error:nil]) {
        return NO;
    }

    const char *args[] = {"/usr/bin/unzip", "-q", "-o", [zipPath UTF8String], "-d", [unzipPath UTF8String], NULL};

    pid_t pid;
    int status;
    posix_spawn(&pid, "/usr/bin/unzip", NULL, NULL, (char * const *)args, NULL);
    waitpid(pid, &status, 0);

    if (WEXITSTATUS(status) != 0) {
        return NO;
    }

    if (![self moveExtractedContentsFrom:unzipPath to:destDir]) {
        return NO;
    }

    [fm removeItemAtPath:unzipPath error:nil];

    return YES;
}

- (BOOL)moveExtractedContentsFrom:(NSString *)sourceDir to:(NSString *)destDir {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSError *error = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:sourceDir error:&error];
    if (!contents || error) {
        return NO;
    }

    for (NSString *item in contents) {
        NSString *sourcePath = [sourceDir stringByAppendingPathComponent:item];
        NSString *destPath = [destDir stringByAppendingPathComponent:item];

        if ([fm fileExistsAtPath:destPath]) {
            [fm removeItemAtPath:destPath error:nil];
        }

        if (![fm moveItemAtPath:sourcePath toPath:destPath error:&error]) {
            return NO;
        }
    }

    return YES;
}

#pragma mark - module.json parsing

// 在 hap 解压目录中定位 module.json(可能在根目录,也可能在 entry/ 子目录下),
// 解析出 bundleName(来自 app.bundleName)、moduleName(来自 module.name)、
// 以及 abilityName(取 module.abilities[0].name 或 module.mainElement)。
- (NSDictionary *)parseModuleJsonInDirectory:(NSString *)extractDir {
    NSString *moduleJsonPath = [extractDir stringByAppendingPathComponent:@"module.json"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:moduleJsonPath]) {
        // 兼容某些 hap 解压后 module.json 位于 entry/ 子目录的情况。
        NSString *entryDir = [extractDir stringByAppendingPathComponent:@"entry"];
        moduleJsonPath = [entryDir stringByAppendingPathComponent:@"module.json"];
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:moduleJsonPath]) {
        return nil;
    }

    NSData *jsonData = [NSData dataWithContentsOfFile:moduleJsonPath];
    if (!jsonData) {
        return nil;
    }

    NSError *error = nil;
    NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    if (error || !jsonDict) {
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    NSDictionary *appObj = jsonDict[@"app"];
    NSDictionary *moduleObj = jsonDict[@"module"];
    if (![moduleObj isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    if ([appObj isKindOfClass:[NSDictionary class]]) {
        NSString *bundleName = appObj[@"bundleName"];
        if ([bundleName isKindOfClass:[NSString class]] && bundleName.length > 0) {
            result[@"bundleName"] = bundleName;
        }
    }

    NSString *moduleName = moduleObj[@"name"];
    if ([moduleName isKindOfClass:[NSString class]] && moduleName.length > 0) {
        result[@"moduleName"] = moduleName;
        // 把 module 名也作为展示名,UI 上更友好。
        if (!result[@"appName"]) {
            result[@"appName"] = moduleName;
        }
    }

    NSString *mainElement = moduleObj[@"mainElement"];
    if ([mainElement isKindOfClass:[NSString class]] && mainElement.length > 0) {
        result[@"abilityName"] = mainElement;
    }

    // 优先从 abilities 数组中取第一个 ability 名,作为运行 abc 的真实入口。
    NSArray *abilities = moduleObj[@"abilities"];
    if ([abilities isKindOfClass:[NSArray class]] && abilities.count > 0) {
        NSDictionary *firstAbility = abilities[0];
        if ([firstAbility isKindOfClass:[NSDictionary class]]) {
            NSString *abilityName = firstAbility[@"name"];
            if ([abilityName isKindOfClass:[NSString class]] && abilityName.length > 0) {
                result[@"abilityName"] = abilityName;
            }
        }
    }

    // 兜底默认值,保证后续拼接 instanceName 不会因为缺字段而失败。
    if (!result[@"bundleName"]) {
        result[@"bundleName"] = kDefaultBundleName;
    }
    if (!result[@"moduleName"]) {
        result[@"moduleName"] = kDefaultModuleName;
    }
    if (!result[@"abilityName"]) {
        result[@"abilityName"] = kDefaultAbilityName;
    }

    return result;
}

// 检查解压目录中是否包含 ArkTS 编译产物 abc 字节码文件,这是 hap 能否被运行的关键依据。
- (BOOL)containsAbcBytecodeInDirectory:(NSString *)directory {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:directory];
    for (NSString *file in enumerator) {
        if ([file hasSuffix:@".abc"]) {
            return YES;
        }
    }
    return NO;
}

// 把 hap 解压内容安置到 Documents/arkui-x/{bundleName}.{moduleName}/ 下。
//
// 目录名用 "bundleName.moduleName" 是为了同时满足三处路径匹配:
//   a) StageViewController.initWithInstanceName 中的 ExistDir: 会按
//      "/{bundleName}.{moduleName}/" 在 StageAssetManager.allModuleFilePathArray 中搜索,
//      命中后才会把 self.moduleName 改写成 bundleName.moduleName,并同步改写 instanceName。
//   b) AppMain 在 LaunchApplication 时扫描 module.json,StageAssetManager 的
//      updateModuleNameWithJsonData: 会在 module.json 路径中包含
//      bundleName.moduleName 时,把 json 里的 module.name 重写成 bundleName.moduleName。
//   c) abc 字节码中的模块引用也需要与 重写后的 module.name 对齐,否则 DispatchOnCreate
//      找不到入口 ability → Surface 出来但一片空白。
//
// 安装完成后,本方法还会:
//   1. 重写安装目录下的 module.json,显式把 module.name 改成 bundleName.moduleName,
//      module.packageName 改成 bundleName.packageName;
//   2. 在 arkuiXDirectory 下生成 AppScope/app.json,写进 app.bundleName 等字段,
//      保证 AppMain 在加载 abc 前能读到完整的 app 信息结构(缺 app.json 会直接崩)。
- (BOOL)installExtractedFilesFrom:(NSString *)extractDir
                       bundleName:(NSString *)bundleName
                       moduleName:(NSString *)moduleName
                    abilityName:(NSString *)abilityName
                toArkuiXDirectory:(NSString *)arkuiXDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:arkuiXDirectory]) {
        [fm createDirectoryAtPath:arkuiXDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // 最终目录名: bundleName.moduleName (例如 com.example.entry)
    NSString *qualifiedModuleName = [NSString stringWithFormat:@"%@.%@", bundleName, moduleName];
    NSString *moduleDestDir = [arkuiXDirectory stringByAppendingPathComponent:qualifiedModuleName];
    if ([fm fileExistsAtPath:moduleDestDir]) {
        [fm removeItemAtPath:moduleDestDir error:nil];
    }
    if (![fm createDirectoryAtPath:moduleDestDir withIntermediateDirectories:YES attributes:nil error:nil]) {
        return NO;
    }

    NSError *error = nil;
    NSArray *entries = [fm contentsOfDirectoryAtPath:extractDir error:&error];
    if (!entries) {
        return NO;
    }

    // 先把文件全部拷贝到 moduleDestDir。
    for (NSString *entry in entries) {
        // hap 内容里若已自带与 moduleName 同名的子目录(例如 entry/),直接展开避免嵌套;
        // 否则把每个条目直接拷贝到 {bundleName}.{moduleName}/ 下。
        if ([entry isEqualToString:moduleName]) {
            NSString *nestedDir = [extractDir stringByAppendingPathComponent:entry];
            NSArray *nestedEntries = [fm contentsOfDirectoryAtPath:nestedDir error:nil];
            if (!nestedEntries) {
                continue;
            }
            for (NSString *nestedEntry in nestedEntries) {
                NSString *sourcePath = [nestedDir stringByAppendingPathComponent:nestedEntry];
                NSString *destPath = [moduleDestDir stringByAppendingPathComponent:nestedEntry];
                if ([fm fileExistsAtPath:destPath]) {
                    [fm removeItemAtPath:destPath error:nil];
                }
                if (![fm copyItemAtPath:sourcePath toPath:destPath error:&error]) {
                    return NO;
                }
            }
            continue;
        }

        NSString *sourcePath = [extractDir stringByAppendingPathComponent:entry];
        NSString *destPath = [moduleDestDir stringByAppendingPathComponent:entry];
        if ([fm fileExistsAtPath:destPath]) {
            [fm removeItemAtPath:destPath error:nil];
        }
        if (![fm copyItemAtPath:sourcePath toPath:destPath error:&error]) {
            return NO;
        }
    }

    // ===== 1. 重写安装目录下的 module.json =====
    // 显式把 module.name 改成 bundleName.moduleName,
    // 保证 AppMain 读到的 module.name 与 StageViewController 传的一致。
    NSString *installedModuleJsonPath = [moduleDestDir stringByAppendingPathComponent:@"module.json"];
    if ([fm fileExistsAtPath:installedModuleJsonPath]) {
        NSData *jsonData = [NSData dataWithContentsOfFile:installedModuleJsonPath];
        if (jsonData) {
            NSError *jsonError = nil;
            NSMutableDictionary *jsonDict = [NSJSONSerialization
                JSONObjectWithData:jsonData
                           options:NSJSONReadingMutableContainers | NSJSONReadingMutableLeaves
                             error:&jsonError];
            if (!jsonError && [jsonDict isKindOfClass:[NSMutableDictionary class]]) {
                NSMutableDictionary *appObj = jsonDict[@"app"];
                NSMutableDictionary *moduleObj = jsonDict[@"module"];

                if (![appObj isKindOfClass:[NSMutableDictionary class]]) {
                    appObj = [NSMutableDictionary dictionary];
                    jsonDict[@"app"] = appObj;
                }
                if (![moduleObj isKindOfClass:[NSMutableDictionary class]]) {
                    moduleObj = [NSMutableDictionary dictionary];
                    jsonDict[@"module"] = moduleObj;
                }

                appObj[@"bundleName"] = bundleName;
                if (!appObj[@"appName"]) {
                    appObj[@"appName"] = moduleName;
                }
                if (!appObj[@"versionCode"]) {
                    appObj[@"versionCode"] = @(1000000);
                }
                if (!appObj[@"versionName"]) {
                    appObj[@"versionName"] = @"1.0.0";
                }
                if (!appObj[@"apiReleaseType"]) {
                    appObj[@"apiReleaseType"] = @"Release";
                }

                // 关键改写: module.name = bundleName.moduleName
                moduleObj[@"name"] = qualifiedModuleName;

                // packageName 同样前缀化,保证与 abc 中注册的包名对齐。
                NSString *origPackage = moduleObj[@"packageName"];
                if (origPackage && [origPackage isKindOfClass:[NSString class]] && origPackage.length > 0) {
                    // 如果原 packageName 已经带了 bundleName 前缀就不用重复加。
                    if (![origPackage hasPrefix:[NSString stringWithFormat:@"%@.", bundleName]]) {
                        moduleObj[@"packageName"] = [NSString stringWithFormat:@"%@.%@", bundleName, origPackage];
                    }
                } else {
                    moduleObj[@"packageName"] = [NSString stringWithFormat:@"%@.%@.uiability", bundleName, moduleName];
                }

                // 确保 module.mainElement 和 abilities[0].name 与传入的 abilityName 对齐。
                if (!moduleObj[@"mainElement"] && abilityName.length > 0) {
                    moduleObj[@"mainElement"] = abilityName;
                }

                NSData *written = [NSJSONSerialization dataWithJSONObject:jsonDict
                                                                   options:NSJSONWritingPrettyPrinted
                                                                     error:nil];
                if (written) {
                    [written writeToFile:installedModuleJsonPath atomically:YES];
                    NSLog(@"[HAPManager] Rewrote module.json: module.name=%@, bundleName=%@",
                          qualifiedModuleName, bundleName);
                }
            }
        }
    }

    // ===== 2. 在 arkuiXDirectory 根下生成 AppScope/app.json =====
    // 很多 ArkUI-X 的 AppMain::LaunchApplication 实现会先读 AppScope/app.json
    // (或等价的 app.json 位置)来取 bundleName 等 app 级信息;缺它的话 LaunchApplication
    // 可能直接 crash,或者后续 DispatchOnCreate 无法匹配到正确的入口 bundle。
    NSString *appScopeDir = [arkuiXDirectory stringByAppendingPathComponent:@"AppScope"];
    if (![fm fileExistsAtPath:appScopeDir]) {
        [fm createDirectoryAtPath:appScopeDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *appJsonPath = [appScopeDir stringByAppendingPathComponent:@"app.json"];

    NSMutableDictionary *appJson = [NSMutableDictionary dictionary];
    NSMutableDictionary *appSection = [NSMutableDictionary dictionaryWithDictionary:@{
        @"bundleName" : bundleName,
        @"vendor"     : @"arkuiplayer",
        @"versionCode": @(1000000),
        @"versionName": @"1.0.0",
        @"icon"       : @"$media:app_icon",
        @"label"      : @"$string:app_name",
        @"apiReleaseType": @"Release",
        @"apiVersion" : @{
            @"apiType":   @"standard",
            @"compatible": @11,
            @"target":    @11,
            @"releaseType": @"Release",
        },
    }];
    appJson[@"app"] = appSection;

    NSMutableArray *moduleListSection = [NSMutableArray arrayWithObject:@{
        @"name":       qualifiedModuleName,
        @"srcEntry":   @"",
        @"description": @"$string:module_description",
        @"mainElement": abilityName.length > 0 ? abilityName : @"EntryAbility",
    }];
    appJson[@"modules"] = moduleListSection;

    NSData *appJsonData = [NSJSONSerialization dataWithJSONObject:appJson
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:nil];
    if (appJsonData) {
        [appJsonData writeToFile:appJsonPath atomically:YES];
        NSLog(@"[HAPManager] Wrote AppScope/app.json with bundleName=%@ module=%@",
              bundleName, qualifiedModuleName);
    }

    return YES;
}

@end
