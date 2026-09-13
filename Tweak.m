#import <Foundation/Foundation.h>
#include <substrate.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <string.h>

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

static NSURLRequest *requestBySpoofingServerIdentity(NSURLRequest *request) {
    if (!request) return request;

    NSMutableURLRequest *mutable = [request mutableCopy];
    [mutable setValue:kServerVersion forHTTPHeaderField:@"x-mobile-app-version"];
    [mutable setValue:kServerBuild forHTTPHeaderField:@"x-mobile-app-build"];

    // Older VAG builds also expose their app version/build through the User-Agent.
    // Rewrite only those two known values and leave device/OS identity unchanged.
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
static DataTaskRequestCompletionIMP originalDataTaskRequestCompletion = NULL;

static NSURLSessionDataTask *spoofedDataTaskRequestCompletion(
    NSURLSession *self,
    SEL _cmd,
    NSURLRequest *request,
    void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    return originalDataTaskRequestCompletion(
        self, _cmd, requestBySpoofingServerIdentity(request), completion);
}

typedef NSURLSessionDataTask *(*DataTaskRequestIMP)(NSURLSession *, SEL, NSURLRequest *);
static DataTaskRequestIMP originalDataTaskRequest = NULL;

static NSURLSessionDataTask *spoofedDataTaskRequest(
    NSURLSession *self,
    SEL _cmd,
    NSURLRequest *request) {
    return originalDataTaskRequest(self, _cmd, requestBySpoofingServerIdentity(request));
}

typedef NSURLSessionUploadTask *(*UploadTaskDataCompletionIMP)(
    NSURLSession *, SEL, NSURLRequest *, NSData *,
    void (^)(NSData *, NSURLResponse *, NSError *));
static UploadTaskDataCompletionIMP originalUploadTaskDataCompletion = NULL;

static NSURLSessionUploadTask *spoofedUploadTaskDataCompletion(
    NSURLSession *self,
    SEL _cmd,
    NSURLRequest *request,
    NSData *bodyData,
    void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    return originalUploadTaskDataCompletion(
        self, _cmd, requestBySpoofingServerIdentity(request), bodyData, completion);
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

        NSLog(@"[OBD11VAG-iOS14] 1.9.28 patched; server identity %@ (%@)",
              kServerVersion, kServerBuild);
    }
}
