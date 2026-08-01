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
// StageAssetProvider::GetAppDataModuleDir() 内部返回的路径是
// Documents/files/arkui-x(见 stage_asset_provider.mm),hap 必须解压到这个目录下,
// 否则 GetModuleBuffer / GetModuleAbilityBuffer 在 StageAssetManager 数组里找不到
// abc 时走回退路径 GetAppDataModuleDir()+moduleName 会落空,返回空 buffer 让 AppMain 崩溃。
static NSString *const kFilesSubdirName = @"files";

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
        // 必须用 Documents/files/arkui-x,与 StageAssetProvider::GetAppDataModuleDir() 对齐。
        // StageAssetProvider 在 StageAssetManager 数组里找不到 abc 时,会回退到
        // GetAppDataModuleDir()+moduleName 查找,如果 hap 没解压到这个目录,回退路径会落空。
        NSString *documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *filesDir = [documentsDir stringByAppendingPathComponent:kFilesSubdirName];
        self.arkuiXDirectory = [filesDir stringByAppendingPathComponent:kArkuiXDirName];

        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:self.arkuiXDirectory]) {
            [fm createDirectoryAtPath:self.arkuiXDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        }

        // 清理旧版本残留在 Documents/arkui-x 的数据(早期版本用 Documents/arkui-x,
        // 与 GetAppDataModuleDir() 的 Documents/files/arkui-x 不一致,留着会干扰扫描)。
        NSString *legacyDir = [documentsDir stringByAppendingPathComponent:kArkuiXDirName];
        if ([fm fileExistsAtPath:legacyDir]) {
            NSLog(@"[HAPManager] Cleaning legacy arkui-x directory at %@", legacyDir);
            [fm removeItemAtPath:legacyDir error:nil];
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

        // 打印 hap 解压后的目录结构(前 30 个条目),便于排查 hap 真实产物结构。
        NSLog(@"[HAPManager] HAP extracted to %@, top-level entries:", extractDir);
        NSArray *extractTopEntries = [fm contentsOfDirectoryAtPath:extractDir error:nil];
        for (NSString *entry in extractTopEntries) {
            BOOL isDir = NO;
            [fm fileExistsAtPath:[extractDir stringByAppendingPathComponent:entry] isDirectory:&isDir];
            NSLog(@"[HAPManager]   %@%@", entry, isDir ? @"/" : @"");
        }
        NSUInteger totalSubpaths = [[fm subpathsOfDirectoryAtPath:extractDir error:nil] count];
        NSLog(@"[HAPManager] Total subpaths under extract dir: %lu", (unsigned long)totalSubpaths);

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

        // 把 hap 解压内容安置到 Documents/arkui-x/{moduleName}/ 下。
        //
        // 真实未签名 hap 解压后根目录直接是 ets/modules.abc、module.json、resources/、resources.index、
        // pack.info、pkgContextInfo.json(没有 entry/ 子目录)。而 ArkUI-X iOS 工程期望的 arkui-x/ 目录
        // 结构是 {moduleName}/ 子目录 + AppScope/(可选) + systemres/(SDK 提供)。
        // 所以这里把 hap 解压根目录的所有条目整体拷贝到 {moduleName}/ 下,目录名用纯 moduleName(如 entry),
        // 与 ArkUI-X 官方文档的 iOS 工程产物结构对齐:
        //   arkui-x/entry/ets/modules.abc
        //   arkui-x/entry/module.json
        //   arkui-x/entry/resources/...
        //
        // 注意:不要把目录名改成 bundleName.moduleName(如 com.example.entry)!
        // a) ArkUI-X 官方文档明确 iOS 工程产物目录名就是纯 moduleName。
        // b) StageViewController.initWithInstanceName 中的 ExistDir 会搜索 "/bundleName.moduleName/",
        //    标准产物路径里只有 "/entry/",所以 ExistDir 返回 NO,StageVC 保持 moduleName="entry" 不重写,
        //    这与 AppMain 从 module.json 读到的 module.name="entry" 一致,DispatchOnCreate 能正确匹配 abc。
        // c) abc 字节码中模块名由 ArkTS 编译器决定(通常是 "entry"),改写 module.json 不会影响 abc 内部
        //    的模块名注册,反而会导致 module.name 与 abc 模块名错位 → AppMain 找不到 abc 入口 → 闪退或白屏。
        // d) SDK 内部的 updateModuleNameWithJsonData: 也只在路径包含 bundleName.moduleName 时才改写
        //    module.name,标准产物路径不包含,所以不改写是预期行为。
        if (![self installExtractedFilesFrom:extractDir
                                  moduleName:moduleName
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
            NSLog(@"[HAPManager] configModuleWithBundleDirectory: %@", self.arkuiXDirectory);
            [StageApplication configModuleWithBundleDirectory:self.arkuiXDirectory];

            // 打印已安装到 arkui-x 下的 module.json 内容,确认 hap 中的 module.json 被原样拷贝
            // (未做改写),module.name 仍是 ArkTS 编译器写入的原始值(通常是 "entry")。
            NSString *installedModuleJson = [self.arkuiXDirectory
                stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/module.json", moduleName]];
            NSData *installedJsonData = [NSData dataWithContentsOfFile:installedModuleJson];
            if (installedJsonData) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:installedJsonData
                                                                     options:0
                                                                       error:nil];
                NSLog(@"[HAPManager] Installed module.json: app.bundleName=%@, module.name=%@, module.mainElement=%@",
                      json[@"app"][@"bundleName"],
                      json[@"module"][@"name"],
                      json[@"module"][@"mainElement"]);
            } else {
                NSLog(@"[HAPManager] ⚠️ module.json not found at %@", installedModuleJson);
            }

            // 确认 abc 文件确实存在于安装目录下。
            NSString *abcPath = [self.arkuiXDirectory
                stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/ets/modules.abc", moduleName]];
            BOOL abcExists = [[NSFileManager defaultManager] fileExistsAtPath:abcPath];
            NSLog(@"[HAPManager] abc file at %@ exists=%d", abcPath, abcExists);
            if (!abcExists) {
                // 退而检查 ets 目录下其他 .abc 文件(AbilityStage.abc 等)。
                NSString *etsDir = [self.arkuiXDirectory
                    stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/ets", moduleName]];
                NSArray *etsFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:etsDir error:nil];
                NSLog(@"[HAPManager] ets dir contents: %@", etsFiles);
            }

            // launchApplication 内部会注册 NSNotificationCenter observer、初始化 AppMain 单例、
            // 启动 ArkUI 虚拟机等全局副作用。重复调用会重复注册 observer 并二次初始化已存在的
            // 全局对象,直接崩溃。所以只在第一次加载 hap 时调用一次,后续 hap 切换只 configModule。
            if (!self.isArkUIRunning) {
                NSLog(@"[HAPManager] First launchApplication, calling StageApplication.launchApplication...");
                @try {
                    [StageApplication launchApplication];
                    self.isArkUIRunning = YES;
                    NSLog(@"[HAPManager] ArkUI runtime launched OK for bundle=%@ module=%@ ability=%@",
                          bundleName, moduleName, abilityName);
                } @catch (NSException *e) {
                    NSLog(@"[HAPManager] ❌ launchApplication crashed: %@\n%@", e, e.callStackSymbols);
                    completion(NO, [NSString stringWithFormat:@"launchApplication crashed: %@", e.reason]);
                    return;
                }
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

// 把 hap 解压内容安置到 Documents/arkui-x/{moduleName}/ 下。
//
// 真实未签名 hap 解压后根目录直接是 ets/modules.abc、module.json、resources/、resources.index、
// pack.info、pkgContextInfo.json 等(没有 entry/ 子目录)。ArkUI-X iOS 工程期望的 arkui-x/ 目录
// 结构是 {moduleName}/ 子目录 + systemres/(SDK 提供)。所以这里把 hap 解压根目录的所有
// 条目整体拷贝到 {moduleName}/ 下,目录名用纯 moduleName(如 entry),与官方产物结构对齐。
//
// 关键:不要改写 module.json,不要生成 AppScope/app.json!
// - module.json 的 module.name 字段在 hap 编译时就由 ArkTS 编译器决定(通常是 "entry"),
//   与 abc 字节码中注册的模块名一致。手动改写 module.name 会导致 module.name 与 abc 模块名错位,
//   AppMain 找不到 abc 入口 → 闪退或白屏。
// - StageAssetManager 的 updateModuleNameWithJsonData: 也只在路径包含 bundleName.moduleName
//   时才改写 module.name。标准产物路径只含 "/entry/",不含 "/bundleName.entry/",所以 SDK
//   不会改写 module.name,这是预期行为。
// - AppMain::LaunchApplication 会从 module.json 自身的 app.bundleName 字段读取 app 信息,
//   不需要额外的 AppScope/app.json。手动合成格式不正确的 app.json 反而会干扰 AppMain。
- (BOOL)installExtractedFilesFrom:(NSString *)extractDir
                       moduleName:(NSString *)moduleName
                toArkuiXDirectory:(NSString *)arkuiXDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:arkuiXDirectory]) {
        [fm createDirectoryAtPath:arkuiXDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // 目录名用纯 moduleName(如 "entry"),对齐 ArkUI-X 官方 iOS 工程产物结构。
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

    NSLog(@"[HAPManager] Installing hap contents into %@ (entries=%lu)",
          moduleDestDir, (unsigned long)entries.count);

    // 把 hap 解压根目录的所有条目整体拷贝到 {moduleName}/ 下。
    // hap 内容里若已自带与 moduleName 同名的子目录(某些 hap 把内容打包在 entry/ 子目录里),
    // 直接展开避免嵌套。
    for (NSString *entry in entries) {
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
                    NSLog(@"[HAPManager] Failed to copy %@ -> %@ : %@", sourcePath, destPath, error);
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
            NSLog(@"[HAPManager] Failed to copy %@ -> %@ : %@", sourcePath, destPath, error);
            return NO;
        }
    }

    // 打印安装后的目录结构(只列前 30 个条目,递归扫描),便于在 CI 日志中排查 hap 结构问题。
    NSLog(@"[HAPManager] Installed directory tree under %@:", moduleDestDir);
    NSArray *installedSubpaths = [fm subpathsOfDirectoryAtPath:moduleDestDir error:nil];
    NSUInteger printCount = MIN(installedSubpaths.count, 30);
    for (NSUInteger i = 0; i < printCount; i++) {
        NSLog(@"[HAPManager]   %@", [moduleDestDir stringByAppendingPathComponent:installedSubpaths[i]]);
    }
    if (installedSubpaths.count > printCount) {
        NSLog(@"[HAPManager]   ... and %lu more entries", (unsigned long)(installedSubpaths.count - printCount));
    }

    return YES;
}

@end
