#import "IPSViewController.h"
#import "StreamClient.h"
#import "IPSSettingsPanel.h"
#import "IPSDiscovery.h"
#import "IPSCrypto.h"
#import <QuartzCore/QuartzCore.h>

/// Defaults key for an address entered by hand. Absent means "find the Mac
/// over Bonjour".
static NSString * const kHostKey = @"IPSHost";
/// Defaults keys for this iPad's identity. The device key comes from
/// pairing (over USB, or with the PIN) and proves who we are to the Mac on
/// every Wi-Fi connection. The PIN itself is never stored.
static NSString * const kDeviceIDKey = @"IPSDeviceID";
static NSString * const kDeviceKeyKey = @"IPSDeviceKey";

@interface IPSViewController () <IPSSettingsPanelDelegate, IPSDiscoveryDelegate, StreamClientDelegate,
                                 UIAlertViewDelegate, UITextFieldDelegate>
@end

@implementation IPSViewController {
    IPSSettingsPanel *_panel;
    IPSDiscovery *_discovery;
    NSString *_host;            // address the Wi-Fi client is using now
    NSString *_manualHost;      // entered in the panel; nil means automatic
    NSString *_discoveredHost;  // last address found over Bonjour
    NSString *_code;            // PIN typed for pairing; memory only
    NSString *_deviceID;        // this iPad's identity, 32 hex chars
    NSData *_deviceKey;         // from pairing; nil until paired
    UIAlertView *_impostorAlert;
    // The Mac refused our code. Wi-Fi retries stop until a new code is
    // entered: retrying with a bad code would count as guessing and lock
    // this iPad out.
    BOOL _authBlocked;
    NSString *_authMessage;     // last "auth=..." from the Mac

    // USB first: in USB mode Wi-Fi isn't tried until this moment, giving
    // the Mac a few seconds to reach us over the cable. With the cable
    // attached the iPad then never needs a pairing code.
    CFAbsoluteTime _usbGraceUntil;

    // Pairing code popup, shown only when Wi-Fi is the only way in.
    UIAlertView *_codeAlert;
    BOOL _codePromptDismissed;  // user closed it; don't pop it up again unasked
    uint16_t _wifiPort;
    uint16_t _usbPort;
    StreamClient *_client;      // the active connection (one of the two below)
    StreamClient *_wifiClient;
    StreamClient *_usbClient;
    CALayer *_screenLayer;
    CADisplayLink *_displayLink;

    UILabel *_statusLabel;

    // Sequence of the last frame put on screen; stops us re-uploading the
    // same frame. No point running the compositor when nothing new arrived.
    uint64_t _displayedSequence;

    // fps measurement
    NSUInteger _drawnFrames;
    CFAbsoluteTime _lastStatsUpdate;
    NSUInteger _lastReceivedCount;
    uint64_t _lastByteCount;
    BOOL _usingUSB;         // frames are coming over USB right now

    // Link mode, shared with the Mac: YES = USB when the cable is attached,
    // Wi-Fi otherwise; NO = Wi-Fi only. The Mac is told about changes made
    // here, and changes made on the Mac arrive as control messages.
    BOOL _preferUSB;
    // A change made here that the Mac hasn't confirmed yet. Resent every
    // couple of seconds until it echoes the same mode back.
    BOOL _modePending;
    CFAbsoluteTime _lastModeSend;
}

- (id)initWithPort:(uint16_t)port usbPort:(uint16_t)usbPort {
    self = [super init];
    if (self) {
        _wifiPort = port;
        _usbPort = usbPort;

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *saved = [defaults stringForKey:kHostKey];
        _manualHost = (saved.length > 0) ? [saved copy] : nil;
        // An earlier version stored the PIN; it isn't needed any more.
        [defaults removeObjectForKey:@"IPSCode"];

        NSData *key = IPSDataFromHex([defaults stringForKey:kDeviceKeyKey]);
        if (key.length == 32) {
            _deviceKey = [key copy];
            _deviceID = [[defaults stringForKey:kDeviceIDKey] copy];
        }
        if (!_deviceKey || _deviceID.length != 32) {
            // Not paired: start with a fresh identity, so a Mac that still
            // remembers an old one doesn't expect a key we no longer have.
            [_deviceKey release];
            _deviceKey = nil;
            [self newDeviceIdentity];
        }

        // The Wi-Fi client is created once we know an address: either the
        // one entered by hand, or whatever Bonjour finds.
        _usbClient = [[StreamClient alloc] initWithListenPort:usbPort];
        _usbClient.delegate = self;
        _usbClient.deviceID = _deviceID;
        _usbClient.deviceKey = _deviceKey;
        _discovery = [[IPSDiscovery alloc] init];
        _discovery.delegate = self;
        // Try both links until the Mac says which mode it's in.
        _preferUSB = YES;
    }
    return self;
}

- (void)dealloc {
    [_displayLink invalidate];
    [_wifiClient stop];
    [_usbClient stop];
    [_wifiClient release];
    [_usbClient release];
    [_discovery stop];
    [_discovery release];
    [_host release];
    [_manualHost release];
    [_discoveredHost release];
    [_code release];
    [_deviceID release];
    [_deviceKey release];
    _impostorAlert.delegate = nil;
    [_impostorAlert release];
    [_authMessage release];
    _codeAlert.delegate = nil;
    [_codeAlert release];
    [_panel release];
    [super dealloc];
}

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    root.backgroundColor = [UIColor blackColor];
    self.view = root;
    [root release];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    CGRect bounds = self.view.bounds;

    // Picture layer. A bare CALayer instead of UIImageView: no intrinsic
    // content size or layout invalidation on every frame.
    _screenLayer = [[CALayer alloc] init];
    _screenLayer.frame = bounds;
    _screenLayer.contentsGravity = kCAGravityResizeAspect;
    _screenLayer.opaque = YES;              // no blending over the window
    _screenLayer.contentsScale = 1.0;       // the iPad 2 isn't Retina
    _screenLayer.magnificationFilter = kCAFilterNearest;
    _screenLayer.minificationFilter = kCAFilterNearest;
    _screenLayer.backgroundColor = [UIColor blackColor].CGColor;
    [self.view.layer addSublayer:_screenLayer];

    _statusLabel = [[UILabel alloc] initWithFrame:bounds];
    _statusLabel.backgroundColor = [UIColor clearColor];
    _statusLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    _statusLabel.textAlignment = UITextAlignmentCenter;
    _statusLabel.font = [UIFont systemFontOfSize:18];
    _statusLabel.text = _manualHost ? @"Connecting to your Mac…" : @"Looking for your Mac…";
    [self.view addSubview:_statusLabel];

    // Settings panel that slides in from the right edge.
    _panel = [[IPSSettingsPanel alloc] initWithHost:_manualHost];
    _panel.delegate = self;
    [_panel presentInView:self.view];
    [_panel setUSBSelected:_preferUSB];

    if (_manualHost) [self useWiFiHost:_manualHost];
    [_usbClient start];

    // Browse even when an address was entered by hand: it's cheap, and the
    // panel can show what was found in case the typed address is wrong.
    [_discovery start];

    // Give USB a head start before trying Wi-Fi.
    _usbGraceUntil = CFAbsoluteTimeGetCurrent() + 4.0;

    // Tapping the screen while a code is needed brings the popup back.
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(screenTapped)];
    [self.view addGestureRecognizer:tap];
    [tap release];

    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    // Check on every vsync (60 Hz) so a 40-60 fps stream doesn't skip
    // frames. The real throttle is checking whether the frame changed.
    _displayLink.frameInterval = 1;
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    _lastStatsUpdate = CFAbsoluteTimeGetCurrent();
}

- (void)tick:(CADisplayLink *)link {
    // In USB mode, use USB once it's delivering frames: far more bandwidth
    // than Wi-Fi. When the cable is pulled we fall back to Wi-Fi on our own.
    //
    // The unused connection MUST be closed: with both open the server sends
    // every frame twice, wasting bandwidth and decode capacity.
    if (_preferUSB) {
        StreamClient *preferred = (_usbClient.framesReceived > 0 && _usbClient.connected)
                                ? _usbClient : _wifiClient;
        if (preferred != _client) {
            _client = preferred;
            _usingUSB = (preferred == _usbClient);

            if (_usingUSB) {
                [_wifiClient stop];
            }

            // Counters are per connection; without a reset on switch, the
            // first sample reads the difference between the two as speed.
            _displayedSequence = 0;
            _lastReceivedCount = 0;
            _lastByteCount = 0;
        }

        // USB dropped; bring Wi-Fi back.
        if (_usingUSB && !_usbClient.connected) {
            _usingUSB = NO;
            _client = _wifiClient;
            if (!_authBlocked) [_wifiClient start];
            _displayedSequence = 0;
            _lastReceivedCount = 0;
            _lastByteCount = 0;
        }
    } else if (_client != _wifiClient || _usingUSB) {
        // Wi-Fi mode. The USB connection is left for the Mac to close once
        // it gets our mode change; closing it here could cut that message off.
        _usingUSB = NO;
        _client = _wifiClient;
        if (!_authBlocked) [_wifiClient start];
        _displayedSequence = 0;
        _lastReceivedCount = 0;
        _lastByteCount = 0;
    }

    // Start Wi-Fi as soon as it's allowed: after USB's head start, or
    // right away in Wi-Fi mode.
    if (_wifiClient && !_wifiClient.running && [self wifiAllowed]) {
        _wifiClient.requestedMode = [self requestedModeForWiFi];
        [_wifiClient start];
        if (!_usingUSB) _client = _wifiClient;
    }

    [self updateCodePrompt];

    if (_modePending && CFAbsoluteTimeGetCurrent() - _lastModeSend > 2.0) {
        [self sendModeToMac];
    }

    uint64_t seq = 0;
    CGImageRef frame = [_client copyLatestFrame:&seq];
    if (frame) {
        if (seq != _displayedSequence) {
            _displayedSequence = seq;
            // Implicit animation off: setting `contents` on a bare layer
            // starts a 0.25 s crossfade by default. At 40 times a second
            // that's both blur and wasted GPU work.
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            _screenLayer.contents = (id)frame;
            [CATransaction commit];

            _drawnFrames++;

            if (!_statusLabel.hidden) {
                _statusLabel.hidden = YES;
                [self layoutScreenLayer];
            }
        }
        CGImageRelease(frame);
    }

    [self updateStatsIfNeeded];
}

/// Places the picture on screen without distorting its aspect ratio.
- (void)layoutScreenLayer {
    NSUInteger fw = _client.frameWidth;
    NSUInteger fh = _client.frameHeight;
    if (fw == 0 || fh == 0) return;

    CGRect bounds = self.view.bounds;
    CGFloat scale = MIN(bounds.size.width / (CGFloat)fw,
                        bounds.size.height / (CGFloat)fh);
    CGFloat w = (CGFloat)fw * scale;
    CGFloat h = (CGFloat)fh * scale;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _screenLayer.frame = CGRectMake((bounds.size.width - w) / 2,
                                    (bounds.size.height - h) / 2, w, h);
    [CATransaction commit];
}

- (void)updateStatsIfNeeded {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime elapsed = now - _lastStatsUpdate;
    if (elapsed < 1.0) return;

    NSUInteger received = _client.framesReceived;
    uint64_t bytes = _client.bytesReceived;
    // Counters reset when the connection changes and can be smaller than
    // the previous value; unsigned subtraction would wrap to a huge number.
    NSUInteger frameDelta = (received >= _lastReceivedCount)
                          ? (received - _lastReceivedCount) : received;
    double netFPS = frameDelta / elapsed;
    double drawFPS = _drawnFrames / elapsed;
    // Mbit/s: tells whether the bottleneck is decode or bandwidth.
    uint64_t byteDelta = (bytes >= _lastByteCount) ? (bytes - _lastByteCount) : bytes;
    double mbps = ((double)byteDelta * 8.0) / elapsed / 1e6;

    // Stats live in the panel only; the overlay strip was removed because
    // it covered the picture.
    // What's actually carrying frames, not just what's selected: if USB is
    // selected but the cable isn't attached, say so.
    NSString *link;
    if (_usingUSB)                link = @"USB";
    else if (_authBlocked)        link = @"Code needed";
    else if (!_client.connected)  link = @"Connecting…";
    else if (_preferUSB)          link = @"Wi-Fi · no cable";
    else                          link = @"Wi-Fi";

    [_panel updateConnection:link
                     drawFPS:drawFPS
                      netFPS:netFPS
                    decodeMS:_client.averageDecodeMS
                        mbps:mbps
                     dropped:_client.framesDropped
                   frameSize:CGSizeMake(_client.frameWidth, _client.frameHeight)];

    _drawnFrames = 0;
    _lastReceivedCount = received;
    _lastByteCount = bytes;
    _lastStatsUpdate = now;
}

#pragma mark - Wi-Fi address

/// Points the Wi-Fi client at a new address. USB doesn't depend on the
/// address, so it's left alone.
- (void)useWiFiHost:(NSString *)host {
    if (_wifiClient && [host isEqualToString:_host]) return;

    [_host release];
    _host = [host copy];
    [self rebuildWiFiClient];
}

/// Recreates the Wi-Fi client for the current address and code.
- (void)rebuildWiFiClient {
    if (!_host) return;

    [_wifiClient stop];
    [_wifiClient release];
    _wifiClient = [[StreamClient alloc] initWithHost:_host port:_wifiPort];
    _wifiClient.deviceID = _deviceID;
    _wifiClient.deviceKey = _deviceKey;
    _wifiClient.pin = _code;
    _wifiClient.delegate = self;

    // Don't start Wi-Fi while USB is carrying the stream (the server would
    // send every frame twice) or while USB still has its head start.
    // tick: starts it once it's allowed.
    if ([self wifiAllowed]) {
        _wifiClient.requestedMode = [self requestedModeForWiFi];
        [_wifiClient start];
        _client = _wifiClient;
        _displayedSequence = 0;
        _lastReceivedCount = 0;
        _lastByteCount = 0;
    }
}

- (void)discovery:(IPSDiscovery *)discovery didFindHost:(NSString *)host name:(NSString *)name {
    [_discoveredHost release];
    _discoveredHost = [host copy];
    [_panel setDiscoveredHost:host name:name];

    // An address typed by hand wins over discovery.
    if (!_manualHost) [self useWiFiHost:host];
}

#pragma mark - Settings panel

/// An empty address switches back to automatic discovery.
- (void)settingsPanelDidChangeHost:(NSString *)host {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [_manualHost release];

    if (host.length > 0) {
        _manualHost = [host copy];
        [defaults setObject:host forKey:kHostKey];
        [self useWiFiHost:host];
    } else {
        _manualHost = nil;
        [defaults removeObjectForKey:kHostKey];
        if (_discoveredHost) [self useWiFiHost:_discoveredHost];
    }
    // iOS 6 doesn't always flush defaults before the app is killed.
    [defaults synchronize];
}

/// Whether the Wi-Fi client may run right now.
- (BOOL)wifiAllowed {
    if (_authBlocked || _usingUSB) return NO;
    if (!_preferUSB) return YES;
    return CFAbsoluteTimeGetCurrent() >= _usbGraceUntil;
}

/// An unpaired iPad asks for USB in its Wi-Fi request, so it can get onto
/// the cable without a code; so does one where USB was just picked here.
/// Otherwise nothing is requested and the Mac's own setting stands.
- (NSString *)requestedModeForWiFi {
    if (_preferUSB && (_modePending || !_deviceKey)) return @"usb";
    return nil;
}

/// Pairs over Wi-Fi with a PIN typed by the user. The PIN stays in memory
/// only until the Mac hands over a device key.
- (void)applyCode:(NSString *)code {
    // The Mac asked for a PIN although we have a key: it forgot us. Drop the
    // key so the handshake takes the pairing path.
    if (_deviceKey) [self forgetPairing];

    [_code release];
    _code = (code.length > 0) ? [code copy] : nil;
    _authBlocked = NO;
    [self rebuildWiFiClient];
}

/// A fresh random identity for this iPad.
- (void)newDeviceIdentity {
    [_deviceID release];
    _deviceID = [IPSRandomHex(16) copy];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:_deviceID forKey:kDeviceIDKey];
    [defaults synchronize];
}

/// Forgets the device key; the next connection pairs again.
- (void)forgetPairing {
    [_deviceKey release];
    _deviceKey = nil;
    [self newDeviceIdentity];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kDeviceKeyKey];
    [defaults synchronize];
    _usbClient.deviceID = _deviceID;
    _usbClient.deviceKey = nil;
}

/// The Mac paired us (over USB, or after the PIN) and sent our key.
- (void)streamClient:(StreamClient *)client didReceiveDeviceKey:(NSString *)keyHex {
    NSData *key = IPSDataFromHex(keyHex);
    if (key.length != 32) return;

    [_deviceKey release];
    _deviceKey = [key copy];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:keyHex forKey:kDeviceKeyKey];
    [defaults setObject:_deviceID forKey:kDeviceIDKey];
    [defaults synchronize];

    // The PIN has done its job.
    [_code release];
    _code = nil;
    _authBlocked = NO;
    _usbClient.deviceKey = _deviceKey;
    _wifiClient.deviceKey = _deviceKey;
    _wifiClient.pin = nil;
}

- (void)settingsPanelDidSelectUSB:(BOOL)usb {
    if (usb == _preferUSB) return;
    _preferUSB = usb;
    _modePending = YES;
    if (usb) {
        // Give the cable a moment, and let a blocked Wi-Fi retry once so it
        // can carry the USB request to a Mac that's in Wi-Fi mode.
        _usbGraceUntil = CFAbsoluteTimeGetCurrent() + 5.0;
        _authBlocked = NO;
    }
    // Tell the Mac before switching, while the current link is still up.
    [self sendModeToMac];
}

#pragma mark - Pairing

/// The Mac refused the Wi-Fi stream: no code, a wrong one, or too many
/// wrong tries. Stop retrying (retrying a bad code counts as guessing and
/// would lock this iPad out) and let updateCodePrompt decide whether to ask.
- (void)handleAuthProblem:(NSString *)message {
    // If this request asked the Mac to switch to USB, the Mac is opening the
    // tunnel now; give the cable a few more seconds before asking for a code,
    // or the popup would flash up and vanish a second later.
    if ([_wifiClient.requestedMode isEqualToString:@"usb"]) {
        _usbGraceUntil = CFAbsoluteTimeGetCurrent() + 4.0;
    }

    _authBlocked = YES;
    [_wifiClient stop];
    [_authMessage release];
    _authMessage = [message copy];
    _codePromptDismissed = NO;

    // Not a question of a code: whatever answered didn't prove it's the Mac
    // we paired with. Don't offer the PIN here; an impostor could work it out
    // from our answer.
    if ([message isEqualToString:@"auth=impostor"]) {
        [self showImpostorAlert];
    }
}

- (void)showImpostorAlert {
    if (_impostorAlert) return;
    _impostorAlert = [[UIAlertView alloc]
        initWithTitle:@"Can't verify your Mac"
              message:[NSString stringWithFormat:
                       @"The Mac at %@ couldn't prove it's the one this iPad is paired with. "
                       @"Something on the network may be pretending to be it.\n\n"
                       @"Connect the USB cable to pair again safely.", _host]
             delegate:self
    cancelButtonTitle:@"OK"
    otherButtonTitles:@"Forget pairing", nil];
    [_impostorAlert show];
}

/// Shows the code popup only when Wi-Fi really is the only way in: nothing
/// on USB, and in USB mode not before the cable had its chance. Takes it
/// down again if USB comes up meanwhile.
- (void)updateCodePrompt {
    if (_usingUSB || _usbClient.connected) {
        if (_codeAlert) [self dismissCodeAlert];
        return;
    }
    if (!_authBlocked) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _screenLayer.contents = nil;                 // no stale picture behind the message
    [CATransaction commit];
    _statusLabel.hidden = NO;
    _statusLabel.text = @"Tap to enter the pairing code shown on your Mac.";

    if ([_authMessage isEqualToString:@"auth=impostor"]) {
        _statusLabel.text = @"Couldn't verify your Mac. Connect the USB cable to pair again.";
        return;
    }

    BOOL cableHadItsChance = !_preferUSB || CFAbsoluteTimeGetCurrent() >= _usbGraceUntil;
    if (!_codeAlert && !_codePromptDismissed && cableHadItsChance) {
        [self showCodeAlert];
    }
}

- (void)screenTapped {
    if (!_authBlocked || _usingUSB) return;
    if ([_authMessage isEqualToString:@"auth=impostor"]) [self showImpostorAlert];
    else if (!_codeAlert) [self showCodeAlert];
}

- (void)showCodeAlert {
    NSString *message;
    if ([_authMessage isEqualToString:@"auth=locked"]) {
        message = @"Too many wrong codes. Wait a minute, then try again.";
    } else if ([_authMessage isEqualToString:@"auth=wrong"]) {
        message = @"That code didn't match. Enter the code shown in iPadScreen on your Mac.";
    } else if ([_authMessage isEqualToString:@"auth=forgotten"]) {
        message = @"Your Mac no longer recognizes this iPad. If you didn't reset pairing on "
                  @"the Mac, something may be pretending to be it: connect the USB cable "
                  @"instead of entering the code.";
    } else {
        message = @"Enter the code shown in iPadScreen on your Mac. "
                  @"With a USB cable attached, no code is needed.";
    }

    _codeAlert = [[UIAlertView alloc] initWithTitle:@"Pairing code"
                                            message:message
                                           delegate:self
                                  cancelButtonTitle:@"Cancel"
                                  otherButtonTitles:@"Connect", nil];
    _codeAlert.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *field = [_codeAlert textFieldAtIndex:0];
    field.keyboardType = UIKeyboardTypeNumberPad;
    field.placeholder = @"4 digits";
    field.textAlignment = UITextAlignmentCenter;
    field.delegate = self;
    [_codeAlert show];
}

- (void)dismissCodeAlert {
    _codeAlert.delegate = nil;
    [_codeAlert dismissWithClickedButtonIndex:0 animated:YES];
    [_codeAlert release];
    _codeAlert = nil;
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)index {
    if (alertView == _impostorAlert) {
        [_impostorAlert release];
        _impostorAlert = nil;
        if (index != alertView.cancelButtonIndex) {
            // Start over: the next Wi-Fi connection asks for the PIN.
            [self forgetPairing];
            [_authMessage release];
            _authMessage = nil;
            _authBlocked = NO;
            [self rebuildWiFiClient];
        }
        return;
    }
    if (alertView != _codeAlert) return;
    NSString *code = [alertView textFieldAtIndex:0].text;
    [_codeAlert release];
    _codeAlert = nil;

    if (index == alertView.cancelButtonIndex) {
        _codePromptDismissed = YES;
        return;
    }
    [self applyCode:code];
}

/// Connect stays disabled until four digits are in.
- (BOOL)alertViewShouldEnableFirstOtherButton:(UIAlertView *)alertView {
    if (alertView != _codeAlert) return YES;
    return [alertView textFieldAtIndex:0].text.length == 4;
}

/// Digits only, at most four. The code goes into the request line, so
/// nothing else may get through.
- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range
        replacementString:(NSString *)string {
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([string rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return NO;
    return field.text.length - range.length + string.length <= 4;
}

#pragma mark - Link mode

/// Sends our link mode to the Mac over every connection that's up. Sending
/// on both is harmless: the Mac ignores a mode it's already in.
- (void)sendModeToMac {
    NSString *message = _preferUSB ? @"mode=usb" : @"mode=wifi";
    if (_usbClient.connected) [_usbClient sendControl:message];
    if (_wifiClient.connected) [_wifiClient sendControl:message];
    _lastModeSend = CFAbsoluteTimeGetCurrent();
}

- (void)streamClient:(StreamClient *)client didReceiveControl:(NSString *)message {
    if ([message hasPrefix:@"auth="]) {
        [self handleAuthProblem:message];
        return;
    }
    if (![message hasPrefix:@"mode="]) return;
    BOOL usb = [message isEqualToString:@"mode=usb"];

    if (_modePending) {
        // We changed the mode here. Either the Mac has caught up, or it
        // hasn't seen our change yet and needs to hear it again.
        if (usb == _preferUSB) _modePending = NO;
        else [self sendModeToMac];
        return;
    }

    // The mode was changed on the Mac (or this is the Mac telling us its
    // mode on connect): follow it, and show it in the panel.
    if (usb && !_preferUSB) _usbGraceUntil = CFAbsoluteTimeGetCurrent() + 5.0;
    _preferUSB = usb;
    [_panel setUSBSelected:usb];
}

- (void)settingsPanelDidRequestReconnect {
    _authBlocked = NO;
    [_wifiClient stop];
    // While USB carries the stream, Wi-Fi stays off; tick: brings it back
    // if the cable goes away.
    if ([self wifiAllowed]) {
        _wifiClient.requestedMode = [self requestedModeForWiFi];
        [_wifiClient start];
    }
    _statusLabel.hidden = NO;
    _statusLabel.text = _wifiClient ? @"Reconnecting…" : @"Looking for your Mac…";
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o {
    return UIInterfaceOrientationIsLandscape(o);
}

- (NSUInteger)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutScreenLayer];
    _statusLabel.frame = self.view.bounds;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

@end
