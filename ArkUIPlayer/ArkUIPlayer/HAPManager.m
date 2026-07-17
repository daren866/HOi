#import "HAPManager.h"
#import "StageApplication.h"
#import <spawn.h>
#import <sys/wait.h>

@interface HAPManager ()

@property (nonatomic, strong) NSString *currentHAPPath;
@property (nonatomic, strong) NSString *arkuiXDirectory;
@property (nonatomic, assign) BOOL isInitialized;

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
        self.arkuiXDirectory = [documentsDir stringByAppendingPathComponent:@"arkui-x"];
        
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
    
    NSString *bundleDirectory = [[NSBundle mainBundle] bundlePath];
    [StageApplication configModuleWithBundleDirectory:bundleDirectory];
    [StageApplication launchApplication];
    
    self.isInitialized = YES;
}

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
        [self unloadCurrentHAP];
        
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
        
        if (![self copyExtractedFilesToArkuiXDirectory:extractDir]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"Failed to copy files to arkui-x directory");
            });
            return;
        }
        
        [fm removeItemAtPath:extractDir error:nil];
        
        self.currentHAPPath = hapPath;
        
        [StageApplication loadModule:@"entry" entryFile:@"index.ets"];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(YES, nil);
        });
    });
}

- (void)getHAPInfoFromPath:(NSString *)hapPath completion:(HAPInfoCompletion)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *appName = [hapPath lastPathComponent];
        appName = [appName stringByReplacingOccurrencesOfString:@".hap" withString:@""];
        
        NSString *bundleName = @"com.example.hap";
        
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *tempDir = NSTemporaryDirectory();
        NSString *extractDir = [tempDir stringByAppendingPathComponent:@"hap_info_extract"];
        
        if ([fm fileExistsAtPath:extractDir]) {
            [fm removeItemAtPath:extractDir error:nil];
        }
        
        if ([self extractZIPFileAtPath:hapPath toDirectory:extractDir]) {
            NSString *moduleJsonPath = [extractDir stringByAppendingPathComponent:@"module.json"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:moduleJsonPath]) {
                NSString *entryDir = [extractDir stringByAppendingPathComponent:@"entry"];
                moduleJsonPath = [entryDir stringByAppendingPathComponent:@"module.json"];
            }
            
            if ([[NSFileManager defaultManager] fileExistsAtPath:moduleJsonPath]) {
                NSError *error = nil;
                NSData *jsonData = [NSData dataWithContentsOfFile:moduleJsonPath];
                if (jsonData) {
                    NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
                    if (jsonDict) {
                        if (jsonDict[@"module"][@"name"]) {
                            appName = jsonDict[@"module"][@"name"];
                        }
                        if (jsonDict[@"module"][@"bundleName"]) {
                            bundleName = jsonDict[@"module"][@"bundleName"];
                        }
                    }
                }
            }
            
            [fm removeItemAtPath:extractDir error:nil];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(appName, bundleName, nil);
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
                NSString *bundleName = @"com.example.hap";
                
                NSString *tempDir = NSTemporaryDirectory();
                NSString *extractDir = [tempDir stringByAppendingPathComponent:@"hap_list_extract"];
                
                if ([fm fileExistsAtPath:extractDir]) {
                    [fm removeItemAtPath:extractDir error:nil];
                }
                
                if ([self extractZIPFileAtPath:hapPath toDirectory:extractDir]) {
                    NSString *moduleJsonPath = [extractDir stringByAppendingPathComponent:@"module.json"];
                    if (![[NSFileManager defaultManager] fileExistsAtPath:moduleJsonPath]) {
                        NSString *entryDir = [extractDir stringByAppendingPathComponent:@"entry"];
                        moduleJsonPath = [entryDir stringByAppendingPathComponent:@"module.json"];
                    }
                    
                    if ([[NSFileManager defaultManager] fileExistsAtPath:moduleJsonPath]) {
                        NSError *jsonError = nil;
                        NSData *jsonData = [NSData dataWithContentsOfFile:moduleJsonPath];
                        if (jsonData) {
                            NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
                            if (jsonDict) {
                                if (jsonDict[@"module"][@"name"]) {
                                    appName = jsonDict[@"module"][@"name"];
                                }
                                if (jsonDict[@"module"][@"bundleName"]) {
                                    bundleName = jsonDict[@"module"][@"bundleName"];
                                }
                            }
                        }
                    }
                    
                    [fm removeItemAtPath:extractDir error:nil];
                }
                
                NSDictionary *hapInfo = @{
                    @"path": hapPath,
                    @"appName": appName,
                    @"bundleName": bundleName
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

- (BOOL)extractZIPFileAtPath:(NSString *)zipPath toDirectory:(NSString *)destDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSString *unzipPath = [destDir stringByAppendingPathComponent:@"unzip"];
    if (![fm createDirectoryAtPath:unzipPath withIntermediateDirectories:YES attributes:nil error:nil]) {
        return NO;
    }
    
    const char *args[] = {"/usr/bin/unzip", "-q", [zipPath UTF8String], "-d", [unzipPath UTF8String], NULL};
    
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

- (BOOL)copyExtractedFilesToArkuiXDirectory:(NSString *)extractDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:self.arkuiXDirectory]) {
        [fm createDirectoryAtPath:self.arkuiXDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    NSError *error = nil;
    NSArray *entries = [fm contentsOfDirectoryAtPath:extractDir error:&error];
    if (!entries) {
        return NO;
    }
    
    for (NSString *entry in entries) {
        NSString *sourcePath = [extractDir stringByAppendingPathComponent:entry];
        NSString *destPath = [self.arkuiXDirectory stringByAppendingPathComponent:entry];
        
        if ([fm fileExistsAtPath:destPath]) {
            [fm removeItemAtPath:destPath error:nil];
        }
        
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:sourcePath isDirectory:&isDir]) {
            if (isDir) {
                [fm copyItemAtPath:sourcePath toPath:destPath error:&error];
            } else {
                [fm copyItemAtPath:sourcePath toPath:destPath error:&error];
            }
        }
    }
    
    return YES;
}

- (void)callCurrentAbilityOnForeground {
    [StageApplication callCurrentAbilityOnForeground];
}

- (void)callCurrentAbilityOnBackground {
    [StageApplication callCurrentAbilityOnBackground];
}

- (void)unloadCurrentHAP {
    [StageApplication releaseViewControllers];
    
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
}

@end
