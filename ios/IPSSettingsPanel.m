#import "IPSSettingsPanel.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kPanelWidth = 320.0;
static const CGFloat kRowHeight = 44.0;
static const NSTimeInterval kSlideDuration = 0.28;

@interface IPSSettingsPanel () <UITextFieldDelegate>
@end

@implementation IPSSettingsPanel {
    UIView *_dimmer;          // darkens the picture while the panel is open
    UIView *_sheet;           // the sliding panel itself
    UIView *_handle;          // grab handle on the edge

    UILabel *_statusValue;
    UILabel *_fpsValue;
    UILabel *_decodeValue;
    UILabel *_mbpsValue;
    UILabel *_netFPSValue;
    UILabel *_droppedValue;
    UILabel *_sizeValue;

    UITextField *_hostField;
    UISegmentedControl *_modeControl;

    NSString *_host;
    BOOL _isOpen;
}

@synthesize delegate = _delegate;
@synthesize isOpen = _isOpen;

- (id)initWithHost:(NSString *)host {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _host = [host copy];
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
    }
    return self;
}

- (void)dealloc {
    [_host release];
    [super dealloc];
}

#pragma mark - Setup

- (void)presentInView:(UIView *)parent {
    self.frame = parent.bounds;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [parent addSubview:self];

    [self buildDimmer];
    [self buildSheet];
    [self buildHandle];
}

- (void)buildDimmer {
    _dimmer = [[UIView alloc] initWithFrame:self.bounds];
    _dimmer.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    _dimmer.alpha = 0;
    _dimmer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _dimmer.userInteractionEnabled = NO;
    [self addSubview:_dimmer];
    [_dimmer release];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
    [_dimmer addGestureRecognizer:tap];
    [tap release];
}

- (void)buildSheet {
    CGRect bounds = self.bounds;
    // Parked just off the right edge while closed.
    _sheet = [[UIView alloc] initWithFrame:
              CGRectMake(bounds.size.width, 0, kPanelWidth, bounds.size.height)];
    _sheet.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    _sheet.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleLeftMargin;

    // Edge line marking where the panel meets the picture.
    UIView *edge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, bounds.size.height)];
    edge.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    edge.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    [_sheet addSubview:edge];
    [edge release];

    [self addSubview:_sheet];
    [_sheet release];

    CGFloat y = 28;

    y = [self addTitle:@"Connection" atY:y];
    y = [self addModeSelectorAtY:y];
    y = [self addStatusRowAtY:y];
    y = [self addMetricsRowAtY:y];

    y += 14;
    y = [self addTitle:@"Mac" atY:y];
    y = [self addHostFieldAtY:y];

    y += 20;
    [self addReconnectButtonAtY:y];
    [self addVersionLabel];
}

/// Version at the bottom of the panel, read from Info.plist. To bump the
/// version, update it there and in the package's `control` file.
- (void)addVersionLabel {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = [info objectForKey:@"CFBundleShortVersionString"];
    if (version.length == 0) version = @"?";

    CGFloat h = 18;
    UILabel *label = [[UILabel alloc] initWithFrame:
                      CGRectMake(20, _sheet.bounds.size.height - h - 16, kPanelWidth - 40, h)];
    label.text = [NSString stringWithFormat:@"iPadScreen %@", version];
    label.font = [UIFont systemFontOfSize:11];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.3];
    label.textAlignment = UITextAlignmentCenter;
    label.backgroundColor = [UIColor clearColor];
    // Stay pinned to the bottom when rotating.
    label.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [_sheet addSubview:label];
    [label release];
}

/// Thin handle on the right edge; swipe or tap it to open the panel.
- (void)buildHandle {
    CGRect bounds = self.bounds;
    _handle = [[UIView alloc] initWithFrame:
               CGRectMake(bounds.size.width - 26, bounds.size.height / 2 - 40, 26, 80)];
    _handle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    _handle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin
                             | UIViewAutoresizingFlexibleBottomMargin;
    _handle.layer.cornerRadius = 6;

    // Three dots hint that the handle can be pulled.
    for (int i = 0; i < 3; i++) {
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(11, 30 + i * 10, 4, 4)];
        dot.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        dot.layer.cornerRadius = 2;
        [_handle addSubview:dot];
        [dot release];
    }

    [self addSubview:_handle];
    [_handle release];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggle)];
    [_handle addGestureRecognizer:tap];
    [tap release];

    UISwipeGestureRecognizer *swipe =
        [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(open)];
    swipe.direction = UISwipeGestureRecognizerDirectionLeft;
    [self addGestureRecognizer:swipe];
    [swipe release];
}

#pragma mark - Rows

- (CGFloat)addTitle:(NSString *)text atY:(CGFloat)y {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, y, kPanelWidth - 40, 16)];
    label.text = [text uppercaseString];
    label.font = [UIFont boldSystemFontOfSize:11];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    label.backgroundColor = [UIColor clearColor];
    [_sheet addSubview:label];
    [label release];
    return y + 24;
}

/// Wi-Fi / USB selector. It's the same setting as the picker on the Mac:
/// changing either one changes both. USB falls back to Wi-Fi while no cable
/// is attached.
- (CGFloat)addModeSelectorAtY:(CGFloat)y {
    NSArray *titles = [NSArray arrayWithObjects:@"Wi-Fi", @"USB", nil];
    _modeControl = [[UISegmentedControl alloc] initWithItems:titles];
    _modeControl.frame = CGRectMake(20, y, kPanelWidth - 40, 32);
    _modeControl.segmentedControlStyle = UISegmentedControlStyleBar;
    _modeControl.tintColor = [UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1.0];
    _modeControl.selectedSegmentIndex = 1;
    [_modeControl addTarget:self action:@selector(modeChanged)
           forControlEvents:UIControlEventValueChanged];
    [_sheet addSubview:_modeControl];
    [_modeControl release];

    return y + 32 + 10;
}

- (CGFloat)addStatusRowAtY:(CGFloat)y {
    UIView *card = [self cardAtY:y height:kRowHeight];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 120, kRowHeight)];
    name.text = @"Status";
    name.font = [UIFont systemFontOfSize:15];
    name.textColor = [UIColor whiteColor];
    name.backgroundColor = [UIColor clearColor];
    [card addSubview:name];
    [name release];

    // Same 14 px inset on the right as the "Status" label on the left; it
    // used to sit flush against the card edge and "Wi-Fi" overflowed.
    _statusValue = [[UILabel alloc] initWithFrame:
                    CGRectMake(kPanelWidth - 40 - 14 - 150, 0, 150, kRowHeight)];
    _statusValue.text = @"Connecting…";
    _statusValue.font = [UIFont systemFontOfSize:15];
    _statusValue.textColor = [UIColor colorWithRed:0.30 green:0.78 blue:0.47 alpha:1.0];
    _statusValue.textAlignment = UITextAlignmentRight;
    _statusValue.backgroundColor = [UIColor clearColor];
    [card addSubview:_statusValue];
    [_statusValue release];

    return y + kRowHeight + 8;
}

/// Stats in two rows: what drives picture quality on top, the network side
/// and frame size below.
- (CGFloat)addMetricsRowAtY:(CGFloat)y {
    CGFloat w = (kPanelWidth - 40) / 3.0;

    UIView *top = [self cardAtY:y height:58];
    _fpsValue    = [self metricInCard:top x:0     width:w caption:@"drawn fps"];
    _decodeValue = [self metricInCard:top x:w     width:w caption:@"ms decode"];
    _mbpsValue   = [self metricInCard:top x:w * 2 width:w caption:@"Mbps"];
    y += 58 + 8;

    UIView *bottom = [self cardAtY:y height:58];
    _netFPSValue  = [self metricInCard:bottom x:0     width:w caption:@"network fps"];
    _droppedValue = [self metricInCard:bottom x:w     width:w caption:@"dropped"];
    _sizeValue    = [self metricInCard:bottom x:w * 2 width:w caption:@"resolution"];

    return y + 58 + 8;
}

- (UILabel *)metricInCard:(UIView *)card x:(CGFloat)x width:(CGFloat)w caption:(NSString *)caption {
    UILabel *value = [[UILabel alloc] initWithFrame:CGRectMake(x, 10, w, 24)];
    value.text = @"—";
    value.font = [UIFont systemFontOfSize:19];
    value.textColor = [UIColor whiteColor];
    value.textAlignment = UITextAlignmentCenter;
    value.backgroundColor = [UIColor clearColor];
    // Long values like "1024×768" shrink to fit instead of being cut off.
    value.adjustsFontSizeToFitWidth = YES;
    value.minimumFontSize = 12;
    [card addSubview:value];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(x, 34, w, 14)];
    label.text = caption;
    label.font = [UIFont systemFontOfSize:10];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    label.textAlignment = UITextAlignmentCenter;
    label.backgroundColor = [UIColor clearColor];
    [card addSubview:label];
    [label release];

    return [value autorelease];
}

- (CGFloat)addHostFieldAtY:(CGFloat)y {
    UIView *card = [self cardAtY:y height:kRowHeight];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 90, kRowHeight)];
    name.text = @"Address";
    name.font = [UIFont systemFontOfSize:15];
    name.textColor = [UIColor whiteColor];
    name.backgroundColor = [UIColor clearColor];
    [card addSubview:name];
    [name release];

    _hostField = [[UITextField alloc] initWithFrame:
                  CGRectMake(104, 0, kPanelWidth - 40 - 118, kRowHeight)];
    // Empty means "find the Mac automatically"; the placeholder says so and
    // shows what Bonjour found once it has.
    _hostField.text = _host;
    _hostField.placeholder = @"Automatic";
    _hostField.font = [UIFont systemFontOfSize:15];
    _hostField.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    _hostField.textAlignment = UITextAlignmentRight;
    // iOS 6 top-aligns text in a text field by default, which left it above
    // the "Address" label in a 44 pt row.
    _hostField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _hostField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    _hostField.keyboardAppearance = UIKeyboardAppearanceAlert;
    _hostField.autocorrectionType = UITextAutocorrectionTypeNo;
    _hostField.returnKeyType = UIReturnKeyDone;
    _hostField.delegate = self;
    [card addSubview:_hostField];
    [_hostField release];

    return y + kRowHeight + 8;
}

- (void)addReconnectButtonAtY:(CGFloat)y {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(20, y, kPanelWidth - 40, 46);
    button.backgroundColor = [UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1.0];
    button.layer.cornerRadius = 10;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [button setTitle:@"Reconnect" forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [button addTarget:self action:@selector(reconnectTapped)
     forControlEvents:UIControlEventTouchUpInside];
    [_sheet addSubview:button];
}

/// Dark card that settings rows sit on.
- (UIView *)cardAtY:(CGFloat)y height:(CGFloat)height {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(20, y, kPanelWidth - 40, height)];
    card.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    card.layer.cornerRadius = 10;
    [_sheet addSubview:card];
    return [card autorelease];
}

#pragma mark - Open / close

- (void)open {
    if (_isOpen) return;
    _isOpen = YES;

    _dimmer.userInteractionEnabled = YES;

    [UIView animateWithDuration:kSlideDuration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        CGRect f = _sheet.frame;
        f.origin.x = self.bounds.size.width - kPanelWidth;
        _sheet.frame = f;
        _dimmer.alpha = 1.0;
        _handle.alpha = 0.0;
    } completion:NULL];
}

- (void)close {
    if (!_isOpen) return;
    _isOpen = NO;

    [_hostField resignFirstResponder];
    _dimmer.userInteractionEnabled = NO;

    [UIView animateWithDuration:kSlideDuration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        CGRect f = _sheet.frame;
        f.origin.x = self.bounds.size.width;
        _sheet.frame = f;
        _dimmer.alpha = 0.0;
        _handle.alpha = 1.0;
    } completion:NULL];
}

- (void)toggle {
    if (_isOpen) [self close]; else [self open];
}

/// While closed, touches must pass through to the picture; only the handle
/// and the open panel receive them.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!_isOpen && hit == self) return nil;
    return hit;
}

#pragma mark - Actions

- (void)modeChanged {
    BOOL usb = (_modeControl.selectedSegmentIndex == 1);
    if ([_delegate respondsToSelector:@selector(settingsPanelDidSelectUSB:)]) {
        [_delegate settingsPanelDidSelectUSB:usb];
    }
}

- (void)setUSBSelected:(BOOL)usb {
    // Setting the index in code doesn't fire UIControlEventValueChanged, so
    // this doesn't bounce back to the Mac as a new change.
    _modeControl.selectedSegmentIndex = usb ? 1 : 0;
}

- (void)reconnectTapped {
    NSString *entered = [_hostField.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
    // An empty field is a real choice too: it switches back to automatic.
    NSString *current = _host ? _host : @"";
    if (![entered isEqualToString:current]) {
        [_host release];
        _host = (entered.length > 0) ? [entered copy] : nil;
        if ([_delegate respondsToSelector:@selector(settingsPanelDidChangeHost:)]) {
            [_delegate settingsPanelDidChangeHost:entered];
        }
    }
    if ([_delegate respondsToSelector:@selector(settingsPanelDidRequestReconnect)]) {
        [_delegate settingsPanelDidRequestReconnect];
    }
    [self close];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Updates

- (void)setDiscoveredHost:(NSString *)host name:(NSString *)name {
    _hostField.placeholder = [NSString stringWithFormat:@"Auto · %@", host];
}

- (void)updateConnection:(NSString *)kind
                 drawFPS:(double)drawFPS
                  netFPS:(double)netFPS
                decodeMS:(double)decodeMS
                    mbps:(double)mbps
                 dropped:(NSUInteger)dropped
               frameSize:(CGSize)frameSize {
    // Update even while closed: once a second costs nothing, and current
    // values are there the moment the panel opens.
    _statusValue.text = kind;
    _fpsValue.text = [NSString stringWithFormat:@"%.0f", drawFPS];
    _decodeValue.text = [NSString stringWithFormat:@"%.0f", decodeMS];
    _mbpsValue.text = [NSString stringWithFormat:@"%.1f", mbps];
    _netFPSValue.text = [NSString stringWithFormat:@"%.0f", netFPS];
    _droppedValue.text = [NSString stringWithFormat:@"%lu", (unsigned long)dropped];
    _sizeValue.text = (frameSize.width > 0)
        ? [NSString stringWithFormat:@"%.0f×%.0f", frameSize.width, frameSize.height]
        : @"—";
}

@end
