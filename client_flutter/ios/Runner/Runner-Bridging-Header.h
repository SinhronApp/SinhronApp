#import "GeneratedPluginRegistrant.h"
#import <Flutter/Flutter.h>

// ADR-043 — FlutterSceneDelegate implements these UISceneDelegate methods
// but doesn't declare them in its header; declared here so SceneDelegate
// can override them and still call Flutter's own handling (`super`).
@interface FlutterSceneDelegate (SinhronLinks)
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions;
- (void)scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)userActivity;
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts;
@end
