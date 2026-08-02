#import "LogFloatingButton.h"
#include <unistd.h>

static LogFloatingButton *_sharedInstance;
static NSMutableString *_logBuffer;
static int _originalStderrFD = -1;
static int _pipeFD[2] = {-1, -1};
static NSThread *_logReaderThread;
static volatile BOOL _logCaptureRunning = NO;
// 最大缓冲 512KB 日志,超过后丢弃前半部分。
static const NSUInteger kMaxLogBufferSize = 512 * 1024;

@interface LogFloatingButton ()

@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIButton *button;

@end

@implementation LogFloatingButton

+ (instancetype)sharedButton {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[LogFloatingButton alloc] init];
        _logBuffer = [NSMutableString stringWithCapacity:kMaxLogBufferSize];
    });
    return _sharedInstance;
}

- (void)show {
    [self startLogCapture];
    [self createFloatingWindow];
}

#pragma mark - 日志捕获

// 通过 pipe + dup2 重定向 stderr,捕获所有 NSLog 输出。
// 同时将日志转发到原始 stderr,保证 Xcode 控制台仍能正常显示。
- (void)startLogCapture {
    if (_logCaptureRunning) return;
    _logCaptureRunning = YES;

    // 创建管道
    pipe(_pipeFD);

    // 保存原始 stderr 副本
    _originalStderrFD = dup(STDERR_FILENO);

    // 将 stderr 重定向到管道写端
    dup2(_pipeFD[1], STDERR_FILENO);

    // 启动后台线程读取管道数据
    _logReaderThread = [[NSThread alloc] initWithTarget:self
                                               selector:@selector(readLogPipe)
                                                 object:nil];
    _logReaderThread.name = @"LogReader";
    [_logReaderThread start];
}

- (void)readLogPipe {
    char buffer[4096];
    ssize_t bytesRead;

    while ((bytesRead = read(_pipeFD[0], buffer, sizeof(buffer))) > 0) {
        // 转发到原始 stderr (Xcode 控制台仍可见)
        if (_originalStderrFD >= 0) {
            write(_originalStderrFD, buffer, bytesRead);
        }

        // 写入内存缓冲
        NSData *data = [NSData dataWithBytes:buffer length:bytesRead];
        NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (str) {
            @synchronized(_logBuffer) {
                [_logBuffer appendString:str];
                // 超过最大大小时,丢弃前半部分,保留最近的日志
                if (_logBuffer.length > kMaxLogBufferSize) {
                    NSRange range = NSMakeRange(0, _logBuffer.length - kMaxLogBufferSize / 2);
                    [_logBuffer deleteCharactersInRange:range];
                }
            }
        }
    }
}

- (NSString *)capturedLogs {
    @synchronized(_logBuffer) {
        return [_logBuffer copy];
    }
}

#pragma mark - 悬浮窗 UI

- (void)createFloatingWindow {
    CGFloat diameter = 56;
    CGRect frame = CGRectMake(16, 220, diameter, diameter);

    self.window = [[UIWindow alloc] initWithFrame:frame];
    // 低于崩溃防护窗口(windowLevel = UIWindowLevelAlert + 1000)
    self.window.windowLevel = UIWindowLevelAlert + 500;
    self.window.backgroundColor = [UIColor clearColor];
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.window.rootViewController.view.clipsToBounds = NO;

    self.button = [UIButton buttonWithType:UIButtonTypeCustom];
    self.button.frame = self.window.rootViewController.view.bounds;
    self.button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.button.layer.cornerRadius = diameter / 2;
    self.button.backgroundColor = [UIColor colorWithRed:0.2 green:0.75 blue:0.2 alpha:1.0];
    self.button.layer.masksToBounds = YES;
    self.button.layer.borderWidth = 2;
    self.button.layer.borderColor = [UIColor whiteColor].CGColor;
    self.button.layer.shadowColor = [UIColor blackColor].CGColor;
    self.button.layer.shadowOpacity = 0.3;
    self.button.layer.shadowRadius = 4;
    self.button.layer.shadowOffset = CGSizeMake(0, 2);

    [self.button setTitle:@"日志" forState:UIControlStateNormal];
    self.button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [self.button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    [self.button addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    // 拖动时不触发 button 的 touchUpInside
    pan.cancelsTouchesInView = NO;
    [self.button addGestureRecognizer:pan];

    [self.window.rootViewController.view addSubview:self.button];
    self.window.hidden = NO;
}

#pragma mark - 拖动

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.button.window];

    CGRect frame = self.window.frame;
    frame.origin.x += translation.x;
    frame.origin.y += translation.y;

    // 限制在屏幕范围内
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
    frame.origin.x = MAX(0, MIN(screenWidth - frame.size.width, frame.origin.x));
    frame.origin.y = MAX(0, MIN(screenHeight - frame.size.height, frame.origin.y));

    self.window.frame = frame;
    [gesture setTranslation:CGPointZero inView:self.button.window];
}

#pragma mark - 点击复制

- (void)buttonTapped {
    NSString *logs = [self capturedLogs];
    if (!logs || logs.length == 0) {
        logs = @"(暂无日志)";
    }

    [UIPasteboard generalPasteboard].string = logs;
    [self showToastWithMessage:@"日志已复制到剪贴板"];
}

#pragma mark - Toast 提示

- (void)showToastWithMessage:(NSString *)message {
    UILabel *toast = [[UILabel alloc] init];
    toast.text = message;
    toast.textColor = [UIColor whiteColor];
    toast.backgroundColor = [UIColor blackColor];
    toast.alpha = 0.0;
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont systemFontOfSize:13];
    toast.layer.cornerRadius = 8;
    toast.layer.masksToBounds = YES;

    [toast sizeToFit];
    CGRect toastFrame = toast.frame;
    toastFrame.size.width += 24;
    toastFrame.size.height += 12;
    toast.frame = toastFrame;

    // 定位在按钮上方
    CGFloat windowWidth = self.window.bounds.size.width;
    toast.center = CGPointMake(windowWidth / 2, -toast.frame.size.height / 2 - 4);

    [self.window.rootViewController.view addSubview:toast];

    [UIView animateWithDuration:0.3 animations:^{
        toast.alpha = 0.9;
    } completion:^(BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                toast.alpha = 0.0;
            } completion:^(BOOL finished) {
                [toast removeFromSuperview];
            }];
        });
    }];
}

@end
