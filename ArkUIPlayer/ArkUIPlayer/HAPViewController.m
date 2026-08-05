#import "HAPViewController.h"
#import "HAPPlayerViewController.h"
#import "LogFloatingButton.h"
#import <QuartzCore/QuartzCore.h>

@interface HAPViewController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>

@property (nonatomic, strong) UITableView *tableView;
// hapInfoList / loadingIndicator 在 .h 中声明为 readonly,这里改为 readwrite 以便内部修改。
@property (nonatomic, strong, readwrite) NSMutableArray<NSDictionary *> *hapInfoList;
@property (nonatomic, strong, readwrite) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UIButton *installButton;
// 标记正在重启 hap,避免 viewDidLoad 注册的通知在 pop 时重复触发。
@property (nonatomic, assign) BOOL isRestarting;

@end

@implementation HAPViewController

- (instancetype)initWithHAPManager:(HAPManager *)manager {
    self = [super init];
    if (self) {
        self.hapManager = manager;
        self.hapInfoList = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"HOi";
    self.view.backgroundColor = [UIColor whiteColor];

    [self setupUI];
    [self loadHAPList];

    // 监听悬浮菜单的退出/重启通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(handleExitHAP)
                                               name:kLogMenuExitHAPNotification
                                             object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(handleRestartHAP)
                                               name:kLogMenuRestartHAPNotification
                                             object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(handleBackPress)
                                               name:kLogMenuBackPressNotification
                                             object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupUI {
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenWidth, 60)];
    headerView.backgroundColor = [UIColor clearColor];
    
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, screenWidth, 60)];
    titleLabel.text = @"HOi";
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [headerView addSubview:titleLabel];
    
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.tableHeaderView = headerView;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];
    
    self.installButton = [[UIButton alloc] initWithFrame:CGRectZero];
    [self.installButton setTitle:@"安装hap" forState:UIControlStateNormal];
    [self.installButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [self.installButton setBackgroundColor:[UIColor colorWithRed:200/255.0 green:200/255.0 blue:200/255.0 alpha:1.0]];
    self.installButton.titleLabel.font = [UIFont systemFontOfSize:18];
    [self.installButton addTarget:self action:@selector(installHAPFile) forControlEvents:UIControlEventTouchUpInside];
    self.installButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.installButton];
    
    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.loadingIndicator.center = self.view.center;
    self.loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.loadingIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.installButton.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        
        [self.installButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-34],
        [self.installButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.installButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.installButton.heightAnchor constraintEqualToConstant:50]
    ]];
}

- (void)loadHAPList {
    [self.loadingIndicator startAnimating];
    
    NSString *documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    
    [self.hapManager listAvailableHAPsInDirectory:documentsDir completion:^(NSArray<NSDictionary *> *hapInfoList, NSError *error) {
        [self.loadingIndicator stopAnimating];
        
        if (error) {
            NSLog(@"Failed to load HAP list: %@", error.localizedDescription);
            return;
        }
        
        [self.hapInfoList removeAllObjects];
        [self.hapInfoList addObjectsFromArray:hapInfoList];
        [self.tableView reloadData];
    }];
}

- (void)installHAPFile {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.item"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) {
        return;
    }
    
    NSURL *fileURL = urls[0];
    NSString *fileName = fileURL.lastPathComponent;
    
    if (![fileName hasSuffix:@".hap"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"请选择.hap格式的文件" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSError *copyError = nil;
    [fm copyItemAtURL:fileURL toURL:[NSURL fileURLWithPath:tempPath] error:&copyError];
    
    if (copyError) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误" message:@"无法读取文件" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    [self.hapManager getHAPInfoFromPath:tempPath completion:^(NSString *appName, NSString *bundleName, NSError *error) {
        [fm removeItemAtPath:tempPath error:nil];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"安装确认" message:[NSString stringWithFormat:@"是否安装 %@?", appName] preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *destPath = [documentsDir stringByAppendingPathComponent:fileName];
            
            NSFileManager *fm2 = [NSFileManager defaultManager];
            if ([fm2 fileExistsAtPath:destPath]) {
                [fm2 removeItemAtPath:destPath error:nil];
            }
            
            NSError *saveError = nil;
            [fm2 copyItemAtURL:fileURL toURL:[NSURL fileURLWithPath:destPath] error:&saveError];
            
            if (saveError) {
                UIAlertController *errorAlert = [UIAlertController alertControllerWithTitle:@"错误" message:@"安装失败" preferredStyle:UIAlertControllerStyleAlert];
                [errorAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:errorAlert animated:YES completion:nil];
                return;
            }
            
            [self loadHAPList];
        }]];
        
        [self presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // User cancelled
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.hapInfoList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"HAPCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"HAPCell"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    NSDictionary *hapInfo = self.hapInfoList[indexPath.row];
    cell.textLabel.text = hapInfo[@"appName"];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:16];

    NSString *bundleName = hapInfo[@"bundleName"] ?: @"";
    NSString *moduleName = hapInfo[@"moduleName"] ?: @"";
    NSString *abilityName = hapInfo[@"abilityName"] ?: @"";
    NSString *pageName = hapInfo[@"pageName"] ?: @"";
    // 在副标题里展示 hap 的入口三元组 + 入口界面名(若解析到 srcEntry),
    // 方便确认 abc 字节码对应的运行入口是否被正确解析。
    NSString *subtitle = [NSString stringWithFormat:@"%@ | %@:%@", bundleName, moduleName, abilityName];
    if (pageName.length > 0) {
        subtitle = [NSString stringWithFormat:@"%@ | page=%@", subtitle, pageName];
    }
    cell.detailTextLabel.text = subtitle;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor grayColor];

    UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
    iconView.backgroundColor = [UIColor colorWithRed:200/255.0 green:200/255.0 blue:200/255.0 alpha:1.0];
    cell.imageView.image = iconView.image;

    return cell;
}

#pragma mark - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 70;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *hapInfo = self.hapInfoList[indexPath.row];
    NSString *hapPath = hapInfo[@"path"];
    NSString *bundleName = hapInfo[@"bundleName"] ?: @"com.example.hap";
    NSString *moduleName = hapInfo[@"moduleName"] ?: @"entry";
    NSString *abilityName = hapInfo[@"abilityName"] ?: @"EntryAbility";
    NSString *appName = hapInfo[@"appName"] ?: [hapPath.lastPathComponent stringByDeletingPathExtension];
    NSString *pageName = hapInfo[@"pageName"] ?: @"";

    // 点击前先清理上一次崩溃可能残留的错误 UI
    [self.hapManager hideGlobalError];

    [self.loadingIndicator startAnimating];

    [self.hapManager loadHAPAtPath:hapPath completion:^(BOOL success, NSString *errorMessage) {
        NSLog(@"[HAPList] loadHAP completion: success=%d error=%@", success, errorMessage);
        [self.loadingIndicator stopAnimating];

        if (success) {
            NSLog(@"[HAPList] loadHAP success, creating HAPPlayerViewController (bundle=%@ module=%@ ability=%@)",
                  bundleName, moduleName, abilityName);
            // push 前先 pop 回根 VC,确保旧的 StageViewController 被 dealloc,
            // 否则旧的 instanceName 仍会留在 AppMain 内部表中,下一个 hap 的 DispatchOnCreate
            // 可能找不到正确的入口或者对同一个 instanceName 重复 DispatchOnCreate 崩。
            @try {
                [self.navigationController popToRootViewControllerAnimated:NO];
            } @catch (NSException *e) {
                NSLog(@"[HAPList] ❌ popToRoot crashed: %@", e);
            }

            // loadHAP 完成后,abc 字节码已经被 ArkUI 运行时加载并启动,
            // 这里用从 module.json5/module.json 解析出的 bundleName/moduleName/abilityName
            // 创建播放 VC,StageViewController 会通过该 instanceName 触发 abc 渲染出的 ArkUI 页面挂载到屏幕上。
            // appName/pageName 也一并通过初始化方法传入,用于播放界面顶部展示当前应用名与入口界面。
            HAPPlayerViewController *playerVC;
            @try {
                playerVC = [[HAPPlayerViewController alloc]
                    initWithHAPManager:self.hapManager
                            bundleName:bundleName
                            moduleName:moduleName
                           abilityName:abilityName
                              appName:appName
                             pageName:pageName];
            } @catch (NSException *e) {
                NSLog(@"[HAPList] ❌ HAPPlayerViewController init crashed: %@\n%@", e, e.callStackSymbols);
                NSString *msg = [NSString stringWithFormat:@"HAPPlayer init: %@\n%@",
                                 e.reason ?: e.name, [e.callStackSymbols componentsJoinedByString:@"\n"]];
                [self.hapManager showGlobalError:msg shortText:@"报错"];
                return;
            }

            // 关键:initWithHAPManager 内部可能因为 initWithInstanceName 异常而 return nil,
            // 此时 HAPPlayerViewController 已经自己调用了 showGlobalError,我们这里再加一层 nil 检查,
            // 避免 pushViewController:nil 触发新的崩溃,确保错误一定能显示出来。
            if (!playerVC) {
                NSLog(@"[HAPList] ❌ HAPPlayerViewController returned nil (init failed)");
                if (self.hapManager && !self.hapManager.crashErrorWindow.hidden == NO) {
                    // 如果 init 内部还没显示出错误(比如 manager 是 nil 的极端情况),兜底再显示一次
                    [self.hapManager showGlobalError:@"HAPPlayerViewController 创建失败,无法打开 HAP。请检查 bundleName/moduleName/abilityName 是否与 module.json 匹配。" shortText:@"报错"];
                }
                return;
            }

            // push 阶段也可能因为导航栏或 StageVC 内部触发 dispatch 而 abort,
            // 用 @try/@catch 包一下,失败则走全局错误 UI。
            @try {
                // 用 animated:YES 推入,等转场完成后再主动触发一次 foreground,
                // 因为 StageViewController.viewDidLoad 已经发过 DispatchOnForeground,
                // 但此时 abc 字节码里的 ability 组件可能还没挂载好。
                __weak typeof(self) weakSelf = self;
                [CATransaction begin];
                [CATransaction setCompletionBlock:^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    if (strongSelf.hapManager.isArkUIRunning) {
                        @try {
                            [strongSelf.hapManager callCurrentAbilityOnForeground];
                        } @catch (NSException *e) {
                            NSLog(@"[HAPList] ❌ post-push onForeground crashed: %@\n%@", e, e.callStackSymbols);
                            NSString *msg = [NSString stringWithFormat:@"post-push onForeground: %@\n%@",
                                             e.reason ?: e.name, [e.callStackSymbols componentsJoinedByString:@"\n"]];
                            [strongSelf.hapManager showGlobalError:msg shortText:@"报错"];
                        }
                    }
                }];
                [self.navigationController pushViewController:playerVC animated:YES];
                NSLog(@"[HAPList] pushViewController done, playerVC=%@", playerVC);
                [CATransaction commit];
            } @catch (NSException *e) {
                NSLog(@"[HAPList] ❌ pushViewController crashed: %@\n%@", e, e.callStackSymbols);
                NSString *msg = [NSString stringWithFormat:@"push: %@\n%@",
                                 e.reason ?: e.name, [e.callStackSymbols componentsJoinedByString:@"\n"]];
                [self.hapManager showGlobalError:msg shortText:@"报错"];
            }
        } else {
            // 加载 hap 失败:此时 hap 没成功加载,不能 push HAPPlayerViewController,
            // 因为 StageViewController.viewDidLoad 会试图调用 AppMain::DispatchOnCreate 而 abc 未就绪,会闪退。
            // 这里优先展示全局红色错误 UI(满足用户"居中红色文本,点击复制"的需求);
            // 同时也提供一个 Alert 作备份,万一 Window 显示失败也能让用户看到错误。
            [self.hapManager showGlobalError:errorMessage shortText:@"加载失败"];

            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"加载失败"
                                                                           message:errorMessage
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"复制错误" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                UIPasteboard *pb = [UIPasteboard generalPasteboard];
                pb.string = errorMessage ?: @"";
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
            @try {
                [self presentViewController:alert animated:YES completion:nil];
            } @catch (NSException *e) {
                NSLog(@"[HAPList] ❌ present alert crashed: %@", e);
            }
        }
    }];
}

// ArkUI-X 运行时内部会通过 libdispatch 异步调用 topViewController.instanceName,
// 当列表页 HAPViewController 处于栈顶时(如 hap 加载完成但 HAPPlayerViewController 尚未 push 的间隙),
// 它不是 StageViewController 子类,不响应 instanceName,触发 unrecognized selector 崩溃。
// 返回 nil 让 ArkUI-X 运行时跳过该次调度,避免崩溃。
- (NSString *)instanceName {
    return nil;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSDictionary *hapInfo = self.hapInfoList[indexPath.row];
        NSString *hapPath = hapInfo[@"path"];

        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:hapPath error:nil];

        [self.hapInfoList removeObjectAtIndex:indexPath.row];
        [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

// 左划(trailing swipe)自定义操作:复制地址 + 删除
// 替换 iOS 默认的 commitEditingStyle 单一删除行为,添加"复制地址"(复制 hoi://包名/ URL)选项。
- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
                     trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath  API_AVAILABLE(ios(11.0)) {
    NSDictionary *hapInfo = self.hapInfoList[indexPath.row];
    NSString *bundleName = hapInfo[@"bundleName"] ?: hapInfo[@"name"] ?: @"";

    // --- 1. 删除 ---
    UIContextualAction *deleteAction =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:NSLocalizedString(@"Delete", nil)
                                              handler:^(UIContextualAction * _Nonnull action,
                                                        __kindof UIView * _Nonnull sourceView,
                                                        void (^ _Nonnull completionHandler)(BOOL)) {
        NSDictionary *hapInfo2 = self.hapInfoList[indexPath.row];
        NSString *hapPath = hapInfo2[@"path"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:hapPath error:nil];
        [self.hapInfoList removeObjectAtIndex:indexPath.row];
        [self.tableView deleteRowsAtIndexPaths:@[indexPath]
                              withRowAnimation:UITableViewRowAnimationAutomatic];
        completionHandler(YES);
    }];
    deleteAction.backgroundColor = [UIColor systemRedColor];

    // --- 2. 复制地址 hoi://{bundleName}/ ---
    NSString *copyTitle = NSLocalizedString(@"Copy url", nil);
    // 优先用中文,zh-CN 下显示"复制地址",其他语言 NSLocalizedString 会走 English 表显示"Copy url"。
    // 如果 NSLocalizedString 未配置本地化,fallback 到"Copy url"。
    // 这里额外做个中文探测(NSLocale preferredLanguages),让没有 strings 文件时中文仍正确显示。
    NSArray<NSString *> *langs = [NSLocale preferredLanguages];
    if (langs.count > 0) {
        NSString *first = langs.firstObject;
        if ([first hasPrefix:@"zh"]) {
            copyTitle = @"复制地址";
        }
    }
    UIContextualAction *copyAction =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                title:copyTitle
                                              handler:^(UIContextualAction * _Nonnull action,
                                                        __kindof UIView * _Nonnull sourceView,
                                                        void (^ _Nonnull completionHandler)(BOOL)) {
        // URL 格式: hoi://{包名}/
        NSString *url = [NSString stringWithFormat:@"hoi://%@/", bundleName];
        [UIPasteboard generalPasteboard].string = url;
        NSLog(@"[HAPList] 复制地址到剪贴板: %@", url);
        // 轻微触觉反馈 + toast 提示(用系统提示太突兀,这里只 toast 到控制台即可)
        completionHandler(YES);
    }];
    copyAction.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];  // 系统蓝色

    // 左划完全展开时优先执行复制(更常用)
    return [UISwipeActionsConfiguration configurationWithActions:@[ deleteAction, copyAction ]];
}

#pragma mark - 悬浮菜单:退出 / 重启 hap

// 退出 hap 应用:pop 回列表页并卸载 hap 数据,释放 ArkUI ability。
- (void)handleExitHAP {
    NSLog(@"[HAPList] 菜单:退出 hap 应用");
    @try {
        [self.navigationController popToRootViewControllerAnimated:YES];
    } @catch (NSException *e) {
        NSLog(@"[HAPList] 退出 popToRoot crashed: %@", e);
    }
    [self.hapManager unloadCurrentHAP];
    [self.hapManager hideGlobalError];
}

// 重启 hap 应用:卸载当前 hap 后用同样的路径重新加载并 push 播放页。
- (void)handleRestartHAP {
    if (self.isRestarting) {
        NSLog(@"[HAPList] 菜单:重启进行中,忽略重复请求");
        return;
    }

    NSString *hapPath = [self.hapManager currentHAPPath];
    if (!hapPath.length) {
        NSLog(@"[HAPList] 菜单:重启失败,currentHAPPath 为空");
        return;
    }

    // 保存当前 hap 的入口信息,卸载后 HAPManager 的 readonly 属性会被清空。
    NSString *bundleName = [self.hapManager currentBundleName] ?: @"entry";
    NSString *moduleName = [self.hapManager currentModuleName] ?: @"entry";
    NSString *abilityName = [self.hapManager currentAbilityName] ?: @"EntryAbility";
    NSString *appName = [self.hapManager currentAppName] ?: hapPath.lastPathComponent;
    NSString *pageName = [self.hapManager currentPageName] ?: @"";

    NSLog(@"[HAPList] 菜单:重启 hap 应用 path=%@", hapPath);
    self.isRestarting = YES;

    // 先 pop 回根 VC,让旧的 HAPPlayerViewController 被 dealloc,
    // 再 unloadCurrentHAP 释放 ability,最后重新加载。
    @try {
        [self.navigationController popToRootViewControllerAnimated:NO];
    } @catch (NSException *e) {
        NSLog(@"[HAPList] 重启 popToRoot crashed: %@", e);
    }

    [self.hapManager hideGlobalError];
    [self.hapManager unloadCurrentHAP];

    [self.loadingIndicator startAnimating];

    __weak typeof(self) weakSelf = self;
    [self.hapManager loadHAPAtPath:hapPath completion:^(BOOL success, NSString *errorMessage) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.isRestarting = NO;
        [strongSelf.loadingIndicator stopAnimating];

        if (!success) {
            NSLog(@"[HAPList] 重启失败: %@", errorMessage);
            [strongSelf.hapManager showGlobalError:errorMessage shortText:@"重启失败"];
            return;
        }

        NSLog(@"[HAPList] 重启成功,创建新的 HAPPlayerViewController");
        HAPPlayerViewController *playerVC;
        @try {
            playerVC = [[HAPPlayerViewController alloc]
                initWithHAPManager:strongSelf.hapManager
                        bundleName:bundleName
                        moduleName:moduleName
                       abilityName:abilityName
                          appName:appName
                         pageName:pageName];
        } @catch (NSException *e) {
            NSLog(@"[HAPList] 重启 init crashed: %@", e);
            NSString *msg = [NSString stringWithFormat:@"重启 init: %@\n%@",
                             e.reason ?: e.name, [e.callStackSymbols componentsJoinedByString:@"\n"]];
            [strongSelf.hapManager showGlobalError:msg shortText:@"报错"];
            return;
        }

        if (!playerVC) {
            [strongSelf.hapManager showGlobalError:@"重启失败:无法创建播放页面" shortText:@"报错"];
            return;
        }

        @try {
            [strongSelf.navigationController pushViewController:playerVC animated:YES];
        } @catch (NSException *e) {
            NSLog(@"[HAPList] 重启 push crashed: %@", e);
            NSString *msg = [NSString stringWithFormat:@"重启 push: %@\n%@",
                             e.reason ?: e.name, [e.callStackSymbols componentsJoinedByString:@"\n"]];
            [strongSelf.hapManager showGlobalError:msg shortText:@"报错"];
        }
    }];
}

// 返回界面：模拟 OpenHarmony 虚拟导航栏上的返回键 API
// 只要 arkui 应用还在前台，都执行 popViewControllerAnimated
- (void)handleBackPress {
    NSLog(@"[HAPList] 菜单：返回界面");
    
    // 检查导航栈中是否有可以返回的页面
    if (self.navigationController.viewControllers.count > 1) {
        // 有页面可以返回，执行返回操作
        @try {
            [self.navigationController popViewControllerAnimated:YES];
        } @catch (NSException *e) {
            NSLog(@"[HAPList] 返回 popViewControllerAnimated crashed: %@", e);
        }
    } else {
        // 已经在根控制器，无法返回
        NSLog(@"[HAPList] 已在根控制器，无法返回");
    }
}

@end