#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/// Decodes JPEG with libjpeg-turbo (NEON).
///
/// Two wins over ImageIO:
///
///  1. NEON acceleration, roughly 2x on the A5.
///  2. `JCS_EXT_BGRX` decodes straight into CoreAnimation's native pixel
///     format, so the intermediate bitmap context and the full-frame copy
///     of the ImageIO path disappear entirely.
///
/// Buffers come from a pool: allocating and freeing 3 MB per frame is a
/// real burden on the iPad 2's memory.
@interface TurboDecoder : NSObject

/// Number of buffers in the pool. At least 3: one decoding, one on screen,
/// one waiting. With fewer, the on-screen frame's buffer risks being
/// overwritten.
- (id)initWithPoolSize:(NSUInteger)count;

/// Decodes a JPEG into an image that can go straight to CoreAnimation.
/// The returned CGImage is owned by the caller.
- (CGImageRef)decode:(NSData *)jpeg;

@end
