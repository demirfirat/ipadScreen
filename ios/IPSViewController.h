#import <UIKit/UIKit.h>

@interface IPSViewController : UIViewController
/// Sets up the Wi-Fi and USB connections together and shows frames from
/// whichever delivers them. With the cable attached the Mac connects over
/// USB and Wi-Fi's bandwidth limit no longer applies.
///
/// The Mac's Wi-Fi address is discovered over Bonjour. An address entered
/// in the settings panel overrides discovery and is remembered.
- (id)initWithPort:(uint16_t)port usbPort:(uint16_t)usbPort;
@end
