#import "OBDUBRootListController.h"

#import <CoreFoundation/CoreFoundation.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

#include <spawn.h>

extern char **environ;

static NSString *const kPreferencesDomain = @"com.551.obdelevenupdatebypass";
static NSString *const kPreferencesChangedNotification =
    @"com.551.obdelevenupdatebypass/preferences.changed";

static id CopyPreferenceValue(NSString *key) {
    if (key.length == 0) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPreferencesDomain);
    CFPropertyListRef raw = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key,
        (__bridge CFStringRef)kPreferencesDomain);
    return raw ? CFBridgingRelease(raw) : nil;
}

static void SetPreferenceValue(NSString *key, id value) {
    if (key.length == 0) return;
    CFPreferencesSetAppValue(
        (__bridge CFStringRef)key,
        (__bridge CFPropertyListRef)value,
        (__bridge CFStringRef)kPreferencesDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPreferencesDomain);
}

static BOOL SpawnCommand(const char *path, char *const argv[]) {
    pid_t pid = 0;
    return posix_spawn(&pid, path, NULL, NULL, argv, environ) == 0;
}

@implementation OBDUBRootListController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

- (void)postPreferencesChangedNotification {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPreferencesDomain);
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kPreferencesChangedNotification,
        NULL,
        NULL,
        true);
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id value = CopyPreferenceValue(key);
    return value ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return;
    SetPreferenceValue(key, value);
    [self postPreferencesChangedNotification];
}

- (void)resetSpoofDefaults {
    [self.view endEditing:YES];
    SetPreferenceValue(@"vagEnabled", @YES);
    SetPreferenceValue(@"vagSpoofedVersion", @"1.9.73");
    SetPreferenceValue(@"vagSpoofedBuild", @"1785335496");
    [self postPreferencesChangedNotification];
    [self reloadSpecifiers];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Defaults Restored"
                                            message:@"Close and reopen OBD11 VAG."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)respring {
    [self.view endEditing:YES];
    [self postPreferencesChangedNotification];

    char *sbreloadArgs[] = {(char *)"sbreload", NULL};
    if (SpawnCommand("/usr/bin/sbreload", sbreloadArgs)) return;

    char *killallArgs[] = {(char *)"killall", (char *)"-9", (char *)"SpringBoard", NULL};
    if (SpawnCommand("/usr/bin/killall", killallArgs)) return;
    SpawnCommand("/bin/killall", killallArgs);
}

- (void)openGitHub {
    NSURL *url = [NSURL URLWithString:@"https://github.com/551UK/OBD11-Bypass-iOS14"];
    if (!url) return;

    UIApplication *application = [UIApplication sharedApplication];
    if ([application respondsToSelector:@selector(openURL:options:completionHandler:)]) {
        [application openURL:url options:@{} completionHandler:nil];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [application openURL:url];
#pragma clang diagnostic pop
    }
}

@end
