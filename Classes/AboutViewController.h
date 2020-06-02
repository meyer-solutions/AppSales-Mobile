//
//  AboutViewController.h
//  AppSales
//
//  Created by Ole Zorn on 02.08.11.
//  Copyright 2011 omz:software. All rights reserved.
//

#import <UIKit/UIKit.h>
@import WebKit;

@interface AboutViewController : UIViewController <WKNavigationDelegate> {
	WKWebView *webView;
}

+ (NSString *)appVersion;
+ (NSString *)currentBuild;
+ (NSString *)latestBuild;

@end
