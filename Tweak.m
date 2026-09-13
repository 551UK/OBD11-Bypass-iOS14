#import <Foundation/Foundation.h>
#include <substrate.h>

static NSString *const kTargetBundle = @"com.voltasit.obdeleven.ios";
static NSString *const kBuildValue = @"2147483647";
static NSString *const kVersionValue = @"1.9.99";
static NSBundle *gMainBundle = nil;

typedef id (*ObjectForInfoKeyIMP)(NSBundle *, SEL, NSString *);
static ObjectForInfoKeyIMP originalObjectForInfoKey = NULL;

static id replacementObjectForInfoKey(NSBundle *self, SEL _cmd, NSString *key) {
    if (self == gMainBundle) {
        if ([key isEqualToString:@"CFBundleVersion"]) return kBuildValue;
        if ([key isEqualToString:@"CFBundleShortVersionString"]) return kVersionValue;
    }
    return originalObjectForInfoKey(self, _cmd, key);
}

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        if (![[bundle bundleIdentifier] isEqualToString:kTargetBundle]) return;
        gMainBundle = bundle;

        MSHookMessageEx([NSBundle class],
                        @selector(objectForInfoDictionaryKey:),
                        (IMP)replacementObjectForInfoKey,
                        (IMP *)&originalObjectForInfoKey);

        NSLog(@"[OBD11VAG-iOS14] compatibility build loaded");
    }
}
