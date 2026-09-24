#import "StreamClient.h"
#import "TurboDecoder.h"
#import "IPSCrypto.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <mach/mach_time.h>

// Must match RawProtocol.magic on the Mac. 02 added control messages, 03
// device keys and mutual authentication.
static const char kMagic[8] = {'I','P','S','C','R','N','0','3'};

// Heartbeat: ping every 2 s; a connection silent for longer than this is
// treated as dead. Without it, a link that died without a clean close
// (out of range, Mac asleep) looked connected forever.
static const NSTimeInterval kPingInterval = 2.0;
static const NSTimeInterval kSilenceLimit = 7.0;

// Top bit of a packet length marks a control message instead of a frame.
static const uint32_t kControlFlag = 0x80000000u;

@implementation StreamClient {
    NSString *_host;
    uint16_t _port;
    NSString *_clientNonce;         // fresh for every Wi-Fi connection
    dispatch_source_t _heartbeat;
    CFAbsoluteTime _lastData;

    int _fd;
    int _listenFD;          // persistent listener in USB mode
    dispatch_source_t _acceptSource;
    dispatch_source_t _readSource;
    dispatch_queue_t _netQueue;
    // Decoding is split across two queues because the A5 is dual core.
    // Three were tried and did worse: past the core count the queues stall
    // each other and decode time goes up.
    dispatch_queue_t _decodeQueues[2];
    NSUInteger _decodeTurn;

    // Buffer for incoming bytes. TCP doesn't preserve frame boundaries;
    // even the 4-byte length prefix can be split across two packets.
    NSMutableData *_buffer;

    BOOL _gotHeader;

    // Most recently decoded frame, single slot.
    CGImageRef _latestFrame;
    NSLock *_frameLock;

    // Keeps a decode that finishes out of order from overwriting a newer
    // frame with an older one.
    uint64_t _frameSequence;
    uint64_t _displayedSequence;

    double _timebaseMS;
    BOOL _running;
    BOOL _listenMode;

    // Each decode queue has its own decoder: the libjpeg context and buffer
    // pool aren't shared, so there's nothing to contend on.
    TurboDecoder *_decoders[2];
}

@synthesize delegate = _delegate;
@synthesize deviceID = _deviceID;
@synthesize deviceKey = _deviceKey;
@synthesize pin = _pin;
@synthesize frameWidth = _frameWidth;
@synthesize frameHeight = _frameHeight;
@synthesize connected = _connected;
@synthesize running = _running;
@synthesize requestedMode = _requestedMode;
@synthesize framesReceived = _framesReceived;
@synthesize framesDecoded = _framesDecoded;
@synthesize framesDropped = _framesDropped;
@synthesize bytesReceived = _bytesReceived;
@synthesize lastDecodeMS = _lastDecodeMS;
@synthesize averageDecodeMS = _averageDecodeMS;

- (id)initWithHost:(NSString *)host port:(uint16_t)port {
    self = [super init];
    if (self) {
        _host = [host retain];
        _port = port;
        _fd = -1;
        _listenFD = -1;
        _buffer = [[NSMutableData alloc] initWithCapacity:512 * 1024];
        _frameLock = [[NSLock alloc] init];

        _netQueue = dispatch_queue_create("ipadscreen.net", DISPATCH_QUEUE_SERIAL);
        _decodeQueues[0] = dispatch_queue_create("ipadscreen.decode0", DISPATCH_QUEUE_SERIAL);
        _decodeQueues[1] = dispatch_queue_create("ipadscreen.decode1", DISPATCH_QUEUE_SERIAL);

        // Three buffers per pool: one decoding, one on screen, one waiting.
        _decoders[0] = [[TurboDecoder alloc] initWithPoolSize:3];
        _decoders[1] = [[TurboDecoder alloc] initWithPoolSize:3];

        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        _timebaseMS = (double)tb.numer / (double)tb.denom / 1e6;
    }
    return self;
}

- (void)dealloc {
    [self stop];
    [_host release];
    [_requestedMode release];
    [_deviceID release];
    [_deviceKey release];
    [_pin release];
    [_clientNonce release];
    [_buffer release];
    [_frameLock release];
    if (_netQueue) dispatch_release(_netQueue);
    if (_decodeQueues[0]) dispatch_release(_decodeQueues[0]);
    if (_decodeQueues[1]) dispatch_release(_decodeQueues[1]);
    [_decoders[0] release];
    [_decoders[1] release];
    if (_latestFrame) CGImageRelease(_latestFrame);
    [super dealloc];
}

#pragma mark - Connection

- (void)start {
    if (_running) return;
    _running = YES;
    dispatch_async(_netQueue, ^{ [self connectAndRun]; });
}

- (void)stop {
    _running = NO;
    [self stopHeartbeat];
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);   // the cancel handler closes the fd
        dispatch_release(_acceptSource);
        _acceptSource = NULL;
        _listenFD = -1;
    }
    if (_readSource) {
        dispatch_source_cancel(_readSource);   // the cancel handler closes the fd
        dispatch_release(_readSource);
        _readSource = NULL;
    }
    _connected = NO;
}

- (id)initWithListenPort:(uint16_t)port {
    self = [self initWithHost:nil port:port];
    if (self) _listenMode = YES;
    return self;
}

/// USB mode: wait for the Mac to connect through `iproxy`.
- (void)listenAndRun {
    if (!_running) return;

    if (_acceptSource) return;   // listener already set up

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) {
        [self scheduleReconnect];
        return;
    }

    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    // Loopback only: connections through the usbmuxd tunnel arrive on
    // 127.0.0.1. Listening on every interface let anyone on the Wi-Fi
    // network connect to this port, feed the app data, or take the single
    // slot so the Mac couldn't get in.
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(_port);

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(srv, 4) != 0) {
        close(srv);
        [self scheduleReconnect];
        return;
    }

    // Keep the listener open. Closing and re-binding after every connection
    // can fail because of TIME_WAIT; in that window the Mac's connection
    // attempt went nowhere and we silently stayed on Wi-Fi.
    _listenFD = srv;
    fcntl(srv, F_SETFL, O_NONBLOCK);

    // A dispatch source instead of a blocking `accept()`, so the listener
    // is always ready. Previously, after a disconnect nothing was accepted
    // until we got back to `accept` (1 s), and the Mac tried and gave up in
    // exactly that window.
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, srv, 0, _netQueue);
    dispatch_source_set_event_handler(_acceptSource, ^{
        int fd = accept(_listenFD, NULL, NULL);
        if (fd >= 0) {
            // Reject a new connection if we already have one; there's only
            // ever one client.
            if (_fd >= 0) {
                close(fd);
                return;
            }
            [self configureAndBegin:fd];
        }
    });
    dispatch_source_set_cancel_handler(_acceptSource, ^{ close(srv); });
    dispatch_resume(_acceptSource);
}

/// Applies the common socket options to an accepted socket and starts reading.
- (void)configureAndBegin:(int)fd {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    int rcvbuf = 512 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    [self beginReadingOnSocket:fd];

    // Tell the Mac a real listener is here (iproxy accepts connections even
    // when nothing is listening on the iPad, so the Mac only treats USB as
    // connected once it hears this) and who we are. Without a key we ask for
    // one: pairing over the cable needs no PIN.
    [self sendControl:[NSString stringWithFormat:@"hello id=%@%@",
                       _deviceID, _deviceKey ? @"" : @" pair"]];
}

- (void)connectAndRun {
    if (!_running) return;

    if (_listenMode) {
        [self listenAndRun];
        return;
    }

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%u", _port);

    if (getaddrinfo([_host UTF8String], portStr, &hints, &res) != 0 || !res) {
        [self scheduleReconnect];
        return;
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        [self scheduleReconnect];
        return;
    }

    // No SIGPIPE: otherwise write() kills the process when the server goes away.
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    int rcvbuf = 512 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
        close(fd);
        freeaddrinfo(res);
        [self scheduleReconnect];
        return;
    }
    freeaddrinfo(res);

    // Send the request. The server sends no HTTP response for /raw; the
    // first bytes back are the "IPSCRN01" magic, so don't wait for headers.
    [_clientNonce release];
    _clientNonce = [IPSRandomHex(16) copy];
    NSString *modeParam = _requestedMode ? [@"&mode=" stringByAppendingString:_requestedMode] : @"";
    NSString *request = [NSString stringWithFormat:
        @"GET /raw?id=%@&cn=%@%@ HTTP/1.1\r\nHost: ipadscreen\r\n\r\n",
        _deviceID, _clientNonce, modeParam];
    const char *req = [request UTF8String];
    if (send(fd, req, strlen(req), 0) < 0) {
        close(fd);
        [self scheduleReconnect];
        return;
    }

    [self beginReadingOnSocket:fd];
}

/// Sets up the read source on a connected socket. Both modes end up here.
- (void)beginReadingOnSocket:(int)fd {
    // Dispatch sources need a non-blocking fd.
    fcntl(fd, F_SETFL, O_NONBLOCK);

    _fd = fd;
    [_buffer setLength:0];
    _gotHeader = NO;
    _framesReceived = 0;
    _lastData = CFAbsoluteTimeGetCurrent();
    [self startHeartbeat];

    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _netQueue);

    dispatch_source_set_event_handler(_readSource, ^{ [self readAvailable]; });

    // The fd is closed only here: closing it while the source is live is a
    // use-after-free on the kqueue registration.
    dispatch_source_set_cancel_handler(_readSource, ^{ close(fd); });

    _connected = YES;
    dispatch_resume(_readSource);    // sources start suspended
}

- (void)scheduleReconnect {
    _connected = NO;
    if (!_running) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   _netQueue, ^{ [self connectAndRun]; });
}

#pragma mark - Reading

- (void)readAvailable {
    // Always drain completely, so we're left holding the newest frame and
    // older ones don't sit in the queue adding latency.
    uint8_t chunk[64 * 1024];
    for (;;) {
        ssize_t n = read(_fd, chunk, sizeof(chunk));
        if (n > 0) {
            _lastData = CFAbsoluteTimeGetCurrent();
            [_buffer appendBytes:chunk length:(NSUInteger)n];
            _bytesReceived += (uint64_t)n;
            continue;
        }
        if (n == 0) {           // peer closed
            [self handleDisconnect];
            return;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == EINTR) continue;
        [self handleDisconnect];
        return;
    }
    [self drainBuffer];
}

- (void)handleDisconnect {
    [self stopHeartbeat];
    if (_readSource) {
        dispatch_source_cancel(_readSource);
        dispatch_release(_readSource);
        _readSource = NULL;
    }
    _fd = -1;
    _connected = NO;

    // No reconnect needed in listening mode: the accept source is still up
    // and picks up the Mac's next connection by itself.
    if (_listenMode && _acceptSource) return;

    [self scheduleReconnect];
}

/// Pulls complete frames out of the buffer. Anything incomplete is left
/// untouched until the next read.
- (void)drainBuffer {
    const uint8_t *bytes = (const uint8_t *)[_buffer bytes];
    NSUInteger len = [_buffer length];
    NSUInteger offset = 0;

    if (!_gotHeader) {
        if (len < 16) return;                       // magic + 2 × uint32
        if (memcmp(bytes, kMagic, 8) != 0) {
            // Wrong server. Retrying won't help, but resetting the
            // connection doesn't hurt either.
            [self handleDisconnect];
            return;
        }
        _frameWidth  = (NSUInteger)ntohl(*(const uint32_t *)(bytes + 8));
        _frameHeight = (NSUInteger)ntohl(*(const uint32_t *)(bytes + 12));
        _gotHeader = YES;
        offset = 16;
    }

    while (offset + 4 <= len) {
        uint32_t packetLen = ntohl(*(const uint32_t *)(bytes + offset));

        if (packetLen & kControlFlag) {
            uint32_t msgLen = packetLen & ~kControlFlag;
            if (msgLen > 4096) {                        // no sane control message is this long
                [self handleDisconnect];
                return;
            }
            if (offset + 4 + msgLen > len) break;       // message not complete yet

            NSString *message = [[NSString alloc] initWithBytes:(bytes + offset + 4)
                                                         length:msgLen
                                                       encoding:NSUTF8StringEncoding];
            offset += 4 + msgLen;
            if (message) [self handleControl:message];
            [message release];
            continue;
        }

        uint32_t frameLen = packetLen;
        // A bogus length means we've lost alignment with the stream.
        if (frameLen == 0 || frameLen > 16 * 1024 * 1024) {
            [self handleDisconnect];
            return;
        }
        if (offset + 4 + frameLen > len) break;     // frame not complete yet

        NSData *jpeg = [[NSData alloc] initWithBytes:(bytes + offset + 4)
                                              length:frameLen];
        offset += 4 + frameLen;
        _framesReceived++;
        [self decodeAsync:jpeg sequence:++_frameSequence];
        [jpeg release];
    }

    if (offset > 0) {
        [_buffer replaceBytesInRange:NSMakeRange(0, offset) withBytes:NULL length:0];
    }
}

#pragma mark - Heartbeat

- (void)startHeartbeat {
    [self stopHeartbeat];
    _heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _netQueue);
    dispatch_source_set_timer(_heartbeat,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPingInterval * NSEC_PER_SEC)),
                              (uint64_t)(kPingInterval * NSEC_PER_SEC), NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(_heartbeat, ^{
        if (_fd < 0) return;
        if (CFAbsoluteTimeGetCurrent() - _lastData > kSilenceLimit) {
            [self handleDisconnect];
            return;
        }
        [self sendControl:@"ping"];
    });
    dispatch_resume(_heartbeat);
}

- (void)stopHeartbeat {
    if (!_heartbeat) return;
    dispatch_source_cancel(_heartbeat);
    dispatch_release(_heartbeat);
    _heartbeat = NULL;
}

#pragma mark - Handshake

/// Runs on the network queue. Handshake messages are answered here; the
/// rest goes to the delegate.
- (void)handleControl:(NSString *)message {
    if ([message isEqualToString:@"ping"]) return;

    if ([message hasPrefix:@"hello="]) {
        // "hello=<server nonce>:<server proof>": the Mac knows us and proves
        // it knows our key. Check that before answering.
        NSArray *parts = [[message substringFromIndex:6] componentsSeparatedByString:@":"];
        if (!_deviceKey || parts.count != 2) {
            [self deliverControl:@"auth=impostor"];
            return;
        }
        NSString *serverNonce = [parts objectAtIndex:0];
        NSString *expected = IPSProof(_deviceKey, @"S", _clientNonce, serverNonce);
        if (!IPSEqual([parts objectAtIndex:1], expected)) {
            [self deliverControl:@"auth=impostor"];
            return;
        }
        [self sendControl:[@"proof=" stringByAppendingString:
                           IPSProof(_deviceKey, @"C", _clientNonce, serverNonce)]];
        return;
    }

    if ([message hasPrefix:@"pin="]) {
        // The Mac doesn't know us. If we do have a key, the Mac was reset or
        // this isn't our Mac; don't answer with a PIN proof unasked, because
        // an impostor could guess the PIN from it offline.
        if (_deviceKey) {
            [self deliverControl:@"auth=forgotten"];
            return;
        }
        if (_pin.length == 0) {
            [self deliverControl:@"auth=required"];
            return;
        }
        NSData *pinKey = [_pin dataUsingEncoding:NSUTF8StringEncoding];
        NSString *serverNonce = [message substringFromIndex:4];
        [self sendControl:[@"pin=" stringByAppendingString:
                           IPSProof(pinKey, @"P", _clientNonce, serverNonce)]];
        return;
    }

    if ([message hasPrefix:@"key="]) {
        NSString *keyHex = [message substringFromIndex:4];
        NSData *key = IPSDataFromHex(keyHex);
        if (key.length != 32) return;
        self.deviceKey = key;
        self.pin = nil;
        NSString *copy = [keyHex copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([_delegate respondsToSelector:@selector(streamClient:didReceiveDeviceKey:)]) {
                [_delegate streamClient:self didReceiveDeviceKey:copy];
            }
            [copy release];
        });
        return;
    }

    [self deliverControl:message];
}

#pragma mark - Control messages

/// Hands a control message from the Mac to the delegate on the main thread.
- (void)deliverControl:(NSString *)message {
    NSString *copy = [message copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([_delegate respondsToSelector:@selector(streamClient:didReceiveControl:)]) {
            [_delegate streamClient:self didReceiveControl:copy];
        }
        [copy release];
    });
}

- (void)sendControl:(NSString *)message {
    NSString *line = [message stringByAppendingString:@"\n"];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    // Synchronous on the network queue, so a message sent right before
    // switching links actually goes out before the socket is touched again.
    // Called from the main thread; the network queue never waits on main.
    dispatch_block_t work = ^{
        if (_fd < 0) return;
        send(_fd, data.bytes, data.length, 0);
    };
    if (dispatch_get_current_queue() == _netQueue) {
        work();
    } else {
        dispatch_sync(_netQueue, work);
    }
}

#pragma mark - Decoding

- (void)decodeAsync:(NSData *)jpeg sequence:(uint64_t)seq {
    NSData *retained = [jpeg retain];
    NSUInteger slot = _decodeTurn % 2;
    dispatch_queue_t q = _decodeQueues[slot];
    TurboDecoder *decoder = _decoders[slot];
    _decodeTurn++;

    dispatch_async(q, ^{
        uint64_t t0 = mach_absolute_time();
        CGImageRef img = [decoder decode:retained];
        uint64_t t1 = mach_absolute_time();
        [retained release];

        if (!img) return;

        double ms = (double)(t1 - t0) * _timebaseMS;
        _lastDecodeMS = ms;
        // Moving average, so a single outlier doesn't skew the reading.
        _averageDecodeMS = (_averageDecodeMS == 0.0) ? ms
                                                     : (_averageDecodeMS * 0.9 + ms * 0.1);

        [_frameLock lock];
        if (seq > _displayedSequence) {
            // Newest frame: release the previous one and take its place.
            if (_latestFrame) CGImageRelease(_latestFrame);
            _latestFrame = img;
            _displayedSequence = seq;
            _framesDecoded++;
        } else {
            // The two queues finished out of order; drop the older frame.
            CGImageRelease(img);
            _framesDropped++;
        }
        [_frameLock unlock];
    });
}

- (CGImageRef)copyLatestFrame:(uint64_t *)sequence {
    [_frameLock lock];
    CGImageRef img = _latestFrame ? CGImageRetain(_latestFrame) : NULL;
    if (sequence) *sequence = _displayedSequence;
    [_frameLock unlock];
    return img;
}

@end
