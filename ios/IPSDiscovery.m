#import "IPSDiscovery.h"
#import <arpa/inet.h>
#import <netinet/in.h>

/// Must match StreamServer.bonjourType on the Mac.
static NSString * const kServiceType = @"_ipadscreen._tcp.";

@interface IPSDiscovery () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@end

@implementation IPSDiscovery {
    NSNetServiceBrowser *_browser;
    // Services must be retained while they resolve; the browser doesn't
    // keep them alive.
    NSMutableArray *_resolving;
}

@synthesize delegate = _delegate;

- (id)init {
    self = [super init];
    if (self) {
        _resolving = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    // A retry may be scheduled from didNotSearch:; don't let it fire on a
    // deallocated object.
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self stop];
    [_resolving release];
    [super dealloc];
}

- (void)start {
    if (_browser) return;
    _browser = [[NSNetServiceBrowser alloc] init];
    _browser.delegate = self;
    [_browser searchForServicesOfType:kServiceType inDomain:@"local."];
}

- (void)stop {
    [_browser stop];
    _browser.delegate = nil;
    [_browser release];
    _browser = nil;

    for (NSNetService *service in _resolving) {
        service.delegate = nil;
        [service stop];
    }
    [_resolving removeAllObjects];
}

#pragma mark - NSNetServiceBrowserDelegate

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
           didFindService:(NSNetService *)service
               moreComing:(BOOL)moreComing {
    [_resolving addObject:service];
    service.delegate = self;
    [service resolveWithTimeout:5.0];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
             didNotSearch:(NSDictionary *)errorDict {
    // Browsing failed to start (e.g. no network yet). Try again shortly.
    [self stop];
    [self performSelector:@selector(start) withObject:nil afterDelay:3.0];
}

#pragma mark - NSNetServiceDelegate

- (void)netServiceDidResolveAddress:(NSNetService *)service {
    NSString *host = [self IPv4AddressOfService:service];
    if (host && [_delegate respondsToSelector:@selector(discovery:didFindHost:name:)]) {
        [_delegate discovery:self didFindHost:host name:service.name];
    }
    [self finishResolving:service];
}

- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary *)errorDict {
    [self finishResolving:service];
}

- (void)finishResolving:(NSNetService *)service {
    service.delegate = nil;
    [service stop];
    [_resolving removeObject:service];
}

/// Picks the IPv4 address out of the resolved addresses. The Mac's server
/// only listens on IPv4, so an IPv6 address would never connect.
- (NSString *)IPv4AddressOfService:(NSNetService *)service {
    for (NSData *data in service.addresses) {
        if (data.length < sizeof(struct sockaddr_in)) continue;
        const struct sockaddr_in *addr = (const struct sockaddr_in *)data.bytes;
        if (addr->sin_family != AF_INET) continue;

        char buf[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &addr->sin_addr, buf, sizeof(buf))) {
            return [NSString stringWithUTF8String:buf];
        }
    }
    return nil;
}

@end
