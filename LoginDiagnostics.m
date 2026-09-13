#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <substrate.h>

extern NSURLRequest *OBDRequestBySpoofingServerIdentity(NSURLRequest *request);

// Diagnostics intentionally keep only fixed labels and numeric error/status
// codes. URLs, query strings, credentials, response text, userInfo and tokens
// are never displayed or persisted.
static NSObject *gLock;
static NSMutableDictionary *gDetails;
static NSUInteger gAttempt;
static BOOL gAlamofireHooksInstalled;
static const char kAttemptKey, kResponseKey;

static NSString *authRoute(NSURLRequest *request) {
    if (!request) return nil;
    NSString *host = request.URL.host.lowercaseString ?: @"";
    NSString *last = request.URL.lastPathComponent.lowercaseString ?: @"";
    if ([host isEqualToString:@"server1.obdeleven.com"]) {
        if ([last isEqualToString:@"temporary-password"]) return @"RestApi password check";
        if ([last isEqualToString:@"login"]) return @"Parse login";
    }
    if ([host isEqualToString:@"api.obdeleven.com"] && [last isEqualToString:@"login"])
        return @"REST login";
    return nil;
}

static NSNumber *beginAuthRequest(NSURLRequest *request, NSString *transport) {
    NSString *route = authRoute(request);
    if (!route) return nil;

    NSString *host = request.URL.host.lowercaseString ?: @"";
    BOOL mobileHeaders = [[request valueForHTTPHeaderField:@"x-mobile-app-version"] isEqualToString:@"1.9.73"] &&
        [[request valueForHTTPHeaderField:@"x-mobile-app-build"] isEqualToString:@"1785335496"];
    BOOL parseHeaders = YES;
    if ([host isEqualToString:@"server1.obdeleven.com"]) {
        parseHeaders = [[request valueForHTTPHeaderField:@"X-Parse-App-Display-Version"] isEqualToString:@"1.9.73"] &&
            [[request valueForHTTPHeaderField:@"X-Parse-App-Build-Version"] isEqualToString:@"1785335496"];
    }

    NSNumber *attempt;
    @synchronized (gLock) {
        gAttempt++;
        attempt = @(gAttempt);
        gDetails = [@{
            @"time": @([NSDate timeIntervalSinceReferenceDate]),
            @"route": route,
            @"transport": transport ?: @"URLSession",
            @"mobile": mobileHeaders ? @"1.9.73 / 1785335496" : @"not matched",
            @"parse": parseHeaders ? @"1.9.73 / 1785335496" : @"not matched"
        } mutableCopy];
    }
    return attempt;
}

static NSNumber *attemptForTask(NSURLSessionTask *task, NSString *transport) {
    NSNumber *attempt = objc_getAssociatedObject(task, &kAttemptKey);
    if (attempt) return attempt;

    NSURLRequest *request = task.currentRequest ?: task.originalRequest;
    attempt = beginAuthRequest(request, transport);
    if (attempt)
        objc_setAssociatedObject(task, &kAttemptKey, attempt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return attempt;
}

static NSString *safeErrorHint(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *s = [value lowercaseString];
    for (NSString *word in @[@"version", @"update", @"password", @"username", @"application",
                             @"session", @"token", @"deprecated", @"disabled", @"maintenance"])
        if ([s containsString:word]) return [@"Server error mentions: " stringByAppendingString:word];
    return @"Server returned an error message";
}

static void finishAuthTask(NSURLSessionTask *task, NSError *error, NSString *transport) {
    NSNumber *attempt = attemptForTask(task, transport);
    if (!attempt) return;

    NSData *data = objc_getAssociatedObject(task, &kResponseKey);
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSNumber *parseCode = [json isKindOfClass:[NSDictionary class]] &&
        [json[@"code"] isKindOfClass:[NSNumber class]] ? json[@"code"] : nil;
    NSString *hint = [json isKindOfClass:[NSDictionary class]] ? safeErrorHint(json[@"error"]) : nil;
    NSInteger status = [task.response isKindOfClass:[NSHTTPURLResponse class]] ?
        [(NSHTTPURLResponse *)task.response statusCode] : 0;

    @synchronized (gLock) {
        if (attempt.unsignedIntegerValue == gAttempt && gDetails) {
            gDetails[@"http"] = @(status);
            if (parseCode) gDetails[@"parseCode"] = parseCode;
            if (hint) gDetails[@"hint"] = hint;
            if (error) {
                gDetails[@"network"] = @(error.code);
                gDetails[@"domain"] = [error.domain isEqualToString:NSURLErrorDomain] ? @"URL" : @"Other";
                NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
                if ([underlying isKindOfClass:[NSError class]])
                    gDetails[@"underlying"] = @(underlying.code);
            }
        }
    }
    objc_setAssociatedObject(task, &kResponseKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void collectErrorData(NSURLSessionTask *task, NSData *data, NSString *transport) {
    if (!attemptForTask(task, transport)) return;
    NSInteger status = [task.response isKindOfClass:[NSHTTPURLResponse class]] ?
        [(NSHTTPURLResponse *)task.response statusCode] : 0;

    // A successful auth response can contain a session token or temporary
    // password, so only retain a small body when the server returned an error.
    if (status < 400 || !data.length) return;

    NSMutableData *buffer = objc_getAssociatedObject(task, &kResponseKey);
    if (!buffer) {
        buffer = [NSMutableData data];
        objc_setAssociatedObject(task, &kResponseKey, buffer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (buffer.length >= 16384) return;
    NSUInteger count = MIN(data.length, (NSUInteger)16384 - buffer.length);
    if (count) [buffer appendBytes:data.bytes length:count];
}

static NSString *diagnosticSummary(void) {
    NSDictionary *d;
    @synchronized (gLock) { d = [gDetails copy]; }
    if (!d || [NSDate timeIntervalSinceReferenceDate] - [d[@"time"] doubleValue] > 120) {
        return [NSString stringWithFormat:@"[VAG 1.0.7]\nNo recent auth request observed.\nAlamofire hooks: %@",
                gAlamofireHooksInstalled ? @"active" : @"not found"];
    }

    NSMutableArray *lines = [NSMutableArray arrayWithObjects:
        @"[VAG 1.0.7]",
        d[@"route"] ?: @"Auth request",
        [@"Transport: " stringByAppendingString:(d[@"transport"] ?: @"URLSession")],
        [@"Mobile headers: " stringByAppendingString:(d[@"mobile"] ?: @"unknown")],
        [@"Parse headers: " stringByAppendingString:(d[@"parse"] ?: @"unknown")], nil];
    [lines addObject:[NSString stringWithFormat:@"HTTP: %@", d[@"http"] ?: @"pending"]];
    if (d[@"parseCode"]) [lines addObject:[NSString stringWithFormat:@"Parse code: %@", d[@"parseCode"]]];
    if (d[@"network"]) [lines addObject:[NSString stringWithFormat:@"Connection: %@ %@", d[@"domain"], d[@"network"]]];
    if (d[@"underlying"]) [lines addObject:[NSString stringWithFormat:@"Underlying code: %@", d[@"underlying"]]];
    if (d[@"hint"]) [lines addObject:d[@"hint"]];
    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - Parse PFURLSession

static id (*originalPerform)(id, SEL, NSURLRequest *, id, id);
static id performRequest(id self, SEL cmd, NSURLRequest *request, id command, id cancellation) {
    NSURLRequest *rewritten = OBDRequestBySpoofingServerIdentity(request);
    return originalPerform(self, cmd, rewritten, command, cancellation);
}

static void (*originalPFReceiveResponse)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSURLResponse *, void (^)(NSURLSessionResponseDisposition));
static void pfReceiveResponse(id self, SEL cmd, NSURLSession *session, NSURLSessionDataTask *task,
                              NSURLResponse *response, void (^completion)(NSURLSessionResponseDisposition)) {
    attemptForTask(task, @"Parse PFURLSession");
    originalPFReceiveResponse(self, cmd, session, task, response, completion);
}

static void (*originalPFReceiveData)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *);
static void pfReceiveData(id self, SEL cmd, NSURLSession *session, NSURLSessionDataTask *task, NSData *data) {
    collectErrorData(task, data, @"Parse PFURLSession");
    originalPFReceiveData(self, cmd, session, task, data);
}

static void (*originalPFComplete)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *);
static void pfComplete(id self, SEL cmd, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    finishAuthTask(task, error, @"Parse PFURLSession");
    originalPFComplete(self, cmd, session, task, error);
}

#pragma mark - Alamofire RestApi SessionDelegate

static void (*originalAFReceiveResponse)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSURLResponse *, void (^)(NSURLSessionResponseDisposition));
static void afReceiveResponse(id self, SEL cmd, NSURLSession *session, NSURLSessionDataTask *task,
                              NSURLResponse *response, void (^completion)(NSURLSessionResponseDisposition)) {
    attemptForTask(task, @"RestApi / Alamofire");
    originalAFReceiveResponse(self, cmd, session, task, response, completion);
}

static void (*originalAFReceiveData)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *);
static void afReceiveData(id self, SEL cmd, NSURLSession *session, NSURLSessionDataTask *task, NSData *data) {
    collectErrorData(task, data, @"RestApi / Alamofire");
    originalAFReceiveData(self, cmd, session, task, data);
}

static void (*originalAFComplete)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *);
static void afComplete(id self, SEL cmd, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    finishAuthTask(task, error, @"RestApi / Alamofire");
    originalAFComplete(self, cmd, session, task, error);
}

#pragma mark - Failed-login popup

static NSString *messageWithDiagnostics(NSString *message) {
    if (![message isKindOfClass:[NSString class]] || [message containsString:@"[VAG 1.0.7]"] ||
        [message rangeOfString:@"Failed to login" options:NSCaseInsensitiveSearch].location == NSNotFound)
        return message;
    return [message stringByAppendingFormat:@"\n\n%@", diagnosticSummary()];
}

static id (*originalAlert)(id, SEL, NSString *, NSString *, UIAlertControllerStyle);
static id createAlert(id self, SEL cmd, NSString *title, NSString *message, UIAlertControllerStyle style) {
    return originalAlert(self, cmd, title, messageWithDiagnostics(message), style);
}

static void (*originalSetMessage)(id, SEL, NSString *);
static void setAlertMessage(id self, SEL cmd, NSString *message) {
    originalSetMessage(self, cmd, messageWithDiagnostics(message));
}

static BOOL hook(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls || !class_getInstanceMethod(cls, sel)) return NO;
    MSHookMessageEx(cls, sel, replacement, original);
    return YES;
}

void OBDInstallLoginDiagnostics(void) {
    gLock = [NSObject new];

    Class pf = NSClassFromString(@"PFURLSession");
    hook(pf, NSSelectorFromString(@"performDataURLRequestAsync:forCommand:cancellationToken:"),
         (IMP)performRequest, (IMP *)&originalPerform);
    hook(pf, @selector(URLSession:dataTask:didReceiveResponse:completionHandler:),
         (IMP)pfReceiveResponse, (IMP *)&originalPFReceiveResponse);
    hook(pf, @selector(URLSession:dataTask:didReceiveData:),
         (IMP)pfReceiveData, (IMP *)&originalPFReceiveData);
    hook(pf, @selector(URLSession:task:didCompleteWithError:),
         (IMP)pfComplete, (IMP *)&originalPFComplete);

    Class af = NSClassFromString(@"Alamofire.SessionDelegate");
    if (!af) af = objc_getClass("_TtC9Alamofire15SessionDelegate");
    BOOL afResponse = hook(af, @selector(URLSession:dataTask:didReceiveResponse:completionHandler:),
                           (IMP)afReceiveResponse, (IMP *)&originalAFReceiveResponse);
    BOOL afData = hook(af, @selector(URLSession:dataTask:didReceiveData:),
                       (IMP)afReceiveData, (IMP *)&originalAFReceiveData);
    BOOL afCompleteHook = hook(af, @selector(URLSession:task:didCompleteWithError:),
                               (IMP)afComplete, (IMP *)&originalAFComplete);
    gAlamofireHooksInstalled = afResponse || afData || afCompleteHook;

    hook(object_getClass([UIAlertController class]),
         @selector(alertControllerWithTitle:message:preferredStyle:),
         (IMP)createAlert, (IMP *)&originalAlert);
    hook([UIAlertController class], @selector(setMessage:),
         (IMP)setAlertMessage, (IMP *)&originalSetMessage);

    NSLog(@"[OBD11VAG-iOS14] login diagnostics: PF=%@ Alamofire=%@",
          pf ? @"found" : @"missing", gAlamofireHooksInstalled ? @"hooked" : @"missing");
}
