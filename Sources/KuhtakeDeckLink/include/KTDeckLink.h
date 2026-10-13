// Blackmagic DeckLink/UltraStudio capture through the DeckLink SDK
// (Desktop Video's own API — what Media Express, OBS and FFmpeg use),
// wrapped for Swift. Follows the SDK's own samples: device discovery with
// arrival/removal notifications (DeviceNotification.cpp), automatic input
// format detection (AutomaticModeDetection.cpp), picture and sound from
// one stream on one clock.
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted (on a DeckLink thread) whenever a device arrives or goes away.
extern NSNotificationName const KTDeckLinkDevicesDidChangeNotification;

/// One device (sub-device, on multi-input cards) that can capture.
@interface KTDeckLinkDeviceInfo : NSObject
/// Stable across reconnects and restarts (`BMDDeckLinkPersistentID`).
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *displayName;
@end

@interface KTDeckLinkDiscovery : NSObject
/// Whether Desktop Video's DeckLinkAPI.framework could be loaded.
+ (BOOL)isDriverAvailable;
/// The installed Desktop Video version, e.g. "14.2" (nil without driver).
+ (nullable NSString *)driverVersion;
/// The capture devices connected right now. Never blocks on the driver.
+ (NSArray<KTDeckLinkDeviceInfo *> *)devices;
@end

typedef NS_ENUM(NSInteger, KTDeckLinkCaptureState) {
    /// No (matching) device connected — waiting for it to arrive.
    KTDeckLinkCaptureStateWaitingForDevice,
    /// Streams started, nothing arrived yet.
    KTDeckLinkCaptureStateStarting,
    /// Frames arrive, but the input has no signal.
    KTDeckLinkCaptureStateNoSignal,
    KTDeckLinkCaptureStateRunning,
    /// Another application holds the input (retried every few seconds).
    KTDeckLinkCaptureStateInUse,
    /// The driver refused to start the input (retried every few seconds).
    KTDeckLinkCaptureStateFailed,
};

/// Captures one device's input — picture and sound together — and keeps
/// it running: follows format changes of the signal, reopens the device
/// the moment it reappears after a disconnect, restarts a stream that
/// stops delivering. Set the handlers before `start`.
@interface KTDeckLinkCapture : NSObject
/// `nil`: the first device found.
- (instancetype)initWithDeviceIdentifier:(nullable NSString *)identifier NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// On the capture thread: a picture (8-bit 4:2:2 or BGRA, color
/// attachments set) and when it was captured, in host-clock seconds (the
/// same clock as `CMClockGetHostTimeClock`). Must return quickly.
@property (nonatomic, copy, nullable) void (^videoHandler)(CVPixelBufferRef pixelBuffer, double time);
/// On the capture thread: interleaved 32-bit integer PCM, 48 kHz, stamped
/// on the same clock as the pictures.
@property (nonatomic, copy, nullable) void (^audioHandler)(const int32_t *samples, NSInteger frameCount, NSInteger channelCount, double time);
/// On any thread, whenever the state changes.
@property (nonatomic, copy, nullable) void (^stateHandler)(KTDeckLinkCaptureState state);

@property (nonatomic, readonly) KTDeckLinkCaptureState state;
/// The device being captured right now, if any.
@property (nonatomic, readonly, copy, nullable) NSString *activeDeviceName;
/// The signal format currently captured, e.g. "1080p25 · YUV 4:2:2".
@property (nonatomic, readonly, copy, nullable) NSString *activeFormatName;
/// How often the input had to be reopened (stalls, disconnects, failures).
@property (nonatomic, readonly) NSInteger restartCount;

- (void)start;
/// Returns once no handler runs any more.
- (void)stop;
@end

NS_ASSUME_NONNULL_END
