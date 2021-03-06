/**
 * this project based on ReactNativeAutoUpdater

 */

#import "DoctorStrangeUpdater.h"
#import "StatusBarNotification.h"
#import "RCTBridge.h"
#include "bspatch.h"
#import "RCTLog.h"
#import "SSZipArchive.h"


NSString* const DoctorStrangeUpdaterLastUpdateCheckDate = @"DoctorStrangeUpdater Last Update Check Date";
NSString* const DoctorStrangeUpdaterCurrentJSCodeMetadata = @"DoctorStrangeUpdater Current JS Code Metadata";

@interface DoctorStrangeUpdater() <NSURLSessionDownloadDelegate, RCTBridgeModule>

@property NSURL* defaultJSCodeLocation;
@property NSURL* defaultMetadataFileLocation;
@property NSURL* _latestJSCodeLocation;
@property NSURL* metadataUrl;
@property BOOL showProgress;
@property BOOL allowCellularDataUse;
@property NSString* hostname;
@property DoctorStrangeUpdaterUpdateType updateType;
@property NSDictionary* updateMetadata;
@property BOOL initializationOK;
@property BOOL downloadPatch;

@end

@implementation DoctorStrangeUpdater

RCT_EXPORT_MODULE()

static DoctorStrangeUpdater *RNAUTOUPDATER_SINGLETON = nil;
static bool isFirstAccess = YES;

+ (id)sharedInstance
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        isFirstAccess = NO;
        RNAUTOUPDATER_SINGLETON = [[super allocWithZone:NULL] init];
        [RNAUTOUPDATER_SINGLETON defaults];
    });

    return RNAUTOUPDATER_SINGLETON;
}

#pragma mark - Life Cycle

+ (id) allocWithZone:(NSZone *)zone {
    return [self sharedInstance];
}

+ (id)copyWithZone:(struct _NSZone *)zone {
    return [self sharedInstance];
}

+ (id)mutableCopyWithZone:(struct _NSZone *)zone {
    return [self sharedInstance];
}

- (id)copy {
    return [[DoctorStrangeUpdater alloc] init];
}

- (id)mutableCopy {
    return [[DoctorStrangeUpdater alloc] init];
}

- (id) init {
    if(RNAUTOUPDATER_SINGLETON){
        return RNAUTOUPDATER_SINGLETON;
    }
    if (isFirstAccess) {
        [self doesNotRecognizeSelector:_cmd];
    }
    self = [super init];
    return self;
}

- (void)defaults {
    self.showProgress = YES;
    self.allowCellularDataUse = NO;
    self.updateType = DoctorStrangeUpdaterMinorUpdate;
}

#pragma mark - JS methods

/**
 * 使用js 获取版本号
 *
 */
- (NSDictionary *)constantsToExport {
    NSDictionary* metadata = [[NSUserDefaults standardUserDefaults] objectForKey:DoctorStrangeUpdaterCurrentJSCodeMetadata];
    NSString* version = @"";
    if (metadata) {
        version = [metadata objectForKey:@"version"];
    }
    return @{
             @"jsCodeVersion": version
             };
}

#pragma mark - initialize Singleton

- (void)initializeWithUpdateMetadataUrl:(NSURL*)url defaultJSCodeLocation:(NSURL*)defaultJSCodeLocation defaultMetadataFileLocation:(NSURL*)metadataFileLocation {
    self.defaultJSCodeLocation = defaultJSCodeLocation;
    self.defaultMetadataFileLocation = metadataFileLocation;
    //是否下载差分包
    self.downloadPatch = NO;

    self.metadataUrl = url;

    NSString* assetsFolder = [[[self libraryDirectory] stringByAppendingPathComponent: @"JSCode"] stringByAppendingPathComponent:@"assets"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    BOOL isDir = FALSE;
    //如果资源文件夹不存在则复制
    BOOL isDirExist = [fileManager fileExistsAtPath: assetsFolder isDirectory: &isDir];
    if (!(isDir && isDirExist)) {
        NSString *bundleAssets = [[[NSBundle mainBundle]resourcePath]stringByAppendingPathComponent:@"assets"];
        [fileManager copyItemAtPath:bundleAssets toPath:assetsFolder error:&error];
    }

    [self compareSavedMetadataAgainstContentsOfFile: self.defaultMetadataFileLocation];
}

//设置是否在状态栏显示下载和更新状态
- (void)showProgress: (BOOL)progress {
    self.showProgress = progress;
}

- (void)allowCellularDataUse: (BOOL)cellular {
    self.allowCellularDataUse = cellular;
}

//设置最小版本号对比
- (void)downloadUpdatesForType:(DoctorStrangeUpdaterUpdateType)type {
    self.updateType = type;
}

- (NSURL*)latestJSCodeLocation {
    NSString* latestJSCodeURLString = [[[self libraryDirectory] stringByAppendingPathComponent:@"JSCode"] stringByAppendingPathComponent:@"doctor.jsbundle"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:latestJSCodeURLString]) {
        self._latestJSCodeLocation = [NSURL URLWithString:[NSString stringWithFormat:@"file://%@", latestJSCodeURLString]];
        return self._latestJSCodeLocation;
    } else {
        return self.defaultJSCodeLocation;
    }
}

//设置主要域名
- (void)setHostnameForRelativeDownloadURLs:(NSString *)hostname {
    self.hostname = hostname;
}

- (void)compareSavedMetadataAgainstContentsOfFile: (NSURL*)metadataFileLocation {
    //本地版本文件
    NSData* fileMetadata = [NSData dataWithContentsOfURL: metadataFileLocation];
    if (!fileMetadata) {
        NSLog(@"[DoctorStrangeUpdater]: Make sure you initialize RNAU with a metadata file.");
        if (self.showProgress) {
            [StatusBarNotification showWithMessage:NSLocalizedString(@"Error reading Metadata File.", nil) backgroundColor:[StatusBarNotification errorColor] autoHide:YES];
        }
        self.initializationOK = NO;
        return;
    }
    NSError *error;
    //格式化为字典
    NSDictionary* localMetadata = [NSJSONSerialization JSONObjectWithData:fileMetadata options:NSJSONReadingAllowFragments error:&error];
    if (error) {
        NSLog(@"[DoctorStrangeUpdater]: Initialized RNAU with a WRONG metadata file.");
        if (self.showProgress) {
            [StatusBarNotification showWithMessage:NSLocalizedString(@"Error reading Metadata File.", nil) backgroundColor:[StatusBarNotification errorColor] autoHide:YES];
        }
        self.initializationOK = NO;
        return;
    }
    NSLog(@"数据格式化完成");

    NSDictionary* savedMetadata = [[NSUserDefaults standardUserDefaults] objectForKey:DoctorStrangeUpdaterCurrentJSCodeMetadata];
    if (!savedMetadata) {
        [[NSUserDefaults standardUserDefaults] setObject:localMetadata forKey:DoctorStrangeUpdaterCurrentJSCodeMetadata];
    }
    else {
        NSLog(@"data");
        //重新启动时加载新版本bundle
        if ([[savedMetadata objectForKey:@"version"] compare:[localMetadata objectForKey:@"version"] options:NSNumericSearch] == NSOrderedAscending) {
            NSData* data = [NSData dataWithContentsOfURL:self.defaultJSCodeLocation];
            NSString* filename = [NSString stringWithFormat:@"%@/%@", [self createCodeDirectory], @"doctor.jsbundle"];

            if ([data writeToFile:filename atomically:YES]) {
                [[NSUserDefaults standardUserDefaults] setObject:localMetadata forKey:DoctorStrangeUpdaterCurrentJSCodeMetadata];
            }
        }
    }
    self.initializationOK = YES;
}



#pragma mark - Check updates

//检查更新
- (void)performUpdateCheck {
    if (!self.initializationOK) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.showProgress) {
            [StatusBarNotification showWithMessage:NSLocalizedString(@"检查更新中.", nil) backgroundColor:[StatusBarNotification infoColor] autoHide:YES];
        }
    });

    //获取当前metadata信息
    NSDictionary* currentMetadata = [[NSUserDefaults standardUserDefaults] objectForKey:DoctorStrangeUpdaterCurrentJSCodeMetadata];
    NSString* checkUrlStr = [self.metadataUrl absoluteString];
    NSLog(@"检查url: %@", checkUrlStr);

    if (currentMetadata) {
        NSLog(@"生成url: %@", checkUrlStr);
        @try {
            NSNumber* oldversionId = [currentMetadata objectForKey:@"versionId"];
            NSString* oldversion = [currentMetadata objectForKey:@"version"];
            NSString *normal = @"&versionId=";
            //设置请求参数，将下载版本告知
            NSNumberFormatter* numberFormatter = [[NSNumberFormatter alloc] init];
            NSString* versionStr = [numberFormatter stringFromNumber:oldversionId];
            NSString *bodyStr = [normal stringByAppendingString:versionStr];
            NSString* newcheckUrl = [checkUrlStr stringByAppendingString:[bodyStr stringByAppendingString:[@"&version=" stringByAppendingString: oldversion]]];
            checkUrlStr = newcheckUrl;
        } @catch (NSException *exception) {
            NSLog(@"exception %@, %@", exception.name, exception.reason);
        } @finally {

        }
    }

    NSData* data = [NSData dataWithContentsOfURL: [NSURL URLWithString: checkUrlStr]];
    if (!data) {
        if (self.showProgress) {
            [StatusBarNotification showWithMessage:NSLocalizedString(@"Received no Update Metadata. Aborted.", nil) backgroundColor:[StatusBarNotification errorColor] autoHide:YES];
        }
        return;
    }
    NSError* error;
    self.updateMetadata = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&error];
    if (error) {
        if (self.showProgress) {
            [StatusBarNotification showWithMessage:NSLocalizedString(@"Error reading Metadata JSON. Update aborted.", nil) backgroundColor:[StatusBarNotification errorColor] autoHide:YES];
        }
        return;
    }
    NSString* versionToDownload = [self.updateMetadata objectForKey:@"version"];
    NSNumber* versionId = [self.updateMetadata objectForKey:@"versionId"];
    NSString* minContainerVersion = [self.updateMetadata objectForKey:@"minContainerVersion"];
    NSNumber* patchId = [self.updateMetadata objectForKey:@"patchId"];
    //这里设置服务器地址
    NSString* serverUrl = [self.updateMetadata objectForKey:@"serverUrl"];

    if ([self isBlankString:serverUrl] == NO) {
        [self setHostnameForRelativeDownloadURLs: serverUrl];
    }

    BOOL isRelative = [[self.updateMetadata objectForKey:@"isRelative"] boolValue];

    if ([self shouldDownloadUpdateWithVersion:versionToDownload forMinContainerVersion:minContainerVersion]) {
        NSLog(@"开始下载更新数据");

        if (self.showProgress) {
            [StatusBarNotification showWithMessage:NSLocalizedString(@"下载更新中.", nil) backgroundColor:[StatusBarNotification infoColor] autoHide:YES];
        }
        if (isRelative) {
            //            urlToDownload = [self.hostname stringByAppendingString:urlToDownload];
            NSLog(@"开始特么下载更新数据");
            
            /**
             * 原生更新会有两种情况出现，这是在添加了静态文件更新以及增量更新后会出现的问题，
             *
             **/
            //检查document文件夹里面是否存在上一版本的zip，如果存在则代表是用户在原来的app基础上进行下载更新的，否则就是在卸载app之后进行更新的
            //获取上一把版本的zip名字
            NSString* filename = [NSString stringWithFormat:@"%@/%@", [self createCodeDirectory], @"doctor.zip"];
            
            //检查该文件是否存在
            if ([[NSFileManager defaultManager] fileExistsAtPath:filename] == YES) {
                //如果存在，且差量id存在， 则可以直接下载差量patch
                if([self isBlankNumber:patchId] == NO){
                    NSLog(@"下载差分包");
                    [self startDownloadingUpdateFromPatchId: patchId];
                    self.downloadPatch = YES;
                } else {
                    NSLog(@"下载整包");
                    [self startDownloadingUpdateFromVersion: versionToDownload];
                    self.downloadPatch = NO;
                }
            } else {
                //否则下载整包
                NSLog(@"下载整包");
                [self startDownloadingUpdateFromVersion: versionToDownload];
                self.downloadPatch = NO;
            };
        } else {
            NSString* urlToDownload = [self.updateMetadata objectForKey:@"url"];
            [self startDownloadingUpdateFromURLAbsolutely:urlToDownload];

        }
    }
    else {
        if (self.showProgress) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [StatusBarNotification showWithMessage:NSLocalizedString(@"已全部更新", nil) backgroundColor:[StatusBarNotification successColor] autoHide:YES];
            });
        }
    }
}

//判断是否应该下载更新数据
- (BOOL)shouldDownloadUpdateWithVersion:(NSString*)version forMinContainerVersion:(NSString*)minContainerVersion {
    NSLog(@"判断是否应该下载更新数据");

    BOOL shouldDownload = NO;

    /*
     * First check for the version match. If we have the update version, then don't download.
     * Also, check what kind of updates the user wants.
     */
    NSDictionary* currentMetadata = [[NSUserDefaults standardUserDefaults] objectForKey:DoctorStrangeUpdaterCurrentJSCodeMetadata];
    if (currentMetadata == [NSNull null] || !currentMetadata) {
        shouldDownload = YES;
    }
    else {
        NSString* currentVersion = [currentMetadata objectForKey:@"version"];

        int currentMajor, currentMinor, currentPatch, updateMajor, updateMinor, updatePatch;
        NSArray* currentComponents = [currentVersion componentsSeparatedByString:@"."];
        if (currentComponents.count == 0) {
            return NO;
        }
        currentMajor = [currentComponents[0] intValue];
        if (currentComponents.count >= 2) {
            currentMinor = [currentComponents[1] intValue];
        }
        else {
            currentMinor = 0;
        }
        if (currentComponents.count >= 3) {
            currentPatch = [currentComponents[2] intValue];
        }
        else {
            currentPatch = 0;
        }
        NSArray* updateComponents = [version componentsSeparatedByString:@"."];
        updateMajor = [updateComponents[0] intValue];
        if (updateComponents.count >= 2) {
            updateMinor = [updateComponents[1] intValue];
        }
        else {
            updateMinor = 0;
        }
        if (updateComponents.count >= 3) {
            updatePatch = [updateComponents[2] intValue];
        }
        else {
            updatePatch = 0;
        }

        switch (self.updateType) {
            case DoctorStrangeUpdaterMajorUpdate: {
                if (currentMajor < updateMajor) {
                    shouldDownload = YES;
                }
                break;
            }
            case DoctorStrangeUpdaterMinorUpdate: {
                if (currentMajor < updateMajor || (currentMajor == updateMajor && currentMinor < updateMinor)) {
                    shouldDownload = YES;
                }

                break;
            }
            case DoctorStrangeUpdaterPatchUpdate: {
                if (currentMajor < updateMajor || (currentMajor == updateMajor && currentMinor < updateMinor)
                    || (currentMajor == updateMajor && currentMinor == updateMinor && currentPatch < updatePatch)) {
                    shouldDownload = YES;
                }
                break;
            }
            default: {
                shouldDownload = YES;
                break;
            }
        }
    }


    NSString* containerVersion = [self containerVersion];
    if (shouldDownload && [containerVersion compare:minContainerVersion options:NSNumericSearch] != NSOrderedAscending) {
        shouldDownload = YES;
    }
    else {
        shouldDownload = NO;
    }

    return shouldDownload;
}

/**
 *
 */
- (void)checkUpdate {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.metadataUrl) {
            [self performUpdateCheck];
            [self setLastUpdateCheckPerformedOnDate: [NSDate date]];
        }
        else {
            NSLog(@"[DoctorStrangeUpdater]: Please make sure you have set the Update Metadata URL");
        }
    });
}

- (void)checkUpdateDaily {
    /*
     On app's first launch, lastVersionCheckPerformedOnDate isn't set.
     Avoid false-positive fulfilment of second condition in this method.
     Also, performs version check on first launch.
     */
    if (![self lastUpdateCheckPerformedOnDate]) {
        [self checkUpdate];
    }

    // If daily condition is satisfied, perform version check
    if ([self numberOfDaysElapsedBetweenLastVersionCheckDate] > 1) {
        [self checkUpdate];
    }
}

- (void)checkUpdateWeekly {
    /*
     On app's first launch, lastVersionCheckPerformedOnDate isn't set.
     Avoid false-positive fulfilment of second condition in this method.
     Also, performs version check on first launch.
     */
    if (![self lastUpdateCheckPerformedOnDate]) {
        [self checkUpdate];
    }

    // If weekly condition is satisfied, perform version check
    if ([self numberOfDaysElapsedBetweenLastVersionCheckDate] > 7) {
        [self checkUpdate];
    }
}

/**
 * 根据差分包生成新的bundle
 * build new bundle from patch and origin bundle
 */
- (BOOL)bsdiffPatch:(NSString *)patchPath
             origin:(NSString *)origin
        destination:(NSString *)destination
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:patchPath]) {
        if (self.showProgress) {
            [StatusBarNotification showWithMessage:NSLocalizedString(@"patch文件不存在.", nil)
                                   backgroundColor:[StatusBarNotification errorColor]
                                          autoHide:YES];
        }
        return NO;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:origin]) {
        if (self.showProgress) {
            [StatusBarNotification showWithMessage:NSLocalizedString(@"originfile not exist.", nil)
                                   backgroundColor:[StatusBarNotification errorColor]
                                          autoHide:YES];
        }
        return NO;
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:destination]) {
        [[NSFileManager defaultManager] removeItemAtPath:destination error:nil];
    }



    int err = beginPatch([origin UTF8String], [destination UTF8String], [patchPath UTF8String]);
    if (err) {
        return NO;
    }
    return YES;
}


#pragma mark - private




/**
 * 判断是否空字符串
 * blank string judge
 **/
- (BOOL) isBlankString:(NSString *)string {
    if (string == nil || string == NULL) {
        return YES;
    }
    if ([string isKindOfClass:[NSNull class]]) {
        return YES;
    }
    if ([[string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length]==0) {
        return YES;
    }
    return NO;
}

/**
 * 数字是否为空
 */
-(BOOL) isBlankNumber:(NSNumber *)number{
    if (number == nil || number == NULL) {
        return YES;
    }

    if ([number isKindOfClass:[NSNull class]]) {
        return YES;
    }

    id temp = number;

    if ([temp isKindOfClass:[NSNull class]]) {
        return YES;
    }

    return NO;
}

/**
 * @Author Jimmy
 * 相对路径根据参数下载文件
 * download bundle from relative path
 **/
- (void)startDownloadingUpdateFromVersion:(NSString*)version{


    NSString *normal = @"version=";
    //设置请求参数，将下载版本告知
    NSString *bodyStr = [normal stringByAppendingString:version];

    NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];

    NSString *idParamStr = [@"&bundleId=" stringByAppendingString:identifier];

    bodyStr = [bodyStr stringByAppendingString:idParamStr];
    NSURL *url = [NSURL URLWithString:self.hostname];

    NSMutableURLRequest *request =  [NSMutableURLRequest requestWithURL:url
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData //忽略缓存直接下载
                                                        timeoutInterval:10];//请求这个地址， timeoutInterval:10 设置为10s超时：请求时间超过10s会被认为连接不上，连接超时
    [request setHTTPMethod: @"POST"];//使用post传参

    [request setHTTPBody:[bodyStr dataUsingEncoding:NSUTF8StringEncoding]];



    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
    sessionConfig.allowsCellularAccess = self.allowCellularDataUse;
    sessionConfig.timeoutIntervalForRequest = 60.0;
    sessionConfig.timeoutIntervalForResource = 60.0;
    sessionConfig.HTTPMaximumConnectionsPerHost = 1;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfig
                                                          delegate:self
                                                     delegateQueue:nil];

    NSURLSessionDownloadTask* task = [session downloadTaskWithRequest:request];

    [task resume];
}

-(void)startDownloadingUpdateFromPatchId:(NSNumber*)patchId{
    NSLog(@"新版本PatchID %@", patchId);

    NSString *normal = @"patchId=";
    //设置请求参数，将下载版本告知
    NSNumberFormatter* numberFormatter = [[NSNumberFormatter alloc] init];
    NSString* versionStr = [numberFormatter stringFromNumber:patchId];
    NSString *bodyStr = [normal stringByAppendingString:versionStr];
    NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
    NSString *idParamStr = [@"&bundleId=" stringByAppendingString:identifier];
    bodyStr = [bodyStr stringByAppendingString:idParamStr];
    NSLog(@"请求参数 %@", bodyStr);

    NSURL *url = [NSURL URLWithString:self.hostname];
    NSLog(@"服务器地址 %@", url);

    NSMutableURLRequest *request =  [NSMutableURLRequest requestWithURL:url
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData //忽略缓存直接下载
                                                        timeoutInterval:10];//请求这个地址， timeoutInterval:10 设置为10s超时：请求时间超过10s会被认为连接不上，连接超时
    [request setHTTPMethod: @"POST"];//使用post传参

    [request setHTTPBody:[bodyStr dataUsingEncoding:NSUTF8StringEncoding]];



    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
    sessionConfig.allowsCellularAccess = self.allowCellularDataUse;
    sessionConfig.timeoutIntervalForRequest = 60.0;
    sessionConfig.timeoutIntervalForResource = 60.0;
    sessionConfig.HTTPMaximumConnectionsPerHost = 1;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfig
                                                          delegate:self
                                                     delegateQueue:nil];

    NSURLSessionDownloadTask* task = [session downloadTaskWithRequest:request];

    [task resume];

}

/**
 * @Author Jimmy
 * 绝对路径直接根据URL下载文件
 * download bundle from absolute path
 **/
- (void)startDownloadingUpdateFromURLAbsolutely:(NSString*)urlString{

    NSURL* url = [NSURL URLWithString:urlString];

    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
    sessionConfig.allowsCellularAccess = self.allowCellularDataUse;
    sessionConfig.timeoutIntervalForRequest = 60.0;
    sessionConfig.timeoutIntervalForResource = 60.0;
    sessionConfig.HTTPMaximumConnectionsPerHost = 1;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfig
                                                          delegate:self
                                                     delegateQueue:nil];

    NSURLSessionDownloadTask* task = [session downloadTaskWithURL:url];
    [task resume];
}


- (NSUInteger)numberOfDaysElapsedBetweenLastVersionCheckDate {
    NSCalendar *currentCalendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [currentCalendar components:NSCalendarUnitDay
                                                      fromDate:[self lastUpdateCheckPerformedOnDate]
                                                        toDate:[NSDate date]
                                                       options:0];
    return [components day];
}

- (NSDate*)lastUpdateCheckPerformedOnDate {
    return [[NSUserDefaults standardUserDefaults] objectForKey:DoctorStrangeUpdaterLastUpdateCheckDate];
}

- (void)setLastUpdateCheckPerformedOnDate: date {
    [[NSUserDefaults standardUserDefaults] setObject:date forKey:DoctorStrangeUpdaterLastUpdateCheckDate];
}

- (NSString*)containerVersion {
    return [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
}

- (NSString*)libraryDirectory {
    return [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
}

- (NSString*)createCodeDirectory {
    NSString* libraryDirectory = [self libraryDirectory];
    NSString *filePathAndDirectory = [libraryDirectory stringByAppendingPathComponent:@"JSCode"];
    NSError *error;

    NSFileManager* fileManager = [NSFileManager defaultManager];

    BOOL isDir;
    if ([fileManager fileExistsAtPath:filePathAndDirectory isDirectory:&isDir]) {
        if (isDir) {
            return filePathAndDirectory;
        }
    }

    if (![fileManager createDirectoryAtPath:filePathAndDirectory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&error])
    {
        NSLog(@"Create directory error: %@", error);
        return nil;
    }
    return filePathAndDirectory;
}

- (NSString*)createTempDirectory: (NSString*)fileName {
    NSString* libraryDirectory = [self libraryDirectory];
    NSString *filePathAndDirectory = [libraryDirectory stringByAppendingPathComponent: fileName];
    NSError *error;

    NSFileManager* fileManager = [NSFileManager defaultManager];

    BOOL isDir;
    if ([fileManager fileExistsAtPath:filePathAndDirectory isDirectory:&isDir]) {
        if (isDir) {
            return filePathAndDirectory;
        }
    }

    if (![fileManager createDirectoryAtPath:filePathAndDirectory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&error])
    {
        NSLog(@"Create directory error: %@", error);
        return nil;
    }
    return filePathAndDirectory;
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown) {
        if (self.showProgress) {
            [StatusBarNotification showWithMessage:[NSString stringWithFormat:NSLocalizedString(@"下载更新中 - %@", nil),
                                                    [NSByteCountFormatter stringFromByteCount:totalBytesWritten
                                                                                   countStyle:NSByteCountFormatterCountStyleFile]]
                                   backgroundColor:[StatusBarNotification infoColor]
                                          autoHide:NO];
        }
    }
    else {
        if (self.showProgress) {
            [StatusBarNotification showWithMessage:[NSString stringWithFormat:NSLocalizedString(@"下载更新中 - %d%%", nil), (int)(totalBytesWritten/totalBytesExpectedToWrite) * 100]
                                   backgroundColor:[StatusBarNotification infoColor]
                                          autoHide:NO];
        }
    }
}

-(void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    if (self.showProgress) {
        [StatusBarNotification showWithMessage:NSLocalizedString(@"下载完成.", nil)
                               backgroundColor:[StatusBarNotification successColor]
                                      autoHide:YES];
    }
    NSError* error;
    //从下载的临时文件中读取数据到NSDATA
    NSData* data = [NSData dataWithContentsOfURL:location];
    //判断NSData是否为空，避免出现下载失误造成空白文件的问题
    if (data) {
        //文件不为空则写入文件到原本的main.jsbundle中
        BOOL updateMetaData = NO;
        NSString* filename = [NSString stringWithFormat:@"%@/%@", [self createCodeDirectory], @"doctor.zip"];
        @try {
            if (self.downloadPatch == YES) {
                RCTLogInfo(@"downLoadPatch");
                if (self.showProgress) {
                    [StatusBarNotification showWithMessage:NSLocalizedString(@"更新差分包.", nil)
                                           backgroundColor:[StatusBarNotification successColor]
                                                  autoHide:YES];
                }
                NSString* patchFileTempName = [NSString stringWithFormat:@"%@/%@", [self createCodeDirectory], @"temp.patch"];
                NSString* tempFileName = [NSString stringWithFormat:@"%@/%@", [self createCodeDirectory], @"temp.zip"];
                if ([data writeToFile:patchFileTempName atomically:YES]) {

                    NSData* originData = [NSData dataWithContentsOfURL: [NSURL URLWithString:[NSString stringWithFormat:@"file://%@", filename]]];

                    if (originData && [originData writeToFile:tempFileName atomically:YES]) {
                        updateMetaData = [self bsdiffPatch: (NSString*)patchFileTempName origin:(NSString*)tempFileName destination:(NSString*)filename];
                    }
                }
            } else {
                RCTLogInfo(@"downLoadbundle");
                updateMetaData = [data writeToFile:filename atomically:YES];
            }
            if (updateMetaData == YES) {
                if (self.showProgress) {
                    [StatusBarNotification showWithMessage:NSLocalizedString(@"初始化完成,应用更新.", nil)
                                           backgroundColor:[StatusBarNotification successColor]
                                                  autoHide:YES];
                }

                if([SSZipArchive unzipFileAtPath:filename toDestination: [self createCodeDirectory]]){
                    NSString* bundleName = [NSString stringWithFormat:@"%@/%@", [self createCodeDirectory], @"doctor.jsbundle"];
                    if ([[NSFileManager defaultManager] fileExistsAtPath:bundleName]) {
                        //写入文件成功后更新文件版本信息
                        [[NSUserDefaults standardUserDefaults] setObject:self.updateMetadata forKey:DoctorStrangeUpdaterCurrentJSCodeMetadata];
                        //提示应用新版本
                        if ([self.delegate respondsToSelector:@selector(DoctorStrangeUpdater_updateDownloadedToURL:)]) {
                            [self.delegate DoctorStrangeUpdater_updateDownloadedToURL:[NSURL URLWithString:[NSString stringWithFormat:@"file://%@", bundleName]]];
                        }
                    }

                };
                self.downloadPatch = NO;
            }
            else {
                RCTLogInfo(@"[DoctorStrangeUpdater]: Update save failed - %@.", error.localizedDescription);
                //                NSLog(@"[DoctorStrangeUpdater]: Update save failed - %@.", error.localizedDescription);
            }

        } @catch (NSException *exception) {
            RCTLogInfo(@"[DoctorStrangeUpdater]: Update save failed - %@. - %@", exception.name, exception.reason);
            //            NSLog(@"[DoctorStrangeUpdater]: Update save failed - %@. - %@", exception.name, exception.reason);
        } @finally {

        }

    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        NSLog(@"[DoctorStrangeUpdater]: %@", error.localizedDescription);
    }
}

@end
