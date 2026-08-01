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
@property (nonatomic, assign) BOOL isInitialized;
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

- (void)initializeArkUI {
    if (self.isInitialized) {
        return;
    }
    self.isInitialized = YES;
    // 注意:StageApplication 的 configModule/launchApplication 推迟到 loadHAPAtPath 时再调用,
    // 因为此时才能从 hap 中解析出真实的 bundle 目录与 abc 字节码位置。
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
        // 先卸载当前已加载的 hap(包括销毁 ArkUI 运行时上下文)。
        [self unloadCurrentHAP];

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

        // 把 hap 解压内容安置到 Documents/arkui-x/{moduleName}/ 下,
        // 这样 StageAssetManager 才能按 "/<moduleName>/" 路径模式定位到 abc 与 resources.index。
        if (![self installExtractedFilesFrom:extractDir moduleName:moduleName toArkuiXDirectory:self.arkuiXDirectory]) {
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
            [StageApplication launchApplication];
            NSLog(@"[HAPManager] ArkUI runtime launched for bundle=%@ module=%@ ability=%@",
                  bundleName, moduleName, abilityName);
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
    // 销毁当前所有 StageViewController 关联的 ability,并尝试销毁 ArkTS 虚拟机,
    // 以确保下一次加载 hap 时 abc 字节码可以干净地重新加载与运行。
    //
    // 注意:releaseViewControllers / destroyVm 这两个 selector 虽然在
    // StageApplication.h 源码里声明了,但官方 SDK(libarkui_ios.xcframework)
    // 的公开导出 Headers 中并未包含它们。为了保证 CI 使用预编译 framework 时也能编过,
    // 这里改为 performSelector 动态调用,并通过 respondsToSelector 做运行时保护。
    StageApplication *shared = [StageApplication class];
    if ([shared respondsToSelector:@selector(releaseViewControllers)]) {
        [shared performSelector:@selector(releaseViewControllers)];
    }
    if ([shared respondsToSelector:@selector(destroyVm)]) {
        // destroyVm 返回 BOOL,用 NSInvocation 忽略返回值,避免 ARC/类型告警。
        SEL sel = @selector(destroyVm);
        NSMethodSignature *sig = [shared methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = shared;
        inv.selector = sel;
        [inv invoke];
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
    // 卸载后允许下一次 loadHAP 重新调用 StageApplication 配置与启动。
    self.isInitialized = NO;
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

// 把 hap 解压内容安置到 Documents/arkui-x/{moduleName}/ 下。
// hap 解压后内容(module.json、ets/、resources/ 等)对应 ArkUI-X 工程中的 "entry" 模块,
// 必须放在 {moduleName}/ 子目录里,StageAssetManager 才能通过 "/<moduleName>/" 路径模式定位到。
- (BOOL)installExtractedFilesFrom:(NSString *)extractDir
                       moduleName:(NSString *)moduleName
                toArkuiXDirectory:(NSString *)arkuiXDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:arkuiXDirectory]) {
        [fm createDirectoryAtPath:arkuiXDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSString *moduleDestDir = [arkuiXDirectory stringByAppendingPathComponent:moduleName];
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

    for (NSString *entry in entries) {
        // hap 内容里若已自带与 moduleName 同名的子目录(例如 entry/),直接整体跳过外层避免嵌套;
        // 否则把每个条目拷贝到 {moduleName}/ 下。
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

    return YES;
}

@end
