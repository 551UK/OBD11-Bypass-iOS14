#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <substrate.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <string.h>

extern void OBDInstallLoginDiagnostics(void);

static NSString *const kTargetBundle = @"com.voltasit.obdeleven.ios";
static NSString *const kTargetVersion = @"1.9.28";
static NSString *const kTargetBuild = @"1704712364";
static NSString *const kServerVersion = @"1.9.73";
static NSString *const kServerBuild = @"1785335496";
static NSString *const kPreferencesPath = @"/var/mobile/Library/Preferences/com.551.obdelevenupdatebypass.plist";

// OBDeleven VAG 1.9.28: final result of UpdateUtility.isForceUpdateNeeded(completion:).
// Preferred image address 0x100367F04 -> image-relative offset 0x00367F04.
static const uintptr_t kUpdateResultOffset = 0x00367F04;
static const uint8_t kExpectedInstruction[4] = {0xE0, 0xA7, 0x9F, 0x1A}; // cset w0, lt
static const uint8_t kNoUpdateInstruction[4] = {0x00, 0x00, 0x80, 0x52}; // mov w0, #0

static BOOL tweakEnabled(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPreferencesPath];
    id value = prefs[@"vagEnabled"];
    return value ? [value boolValue] : YES;
}

static BOOL isParseHost(NSString *host) {
    return [host caseInsensitiveCompare:@"server1.obdeleven.com"] == NSOrderedSame;
}

static BOOL isRestHost(NSString *host) {
    return [host caseInsensitiveCompare:@"api.obdeleven.com"] == NSOrderedSame;
}

NSURLRequest *OBDRequestBySpoofingServerIdentity(NSURLRequest *request) {
    if (!request) return request;

    NSString *host = request.URL.host ?: @"";
    BOOL parseHost = isParseHost(host);
    BOOL restHost = isRestHost(host);
    if (!parseHost && !restHost) return request;

    NSMutableURLRequest *mutable = [request mutableCopy];

    // RestApi.ParseAuthClient sends its password-verification request to
    // server1.obdeleven.com, so both OBDeleven mobile headers must be present on
    // that host too (not only api.obdeleven.com).
    [mutable setValue:kServerVersion forHTTPHeaderField:@"x-mobile-app-version"];
    [mutable setValue:kServerBuild forHTTPHeaderField:@"x-mobile-app-build"];

    // Parse/PFUser login also runs on server1 and uses Parse's app version keys.
    if (parseHost) {
        [mutable setValue:kServerVersion forHTTPHeaderField:@"X-Parse-App-Display-Version"];
        [mutable setValue:kServerBuild forHTTPHeaderField:@"X-Parse-App-Build-Version"];
    }

    // Keep the real device/iOS identity but replace the old app version/build if present.
    NSString *userAgent = [mutable valueForHTTPHeaderField:@"User-Agent"];
    if (userAgent.length > 0) {
        NSString *spoofed = [userAgent stringByReplacingOccurrencesOfString:kTargetVersion
                                                                 withString:kServerVersion];
        spoofed = [spoofed stringByReplacingOccurrencesOfString:kTargetBuild
                                                     withString:kServerBuild];
        [mutable setValue:spoofed forHTTPHeaderField:@"User-Agent"];
    }

    return mutable;
}

typedef NSURLSessionDataTask *(*DataTaskRequestCompletionIMP)(
    NSURLSession *, SEL, NSURLRequest *,
    void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionDataTask *(*DataTaskRequestIMP)(NSURLSession *, SEL, NSURLRequest *);
typedef NSURLSessionUploadTask *(*UploadTaskDataCompletionIMP)(
    NSURLSession *, SEL, NSURLRequest *, NSData *,
    void (^)(NSData *, NSURLResponse *, NSError *));

static DataTaskRequestCompletionIMP originalDataTaskRequestCompletion = NULL;
static DataTaskRequestIMP originalDataTaskRequest = NULL;
static UploadTaskDataCompletionIMP originalUploadTaskDataCompletion = NULL;

static NSURLSessionDataTask *spoofedDataTaskRequestCompletion(
    NSURLSession *self,
    SEL _cmd,
    NSURLRequest *request,
    void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    return originalDataTaskRequestCompletion(
        self, _cmd, OBDRequestBySpoofingServerIdentity(request), completion);
}

static NSURLSessionDataTask *spoofedDataTaskRequest(
    NSURLSession *self,
    SEL _cmd,
    NSURLRequest *request) {
    return originalDataTaskRequest(self, _cmd, OBDRequestBySpoofingServerIdentity(request));
}

static NSURLSessionUploadTask *spoofedUploadTaskDataCompletion(
    NSURLSession *self,
    SEL _cmd,
    NSURLRequest *request,
    NSData *bodyData,
    void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    return originalUploadTaskDataCompletion(
        self, _cmd, OBDRequestBySpoofingServerIdentity(request), bodyData, completion);
}

// Alamofire on iOS 14 creates tasks on NSURLSession's concrete class. Hooking
// NSURLSession itself is retained, but these hooks cover the class-cluster path
// used by RestApi.ParseAuthClient as well.
static DataTaskRequestCompletionIMP originalConcreteDataTaskRequestCompletion = NULL;
static DataTaskRequestIMP originalConcreteDataTaskRequest = NULL;
static UploadTaskDataCompletionIMP originalConcreteUploadTaskDataCompletion = NULL;

static NSURLSessionDataTask *spoofedConcreteDataTaskRequestCompletion(
    NSURLSession *self,
    SEL _cmd,
    NSURLRequest *request,
    void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    return originalConcreteDataTaskRequestCompletion(
        self, _cmd, OBDRequestBySpoofingServerIdentity(request), completion);
}

static NSURLSessionDataTask *spoofedConcreteDataTaskRequest(
    NSURLSession *self,
    SEL _cmd,
    NSURLRequest *request) {
    return originalConcreteDataTaskRequest(
        self, _cmd, OBDRequestBySpoofingServerIdentity(request));
}

static NSURLSessionUploadTask *spoofedConcreteUploadTaskDataCompletion(
    NSURLSession *self,
    SEL _cmd,
    NSURLRequest *request,
    NSData *bodyData,
    void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    return originalConcreteUploadTaskDataCompletion(
        self, _cmd, OBDRequestBySpoofingServerIdentity(request), bodyData, completion);
}

static BOOL classHasSelector(Class cls, SEL selector) {
    return cls && class_getInstanceMethod(cls, selector) != NULL;
}

static void installNetworkSpoofs(void) {
    Class sessionClass = [NSURLSession class];

    MSHookMessageEx(sessionClass,
                    @selector(dataTaskWithRequest:completionHandler:),
                    (IMP)spoofedDataTaskRequestCompletion,
                    (IMP *)&originalDataTaskRequestCompletion);

    MSHookMessageEx(sessionClass,
                    @selector(dataTaskWithRequest:),
                    (IMP)spoofedDataTaskRequest,
                    (IMP *)&originalDataTaskRequest);

    MSHookMessageEx(sessionClass,
                    @selector(uploadTaskWithRequest:fromData:completionHandler:),
                    (IMP)spoofedUploadTaskDataCompletion,
                    (IMP *)&originalUploadTaskDataCompletion);

    NSURLSession *probe = [NSURLSession sessionWithConfiguration:
                           [NSURLSessionConfiguration ephemeralSessionConfiguration]];
    Class concreteClass = [probe class];
    if (concreteClass && concreteClass != sessionClass) {
        if (classHasSelector(concreteClass, @selector(dataTaskWithRequest:completionHandler:))) {
            MSHookMessageEx(concreteClass,
                            @selector(dataTaskWithRequest:completionHandler:),
                            (IMP)spoofedConcreteDataTaskRequestCompletion,
                            (IMP *)&originalConcreteDataTaskRequestCompletion);
        }
        if (classHasSelector(concreteClass, @selector(dataTaskWithRequest:))) {
            MSHookMessageEx(concreteClass,
                            @selector(dataTaskWithRequest:),
                            (IMP)spoofedConcreteDataTaskRequest,
                            (IMP *)&originalConcreteDataTaskRequest);
        }
        if (classHasSelector(concreteClass, @selector(uploadTaskWithRequest:fromData:completionHandler:))) {
            MSHookMessageEx(concreteClass,
                            @selector(uploadTaskWithRequest:fromData:completionHandler:),
                            (IMP)spoofedConcreteUploadTaskDataCompletion,
                            (IMP *)&originalConcreteUploadTaskDataCompletion);
        }
        NSLog(@"[OBD11VAG-iOS14] Concrete NSURLSession hook class: %@", NSStringFromClass(concreteClass));
    }
    [probe invalidateAndCancel];
}

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        if (![[bundle bundleIdentifier] isEqualToString:kTargetBundle]) return;
        if (!tweakEnabled()) return;

        NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        if (![version isEqualToString:kTargetVersion] || ![build isEqualToString:kTargetBuild]) {
            NSLog(@"[OBD11VAG-iOS14] Unsupported VAG build %@ (%@); no patch applied", version, build);
            return;
        }

        const struct mach_header *header = _dyld_get_image_header(0);
        if (!header) return;

        uint8_t *target = (uint8_t *)header + kUpdateResultOffset;
        if (memcmp(target, kExpectedInstruction, sizeof(kExpectedInstruction)) != 0) {
            NSLog(@"[OBD11VAG-iOS14] 1.9.28 force-update bytes did not match; no patch applied");
            return;
        }

        MSHookMemory(target, kNoUpdateInstruction, sizeof(kNoUpdateInstruction));
        installNetworkSpoofs();
        OBDInstallLoginDiagnostics();

        NSLog(@"[OBD11VAG-iOS14] 1.9.28 patched; Parse/RestApi identity %@ (%@)",
              kServerVersion, kServerBuild);
    }
}
