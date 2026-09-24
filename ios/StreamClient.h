#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/// Reads the raw JPEG stream from the Mac and delivers decoded frames.
///
/// Wire format (matches RawClient.swift on the server):
///
///     "IPSCRN02"   8-byte magic
///     [width]      4 bytes big-endian
///     [height]     4 bytes big-endian
///     packets:     [length, 4 bytes big-endian][payload]
///
/// A packet whose length has the top bit set is a UTF-8 control message
/// ("mode=usb"); otherwise the payload is a JPEG frame. Control messages to
/// the Mac are newline-terminated UTF-8 lines.
@class StreamClient;

@protocol StreamClientDelegate <NSObject>
/// A control message from the Mac, such as "mode=usb" or "auth=wrong".
/// Called on the main thread. Handshake messages are handled internally.
- (void)streamClient:(StreamClient *)client didReceiveControl:(NSString *)message;
/// The Mac paired this iPad and handed over its device key (hex). Store it.
- (void)streamClient:(StreamClient *)client didReceiveDeviceKey:(NSString *)keyHex;
@end

@interface StreamClient : NSObject

@property (nonatomic, assign) id<StreamClientDelegate> delegate;

/// Connects to the Mac over Wi-Fi. Set `deviceID` and either `deviceKey`
/// (paired) or `pin` (pairing now) before `start`.
///
/// The handshake (see PairingCrypto in the Mac app) is done here: the Mac
/// has to prove it knows our key before we answer, so a device pretending
/// to be the Mac learns nothing. Problems are reported to the delegate as
/// control messages:
///
///   auth=required   Mac doesn't know us and no PIN was set
///   auth=wrong      wrong PIN or proof
///   auth=locked     too many failures from this address
///   auth=forgotten  we have a key but the Mac asked for a PIN: the Mac was
///                   reset, or something is impersonating it
///   auth=impostor   the Mac's proof was wrong: not our Mac
- (id)initWithHost:(NSString *)host port:(uint16_t)port;

/// This iPad's identity, 32 hex characters.
@property (nonatomic, copy) NSString *deviceID;
/// Key from pairing; nil if not paired yet.
@property (nonatomic, copy) NSData *deviceKey;
/// PIN typed by the user, only used for pairing; nil otherwise.
@property (nonatomic, copy) NSString *pin;

/// Listening mode, for USB.
///
/// Over USB the direction is reversed: the Mac connects to this port on the
/// iPad through `iproxy`, because a usbmuxd tunnel can only be opened
/// Mac → device. The wire format is the same; only who connects differs.
- (id)initWithListenPort:(uint16_t)port;

- (void)start;
- (void)stop;

/// Sends a control message to the Mac (a newline is appended). Does nothing
/// while not connected.
- (void)sendControl:(NSString *)message;

/// The most recently decoded frame, which the drawing side puts on screen.
/// Single slot: a late frame is dropped rather than queued, because on a
/// remote display accumulated latency is much worse than a lost frame.
///
/// `sequence` returns the frame's sequence number, which the drawing side
/// uses to avoid re-uploading the same frame. Comparing CGImage pointers
/// isn't reliable: once the buffer pool reuses freed memory, a new frame can
/// land at the same address.
/// The returned CGImage is owned by the caller (it comes retained).
- (CGImageRef)copyLatestFrame:(uint64_t *)sequence;

/// Frame size reported by the server when the connection is set up.
@property (nonatomic, readonly) NSUInteger frameWidth;
@property (nonatomic, readonly) NSUInteger frameHeight;

@property (nonatomic, readonly) BOOL connected;
/// Between start and stop, whether or not a connection is up right now.
@property (nonatomic, readonly) BOOL running;

/// Wi-Fi only: a link mode to ask for in the request line ("usb"), even
/// without a pairing code. The Mac honors "usb" unauthenticated, since it
/// only opens the USB tunnel; that's how an unpaired iPad gets onto the
/// cable. Set before `start`.
@property (nonatomic, copy) NSString *requestedMode;

/// Measurement counters, read by the stats display. `framesReceived`
/// counts the current connection only.
@property (nonatomic, readonly) NSUInteger framesReceived;
@property (nonatomic, readonly) NSUInteger framesDecoded;
@property (nonatomic, readonly) NSUInteger framesDropped;
/// Total bytes read from the network, to tell whether the bottleneck is
/// decode or bandwidth.
@property (nonatomic, readonly) uint64_t bytesReceived;
/// How many milliseconds the last frame took to decode.
@property (nonatomic, readonly) double lastDecodeMS;
/// Moving average of decode time.
@property (nonatomic, readonly) double averageDecodeMS;

@end
