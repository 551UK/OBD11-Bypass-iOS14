#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <substrate.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <string.h>

extern void OBDInstallLoginCompatibility(void);

typedef NS_ENUM(NSInteger, OBDTargetKind) {
    OBDTargetNone = 0,
    OBDTargetVAG,
    OBDTargetMain
};

static NSString *const kVAGBundle = @"com.voltasit.obdeleven.ios";
static NSString *const kVAGTargetVersion = @"1.9.28";
static NSString *const kVAGTargetBuild = @"1704712364";
static NSString *const kVAGDefaultSpoofedVersion = @"1.9.73";
static NSString *const kVAGDefaultSpoofedBuild = @"1785335496";

static NSString *const kMainBundle = @"com.voltasit.obdeleven.ios.basic";
static NSString *const kMainTargetVersion = @"1.2.1";
static NSString *const kMainTargetBuild = @"12103";
static NSString *const kMainDefaultSpoofedVersion = @"2.11.0";
static NSString *const kMainDefaultSpoofedBuild = @"2147483647";

static NSString *const kLegacyParseHost = @"server1.obdeleven.com";
static NSString *const kCurrentParseHost = @"parse.obdeleven.com";
static NSString *const kRestHost = @"api.obdeleven.com";
static NSString *const kPreferencesPath = @"/var/mobile/Library/Preferences/com.551.obdelevenupdatebypass.plist";
static CFStringRef const kPreferencesChangedNotification = CFSTR("com.551.obdelevenupdatebypass/preferences.changed");

// Exact VAG 1.9.28 force-update result patch. The main/BMW 1.2.1 app uses
// its bundle/app version for the update decision, so its update bypass is the
// bundle identity spoof below rather than a hard-coded binary patch.
static const uintptr_t kVAGUpdateResultOffset = 0x00367F04;
static const uint8_t kVAGExpectedInstruction[4] = {0xE0, 0xA7, 0x9F, 0x1A};
static const uint8_t kVAGNoUpdateInstruction[4] = {0x00, 0x00, 0x80, 0x52};

static OBDTargetKind gTarget = OBDTargetNone;
static BOOL gEnabled = YES;
static NSString *gSpoofedVersion;
static NSString *gSpoofedBuild;
static NSString *gRealVersion;
static NSString *gRealBuild;
static NSBundle *gMainBundleObject;

static NSString *targetVersion(void) {
    return gTarget == OBDTargetVAG ? kVAGTargetVersion : kMainTargetVersion;
}

static NSString *targetBuild(void) {
    return gTarget == OBDTargetVAG ? kVAGTargetBuild : kMainTargetBuild;
}

static NSString *defaultSpoofedVersion(void) {
    return gTarget == OBDTargetVAG ? kVAGDefaultSpoofedVersion : kMainDefaultSpoofedVersion;
}

static NSString *defaultSpoofedBuild(void) {
    return gTarget == OBDTargetVAG ? kVAGDefaultSpoofedBuild : kMainDefaultSpoofedBuild;
}

static NSString *enabledPreferenceKey(void) {
    return gTarget == OBDTargetVAG ? @"vagEnabled" : @"enabled";
}

static NSString *versionPreferenceKey(void) {
    return gTarget == OBDTargetVAG ? @"vagSpoofedVersion" : @"spoofedVersion";
}

static NSString *buildPreferenceKey(void) {
    return gTarget == OBDTargetVAG ? @"vagSpoofedBuild" : @"spoofedBuild";
}

static BOOL validValue(NSString *value, BOOL allowDots) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0 || value.length > 64) return NO;
    NSCharacterSet *allowed = allowDots
        ? [NSCharacterSet characterSetWithCharactersInString:@"0123456789."]
        : [NSCharacterSet decimalDigitCharacterSet];
    return [value rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound;
}

static void loadPreferences(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPreferencesPath] ?: @{};
    id enabled = prefs[enabledPreferenceKey()];
    NSString *version = prefs[versionPreferenceKey()];
    NSString *build = prefs[buildPreferenceKey()];

    @synchronized ([NSBundle class]) {
        gEnabled = enabled ? [enabled boolValue] : YES;
        gSpoofedVersion = validValue(version, YES) ? [version copy] : defaultSpoofedVersion();
        gSpoofedBuild = validValue(build, NO) ? [build copy] : defaultSpoofedBuild();
    }
}

static void preferencesChanged(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object,
                               CFDictionaryRef userInfo) {
    loadPreferences();
}

static NSString *spoofedVersion(void) {
    @synchronized ([NSBundle class]) { return gSpoofedVersion ?: defaultSpoofedVersion(); }
}

static NSString *spoofedBuild(void) {
    @synchronized ([NSBundle class]) { return gSpoofedBuild ?: defaultSpoofedBuild(); }
}

static BOOL tweakEnabled(void) {
    @synchronized ([NSBundle class]) { return gEnabled; }
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

#pragma mark - Bundle identity / Parse config

static id (*originalBundleObjectForInfoKey)(NSBundle *, SEL, NSString *);
static id spoofedBundleObjectForInfoKey(NSBundle *self, SEL cmd, NSString *key) {
    if (self == gMainBundleObject && tweakEnabled()) {
        if ([key isEqualToString:@"CFBundleShortVersionString"]) return spoofedVersion();
        if ([key isEqualToString:@"CFBundleVersion"]) return spoofedBuild();
        if ([key isEqualToString:@"PARSE_API_URL"]) return kCurrentParseHost;
    }
    return originalBundleObjectForInfoKey(self, cmd, key);
}

static NSDictionary *(*originalBundleInfoDictionary)(NSBundle *, SEL);
static NSDictionary *spoofedBundleInfoDictionary(NSBundle *self, SEL cmd) {
    NSDictionary *original = originalBundleInfoDictionary(self, cmd);
    if (self != gMainBundleObject || !original || !tweakEnabled()) return original;

    NSMutableDictionary *copy = [original mutableCopy];
    copy[@"CFBundleShortVersionString"] = spoofedVersion();
    copy[@"CFBundleVersion"] = spoofedBuild();
    copy[@"PARSE_API_URL"] = kCurrentParseHost;
    return copy;
}

static CFTypeRef (*originalCFBundleGetValueForInfoDictionaryKey)(CFBundleRef, CFStringRef);
static CFTypeRef spoofedCFBundleGetValueForInfoDictionaryKey(CFBundleRef bundle, CFStringRef key) {
    if (bundle == CFBundleGetMainBundle() && tweakEnabled() && key) {
        if (CFEqual(key, CFSTR("CFBundleShortVersionString")))
            return (__bridge CFTypeRef)spoofedVersion();
        if (CFEqual(key, CFSTR("CFBundleVersion")))
            return (__bridge CFTypeRef)spoofedBuild();
        if (CFEqual(key, CFSTR("PARSE_API_URL")))
            return (__bridge CFTypeRef)kCurrentParseHost;
    }
    return originalCFBundleGetValueForInfoDictionaryKey(bundle, key);
}

static void installBundleSpoofs(void) {
    Class cls = [NSBundle class];
    MSHookMessageEx(cls,
                    @selector(objectForInfoDictionaryKey:),
                    (IMP)spoofedBundleObjectForInfoKey,
                    (IMP *)&originalBundleObjectForInfoKey);
    MSHookMessageEx(cls,
                    @selector(infoDictionary),
                    (IMP)spoofedBundleInfoDictionary,
                    (IMP *)&originalBundleInfoDictionary);
    MSHookFunction((void *)CFBundleGetValueForInfoDictionaryKey,
                   (void *)spoofedCFBundleGetValueForInfoDictionaryKey,
                   (void **)&originalCFBundleGetValueForInfoDictionaryKey);
}

#pragma mark - Network identity / Parse migration

NSURLRequest *OBDRequestBySpoofingServerIdentity(NSURLRequest *request) {
    if (!request || !tweakEnabled()) return request;

    NSString *host = request.URL.host ?: @"";
    BOOL parseHost = isParseHost(host);
    BOOL restHost = isRestHost(host);
    if (!parseHost && !restHost) return request;

    NSString *version = spoofedVersion();
    NSString *build = spoofedBuild();
    NSMutableURLRequest *mutable = [request mutableCopy];

    if (isLegacyParseHost(host)) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:mutable.URL
                                                  resolvingAgainstBaseURL:NO];
        components.host = kCurrentParseHost;
        if (components.URL) mutable.URL = components.URL;
    }

    [mutable setValue:version forHTTPHeaderField:@"x-mobile-app-version"];
    [mutable setValue:build forHTTPHeaderField:@"x-mobile-app-build"];

    if (parseHost) {
        [mutable setValue:version forHTTPHeaderField:@"X-Parse-App-Display-Version"];
        [mutable setValue:build forHTTPHeaderField:@"X-Parse-App-Build-Version"];
    }

    NSString *userAgent = [mutable valueForHTTPHeaderField:@"User-Agent"];
    if (userAgent.length) {
        if (gRealVersion.length) {
            userAgent = [userAgent stringByReplacingOccurrencesOfString:gRealVersion
                                                              withString:version];
        }
        if (gRealBuild.length) {
            userAgent = [userAgent stringByReplacingOccurrencesOfString:gRealBuild
                                                              withString:build];
        }
        [mutable setValue:userAgent forHTTPHeaderField:@"User-Agent"];
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

static void installVAGForceUpdatePatch(void) {
    if (gTarget != OBDTargetVAG || !tweakEnabled()) return;

    const struct mach_header *header = _dyld_get_image_header(0);
    if (!header) return;

    uint8_t *target = (uint8_t *)header + kVAGUpdateResultOffset;
    if (memcmp(target, kVAGExpectedInstruction, sizeof(kVAGExpectedInstruction)) != 0) {
        NSLog(@"[OBDelevenUpdateBypass] VAG force-update patch bytes did not match; continuing with identity spoofing");
        return;
    }

    MSHookMemory(target, kVAGNoUpdateInstruction, sizeof(kVAGNoUpdateInstruction));
}

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        gMainBundleObject = [NSBundle mainBundle];
        NSString *bundleID = [gMainBundleObject bundleIdentifier];

        if ([bundleID isEqualToString:kVAGBundle]) {
            gTarget = OBDTargetVAG;
        } else if ([bundleID isEqualToString:kMainBundle]) {
            gTarget = OBDTargetMain;
        } else {
            return;
        }

        gRealVersion = [[gMainBundleObject objectForInfoDictionaryKey:@"CFBundleShortVersionString"] copy];
        gRealBuild = [[gMainBundleObject objectForInfoDictionaryKey:@"CFBundleVersion"] copy];

        if (![gRealVersion isEqualToString:targetVersion()] ||
            ![gRealBuild isEqualToString:targetBuild()]) {
            NSLog(@"[OBDelevenUpdateBypass] Unsupported %@ build %@ (%@)", bundleID, gRealVersion, gRealBuild);
            return;
        }

        loadPreferences();
        installBundleSpoofs();
        installNetworkSpoofs();
        OBDInstallLoginCompatibility();
        installVAGForceUpdatePatch();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        preferencesChanged,
                                        kPreferencesChangedNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        NSLog(@"[OBDelevenUpdateBypass] loaded target=%@ real=%@/%@ spoof=%@/%@ enabled=%d parse=%@",
              gTarget == OBDTargetVAG ? @"VAG" : @"OBDeleven/BMW",
              gRealVersion,
              gRealBuild,
              spoofedVersion(),
              spoofedBuild(),
              tweakEnabled(),
              kCurrentParseHost);
    }
}
