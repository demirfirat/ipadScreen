#import <UIKit/UIKit.h>

@class IPSSettingsPanel;

@protocol IPSSettingsPanelDelegate <NSObject>
- (void)settingsPanelDidChangeHost:(NSString *)host;
- (void)settingsPanelDidRequestReconnect;
/// The user picked the link mode: USB (with Wi-Fi as fallback when no cable
/// is attached) or Wi-Fi only. The same setting as on the Mac.
- (void)settingsPanelDidSelectUSB:(BOOL)usb;
@end

/// Settings panel that slides in from the right edge of the screen.
///
/// iOS 6 has no built-in slide-over panel, so this one is drawn by hand. It
/// sits on top of the picture and mirroring keeps running behind it, so
/// the effect of a change is visible right away.
@interface IPSSettingsPanel : UIView

@property (nonatomic, assign) id<IPSSettingsPanelDelegate> delegate;
@property (nonatomic, readonly) BOOL isOpen;

/// `host` is the address entered by hand, or nil for automatic discovery.
- (id)initWithHost:(NSString *)host;

- (void)presentInView:(UIView *)parent;
- (void)open;
- (void)close;
- (void)toggle;

/// Reflects a link mode change made on the Mac, without calling the delegate.
- (void)setUSBSelected:(BOOL)usb;

/// Shows the address Bonjour found as the hint in the empty address field.
- (void)setDiscoveredHost:(NSString *)host name:(NSString *)name;

/// Updates connection status and stats. Everything that used to be in the
/// on-screen stats strip now lives here.
- (void)updateConnection:(NSString *)kind
                 drawFPS:(double)drawFPS
                  netFPS:(double)netFPS
                decodeMS:(double)decodeMS
                    mbps:(double)mbps
                 dropped:(NSUInteger)dropped
               frameSize:(CGSize)frameSize;

@end
