//
//  ASAccount.m
//  AppSales
//
//  Created by Ole Zorn on 30.06.11.
//  Copyright (c) 2011 omz:software. All rights reserved.
//

#import "ASAccount.h"
#import "SAMKeychain.h"

#define kAccountKeychainiTunesConnect  @"iTunesConnect"
#define kAccountKeychainAppSalesMobile @"AppSales-Mobile"

@implementation ASAccount

@dynamic username, providerID, vendorID, title, sortIndex, dailyReports, weeklyReports, products, payments, paymentReports, reportsBadge, paymentsBadge;
@synthesize isDownloadingReports, downloadStatus, downloadProgress;

- (NSString *)password {
#if TARGET_OS_MACCATALYST
    return [[NSUserDefaults standardUserDefaults] stringForKey:kAccountKeychainiTunesConnect];
#else
	return [SAMKeychain passwordForService:kAccountKeychainiTunesConnect account:self.username];
#endif
}

- (void)setPassword:(NSString *)password {
#if TARGET_OS_MACCATALYST
    [[NSUserDefaults standardUserDefaults] setObject:password forKey:kAccountKeychainiTunesConnect];
#else
	[SAMKeychain setPassword:password forService:kAccountKeychainiTunesConnect account:self.username];
#endif
}

- (void)deletePassword {
	[SAMKeychain deletePasswordForService:kAccountKeychainiTunesConnect account:self.username];
}

- (NSString *)accessToken {
#if TARGET_OS_MACCATALYST
    return [[NSUserDefaults standardUserDefaults] stringForKey:kAccountKeychainAppSalesMobile];
#else
	return [SAMKeychain passwordForService:kAccountKeychainAppSalesMobile account:self.username];
#endif
}

- (void)setAccessToken:(NSString *)accessToken {
#if TARGET_OS_MACCATALYST
    [[NSUserDefaults standardUserDefaults] setObject:accessToken forKey:kAccountKeychainAppSalesMobile];
#else
	[SAMKeychain setPassword:accessToken forService:kAccountKeychainAppSalesMobile account:self.username];
#endif
}

- (void)deleteAccessToken {
	[SAMKeychain deletePasswordForService:kAccountKeychainAppSalesMobile account:self.username];
}

- (NSString *)displayName {
	if (self.title && ![self.title isEqualToString:@""]) {
		return self.title;
	}
	return self.username;
}

@end
