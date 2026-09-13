#import <Foundation/Foundation.h>
#include <substrate.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <string.h>

static NSString *const kTargetBundle = @"com.voltasit.obdeleven.ios";
static NSString *const kTargetVersion = @"1.9.28";
static NSString *const kTargetBuild = @"1704712364";
static NSString *const kPreferencesPath = @"/var/mobile/Library/Preferences/com.551.obdelevenupdatebypass.plist";

// OBDeleven VAG 1.9.28: final boolean returned by AppVersionUtility.isAppUpdateAvailable().
// Preferred image address 0x1003D0A1C -> image-relative offset 0x003D0A1C.
static const uintptr_t kUpdateResultOffset = 0x003D0A1C;
static const uint8_t kExpectedInstruction[4] = {0x80, 0x02, 0x00, 0x12}; // and w0, w20, #1
static const uint8_t kNoUpdateInstruction[4] = {0x00, 0x00, 0x80, 0x52}; // mov w0, #0

static BOOL tweakEnabled(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPreferencesPath];
    id value = prefs[@"vagEnabled"];
    return value ? [value boolValue] : YES;
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
            NSLog(@"[OBD11VAG-iOS14] 1.9.28 patch bytes did not match; no patch applied");
            return;
        }

        MSHookMemory(target, kNoUpdateInstruction, sizeof(kNoUpdateInstruction));
        NSLog(@"[OBD11VAG-iOS14] 1.9.28 update check patched");
    }
}
