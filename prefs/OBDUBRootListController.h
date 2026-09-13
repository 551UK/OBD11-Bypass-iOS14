#import <Preferences/PSListController.h>

@class PSSpecifier;

@interface OBDUBRootListController : PSListController
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (void)resetOBDDefaults;
- (void)resetVAGDefaults;
- (void)respring;
- (void)openGitHub;
@end
