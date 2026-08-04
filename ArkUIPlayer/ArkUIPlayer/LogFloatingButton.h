#import <UIKit/UIKit.h>

// 可拖动的悬浮菜单按钮。
// 灰色背景,黑色"菜单"文字,点击弹出 iOS ActionSheet 菜单:
//   1. 退出hap应用 — 发送 kLogMenuExitHAPNotification
//   2. 重启hap应用 — 发送 kLogMenuRestartHAPNotification
//   3. 复制日志     — 直接复制捕获的日志到剪贴板
// 通过重定向 stderr 捕获 NSLog 输出,同时保持 Xcode 控制台正常显示。
@interface LogFloatingButton : NSObject

// 退出 hap 应用的通知。HAPViewController 监听后执行 popToRoot + unloadCurrentHAP。
extern NSNotificationName const kLogMenuExitHAPNotification;
// 重启 hap 应用的通知。HAPViewController 监听后执行 unloadCurrentHAP + 重新加载。
extern NSNotificationName const kLogMenuRestartHAPNotification;

+ (instancetype)sharedButton;

// 显示悬浮窗并启动日志捕获。
// 应在 AppDelegate didFinishLaunchingWithOptions 中调用。
- (void)show;

// 获取当前捕获的日志文本。
- (NSString *)capturedLogs;

@end
