#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <substrate.h>

extern NSURLRequest *OBDRequestBySpoofingServerIdentity(NSURLRequest *request);

static id (*originalPerform)(id, SEL, NSURLRequest *, id, id);

static id performRequest(id self, SEL cmd, NSURLRequest *request, id command, id cancellation) {
    return originalPerform(self,
                           cmd,
                           OBDRequestBySpoofingServerIdentity(request),
                           command,
                           cancellation);
}

void OBDInstallLoginCompatibility(void) {
    Class pf = NSClassFromString(@"PFURLSession");
    SEL sel = NSSelectorFromString(@"performDataURLRequestAsync:forCommand:cancellationToken:");
    if (!pf || !class_getInstanceMethod(pf, sel)) return;

    MSHookMessageEx(pf,
                    sel,
                    (IMP)performRequest,
                    (IMP *)&originalPerform);
}
