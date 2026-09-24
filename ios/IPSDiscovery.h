#import <Foundation/Foundation.h>

@class IPSDiscovery;

@protocol IPSDiscoveryDelegate <NSObject>
/// A Mac running iPadScreen was found and its IPv4 address resolved.
- (void)discovery:(IPSDiscovery *)discovery didFindHost:(NSString *)host name:(NSString *)name;
@end

/// Finds the Mac on the local network over Bonjour.
///
/// The Mac app advertises `_ipadscreen._tcp`; this browses for it and
/// resolves the first match to an IPv4 address, so nobody has to type an IP
/// in. Keeps browsing after a match, so if the Mac's address changes it is
/// reported again.
@interface IPSDiscovery : NSObject

@property (nonatomic, assign) id<IPSDiscoveryDelegate> delegate;

- (void)start;
- (void)stop;

@end
