// Loaded into /usr/bin/perl by np.pl. Streams now-playing JSON lines on stdout,
// takes "cmd <n>" / "seek <seconds>" on stdin, exits when stdin closes.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/message.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef Boolean (*SendFn)(int, NSDictionary *);
typedef void (*SeekFn)(double);

static GetInfoFn getInfo;
static SendFn sendCmd;
static SeekFn setElapsed;
static Class Req;
static NSString *lastLine, *sentArt;

static NSString *K(NSString *k) { return [@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:k]; }
static id str(id v) { return [v isKindOfClass:NSString.class] ? v : @""; }
static id num(id v) { return [v isKindOfClass:NSNumber.class] ? v : @0; }

static void emit(NSDictionary *o) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
    if (!d) return;
    fwrite(d.bytes, 1, d.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void poll(void) {
    getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        @autoreleasepool {
            NSMutableDictionary *o = [NSMutableDictionary dictionary];
            o[@"playing"] = @(((BOOL (*)(id, SEL))objc_msgSend)(Req, sel_registerName("localIsPlaying")));
            @try {
                id path = ((id (*)(id, SEL))objc_msgSend)(Req, sel_registerName("localNowPlayingPlayerPath"));
                NSString *bid = [[path valueForKey:@"client"] valueForKey:@"bundleIdentifier"];
                if ([bid isKindOfClass:NSString.class]) o[@"app"] = bid;
            } @catch (id e) {}
            if (info.count) {
                o[@"title"] = str(info[K(@"Title")]);
                o[@"artist"] = str(info[K(@"Artist")]);
                o[@"album"] = str(info[K(@"Album")]);
                o[@"duration"] = num(info[K(@"Duration")]);
                o[@"elapsed"] = num(info[K(@"ElapsedTime")]);
                o[@"rate"] = num(info[K(@"PlaybackRate")]);
                NSDate *ts = info[K(@"Timestamp")];
                if ([ts isKindOfClass:NSDate.class]) o[@"ts"] = @(ts.timeIntervalSince1970);
                NSString *ak = info[K(@"ArtworkIdentifier")];
                if (![ak isKindOfClass:NSString.class]) ak = [NSString stringWithFormat:@"%@|%@", o[@"title"], o[@"artist"]];
                o[@"artKey"] = ak;
            }
            NSData *lineData = [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:nil];
            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            NSData *art = info[K(@"ArtworkData")];
            BOOL sendArt = o[@"artKey"] && ![o[@"artKey"] isEqual:sentArt] && [art isKindOfClass:NSData.class] && art.length > 0;
            if (![line isEqual:lastLine] || sendArt) {
                if (sendArt) { o[@"art"] = [art base64EncodedStringWithOptions:0]; sentArt = o[@"artKey"]; }
                emit(o);
                lastLine = line;
            }
        }
    });
}

static void handle(NSString *s) {
    NSArray *p = [s componentsSeparatedByString:@" "];
    if (p.count < 2) return;
    if ([p[0] isEqual:@"cmd"]) sendCmd([p[1] intValue], nil);
    else if ([p[0] isEqual:@"seek"]) setElapsed([p[1] doubleValue]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ poll(); });
}

void np_run(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    getInfo = (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    sendCmd = (SendFn)dlsym(h, "MRMediaRemoteSendCommand");
    setElapsed = (SeekFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    Req = NSClassFromString(@"MRNowPlayingRequest");
    if (!getInfo || !sendCmd || !Req) { fprintf(stderr, "MediaRemote unavailable\n"); exit(2); }

    [NSThread detachNewThreadWithBlock:^{
        char buf[256];
        while (fgets(buf, sizeof buf, stdin)) {
            NSString *s = [[NSString stringWithUTF8String:buf] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{ handle(s); });
        }
        exit(0);
    }];

    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{ poll(); });
    dispatch_resume(t);
    CFRunLoopRun();
}
