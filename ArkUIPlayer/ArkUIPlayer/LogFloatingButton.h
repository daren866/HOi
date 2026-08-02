#import <UIKit/UIKit.h>

// 可拖动的悬浮日志按钮。
// 正圆形绿色外观,白色"日志"文字,点击复制应用运行日志到剪贴板。
// 通过重定向 stderr 捕获 NSLog 输出,同时保持 Xcode 控制台正常显示。
@interface LogFloatingButton : NSObject

+ (instancetype)sharedButton;

// 显示悬浮窗并启动日志捕获。
// 应在 AppDelegate didFinishLaunchingWithOptions 中调用。
- (void)show;

// 获取当前捕获的日志文本。
- (NSString *)capturedLogs;

@end
