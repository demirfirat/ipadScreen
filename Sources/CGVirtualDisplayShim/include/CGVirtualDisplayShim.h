//
//  CGVirtualDisplayShim.h
//  iPadScreen
//
//  Declarations for the private CoreGraphics classes that create a virtual
//  display. macOS has no public API for this — the supported route is a
//  DriverKit extension with an entitlement Apple grants case by case — so
//  this uses the same undocumented classes BetterDisplay, DeskPad and
//  Chromium's test harness use.
//
//  Nothing is implemented in this target: the classes themselves live in
//  CoreGraphics and are resolved from there at run time. This header only
//  gives Swift the types to call them.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN

/// Configuration for a display that doesn't exist yet.
@interface CGVirtualDisplayDescriptor : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic, strong) dispatch_queue_t queue;

@end

/// One resolution the display can show.
@interface CGVirtualDisplayMode : NSObject

- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;

@end

/// Modes applied to a display after it is created.
@interface CGVirtualDisplaySettings : NSObject

/// 1 advertises Retina modes, which halves the resolution macOS lays out at.
@property (nonatomic) uint32_t hiDPI;
@property (nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;

@end

/// The virtual display. It exists while this object is alive.
@interface CGVirtualDisplay : NSObject

@property (nonatomic, readonly) CGDirectDisplayID displayID;

- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;

@end

NS_ASSUME_NONNULL_END
