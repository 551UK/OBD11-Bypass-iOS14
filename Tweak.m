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
static NSString *const kLegacyParseHost = @"server1.obdeleven.com";
static NSString *const kCurrentParseHost = @"parse.obdeleven.com";
static NSString *const kRestHost = @"api.obdeleven.com";
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

static BOOL isLegacyParseHost(NSString *host) {
    return [host caseInsensitiveCompare:kLegacyParseHost] == NSOrderedSame;
}

static BOOL isParseHost(NSString *host) {
    return isLegacyParseHost(host) || [host caseInsensitiveCompare:kCurrentParseHost] == NSOrderedSame;
}

static BOOL isRestHost(NSString *host) {
    return [host caseInsensitiveCompare:kRestHost] == NSOrderedSame;
}

#pragma mark - Parse config migration

// Static comparison of the supplied 1.9.28 and 1.9.73 IPAs shows that
// PARSE_API_URL moved from server1.obdeleven.com to parse.obdeleven.com.
// Return the current official host to app code that reads Info.plist at runtime.
static id (*originalBundleObjectForInfoKey)(NSBundle *, SEL, NSString *);
static id spoofedBundleObjectForInfoKey(NSBundle *self, SEL cmd, NSString *key) {
    if (self == [NSBundle mainBundle] && [key isEqualToString:@"PARSE_API_URL"])
        return kCurrentParseHost;
    return originalBundleObjectForInfoKey(self, cmd, key);
}

static NSDictionary *(*originalBundleInfoDictionary)(NSBundle *, SEL);
static NSDictionary *spoofedBundleInfoDictionary(NSBundle *self, SEL cmd) {
    NSDictionary *original = originalBundleInfoDictionary(self, cmd);
    if (self != [NSBundle mainBundle] || !original) return original;
    NSMutableDictionary *copy = [original mutableCopy];
    copy[@"PARSE_API_URL"] = kCurrentParseHost;
    return copy;
}

static void installParseConfigSpoof(void) {
    Class bundleClass = [NSBundle class];
    MSHookMessageEx(bundleClass,
                    @selector(objectForInfoDictionaryKey:),
                    (IMP)spoofedBundleObjectForInfoKey,
                    (IMP *)&originalBundleObjectForInfoKey);
    MSHookMessageEx(bundleClass,
                    @selector(infoDictionary),
                    (IMP)spoofedBundleInfoDictionary,
                    (IMP *)&originalBundleInfoDictionary);
}

#pragma mark - Request migration / version headers

NSURLRequest *OBDRequestBySpoofingServerIdentity(NSURLRequest *request) {
    if (!request) return request;

    NSString *originalHost = request.URL.host ?: @"";
    BOOL parseHost = isParseHost(originalHost);
    BOOL restHost = isRestHost(originalHost);
    if (!parseHost && !restHost) return request;

    NSMutableURLRequest *mutable = [request mutableCopy];

    // Old VAG hard-codes the retired Parse hostname. Move requests to the same
    // Parse hostname shipped by VAG 1.9.73 while preserving path/query/method/body.
    if (isLegacyParseHost(originalHost)) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:mutable.URL
                                                  resolvingAgainstBaseURL:NO];
        components.host = kCurrentParseHost;
        NSURL *migratedURL = components.URL;
        if (migratedURL) mutable.URL = migratedURL;
    }

    // RestApi.ParseAuthClient and the REST API identify the mobile client with
    // these headers. Apply them on both Parse hosts and api.obdeleven.com.
    [mutable setValue:kServerVersion forHTTPHeaderField:@"x-mobile-app-version"];
    [mutable setValue:kServerBuild forHTTPHeaderField:@"x-mobile-app-build"];

    if (parseHost) {
        [mutable setValue:kServerVersion forHTTPHeaderField:@"X-Parse-App-Display-Version"];
        [mutable setValue:kServerBuild forHTTPHeaderField:@"X-Parse-App-Build-Version"];
    }

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
    NSURLSession *self, SEL cmd, NSURLRequest *request,
    void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    return originalDataTaskRequestCompletion(
        self, cmd, OBDRequestBySpoofingServerIdentity(request), completion);
}

static NSURLSessionDataTask *spoofedDataTaskRequest(
    NSURLSession *self, SEL cmd, NSURLRequest *request) {
    return originalDataTaskRequest(self, cmd, OBDRequestBySpoofingServerIdentity(request));
}

static NSURLSessionUploadTask *spoofedUploadTaskDataCompletion(
    NSURLSession *self, SEL cmd, NSURLRequest *request, NSData *bodyData,
    void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    return originalUploadTaskDataCompletion(
        self, cmd, OBDRequestBySpoofingServerIdentity(request), bodyData, completion);
}

// Alamofire on iOS 14 creates tasks on NSURLSession's concrete class. Hooking
// NSURLSession itself is retained, but these hooks cover that class-cluster path.
static DataTaskRequestCompletionIMP originalConcreteDataTaskRequestCompletion = NULL;
static DataTaskRequestIMP originalConcreteDataTaskRequest = NULL;
static UploadTaskDataCompletionIMP originalConcreteUploadTaskDataCompletion = NULL;

static NSURLSessionDataTask *spoofedConcreteDataTaskRequestCompletion(
    NSURLSession *self, SEL cmd, NSURLRequest *request,
    void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    return originalConcreteDataTaskRequestCompletion(
        self, cmd, OBDRequestBySpoofingServerIdentity(request), completion);
}

static NSURLSessionDataTask *spoofedConcreteDataTaskRequest(
    NSURLSession *self, SEL cmd, NSURLRequest *request) {
    return originalConcreteDataTaskRequest(
        self, cmd, OBDRequestBySpoofingServerIdentity(request));
}

static NSURLSessionUploadTask *spoofedConcreteUploadTaskDataCompletion(
    NSURLSession *self, SEL cmd, NSURLRequest *request, NSData *bodyData,
    void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    return originalConcreteUploadTaskDataCompletion(
        self, cmd, OBDRequestBySpoofingServerIdentity(request), bodyData, completion);
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

        // Read the real bundle version before installing any bundle hooks.
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
        installParseConfigSpoof();
        installNetworkSpoofs();
        OBDInstallLoginDiagnostics();

        NSLog(@"[OBD11VAG-iOS14] 1.9.28 patched; Parse %@ -> %@; identity %@ (%@)",
              kLegacyParseHost, kCurrentParseHost, kServerVersion, kServerBuild);
    }
}
