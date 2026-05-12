//
//  ReportDownloadOperation.m
//  AppSales
//
//  Created by Ole Zorn on 01.07.11.
//  Copyright 2011 omz:software. All rights reserved.
//

#import "ReportDownloadOperation.h"
#import "ASAccount.h"
#import "Report.h"
#import "WeeklyReport.h"
#import "NSData+Compression.h"
#import "ReporterParser.h"

// Forward declarations of category-private helpers.
@interface ReportDownloadOperation ()
- (void)downloadFinanceReports;
- (NSArray<NSString *> *)fetchAvailableFinanceRegionsForVendor:(NSString *)vendor;
- (NSString *)fetchFinanceTSVForVendor:(NSString *)vendor
								region:(NSString *)region
							fiscalYear:(NSInteger)fiscalYear
						  fiscalPeriod:(NSInteger)fiscalPeriod
							  outError:(NSString **)outError;
- (NSDictionary<NSString *, NSNumber *> *)aggregateProceedsByCurrencyFromTSV:(NSString *)tsv;
- (void)mapCalendarYear:(NSInteger)year month:(NSInteger)month
		   toFiscalYear:(NSInteger *)outFiscalYear period:(NSInteger *)outPeriod;
- (NSString *)callReporterMethod:(NSString *)methodCall service:(NSString *)serviceType;
+ (NSSet<NSString *> *)rollupRegionCodes;
@end

// iTunes Connect Reporter API
NSString *const kITCReporterVersion            = @"2.2";
NSString *const kITCReporterMode               = @"Robot.XML";
NSString *const kITCReporterBaseURL            = @"https://reportingitc-reporter.apple.com";
NSString *const kITCReporterServiceAction      = @"/reportservice/%@/v1";
NSString *const kITCReporterServiceTypeSales   = @"sales";
NSString *const kITCReporterServiceTypeFinance = @"finance";
NSString *const kITCReporterServiceBody        = @"[p=Reporter.properties, m=Robot.XML, %@]";

static NSString *NSStringPercentEscaped(NSString *string) {
    return [string stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
}

@implementation ReportDownloadOperation

@synthesize accountObjectID;

- (instancetype)initWithAccount:(ASAccount *)account {
	self = [super init];
	if (self) {
		accessToken = [account.accessToken copy];
		providerID = [account.providerID copy];
		_account = account;
		accountObjectID = [account.objectID copy];
		psc = [account.managedObjectContext persistentStoreCoordinator];

		[UIApplication sharedApplication].idleTimerDisabled = YES;
		backgroundTaskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^(void) {
			NSLog(@"Background task for downloading reports has expired!");
		}];
	}
	return self;
}

- (void)main {
	@autoreleasepool {

		NSInteger numberOfReportsDownloaded = 0;
		[self downloadProgress:0.0f withStatus:NSLocalizedString(@"Starting download", nil)];
        
        NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
		moc.persistentStoreCoordinator = psc;
		moc.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;

		ASAccount *account = (ASAccount *)[moc objectWithID:accountObjectID];
		NSInteger previousBadge = account.reportsBadge.integerValue;
		NSString *vendorID = account.vendorID;
		NSString *salesKey = kITCReporterServiceTypeSales.capitalizedString;

		LoginManager *loginManager = [[LoginManager alloc] initWithLoginInfo:nil];
		loginManager.shouldDeleteCookies = NO;
		[loginManager logOut];

		NSMutableDictionary *errors = [[NSMutableDictionary alloc] init];
		for (NSString *dateType in @[@"Daily", @"Weekly"]) {
			// Determine which reports should be available for download.
			NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
			[dateFormatter setDateFormat:@"yyyyMMdd"];
			[dateFormatter setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
			NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
			[calendar setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];

			NSDate *today = [NSDate date];
			if ([dateType isEqualToString:@"Weekly"]) {
				// Find the next Sunday.
				NSInteger weekday = -1;
				while (YES) {
					NSDateComponents *weekdayComponents = [calendar components:NSCalendarUnitWeekday fromDate:today];
					weekday = weekdayComponents.weekday;
					if (weekday == 1) {
						break;
					} else {
						today = [today dateByAddingTimeInterval:24 * 60 * 60];
					}
				}
			}

			NSMutableArray *availableReportDateStrings = [NSMutableArray array];
			NSMutableSet *availableReportDates = [NSMutableSet set];

			NSInteger maxNumberOfAvailableReports = [dateType isEqualToString:@"Daily"] ? 90 : 20;
			for (int i = 1; i <= maxNumberOfAvailableReports; i++) {
				NSDate *date = nil;
				if ([dateType isEqualToString:@"Daily"]) {
					date = [today dateByAddingTimeInterval:i * -24 * 60 * 60];
				} else { // Weekly
					date = [today dateByAddingTimeInterval:i * -7 * 24 * 60 * 60];
				}
				NSDateComponents *components = [calendar components:NSCalendarUnitDay | NSCalendarUnitMonth | NSCalendarUnitYear fromDate:date];
				NSDate *normalizedDate = [calendar dateFromComponents:components];
				NSString *dateString = [dateFormatter stringFromDate:normalizedDate];
				[availableReportDateStrings insertObject:dateString atIndex:0];
				[availableReportDates addObject:normalizedDate];
			}

			// Filter out reports we already have.
			NSFetchRequest *existingReportsFetchRequest = [[NSFetchRequest alloc] init];
			if ([dateType isEqualToString:@"Daily"]) {
				[existingReportsFetchRequest setEntity:[NSEntityDescription entityForName:@"DailyReport" inManagedObjectContext:moc]];
				[existingReportsFetchRequest setPredicate:[NSPredicate predicateWithFormat:@"account == %@ AND startDate IN %@", account, availableReportDates]];
			} else {
				[existingReportsFetchRequest setEntity:[NSEntityDescription entityForName:@"WeeklyReport" inManagedObjectContext:moc]];
				[existingReportsFetchRequest setPredicate:[NSPredicate predicateWithFormat:@"account == %@ AND endDate IN %@", account, availableReportDates]];
			}
			NSArray *existingReports = [moc executeFetchRequest:existingReportsFetchRequest error:nil];

			for (Report *report in existingReports) {
				if ([dateType isEqualToString:@"Daily"]) {
					NSDate *startDate = report.startDate;
					NSString *startDateString = [dateFormatter stringFromDate:startDate];
					[availableReportDateStrings removeObject:startDateString];
				} else {
					NSDate *endDate = ((WeeklyReport *)report).endDate;
					NSString *endDateString = [dateFormatter stringFromDate:endDate];
					[availableReportDateStrings removeObject:endDateString];
				}
			}

			int i = 0;
			NSUInteger numberOfReportsAvailable = [availableReportDateStrings count];
			for (NSString *reportDateString in availableReportDateStrings) {
				if (self.isCancelled) {
					[self completeDownloadWithStatus:NSLocalizedString(@"Canceled", nil)];
					return;
				}
				if (i == 0) {
					if ([dateType isEqualToString:@"Daily"]) {
						[self downloadProgress:0.1f withStatus:NSLocalizedString(@"Checking for daily reports...", nil)];
					} else {
						[self downloadProgress:0.5f withStatus:NSLocalizedString(@"Checking for weekly reports...", nil)];
					}
				} else {
					if ([dateType isEqualToString:@"Daily"]) {
						CGFloat progress = 0.5f * ((CGFloat)i / (CGFloat)numberOfReportsAvailable);
                        NSString *status = [NSString stringWithFormat:NSLocalizedString(@"Loading daily report %i / %lu", nil), i + 1, (unsigned long)numberOfReportsAvailable];
						[self downloadProgress:progress withStatus:status];
					} else {
						CGFloat progress = 0.5f + 0.4f * ((CGFloat)i / (CGFloat)numberOfReportsAvailable);
                        NSString *status = [NSString stringWithFormat:NSLocalizedString(@"Loading weekly report %i / %lu", nil), i + 1, (unsigned long)numberOfReportsAvailable];
						[self downloadProgress:progress withStatus:status];
					}
				}

				NSString *query = [NSString stringWithFormat:@"a=%@, %@.getReport, %@,%@,Summary,%@,%@", providerID, salesKey, vendorID, salesKey, dateType, reportDateString];

				NSDictionary *getReportData = @{@"accesstoken": NSStringPercentEscaped(accessToken),
												@"version":     kITCReporterVersion,
												@"mode":        kITCReporterMode,
												@"queryInput":  NSStringPercentEscaped([NSString stringWithFormat:kITCReporterServiceBody, query]),
												@"salesurl":    NSStringPercentEscaped([kITCReporterBaseURL stringByAppendingFormat:kITCReporterServiceAction, kITCReporterServiceTypeSales]),
												@"financeurl":  NSStringPercentEscaped([kITCReporterBaseURL stringByAppendingFormat:kITCReporterServiceAction, kITCReporterServiceTypeFinance]),
												};
				NSData *jsonData = [NSJSONSerialization dataWithJSONObject:getReportData options:0 error:nil];
				NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
				NSString *getReportBody = [NSString stringWithFormat:@"jsonRequest=%@", jsonString];
				NSData *getReportBodyData = [getReportBody dataUsingEncoding:NSUTF8StringEncoding];

				NSURL *reporterURL = [NSURL URLWithString:[kITCReporterBaseURL stringByAppendingFormat:kITCReporterServiceAction, kITCReporterServiceTypeSales]];
				NSMutableURLRequest *reporterRequest = [NSMutableURLRequest requestWithURL:reporterURL];
				[reporterRequest setHTTPMethod:@"POST"];
				[reporterRequest setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
				[reporterRequest setHTTPBody:getReportBodyData];

				NSHTTPURLResponse *response = nil;
				NSData *reportData = [NSURLConnection sendSynchronousRequest:reporterRequest returningResponse:&response error:nil];

				if ([response.MIMEType isEqualToString:@"text/plain"]) {
					ReporterParser *reporterParser = [[ReporterParser alloc] initWithData:reportData];
					[reporterParser parse];
					NSDictionary *root = reporterParser.root;
					NSDictionary *node = root[kReporterErrorKey];
					if (node != nil) {
						NSNumber *errorCode = node[kReporterCodeKey];
						NSString *errorMessage = node[kReporterMessageKey];
						if ((errorCode.integerValue != 210) && (errorMessage != nil)) {
							NSLog(@"%@ -> %@", reportDateString, errorMessage);

							NSInteger year = [[reportDateString substringWithRange:NSMakeRange(0, 4)] intValue];
							NSInteger month = [[reportDateString substringWithRange:NSMakeRange(4, 2)] intValue];
							NSInteger day = [[reportDateString substringWithRange:NSMakeRange(6, 2)] intValue];

							NSDateComponents *components = [[NSDateComponents alloc] init];
							[components setYear:year];
							[components setMonth:month];
							[components setDay:day];

							NSDate *reportDate = [[NSCalendar currentCalendar] dateFromComponents:components];

							NSMutableDictionary *reportTypes = [[NSMutableDictionary alloc] initWithDictionary:errors[errorMessage]];

							NSMutableArray *reports = [[NSMutableArray alloc] initWithArray:reportTypes[dateType]];
							[reports addObject:reportDate];
							reportTypes[dateType] = reports;

							errors[errorMessage] = reportTypes;
						}
					}
				} else if ([response.MIMEType isEqualToString:@"application/a-gzip"]) {
					NSString *originalFilename = response.allHeaderFields[@"filename"];
					NSData *inflatedReportData = [reportData gzipInflate];
					NSString *reportCSV = [[NSString alloc] initWithData:inflatedReportData encoding:NSUTF8StringEncoding];
					if (originalFilename && (reportCSV.length > 0)) {
						// Parse report CSV.
						Report *report = [Report insertNewReportWithCSV:reportCSV inAccount:account];

						// Check if the downloaded report is actually the one we expect.
						// (mostly to work around a bug in ITC that causes the wrong weekly report to be downloaded).
						NSString *downloadedReportDateString = nil;
						if ([report isKindOfClass:[WeeklyReport class]]) {
							WeeklyReport *weeklyReport = (WeeklyReport *)report;
							downloadedReportDateString = [dateFormatter stringFromDate:weeklyReport.endDate];
						} else {
							downloadedReportDateString = [dateFormatter stringFromDate:report.startDate];
						}
						if (![reportDateString isEqualToString:downloadedReportDateString]) {
							NSLog(@"Downloaded report has incorrect date, ignoring");
							[[report managedObjectContext] deleteObject:report];
							report = nil;
							continue;
						}

						if (report && originalFilename) {
							NSManagedObject *originalReport = [NSEntityDescription insertNewObjectForEntityForName:@"ReportCSV" inManagedObjectContext:moc];
							[originalReport setValue:reportCSV forKey:@"content"];
							[originalReport setValue:report forKey:@"report"];
							[originalReport setValue:originalFilename forKey:@"filename"];
							[report generateCache];
							numberOfReportsDownloaded++;
							account.reportsBadge = @(previousBadge + numberOfReportsDownloaded);
						} else {
							NSLog(@"Could not parse report %@", originalFilename);
						}
						// Save data.
						[psc performBlockAndWait:^{
							NSError *saveError = nil;
							[moc save:&saveError];
							if (saveError) {
								NSLog(@"Could not save context: %@", saveError);
							}
						}];
					}
				} else {
					NSString *content = [[NSString alloc] initWithData:reportData encoding:NSUTF8StringEncoding];
					NSLog(@"Error downloading %@ report for %@.", dateType, reportDateString);
					NSLog(@"%@: %@", response.MIMEType, content);
				}
				i++;
			}
		}
		if (self.isCancelled) {
			[self completeDownloadWithStatus:NSLocalizedString(@"Canceled", nil)];
			return;
		}

		NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
		dateFormatter.timeStyle = NSDateFormatterNoStyle;
		dateFormatter.dateStyle = NSDateFormatterShortStyle;
		for (NSString *error in errors.allKeys) {
			NSString *message = error;

			NSDictionary *reportTypes = errors[error];
			for (NSString *reportType in reportTypes.allKeys) {
				message = [message stringByAppendingFormat:@"\n\n%@ Reports:", reportType];
				for (NSDate *reportDate in reportTypes[reportType]) {
					message = [message stringByAppendingFormat:@"\n%@", [dateFormatter stringFromDate:reportDate]];
				}
			}

			[self showErrorWithMessage:message];
		}

		BOOL downloadPayments = [[NSUserDefaults standardUserDefaults] boolForKey:kSettingDownloadPayments];
		if (downloadPayments && ((numberOfReportsDownloaded >= 0) || (account.payments.count == 0))) {
			// Apple has retired the legacy cookie-based payments login flow on
			// itunesconnect.apple.com (idmsa /signin returns 503). Pull the
			// equivalent data via the same Reporter API access token that
			// already powers the sales download. The data we get is the
			// per-app royalty breakdown (Finance.getReport), which we aggregate
			// per currency per month to populate PaymentReport / PaymentDetailed.
			[self downloadFinanceReports];
			[self completeDownload];
		} else {
			if (numberOfReportsDownloaded > 0) {
				[self completeDownload];
			} else {
				[self completeDownloadWithStatus:NSLocalizedString(@"No new reports found", nil)];
			}
		}

		if ([moc hasChanges]) {
			[psc performBlockAndWait:^{
				NSError *saveError = nil;
				[moc save:&saveError];
				if (saveError) {
					NSLog(@"Could not save context: %@", saveError);
				}
			}];
		}
	}
}

- (void)loginSucceeded:(LoginManager *)loginManager {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0ul), ^{
		@autoreleasepool {

			[self downloadProgress:0.95f withStatus:NSLocalizedString(@"Loading payments...", nil)];

			//==== Payments

			if (self.isCancelled) {
				[self completeDownloadWithStatus:NSLocalizedString(@"Canceled", nil)];
            } else if (self->providerID.length > 0) {
                NSURL *paymentVendorsURL = [NSURL URLWithString:[kITCBaseURL stringByAppendingFormat:kITCPaymentVendorsAction, self->providerID]];
                [[NSURLSession.sharedSession dataTaskWithRequest:[NSURLRequest requestWithURL:paymentVendorsURL]
                                               completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                    
                    NSDictionary *paymentVendors = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    NSArray *sapVendors = paymentVendors[@"data"];

                    if (self.isCancelled) {
                        [self completeDownloadWithStatus:NSLocalizedString(@"Canceled", nil)];
                    } else if ((sapVendors != nil) && ![sapVendors isEqual:[NSNull null]] && (sapVendors.count > 0)) {
                        if (self->downloadedVendors == nil) {
                            self->downloadedVendors = [[NSMutableDictionary alloc] init];
                        } else {
                            [self->downloadedVendors removeAllObjects];
                        }
                        for (NSDictionary *vendor in sapVendors) {
                            NSNumber *vendorID = vendor[@"sapVendorNumber"];
                            self->downloadedVendors[vendorID.description] = @(0);
                        }
                        for (NSString *vendorID in self->downloadedVendors.allKeys) {
                            [self fetchPaymentsForVendorID:vendorID];
                        }
                    } else {
                        [self completeDownload];
                    }
                }] resume];
			}

			//==== /Payments
		}
	});
}

- (void)loginFailed:(LoginManager *)loginManager {
	[self completeDownload];
}

- (void)fetchPaymentsForVendorID:(NSString *)vendorID {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0ul), ^{
		@autoreleasepool {

            NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
            [moc setPersistentStoreCoordinator:self->psc];
			[moc setMergePolicy:NSMergeByPropertyObjectTrumpMergePolicy];

            ASAccount *account = (ASAccount *)[moc objectWithID:self->accountObjectID];

			NSMutableArray *reportsToDelete = [NSMutableArray array];
			NSMutableSet *allExistingPaymentReports = [NSMutableSet setWithSet:account.paymentReports];

			for (NSManagedObject *paymentReport in allExistingPaymentReports) {
				NSSet *payments = [paymentReport valueForKey:@"payments"];
				if (payments.count == 0) {
					[reportsToDelete addObject:paymentReport];
					continue;
				}
				for (NSManagedObject *payment in payments) {
					if ([[payment valueForKey:@"isExpected"] boolValue]) {
						NSDate *expectedPaymentDate = [payment valueForKey:@"paidOrExpectingPaymentDate"];
						if ([expectedPaymentDate compare:[NSDate date]] == NSOrderedAscending) {
							[reportsToDelete addObject:paymentReport];
							break;
						}
					}
				}
			}
			for (NSManagedObject *reportToDelete in reportsToDelete) {
				[moc deleteObject:reportToDelete];
				[allExistingPaymentReports removeObject:reportToDelete];
			}

			NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
			NSMutableSet *existingPaymentReportIdentifiers = [NSMutableSet set];
			for (NSManagedObject *paymentReport in allExistingPaymentReports) {
				NSDateComponents *dateComponents = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth) fromDate:[paymentReport valueForKey:@"reportDate"]];
				[existingPaymentReportIdentifiers addObject:[NSString stringWithFormat:@"%li-%li", (long)dateComponents.year, (long)dateComponents.month]];
			}

			NSNumberFormatter *currencyFormatter = [[NSNumberFormatter alloc] init];
			currencyFormatter.numberStyle = NSNumberFormatterDecimalStyle;
			currencyFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];

			NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
			[dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];

			NSDate *currDate = [NSDate date];
			NSDateComponents *offsetComponents = [[NSDateComponents alloc] init];
			offsetComponents.month = -1;

			while (YES) {
				currDate = [calendar dateByAddingComponents:offsetComponents toDate:currDate options:0];

				NSDateComponents *dateComponents = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth) fromDate:currDate];
				NSInteger year = dateComponents.year;
				NSInteger month = dateComponents.month;

				NSString *paymentReportIdentifier = [NSString stringWithFormat:@"%li-%li", (long)year, (long)month];
				if ([existingPaymentReportIdentifiers containsObject:paymentReportIdentifier]) {
					// We've already been here before, so bail out.
					break;
				}

                NSURL *paymentURL = [NSURL URLWithString:[kITCBaseURL stringByAppendingFormat:kITCPaymentVendorsPaymentAction, self->providerID, vendorID, year, month]];
				NSData *paymentData = [NSURLConnection sendSynchronousRequest:[NSURLRequest requestWithURL:paymentURL] returningResponse:nil error:nil];
				NSDictionary *payment = [NSJSONSerialization JSONObjectWithData:paymentData options:0 error:nil];
				payment = payment[@"data"];
				NSDate *paymentReportDate = [dateFormatter dateFromString:payment[@"reportDate"]];
				NSArray *paymentSummaries = payment[@"reportSummaries"];

				if (self.isCancelled) {
					[self completeDownloadWithStatus:NSLocalizedString(@"Canceled", nil)];
					break;
				} else if ((paymentSummaries == nil) || [paymentSummaries isEqual:[NSNull null]] || (paymentSummaries.count == 0)) {
                    @synchronized(self->downloadedVendors) {
                        NSInteger count = [self->downloadedVendors[vendorID] integerValue];
						count++;
                        self->downloadedVendors[vendorID] = @(count);
						// Bail out if there are no payments for over 12 consecutive months.
						if (count > 12) { break; }
					}
				} else {
                    @synchronized(self->downloadedVendors) {
                        self->downloadedVendors[vendorID] = @(0);
					}
					NSManagedObject *paymentReport = [NSEntityDescription insertNewObjectForEntityForName:@"PaymentReport" inManagedObjectContext:moc];
					[paymentReport setValue:paymentReportDate forKey:@"reportDate"];
					[paymentReport setValue:account forKey:@"account"];

					BOOL hasOnePaymentSummary = NO;
					for (NSDictionary *payment in paymentSummaries) {
						if (payment[@"paidOrExpectingPaymentDate"] == [NSNull null]) {
							continue;
						}
						NSDate *paidOrExpectedDate = [dateFormatter dateFromString:payment[@"paidOrExpectingPaymentDate"]];
						if (paidOrExpectedDate == nil) {
							// This payment is neither paid nor expected. Ignore it.
							continue;
						}
						hasOnePaymentSummary = YES;
						NSManagedObject *paymentDetailed = [NSEntityDescription insertNewObjectForEntityForName:@"PaymentDetailed" inManagedObjectContext:moc];
						CGFloat amount = [currencyFormatter numberFromString:payment[@"amount"]].floatValue;
						[paymentDetailed setValue:@(amount) forKey:@"amount"];
						[paymentDetailed setValue:payment[@"currency"] forKey:@"currency"];
						[paymentDetailed setValue:payment[@"bankName"] forKey:@"bankName"];
						[paymentDetailed setValue:payment[@"isPaymentExpected"] forKey:@"isExpected"];
						[paymentDetailed setValue:payment[@"maskedBankAccount"] forKey:@"maskedBankAccount"];
						[paymentDetailed setValue:paidOrExpectedDate forKey:@"paidOrExpectingPaymentDate"];
						[paymentDetailed setValue:payment[@"status"] forKey:@"status"];
						[paymentDetailed setValue:paymentReport forKey:@"paymentReport"];
					}
					if (!hasOnePaymentSummary) {
						[moc deleteObject:paymentReport];
						continue;
					}
					account.paymentsBadge = @(account.paymentsBadge.integerValue + 1);

					if ([moc hasChanges]) {
                        [self->psc performBlockAndWait:^{
							NSError *saveError = nil;
							[moc save:&saveError];
							if (saveError) {
								NSLog(@"Could not save context: %@", saveError);
							}
						}];
					}
				}
			}

            @synchronized(self->downloadedVendors) {
                [self->downloadedVendors removeObjectForKey:vendorID];
                if (self->downloadedVendors.count == 0) {
					[self completeDownload];
				}
			}
		}
	});
}

#pragma mark - Finance Reports (Reporter API)

// Replacement for the legacy cookie-based payments fetch. Uses the same
// Reporter API access token already used by the sales download.
//
// Mapping into the existing data model:
//   - For each calendar month we don't already have a PaymentReport for,
//     fetch Finance.getReport for every region the vendor publishes to
//     (discovered via Finance.getVendorsAndRegions).
//   - Aggregate the "Extended Partner Share" column per "Partner Share
//     Currency" across all regions of that month.
//   - Insert one PaymentReport per month, with one PaymentDetailed per
//     currency. Bank info / paid-vs-expected status is not available from
//     this API path — those fields are left nil. The UI must tolerate this.
- (void)downloadFinanceReports {
	@autoreleasepool {
		[self downloadProgress:0.9f withStatus:NSLocalizedString(@"Loading finance reports...", nil)];

		if ((accessToken.length == 0) || (providerID.length == 0)) {
			NSLog(@"Finance: skipping — access token or provider ID is missing on the account.");
			return;
		}

		NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
		moc.persistentStoreCoordinator = psc;
		moc.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
		ASAccount *account = (ASAccount *)[moc objectWithID:accountObjectID];
		NSString *vendorID = account.vendorID;
		if (vendorID.length == 0) {
			NSLog(@"Finance: skipping — vendor ID is missing on the account.");
			return;
		}

		// Build a set of calendar (year, month) keys we already have a
		// PaymentReport for. Existing reports — whether from the legacy
		// cookie path or from a previous Finance-API run — are left untouched.
		// Only months with no existing PaymentReport will be fetched.
		NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
		NSMutableSet<NSString *> *existingKeys = [NSMutableSet set];
		for (NSManagedObject *report in account.paymentReports) {
			NSDate *reportDate = [report valueForKey:@"reportDate"];
			if (reportDate == nil) continue;
			NSDateComponents *c = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth) fromDate:reportDate];
			[existingKeys addObject:[NSString stringWithFormat:@"%ld-%ld", (long)c.year, (long)c.month]];
		}
		NSLog(@"Finance: already have %lu PaymentReports — only missing months will be fetched.", (unsigned long)existingKeys.count);
        
        /*
		// One-shot diagnostic: ask Apple for the canonical Finance.getReport
		// signature so future format drift is self-debuggable from logs alone.
		static dispatch_once_t helpOnce;
		dispatch_once(&helpOnce, ^{
			NSString *help = [self callReporterMethod:@"Finance.getHelp" service:kITCReporterServiceTypeFinance];
			NSLog(@"Finance.getHelp →\n%@", help ?: @"(no response)");
		});
         */

		// Discover available regions for this vendor.
		NSArray<NSString *> *regions = [self fetchAvailableFinanceRegionsForVendor:vendorID];
		if (regions.count == 0) {
			NSLog(@"Finance: Finance.getVendorsAndRegions returned no regions; falling back to ['WW'].");
			regions = @[@"WW"];
		}
		NSLog(@"Finance: %lu regions available for vendor %@: %@",
			  (unsigned long)regions.count, vendorID, [regions componentsJoinedByString:@", "]);

		// Walk back through the last 24 calendar months. Skip any we already
		// have. For each remaining month, try to fetch all regions.
		NSDate *cursor = [NSDate date];
		NSDateComponents *minusMonth = [[NSDateComponents alloc] init];
		minusMonth.month = -1;
		NSInteger consecutiveEmpty = 0;
		for (NSInteger monthsBack = 1; monthsBack <= 24; monthsBack++) {
			if (self.isCancelled) break;

			cursor = [calendar dateByAddingComponents:minusMonth toDate:cursor options:0];
			NSDateComponents *c = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth) fromDate:cursor];
			NSString *key = [NSString stringWithFormat:@"%ld-%ld", (long)c.year, (long)c.month];
			if ([existingKeys containsObject:key]) {
				NSLog(@"Finance: %ld-%02ld already imported, skipping.", (long)c.year, (long)c.month);
				continue;
			}

			NSInteger fiscalYear = 0, fiscalPeriod = 0;
			[self mapCalendarYear:c.year month:c.month toFiscalYear:&fiscalYear period:&fiscalPeriod];

			NSMutableDictionary<NSString *, NSDecimalNumber *> *totalsByCurrency = [NSMutableDictionary dictionary];
			BOOL anyRegionHadData = NO;
			// First imported month of this run gets verbose per-region logging
			// so the user can spot any remaining rollup/duplicate region.
			static dispatch_once_t verboseOnce;
			__block BOOL verboseThisMonth = NO;
			dispatch_once(&verboseOnce, ^{ verboseThisMonth = YES; });

			for (NSString *region in regions) {
				if (self.isCancelled) break;
				NSString *errorMessage = nil;
				NSString *tsv = [self fetchFinanceTSVForVendor:vendorID
														region:region
													fiscalYear:fiscalYear
												  fiscalPeriod:fiscalPeriod
													  outError:&errorMessage];
				if (tsv.length == 0) {
					if (errorMessage.length > 0) {
						NSLog(@"Finance: %ld-%02ld %@ → %@", (long)c.year, (long)c.month, region, errorMessage);
					}
					continue;
				}
				anyRegionHadData = YES;
				NSDictionary<NSString *, NSNumber *> *regionTotals = [self aggregateProceedsByCurrencyFromTSV:tsv];
				if (verboseThisMonth) {
					NSMutableString *summary = [NSMutableString string];
					for (NSString *cur in regionTotals) {
						[summary appendFormat:@"%@=%.2f ", cur, regionTotals[cur].floatValue];
					}
					NSLog(@"Finance: %ld-%02ld %@ → %@", (long)c.year, (long)c.month, region, summary);
				}
				for (NSString *currency in regionTotals) {
					NSDecimalNumber *running = totalsByCurrency[currency] ?: [NSDecimalNumber zero];
					NSDecimalNumber *add = [NSDecimalNumber decimalNumberWithDecimal:[regionTotals[currency] decimalValue]];
					totalsByCurrency[currency] = [running decimalNumberByAdding:add];
				}
			}

			if (!anyRegionHadData) {
				consecutiveEmpty++;
				// Apple keeps ~24 months of finance data. If we've seen 6 empty
				// months in a row, assume we've walked off the end and stop.
				if (consecutiveEmpty >= 6) {
					NSLog(@"Finance: 6 consecutive empty months, stopping backfill.");
					break;
				}
				continue;
			}
			consecutiveEmpty = 0;

			// Insert PaymentReport + one PaymentDetailed per currency.
			NSDateComponents *firstOfMonth = [[NSDateComponents alloc] init];
			firstOfMonth.year = c.year;
			firstOfMonth.month = c.month;
			firstOfMonth.day = 1;
			NSDate *reportDate = [calendar dateFromComponents:firstOfMonth];

			NSManagedObject *paymentReport = [NSEntityDescription insertNewObjectForEntityForName:@"PaymentReport" inManagedObjectContext:moc];
			[paymentReport setValue:reportDate forKey:@"reportDate"];
			[paymentReport setValue:account forKey:@"account"];

			for (NSString *currency in totalsByCurrency) {
				NSDecimalNumber *amount = totalsByCurrency[currency];
				NSManagedObject *paymentDetailed = [NSEntityDescription insertNewObjectForEntityForName:@"PaymentDetailed" inManagedObjectContext:moc];
				[paymentDetailed setValue:@(amount.floatValue) forKey:@"amount"];
				[paymentDetailed setValue:currency forKey:@"currency"];
				[paymentDetailed setValue:@(NO) forKey:@"isExpected"];
				// Bank name, masked account, paid-or-expected date, and status
				// are not available via the Reporter API. Left nil intentionally.
				[paymentDetailed setValue:paymentReport forKey:@"paymentReport"];
			}
			account.paymentsBadge = @(account.paymentsBadge.integerValue + 1);

			NSError *saveError = nil;
			[psc performBlockAndWait:^{
				NSError *err = nil;
				[moc save:&err];
				if (err) NSLog(@"Finance: save error for %ld-%02ld: %@", (long)c.year, (long)c.month, err);
			}];
			if (saveError == nil) {
				NSLog(@"Finance: imported %ld-%02ld with %lu currency totals.",
					  (long)c.year, (long)c.month, (unsigned long)totalsByCurrency.count);
			}
		}
	}
}

// Apple fiscal calendar: year starts in October.
//   Calendar Oct/Nov/Dec of year N  →  fiscal year N+1, periods 1/2/3
//   Calendar Jan–Sep of year N      →  fiscal year N,   periods 4–12
- (void)mapCalendarYear:(NSInteger)year month:(NSInteger)month
		   toFiscalYear:(NSInteger *)outFiscalYear period:(NSInteger *)outPeriod {
	if (month >= 10) {
		*outFiscalYear = year + 1;
		*outPeriod = month - 9;
	} else {
		*outFiscalYear = year;
		*outPeriod = month + 3;
	}
}

// Generic Reporter-API caller — used for diagnostic calls like Finance.getHelp.
// Returns the raw response text (or nil), with no parsing.
- (NSString *)callReporterMethod:(NSString *)methodCall service:(NSString *)serviceType {
	NSString *query = [NSString stringWithFormat:@"a=%@, %@", providerID, methodCall];
	NSDictionary *getReportData = @{@"accesstoken": NSStringPercentEscaped(accessToken),
									@"version":     kITCReporterVersion,
									@"mode":        kITCReporterMode,
									@"queryInput":  NSStringPercentEscaped([NSString stringWithFormat:kITCReporterServiceBody, query]),
									@"salesurl":    NSStringPercentEscaped([kITCReporterBaseURL stringByAppendingFormat:kITCReporterServiceAction, kITCReporterServiceTypeSales]),
									@"financeurl":  NSStringPercentEscaped([kITCReporterBaseURL stringByAppendingFormat:kITCReporterServiceAction, kITCReporterServiceTypeFinance]),
									};
	NSData *jsonData = [NSJSONSerialization dataWithJSONObject:getReportData options:0 error:nil];
	NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
	NSString *body = [NSString stringWithFormat:@"jsonRequest=%@", jsonString];

	NSURL *url = [NSURL URLWithString:[kITCReporterBaseURL stringByAppendingFormat:kITCReporterServiceAction, serviceType]];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
	request.HTTPMethod = @"POST";
	[request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
	request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

	NSData *responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:nil error:nil];
	if (responseData.length == 0) return nil;
	return [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
}

// Region codes that are ROLLUPS of other regions and must not be summed
// alongside them, or every transaction is counted twice.
//   WW — "Worldwide" rollup of every per-currency settlement region.
//   ZZ — also a rollup; the 2026-04 log proved it by reproducing the exact
//        per-currency amounts of CH+EU+GB+RO+US in a single 'ZZ' row.
// Including either inflates totals by 2×.
+ (NSSet<NSString *> *)rollupRegionCodes {
	static NSSet *codes = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		codes = [NSSet setWithObjects:@"WW", @"ZZ", nil];
	});
	return codes;
}

- (NSArray<NSString *> *)fetchAvailableFinanceRegionsForVendor:(NSString *)vendor {
	NSString *query = [NSString stringWithFormat:@"a=%@, Finance.getVendorsAndRegions", providerID];

	NSDictionary *getReportData = @{@"accesstoken": NSStringPercentEscaped(accessToken),
									@"version":     kITCReporterVersion,
									@"mode":        kITCReporterMode,
									@"queryInput":  NSStringPercentEscaped([NSString stringWithFormat:kITCReporterServiceBody, query]),
									@"salesurl":    NSStringPercentEscaped([kITCReporterBaseURL stringByAppendingFormat:kITCReporterServiceAction, kITCReporterServiceTypeSales]),
									@"financeurl":  NSStringPercentEscaped([kITCReporterBaseURL stringByAppendingFormat:kITCReporterServiceAction, kITCReporterServiceTypeFinance]),
									};
	NSData *jsonData = [NSJSONSerialization dataWithJSONObject:getReportData options:0 error:nil];
	NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
	NSString *body = [NSString stringWithFormat:@"jsonRequest=%@", jsonString];

	NSURL *url = [NSURL URLWithString:[kITCReporterBaseURL stringByAppendingFormat:kITCReporterServiceAction, kITCReporterServiceTypeFinance]];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
	request.HTTPMethod = @"POST";
	[request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
	request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

	NSHTTPURLResponse *response = nil;
	NSData *responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:nil];
	if (responseData.length == 0) {
		NSLog(@"Finance.getVendorsAndRegions: no response (status=%ld).", (long)response.statusCode);
		return @[];
	}

	// Parse the XML response — structure is Vendor → Region → Code/Reports.
	// ReporterParser is geared for simple lists; for nested XML we do a quick
	// regex scrape over the <Code>…</Code> tags inside <Region> blocks.
	NSString *xml = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
	NSMutableArray<NSString *> *regions = [NSMutableArray array];
	NSError *regexError = nil;
	NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<Code>([^<]+)</Code>"
																		   options:0
																			 error:&regexError];
	NSSet *rollups = [ReportDownloadOperation rollupRegionCodes];
	[regex enumerateMatchesInString:xml options:0 range:NSMakeRange(0, xml.length)
						 usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
		NSString *code = [xml substringWithRange:[match rangeAtIndex:1]];
		if (code.length == 0) return;
		if ([rollups containsObject:code]) {
			NSLog(@"Finance: skipping rollup region '%@' to avoid double-counting.", code);
			return;
		}
		if (![regions containsObject:code]) {
			[regions addObject:code];
		}
	}];
	return regions;
}

// Returns nil + sets *outError on failure / not-available; returns parsed TSV string on success.
- (NSString *)fetchFinanceTSVForVendor:(NSString *)vendor
								region:(NSString *)region
							fiscalYear:(NSInteger)fiscalYear
						  fiscalPeriod:(NSInteger)fiscalPeriod
							  outError:(NSString **)outError {
	// Apple Reporter 2.2 signature for Finance.getReport is:
	//   Finance.getReport <vendor>, <region>, <reportType>, <fiscalYear>, <fiscalPeriod>
	// (fiscal_year and fiscal_period are SEPARATE parameters.)
	//
	// Spacing: match the sales-side format exactly — space after `a=…,` and
	// after the method name, but NO space between subsequent arguments. The
	// Reporter parser appears to treat leading whitespace as part of the value
	// for some args, which causes silent rejection.
	NSString *query = [NSString stringWithFormat:@"a=%@, Finance.getReport, %@,%@,Financial,%ld,%02ld",
					   providerID, vendor, region, (long)fiscalYear, (long)fiscalPeriod];
	static dispatch_once_t logQueryOnce;
	dispatch_once(&logQueryOnce, ^{
		NSLog(@"Finance.getReport query (first attempt): %@", query);
	});

	NSDictionary *getReportData = @{@"accesstoken": NSStringPercentEscaped(accessToken),
									@"version":     kITCReporterVersion,
									@"mode":        kITCReporterMode,
									@"queryInput":  NSStringPercentEscaped([NSString stringWithFormat:kITCReporterServiceBody, query]),
									@"salesurl":    NSStringPercentEscaped([kITCReporterBaseURL stringByAppendingFormat:kITCReporterServiceAction, kITCReporterServiceTypeSales]),
									@"financeurl":  NSStringPercentEscaped([kITCReporterBaseURL stringByAppendingFormat:kITCReporterServiceAction, kITCReporterServiceTypeFinance]),
									};
	NSData *jsonData = [NSJSONSerialization dataWithJSONObject:getReportData options:0 error:nil];
	NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
	NSString *body = [NSString stringWithFormat:@"jsonRequest=%@", jsonString];

	NSURL *url = [NSURL URLWithString:[kITCReporterBaseURL stringByAppendingFormat:kITCReporterServiceAction, kITCReporterServiceTypeFinance]];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
	request.HTTPMethod = @"POST";
	[request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
	request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

	NSHTTPURLResponse *response = nil;
	NSData *responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:nil];

	if ([response.MIMEType isEqualToString:@"application/a-gzip"]) {
		NSData *inflated = [responseData gzipInflate];
		return [[NSString alloc] initWithData:inflated encoding:NSUTF8StringEncoding];
	}
	if ([response.MIMEType isEqualToString:@"text/plain"]) {
		ReporterParser *parser = [[ReporterParser alloc] initWithData:responseData];
		[parser parse];
		NSDictionary *errorNode = parser.root[kReporterErrorKey];
		if (errorNode != nil) {
			NSNumber *code = errorNode[kReporterCodeKey];
			NSString *message = errorNode[kReporterMessageKey];
			// Codes 210 ("no report available") and 213 ("no sales for that
			// date") are both legitimate empty responses — most region/period
			// combinations have no data and that's normal. Only surface
			// unexpected errors so logs aren't drowned in 576-line spam.
			if ((code.integerValue == 210) || (code.integerValue == 213)) {
				// expected empty — leave outError nil so the caller skips silently
			} else if (outError) {
				*outError = [NSString stringWithFormat:@"code=%@ %@", code, message];
			}
		}
		return nil;
	}
	if (outError) *outError = [NSString stringWithFormat:@"unexpected MIME %@ status=%ld", response.MIMEType, (long)response.statusCode];
	return nil;
}

// Finance.getReport TSV columns include (typical layout):
//   Start Date \t End Date \t UPC \t ISRC \t Vendor Identifier \t Quantity \t
//   Partner Share \t Extended Partner Share \t Partner Share Currency \t
//   Sales or Return \t Apple Identifier \t Artist/Show \t Title/Episode/Season \t
//   ... (further metadata columns)
//
// We sum "Extended Partner Share" grouped by "Partner Share Currency". This
// is the amount per app per country times its quantity — i.e. the money
// Apple actually owes you, before tax withholding and bank-transfer fees.
- (NSDictionary<NSString *, NSNumber *> *)aggregateProceedsByCurrencyFromTSV:(NSString *)tsv {
	NSArray<NSString *> *lines = [tsv componentsSeparatedByString:@"\n"];
	if (lines.count < 2) return @{};
	NSArray<NSString *> *headers = [lines.firstObject componentsSeparatedByString:@"\t"];

	NSInteger amountColumn = -1;
	NSInteger currencyColumn = -1;
	for (NSInteger i = 0; i < (NSInteger)headers.count; i++) {
		NSString *h = headers[i];
		if ([h caseInsensitiveCompare:@"Extended Partner Share"] == NSOrderedSame) amountColumn = i;
		else if ([h caseInsensitiveCompare:@"Partner Share Currency"] == NSOrderedSame) currencyColumn = i;
	}
	if ((amountColumn < 0) || (currencyColumn < 0)) {
		NSLog(@"Finance: TSV missing expected columns. Headers were: %@", [headers componentsJoinedByString:@" | "]);
		return @{};
	}

	NSNumberFormatter *fmt = [[NSNumberFormatter alloc] init];
	fmt.numberStyle = NSNumberFormatterDecimalStyle;
	fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];

	NSMutableDictionary<NSString *, NSDecimalNumber *> *totals = [NSMutableDictionary dictionary];
	for (NSInteger row = 1; row < (NSInteger)lines.count; row++) {
		NSString *line = lines[row];
		if (line.length == 0) continue;
		NSArray<NSString *> *cols = [line componentsSeparatedByString:@"\t"];
		if (cols.count <= MAX(amountColumn, currencyColumn)) continue;
		NSString *currency = cols[currencyColumn];
		NSString *amountStr = cols[amountColumn];
		if (currency.length == 0 || amountStr.length == 0) continue;
		NSNumber *amount = [fmt numberFromString:amountStr];
		if (amount == nil) continue;
		NSDecimalNumber *running = totals[currency] ?: [NSDecimalNumber zero];
		NSDecimalNumber *add = [NSDecimalNumber decimalNumberWithDecimal:amount.decimalValue];
		totals[currency] = [running decimalNumberByAdding:add];
	}

	NSMutableDictionary<NSString *, NSNumber *> *out = [NSMutableDictionary dictionary];
	for (NSString *currency in totals) {
		out[currency] = @(totals[currency].floatValue);
	}
	return out;
}

#pragma mark - Helper Methods

- (void)showErrorWithMessage:(NSString *)message {
	dispatch_async(dispatch_get_main_queue(), ^{
		UIAlertController *alertController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Error", nil)
																				 message:message
																		  preferredStyle:UIAlertControllerStyleAlert];
		[alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleCancel handler:nil]];
		[alertController show];
	});
}

- (void)downloadProgress:(CGFloat)progress withStatus:(NSString *)status {
	dispatch_async(dispatch_get_main_queue(), ^{
		if (status != nil) {
            self->_account.downloadStatus = status;
		}
        self->_account.downloadProgress = progress;
	});
}

- (void)completeDownload {
	[self completeDownloadWithStatus:NSLocalizedString(@"Finished", nil)];
}

- (void)completeDownloadWithStatus:(NSString *)status {
	dispatch_async(dispatch_get_main_queue(), ^{
        self->_account.downloadStatus = status;
        self->_account.downloadProgress = 1.0f;
        self->_account.isDownloadingReports = NO;
		[UIApplication sharedApplication].idleTimerDisabled = NO;
        if (self->backgroundTaskID != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:self->backgroundTaskID];
		}
	});
}

@end
