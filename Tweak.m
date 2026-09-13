#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <substrate.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <string.h>

extern void OBDInstallLoginCompatibility(void);

static NSString *const kTargetBundle = @"com.voltasit.obdeleven.ios";
static NSString *const kTargetVersion = @"1.9.28";
static NSString *const kTargetBuild = @"1704712364";
static NSString *const kServerVersion = @"1.9.73";
static NSString *const kServerBuild = @"1785335496";
static NSString *const kLegacyParseHost = @"server1.obdeleven.com";
static NSString *const kCurrentParseHost = @"parse.obdeleven.com";
static NSString *const kRestHost = @"api.obdeleven.com";
static NSString *const kPreferencesPath = @"/var/mobile/Library/Preferences/com.551.obdelevenupdatebypass.plist";

static const uintptr_t kUpdateResultOffset = 0x00367F04;
static const uint8_t kExpectedInstruction[4] = {0xE0, 0xA7, 0x9F, 0x1A};
static const uint8_t kNoUpdateInstruction[4] = {0x00, 0x00, 0x80, 0x52};

static BOOL tweakEnabled(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPreferencesPath];
    id value = prefs[@"vagEnabled"];
    return value ? [value boolValue] : YES;
}

static BOOL isLegacyParseHost(NSString *host) {
    return [host caseInsensitiveCompare:kLegacyParseHost] == NSOrderedSame;
}

static BOOL isParseHost(NSString *host) {
    return isLegacyParseHost(host) ||
           [host caseInsensitiveCompare:kCurrentParseHost] == NSOrderedSame;
}

static BOOL isRestHost(NSString *host) {
    return [host caseInsensitiveCompare:kRestHost] == NSOrderedSame;
}

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
    Class cls = [NSBundle class];
    MSHookMessageEx(cls,
                    @selector(objectForInfoDictionaryKey:),
                    (IMP)spoofedBundleObjectForInfoKey,
                    (IMP *)&originalBundleObjectForInfoKey);
    MSHookMessageEx(cls,
                    @selector(infoDictionary),
                    (IMP)spoofedBundleInfoDictionary,
                    (IMP *)&originalBundleInfoDictionary);
}

NSURLRequest *OBDRequestBySpoofingServerIdentity(NSURLRequest *request) {
    if (!request) return request;

    NSString *host = request.URL.host ?: @"";
    BOOL parseHost = isParseHost(host);
    BOOL restHost = isRestHost(host);
    if (!parseHost && !restHost) return request;

    NSMutableURLRequest *mutable = [request mutableCopy];

    if (isLegacyParseHost(host)) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:mutable.URL
                                                  resolvingAgainstBaseURL:NO];
        components.host = kCurrentParseHost;
        if (components.URL) mutable.URL = components.URL;
    }

    [mutable setValue:kServerVersion forHTTPHeaderField:@"x-mobile-app-version"];
    [mutable setValue:kServerBuild forHTTPHeaderField:@"x-mobile-app-build"];

    if (parseHost) {
        [mutable setValue:kServerVersion forHTTPHeaderField:@"X-Parse-App-Display-Version"];
        [mutable setValue:kServerBuild forHTTPHeaderField:@"X-Parse-App-Build-Version"];
    }

    NSString *userAgent = [mutable valueForHTTPHeaderField:@"User-Agent"];
    if (userAgent.length) {
        NSString *spoofed = [userAgent stringByReplacingOccurrencesOfString:kTargetVersion
                                                                 withString:kServerVersion];
        spoofed = [spoofed stringByReplacingOccurrencesOfString:kTargetBuild
                                                     withString:kServerBuild];
        [mutable setValue:spoofed forHTTPHeaderField:@"User-Agent"];
    }

    return mutable;
}

typedef NSURLSessionDataTask *(*DataTaskRequestCompletionIMP)(
    NSURLSession *, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionDataTask *(*DataTaskRequestIMP)(NSURLSession *, SEL, NSURLRequest *);
typedef NSURLSessionUploadTask *(*UploadTaskDataCompletionIMP)(
    NSURLSession *, SEL, NSURLRequest *, NSData *, void (^)(NSData *, NSURLResponse *, NSError *));

static DataTaskRequestCompletionIMP originalDataTaskRequestCompletion;
static DataTaskRequestIMP originalDataTaskRequest;
static UploadTaskDataCompletionIMP originalUploadTaskDataCompletion;

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

static DataTaskRequestCompletionIMP originalConcreteDataTaskRequestCompletion;
static DataTaskRequestIMP originalConcreteDataTaskRequest;
static UploadTaskDataCompletionIMP originalConcreteUploadTaskDataCompletion;

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
        if (![version isEqualToString:kTargetVersion] || ![build isEqualToString:kTargetBuild]) return;

        const struct mach_header *header = _dyld_get_image_header(0);
        if (!header) return;

        uint8_t *target = (uint8_t *)header + kUpdateResultOffset;
        if (memcmp(target, kExpectedInstruction, sizeof(kExpectedInstruction)) != 0) return;

        MSHookMemory(target, kNoUpdateInstruction, sizeof(kNoUpdateInstruction));
        installParseConfigSpoof();
        installNetworkSpoofs();
        OBDInstallLoginCompatibility();
    }
}
