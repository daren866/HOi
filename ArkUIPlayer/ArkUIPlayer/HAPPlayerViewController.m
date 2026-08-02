#import "HAPPlayerViewController.h"

@interface HAPPlayerViewController ()

// 居中红色错误文本标签:hap 加载/渲染失败时不闪退,改为展示报错。
// 点击该标签可复制报错内容到剪贴板,方便用户反馈。
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) UIScrollView *errorScrollView;
@property (nonatomic, copy) NSString *lastErrorMessage;
// 标记 viewDidLoad 是否已经成功执行过(防止生命周期内多次重复 try)。
@property (nonatomic, assign) BOOL didLoadViewSucceed;

@end

@implementation HAPPlayerViewController

- (instancetype)initWithHAPManager:(HAPManager *)manager
                        bundleName:(NSString *)bundleName
                        moduleName:(NSString *)moduleName
                       abilityName:(NSString *)abilityName
                          appName:(NSString *)appName
                         pageName:(NSString *)pageName {
    // instanceName 格式为 "bundleName:moduleName:abilityName",
    // StageViewController 内部据此定位 hap 解压后 {moduleName}/ 目录里的 abc 字节码与渲染入口。
    NSString *safeBundleName = bundleName.length ? bundleName : @"com.example.hap";
    NSString *safeModuleName = moduleName.length ? moduleName : @"entry";
    NSString *safeAbilityName = abilityName.length ? abilityName : @"EntryAbility";

#if HAS_ARKUI_X
    NSString *instanceName = [NSString stringWithFormat:@"%@:%@:%@", safeBundleName, safeModuleName, safeAbilityName];
    self = [super initWithInstanceName:instanceName];
#else
    self = [super init];
#endif
    if (self) {
        self.hapManager = manager;
        self.bundleName = safeBundleName;
        self.moduleName = safeModuleName;
        self.abilityName = safeAbilityName;
        self.appName = appName.length ? appName : safeModuleName;
        self.pageName = pageName ?: @"";
        // 注意:不要再在这里调用 hapManager.initializeArkUI。
        // ArkUI 运行时已经在 loadHAPAtPath 的 completion 触发前启动完毕(由 HAPManager 内部
        // 调用 StageApplication launchApplication 完成),此时 VC 才被创建。
    }
    return self;
}

- (void)viewDidLoad {
    // StageViewController.viewDidLoad 会创建 Surface、调用 AppMain::DispatchOnCreate/DispatchOnForeground,
    // 这两个 C++ 调用如果 abc 字节码缺失/损坏,或 instanceName 不匹配 hap 实际入口,
    // 会抛出 ObjC 异常或直接 abort。这里用 @try/@catch 拦截 ObjC 异常,
    // 失败时不闪退,改为展示居中红色错误文本。
    @try {
        [super viewDidLoad];
        self.didLoadViewSucceed = YES;
    } @catch (NSException *e) {
        NSLog(@"[HAPPlayer] ❌ viewDidLoad crashed: %@\n%@", e, e.callStackSymbols);
        self.didLoadViewSucceed = NO;
        [self showErrorMessage:[NSString stringWithFormat:@"viewDidLoad: %@\n\nCallstack:\n%@",
                                e.reason ?: e.name ?: @"unknown",
                                [e.callStackSymbols componentsJoinedByString:@"\n"]]];
        return;
    }

    self.title = self.appName.length ? self.appName : @"ArkUI Player";
    self.view.backgroundColor = [UIColor whiteColor];
}

- (void)viewWillAppear:(BOOL)animated {
    // 已经处于错误展示状态(viewDidLoad 或上一次 viewWillAppear 抛过异常)时,
    // 不再转发任何生命周期给 StageVC,避免二次触发同一异常把 app 拖崩。
    if (self.lastErrorMessage.length > 0) {
        return;
    }

    @try {
        [super viewWillAppear:animated];
    } @catch (NSException *e) {
        NSLog(@"[HAPPlayer] ❌ viewWillAppear crashed: %@", e);
        [self showErrorMessage:[NSString stringWithFormat:@"viewWillAppear: %@", e.reason ?: e.name]];
        return;
    }

    // ArkUI 未启动时不要转发 foreground,否则 StageApplication 取到的 topViewController
    // 不是 StageViewController,会触发空指针/状态机错乱崩溃。
    if (self.hapManager.isArkUIRunning) {
        @try {
            [self.hapManager callCurrentAbilityOnForeground];
        } @catch (NSException *e) {
            NSLog(@"[HAPPlayer] ❌ callCurrentAbilityOnForeground crashed: %@", e);
            [self showErrorMessage:[NSString stringWithFormat:@"onForeground: %@", e.reason ?: e.name]];
        }
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    if (!self.didLoadViewSucceed) {
        return;
    }

    @try {
        [super viewWillDisappear:animated];
    } @catch (NSException *e) {
        NSLog(@"[HAPPlayer] ❌ viewWillDisappear crashed: %@", e);
    }

    if (self.hapManager.isArkUIRunning) {
        @try {
            [self.hapManager callCurrentAbilityOnBackground];
        } @catch (NSException *e) {
            NSLog(@"[HAPPlayer] ❌ callCurrentAbilityOnBackground crashed: %@", e);
        }
    }
}

#pragma mark - Error UI

// 在视图最顶层叠加一个全屏的红色错误文本,内容为当前 lastErrorMessage。
// 失败时调用,不再闪退;点击红色文本可复制错误到剪贴板。
- (void)showErrorMessage:(NSString *)message {
    if (!message || message.length == 0) {
        message = @"Unknown error";
    }
    self.lastErrorMessage = message;
    NSLog(@"[HAPPlayer] Show error message: %@", message);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self buildErrorUIIfNeeded];
        self.errorLabel.text = message;
        self.errorScrollView.hidden = NO;

        // 错误出现后,把 StageVC 的 windowView 等可能存在的渲染 surface 隐藏,避免红色文本被覆盖。
        // 不能直接 self.view = ... 因为 StageVC 内部已经 setup 了 self.view,这里只在 self.view 上盖一层。
        if (![self.errorScrollView isDescendantOfView:self.view]) {
            [self.view addSubview:self.errorScrollView];
        }
        [self.view bringSubviewToFront:self.errorScrollView];
    });
}

- (void)buildErrorUIIfNeeded {
    if (self.errorScrollView) {
        return;
    }

    // 用 ScrollView 包住 Label,允许长错误信息(含 callstack)滚动查看。
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.backgroundColor = [UIColor whiteColor];
    scrollView.alwaysBounceVertical = YES;
    scrollView.showsVerticalScrollIndicator = YES;
    self.errorScrollView = scrollView;

    // 用一个容器视图包住 Label,容器高度 >= ScrollView 可视高度,
    // 这样当错误信息较短时,Label 在容器中垂直居中 = 在屏幕可视区域居中;
    // 当错误信息较长(含 callstack)时,容器高度跟随 Label 撑开,ScrollView 自动可滚动。
    UIView *containerView = [[UIView alloc] initWithFrame:CGRectZero];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:containerView];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor systemRedColor];
    label.font = [UIFont systemFontOfSize:14];
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.adjustsFontSizeToFitWidth = NO;
    // 留出内边距,文本不贴边。
    label.preferredMaxLayoutWidth = [UIScreen mainScreen].bounds.size.width - 32;
    self.errorLabel = label;
    [containerView addSubview:label];

    // 点击红色文本复制错误信息到剪贴板,UIPasteboard 在 iOS 14+ 限制了直接 setItems,
    // 但 setString: 仍然可用。
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleErrorLabelTap:)];
    tap.numberOfTapsRequired = 1;
    [label setUserInteractionEnabled:YES];
    [label addGestureRecognizer:tap];

    [self.view addSubview:scrollView];

    // 布局:
    // - ScrollView 占满父视图
    // - Container 在 ScrollView 内撑满宽度,高度 = max(Label 高度 + 上下内边距, ScrollView 可视高度)
    //   (contentLayoutGuide 用于让 Container 自动撑开 contentSize;
    //    frameLayoutGuide 用于约束 Container 宽度与 ScrollView 可视宽度一致,避免横屏跑飞;
    //    Container 高度 >= frameLayoutGuide 高度,保证短文本时也能撑满可视区域从而居中)
    // - Label 在 Container 中水平撑满(留 16pt 边距),垂直居中(留 >=24pt 上下边距防止贴边)
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [containerView.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [containerView.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [containerView.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [containerView.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [containerView.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor],
        // 关键:Container 高度至少等于 ScrollView 可视高度,这样短文本时 Label 能在可视区域内垂直居中。
        [containerView.heightAnchor constraintGreaterThanOrEqualToAnchor:scrollView.frameLayoutGuide.heightAnchor],

        [label.centerYAnchor constraintEqualToAnchor:containerView.centerYAnchor],
        [label.topAnchor constraintGreaterThanOrEqualToAnchor:containerView.topAnchor constant:24],
        [label.bottomAnchor constraintLessThanOrEqualToAnchor:containerView.bottomAnchor constant:-24],
        [label.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-16],
    ]];
}

- (void)handleErrorLabelTap:(UITapGestureRecognizer *)gesture {
    NSString *message = self.lastErrorMessage ?: @"(no error message)";
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = message;

    // 给用户一个轻量视觉反馈:让 Label 短暂闪烁一下。
    [UIView animateWithDuration:0.1
                     animations:^{
                         self.errorLabel.alpha = 0.4;
                     } completion:^(BOOL finished) {
                         [UIView animateWithDuration:0.2 animations:^{
                             self.errorLabel.alpha = 1.0;
                         }];
                     }];

    NSLog(@"[HAPPlayer] Error message copied to pasteboard (%lu chars)",
          (unsigned long)message.length);
}

@end
