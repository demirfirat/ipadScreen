#import "IPSCrypto.h"
#import <CommonCrypto/CommonHMAC.h>
#import <Security/Security.h>

static NSString *IPSHex(const unsigned char *bytes, size_t length) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:length * 2];
    for (size_t i = 0; i < length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

NSString *IPSRandomHex(size_t bytes) {
    unsigned char buffer[64];
    if (bytes > sizeof(buffer)) bytes = sizeof(buffer);
    if (SecRandomCopyBytes(kSecRandomDefault, bytes, buffer) != 0) return nil;
    return IPSHex(buffer, bytes);
}

NSString *IPSProof(NSData *key, NSString *tag, NSString *clientNonce, NSString *serverNonce) {
    NSString *text = [NSString stringWithFormat:@"%@:%@:%@", tag, clientNonce, serverNonce];
    NSData *message = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, message.bytes, message.length, mac);
    return IPSHex(mac, sizeof(mac));
}

NSData *IPSDataFromHex(NSString *hex) {
    if (hex.length % 2 != 0) return nil;
    NSMutableData *data = [NSMutableData dataWithCapacity:hex.length / 2];
    const char *chars = [hex UTF8String];
    for (NSUInteger i = 0; i < hex.length; i += 2) {
        char pair[3] = { chars[i], chars[i + 1], 0 };
        char *end = NULL;
        unsigned long byte = strtoul(pair, &end, 16);
        if (end != pair + 2) return nil;
        unsigned char b = (unsigned char)byte;
        [data appendBytes:&b length:1];
    }
    return data;
}

BOOL IPSEqual(NSString *a, NSString *b) {
    NSData *x = [a dataUsingEncoding:NSUTF8StringEncoding];
    NSData *y = [b dataUsingEncoding:NSUTF8StringEncoding];
    if (x.length != y.length) return NO;
    const unsigned char *p = x.bytes, *q = y.bytes;
    unsigned char diff = 0;
    for (NSUInteger i = 0; i < x.length; i++) diff |= p[i] ^ q[i];
    return diff == 0;
}
