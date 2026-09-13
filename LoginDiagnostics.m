#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <substrate.h>

extern NSURLRequest *OBDRequestBySpoofingServerIdentity(NSURLRequest *request);

// Only numeric error codes and fixed labels reach the popup. Never persist or
// print URLs, queries, credentials, response text, NSError.userInfo or tokens.
static NSObject *gLock;
static NSMutableDictionary *gDetails;
static NSUInteger gAttempt;
static const char kAttemptKey, kResponseKey;

static BOOL isLoginRequest(NSURLRequest *request) {
    return [request.URL.lastPathComponent isEqualToString:@"login"];
}

static void beginLoginRequest(NSURLRequest *request) {
    if (!isLoginRequest(request)) return;
    NSString *host = request.URL.host.lowercaseString;
    NSString *server = [host isEqualToString:@"server1.obdeleven.com"] ? @"Parse server1" :
        ([host isEqualToString:@"api.obdeleven.com"] ? @"REST api" : @"Other host");
    BOOL parseHeaders = [[request valueForHTTPHeaderField:@"X-Parse-App-Display-Version"] isEqualToString:@"1.9.73"] &&
        [[request valueForHTTPHeaderField:@"X-Parse-App-Build-Version"] isEqualToString:@"1785335496"];
    @synchronized (gLock) {
        gAttempt++;
        gDetails = [@{@"time": @([NSDate timeIntervalSinceReferenceDate]),
                      @"server": server,
                      @"headers": parseHeaders ? @"1.9.73 / 1785335496" : @"not matched"} mutableCopy];
    }
}

static NSNumber *attemptForTask(NSURLSessionTask *task) {
    NSNumber *attempt = objc_getAssociatedObject(task, &kAttemptKey);
    if (!attempt && isLoginRequest(task.originalRequest)) {
        @synchronized (gLock) { attempt = @(gAttempt); }
        objc_setAssociatedObject(task, &kAttemptKey, attempt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return attempt;
}

static NSString *safeErrorHint(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *s = [value lowercaseString];
    // Fixed output only: never expose the backend's free-form error text.
    for (NSString *word in @[@"version", @"update", @"password", @"username", @"application",
                             @"session", @"token", @"deprecated", @"disabled", @"maintenance"])
        if ([s containsString:word]) return [@"Server error mentions: " stringByAppendingString:word];
    return @"Server returned an error message";
}

static void finishLoginTask(NSURLSessionTask *task, NSError *error) {
    NSNumber *attempt = attemptForTask(task);
    if (!attempt) return;
    NSData *data = objc_getAssociatedObject(task, &kResponseKey);
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSNumber *parseCode = [json isKindOfClass:[NSDictionary class]] && [json[@"code"] isKindOfClass:[NSNumber class]] ? json[@"code"] : nil;
    NSString *hint = [json isKindOfClass:[NSDictionary class]] ? safeErrorHint(json[@"error"]) : nil;
    NSInteger status = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)task.response statusCode] : 0;
    @synchronized (gLock) {
        if (attempt.unsignedIntegerValue == gAttempt && gDetails) {
            gDetails[@"http"] = @(status);
            if (parseCode) gDetails[@"parse"] = parseCode;
            if (hint) gDetails[@"hint"] = hint;
            if (error) {
                gDetails[@"network"] = @(error.code);
                gDetails[@"domain"] = [error.domain isEqualToString:NSURLErrorDomain] ? @"URL" : @"Other";
                NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
                if ([underlying isKindOfClass:[NSError class]]) gDetails[@"underlying"] = @(underlying.code);
            }
        }
    }
    objc_setAssociatedObject(task, &kResponseKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString *diagnosticSummary(void) {
    NSDictionary *d;
    @synchronized (gLock) { d = [gDetails copy]; }
    if (!d || [NSDate timeIntervalSinceReferenceDate] - [d[@"time"] doubleValue] > 120)
        return @"[VAG 1.0.6]\nNo recent Parse login request observed.";
    NSMutableArray *lines = [NSMutableArray arrayWithObjects:@"[VAG 1.0.6]", d[@"server"],
                            [@"Parse headers: " stringByAppendingString:d[@"headers"]], nil];
    [lines addObject:[NSString stringWithFormat:@"HTTP: %@", d[@"http"] ?: @"pending"]];
    if (d[@"parse"]) [lines addObject:[NSString stringWithFormat:@"Parse code: %@", d[@"parse"]]];
    if (d[@"network"]) [lines addObject:[NSString stringWithFormat:@"Connection: %@ %@", d[@"domain"], d[@"network"]]];
    if (d[@"underlying"]) [lines addObject:[NSString stringWithFormat:@"Underlying code: %@", d[@"underlying"]]];
    if (d[@"hint"]) [lines addObject:d[@"hint"]];
    return [lines componentsJoinedByString:@"\n"];
}

// Static analysis verified these Objective-C selectors in VAG 1.9.28.
static id (*originalPerform)(id, SEL, NSURLRequest *, id, id);
static id performRequest(id self, SEL cmd, NSURLRequest *request, id command, id cancellation) {
    NSURLRequest *rewritten = OBDRequestBySpoofingServerIdentity(request);
    beginLoginRequest(rewritten);
    return originalPerform(self, cmd, rewritten, command, cancellation);
}

static void (*originalReceiveResponse)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSURLResponse *, void (^)(NSURLSessionResponseDisposition));
static void receiveResponse(id self, SEL cmd, NSURLSession *session, NSURLSessionDataTask *task,
                            NSURLResponse *response, void (^completion)(NSURLSessionResponseDisposition)) {
    attemptForTask(task);
    originalReceiveResponse(self, cmd, session, task, response, completion);
}

static void (*originalReceiveData)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *);
static void receiveData(id self, SEL cmd, NSURLSession *session, NSURLSessionDataTask *task, NSData *data) {
    // Successful login responses contain tokens: do not copy them at all.
    NSInteger status = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)task.response statusCode] : 0;
    if (attemptForTask(task) && status >= 400) {
        NSMutableData *buffer = objc_getAssociatedObject(task, &kResponseKey);
        if (!buffer) {
            buffer = [NSMutableData data];
            objc_setAssociatedObject(task, &kResponseKey, buffer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSUInteger count = MIN(data.length, (NSUInteger)16384 - buffer.length);
        if (count) [buffer appendBytes:data.bytes length:count];
    }
    originalReceiveData(self, cmd, session, task, data);
}

static void (*originalComplete)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *);
static void completeTask(id self, SEL cmd, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    finishLoginTask(task, error);
    originalComplete(self, cmd, session, task, error);
}

static NSString *messageWithDiagnostics(NSString *message) {
    if (![message isKindOfClass:[NSString class]] || [message containsString:@"[VAG 1.0.6]"] ||
        [message rangeOfString:@"Failed to login" options:NSCaseInsensitiveSearch].location == NSNotFound) return message;
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
    Class cls = NSClassFromString(@"PFURLSession");
    hook(cls, NSSelectorFromString(@"performDataURLRequestAsync:forCommand:cancellationToken:"), (IMP)performRequest, (IMP *)&originalPerform);
    hook(cls, @selector(URLSession:dataTask:didReceiveResponse:completionHandler:), (IMP)receiveResponse, (IMP *)&originalReceiveResponse);
    hook(cls, @selector(URLSession:dataTask:didReceiveData:), (IMP)receiveData, (IMP *)&originalReceiveData);
    hook(cls, @selector(URLSession:task:didCompleteWithError:), (IMP)completeTask, (IMP *)&originalComplete);
    hook(object_getClass([UIAlertController class]), @selector(alertControllerWithTitle:message:preferredStyle:), (IMP)createAlert, (IMP *)&originalAlert);
    hook([UIAlertController class], @selector(setMessage:), (IMP)setAlertMessage, (IMP *)&originalSetMessage);
}
