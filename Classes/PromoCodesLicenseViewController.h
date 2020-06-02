//
//  PromoCodesLicenseViewController.h
//  AppSales
//
//  Created by Ole Zorn on 14.08.11.
//  Copyright 2011 omz:software. All rights reserved.
//

#import <UIKit/UIKit.h>
@import WebKit;

@class DownloadStepOperation;

@interface PromoCodesLicenseViewController : UIViewController <WKNavigationDelegate> {
	NSString *licenseAgreementHTML;
	DownloadStepOperation *downloadOperation;
	WKWebView *webView;
}

@property (nonatomic, strong) WKWebView *webView;

- (instancetype)initWithLicenseAgreement:(NSString *)licenseAgreement operation:(DownloadStepOperation *)operation;

@end
