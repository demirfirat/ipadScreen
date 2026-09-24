#import <UIKit/UIKit.h>
#import "IPSViewController.h"

/// Port the Mac's server listens on (Wi-Fi).
static const uint16_t kPort = 8765;
/// Port we listen on in USB mode; the Mac connects to it through `iproxy`.
static const uint16_t kUSBPort = 8766;

@interface IPSAppDelegate : NSObject <UIApplicationDelegate, UIAlertViewDelegate>
@property (nonatomic, retain) UIWindow *window;
@end

@implementation IPSAppDelegate {
    IPSViewController *_vc;
}
@synthesize window = _window;

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)options {

    // Keep the screen awake; this device is acting as a display.
    application.idleTimerDisabled = YES;
    [application setStatusBarHidden:YES withAnimation:UIStatusBarAnimationNone];

    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    self.window.backgroundColor = [UIColor blackColor];

    // USB and Wi-Fi are both open; whichever connects gets used. With the
    // cable attached the Mac connects over USB and Wi-Fi's bandwidth limit
    // no longer applies. The Mac's Wi-Fi address is found over Bonjour
    // unless one was entered by hand.
    _vc = [[IPSViewController alloc] initWithPort:kPort usbPort:kUSBPort];
    self.window.rootViewController = _vc;
    [self.window makeKeyAndVisible];

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // idleTimerDisabled resets when the app goes to the background; set it
    // again every time we come to the foreground.
    application.idleTimerDisabled = YES;
}

- (void)dealloc {
    [_vc release];
    [_window release];
    [super dealloc];
}

@end

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int ret = UIApplicationMain(argc, argv, nil, @"IPSAppDelegate");
    [pool release];
    return ret;
}
