//
//  AppSalesSceneDelegate.m
//  AppSales
//
//  Scene delegate for the UIScene-based life cycle. Owns the single
//  application window and forwards scene events to AppSalesAppDelegate.
//

#import "AppSalesSceneDelegate.h"
#import "AppSalesAppDelegate.h"

@implementation AppSalesSceneDelegate

- (AppSalesAppDelegate *)appDelegate {
	return (AppSalesAppDelegate *)[UIApplication sharedApplication].delegate;
}

#pragma mark - UIWindowSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
	if (![scene isKindOfClass:[UIWindowScene class]]) {
		return;
	}
	UIWindowScene *windowScene = (UIWindowScene *)scene;
	
	self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
	[self.appDelegate setupUserInterfaceInWindow:self.window];
	
	// URLs the app was launched with (e.g. "appsales://") arrive via the connection options.
	if (connectionOptions.URLContexts.count > 0) {
		[self.appDelegate handleOpenURLs];
	}
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
	if (URLContexts.count > 0) {
		[self.appDelegate handleOpenURLs];
	}
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
	[self.appDelegate handleDidBecomeActive];
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
	[self.appDelegate handleWillEnterForeground];
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
	[self.appDelegate handleDidEnterBackground];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientationsForWindowScene:(UIWindowScene *)windowScene API_AVAILABLE(ios(27.0)) {
	return [self.appDelegate supportedInterfaceOrientationsForWindow:self.window];
}

@end
