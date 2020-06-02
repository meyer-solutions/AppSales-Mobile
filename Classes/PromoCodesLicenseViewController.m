//
//  PromoCodesLicenseViewController.m
//  AppSales
//
//  Created by Ole Zorn on 14.08.11.
//  Copyright 2011 omz:software. All rights reserved.
//

#import "PromoCodesLicenseViewController.h"
#import "DownloadStepOperation.h"
#import "ASProgressHUD.h"

@implementation PromoCodesLicenseViewController

@synthesize webView;

- (instancetype)initWithLicenseAgreement:(NSString *)licenseAgreement operation:(DownloadStepOperation *)operation {
	self = [super init];
	if (self) {
		self.title = NSLocalizedString(@"License", nil);
		licenseAgreementHTML = licenseAgreement;
		downloadOperation = operation;
	}
	return self;
}

- (void)loadView {
	self.webView = [[WKWebView alloc] initWithFrame:CGRectZero];
	//webView.scalesPageToFit = YES;
	//webView.dataDetectorTypes = UIDataDetectorTypeNone;
	webView.navigationDelegate = self;
	self.view = webView;
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Agree", nil) style:UIBarButtonItemStyleDone target:self action:@selector(agree:)];
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel:)];
}

- (void)agree:(id)sender {
	downloadOperation.paused = NO;
	[downloadOperation start];
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)cancel:(id)sender {
	[downloadOperation cancel];
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
	[self.webView loadHTMLString:licenseAgreementHTML baseURL:nil];
	
	[ASProgressHUD showHUDAddedTo:self.view animated:YES];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation {
	if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
		return YES;
	}
	return (interfaceOrientation == UIInterfaceOrientationPortrait);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(nonnull WKNavigationAction *)navigationAction decisionHandler:(nonnull void (^)(WKNavigationActionPolicy))decisionHandler {
    
    if (navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        [[UIApplication sharedApplication] openURL:[navigationAction.request URL]];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [ASProgressHUD hideHUDForView:self.view animated:YES];
}

- (void)done:(id)sender {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc {
	//webView.delegate = nil;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
	return UIInterfaceOrientationMaskPortrait;
}

@end
