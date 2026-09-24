#import <Foundation/Foundation.h>

/// Helpers for the pairing handshake. See `PairingCrypto` in the Mac app for
/// the protocol; the two sides must compute exactly the same values.

/// `bytes` random bytes from the system's secure generator, as lowercase hex.
NSString *IPSRandomHex(size_t bytes);

/// HMAC-SHA256(key, "<tag>:<clientNonce>:<serverNonce>") as lowercase hex.
NSString *IPSProof(NSData *key, NSString *tag, NSString *clientNonce, NSString *serverNonce);

/// Hex string to bytes; nil if it isn't valid hex.
NSData *IPSDataFromHex(NSString *hex);

/// Constant-time string comparison, so timing doesn't reveal a partial match.
BOOL IPSEqual(NSString *a, NSString *b);
