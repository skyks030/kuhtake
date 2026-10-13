#import "KTDeckLink.h"

#import <CoreMedia/CoreMedia.h>
#import <os/log.h>

#include <atomic>
#include <deque>
#include <mutex>
#include <vector>

#include "DeckLinkAPI.h"

// Defined in DeckLinkAPIDispatch.cpp, not declared in the headers.
extern bool IsDeckLinkAPIPresent(void);

NSNotificationName const KTDeckLinkDevicesDidChangeNotification = @"KTDeckLinkDevicesDidChangeNotification";

static os_log_t Log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.skyks030.kuhtake", "DeckLink"); });
    return log;
}

/// The host clock in seconds — `CMClockGetHostTimeClock`.
static double HostNow(void) {
    return CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
}

static NSString *TakeString(CFStringRef string) {
    return string ? (NSString *)CFBridgingRelease(string) : nil;
}

// MARK: - Discovery

namespace {

struct DeviceEntry {
    IDeckLink *deckLink;  // AddRef'ed while listed
    NSString *identifier;
    NSString *displayName;
};

std::mutex gDevicesMutex;
std::vector<DeviceEntry> gDevices;

/// Only devices that can capture; the SDK keeps notifying about the
/// others too (e.g. playback-only cards).
bool CanCapture(IDeckLink *deckLink) {
    IDeckLinkProfileAttributes *attributes = nullptr;
    if (deckLink->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attributes) != S_OK) return false;
    int64_t support = 0;
    bool result = attributes->GetInt(BMDDeckLinkVideoIOSupport, &support) == S_OK && (support & bmdDeviceSupportsCapture);
    attributes->Release();
    return result;
}

NSString *IdentifierOf(IDeckLink *deckLink, NSString *fallback) {
    IDeckLinkProfileAttributes *attributes = nullptr;
    int64_t persistentID = 0;
    if (deckLink->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attributes) == S_OK) {
        if (attributes->GetInt(BMDDeckLinkPersistentID, &persistentID) != S_OK) persistentID = 0;
        attributes->Release();
    }
    return persistentID > 0 ? [NSString stringWithFormat:@"%lld", persistentID] : fallback;
}

/// Keeps `gDevices` current (the SDK's DeviceNotification sample): the
/// `IDeckLink` of every arrived device is retained so its removal is
/// reported too.
class DiscoveryCallback final : public IDeckLinkDeviceNotificationCallback {
public:
    HRESULT STDMETHODCALLTYPE DeckLinkDeviceArrived(IDeckLink *deckLink) override {
        if (!CanCapture(deckLink)) return S_OK;
        CFStringRef name = nullptr;
        NSString *displayName = deckLink->GetDisplayName(&name) == S_OK ? TakeString(name) : @"DeckLink";
        NSString *identifier = IdentifierOf(deckLink, displayName);
        deckLink->AddRef();
        {
            std::lock_guard<std::mutex> guard(gDevicesMutex);
            gDevices.push_back({deckLink, identifier, displayName});
        }
        os_log(Log(), "Device arrived: %{public}@ (%{public}@)", displayName, identifier);
        [NSNotificationCenter.defaultCenter postNotificationName:KTDeckLinkDevicesDidChangeNotification object:nil];
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE DeckLinkDeviceRemoved(IDeckLink *deckLink) override {
        bool found = false;
        {
            std::lock_guard<std::mutex> guard(gDevicesMutex);
            for (auto it = gDevices.begin(); it != gDevices.end(); ++it) {
                if (it->deckLink == deckLink) {
                    os_log(Log(), "Device removed: %{public}@", it->displayName);
                    gDevices.erase(it);
                    found = true;
                    break;
                }
            }
        }
        if (found) {
            deckLink->Release();
            [NSNotificationCenter.defaultCenter postNotificationName:KTDeckLinkDevicesDidChangeNotification object:nil];
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, LPVOID *ppv) override {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    // Lives as long as the app.
    ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }
};

/// Starts discovery once, for the life of the app; false without a driver.
bool EnsureDiscovery() {
    static bool available = false;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        IDeckLinkDiscovery *discovery = CreateDeckLinkDiscoveryInstance();
        if (!discovery) {
            os_log_error(Log(), "DeckLinkAPI.framework not available — Desktop Video not installed?");
            return;
        }
        static DiscoveryCallback callback;
        if (discovery->InstallDeviceNotifications(&callback) != S_OK) {
            os_log_error(Log(), "Could not install device notifications");
            discovery->Release();
            return;
        }
        // Kept for the life of the app: uninstalling would stop the
        // notifications every capture relies on.
        available = true;
    });
    return available;
}

/// The listed device matching `identifier` (`nil`: the first), AddRef'ed.
IDeckLink *CopyDevice(NSString *identifier, NSString **displayName) {
    std::lock_guard<std::mutex> guard(gDevicesMutex);
    for (auto &entry : gDevices) {
        if (identifier == nil || [entry.identifier isEqualToString:identifier]) {
            entry.deckLink->AddRef();
            if (displayName) *displayName = entry.displayName;
            return entry.deckLink;
        }
    }
    return nullptr;
}

bool IsListed(IDeckLink *deckLink) {
    std::lock_guard<std::mutex> guard(gDevicesMutex);
    for (auto &entry : gDevices) {
        if (entry.deckLink == deckLink) return true;
    }
    return false;
}

/// Maps the stream's own clock onto the host clock: the offset is the
/// smallest (arrival − stream time) of the last `span` seconds — the
/// frames that came through fastest — so delivery jitter never shows up
/// in the timestamps, while the two clocks' slow drift is followed.
/// Picture and sound share it, so they stay in sync to the sample.
class ClockMap {
public:
    void reset() { window.clear(); }

    double update(double host, double sample) {
        while (!window.empty() && window.back().second >= sample) window.pop_back();
        window.emplace_back(host, sample);
        while (host - window.front().first > span) window.pop_front();
        return window.front().second;
    }

    bool isEmpty() const { return window.empty(); }
    double offset() const { return window.front().second; }

private:
    static constexpr double span = 10;
    /// (host time, sample), samples increasing: the front is the minimum.
    std::deque<std::pair<double, double>> window;
};

} // namespace

@implementation KTDeckLinkDeviceInfo

- (instancetype)initWithIdentifier:(NSString *)identifier displayName:(NSString *)displayName {
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _displayName = [displayName copy];
    }
    return self;
}

@end

@implementation KTDeckLinkDiscovery

+ (BOOL)isDriverAvailable {
    return EnsureDiscovery() && IsDeckLinkAPIPresent();
}

+ (NSString *)driverVersion {
    if (!IsDeckLinkAPIPresent()) return nil;
    IDeckLinkAPIInformation *info = CreateDeckLinkAPIInformationInstance();
    if (!info) return nil;
    CFStringRef version = nullptr;
    NSString *result = info->GetString(BMDDeckLinkAPIVersion, &version) == S_OK ? TakeString(version) : nil;
    info->Release();
    return result;
}

+ (NSArray<KTDeckLinkDeviceInfo *> *)devices {
    if (!EnsureDiscovery()) return @[];
    std::lock_guard<std::mutex> guard(gDevicesMutex);
    NSMutableArray *result = [NSMutableArray array];
    for (auto &entry : gDevices) {
        [result addObject:[[KTDeckLinkDeviceInfo alloc] initWithIdentifier:entry.identifier displayName:entry.displayName]];
    }
    return result;
}

@end

// MARK: - Capture

@interface KTDeckLinkCapture ()
- (void)handleFormatChange:(BMDVideoInputFormatChangedEvents)events mode:(IDeckLinkDisplayMode *)mode flags:(BMDDetectedVideoInputFormatFlags)flags;
- (void)handleVideoFrame:(IDeckLinkVideoInputFrame *)videoFrame audioPacket:(IDeckLinkAudioInputPacket *)audioPacket;
@end

namespace {

class InputCallback final : public IDeckLinkInputCallback {
public:
    explicit InputCallback(KTDeckLinkCapture *owner) : owner(owner) {}

    HRESULT STDMETHODCALLTYPE VideoInputFormatChanged(BMDVideoInputFormatChangedEvents events, IDeckLinkDisplayMode *mode, BMDDetectedVideoInputFormatFlags flags) override {
        [owner handleFormatChange:events mode:mode flags:flags];
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE VideoInputFrameArrived(IDeckLinkVideoInputFrame *videoFrame, IDeckLinkAudioInputPacket *audioPacket) override {
        @autoreleasepool {
            [owner handleVideoFrame:videoFrame audioPacket:audioPacket];
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, LPVOID *ppv) override {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refCount; }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG value = --refCount;
        if (value == 0) delete this;
        return value;
    }

private:
    __weak KTDeckLinkCapture *owner;
    std::atomic<ULONG> refCount{1};
};

} // namespace

@implementation KTDeckLinkCapture {
    NSString *_wantedIdentifier;
    /// Opening, closing and supervision.
    dispatch_queue_t _queue;
    dispatch_source_t _watchdog;
    id _devicesObserver;

    // Only touched on `_queue`.
    BOOL _isStarted;
    IDeckLink *_deckLink;
    IDeckLinkInput *_input;
    InputCallback *_callback;
    /// No new attempt before this (after the input was in use / failed).
    double _retryAt;

    // Guarded by `_mutex` (also taken by the capture thread for the whole
    // of every callback, so after `close` no handler runs any more).
    std::mutex _mutex;
    BOOL _isOpen;
    BMDDisplayMode _mode;
    BMDPixelFormat _pixelFormat;
    ClockMap _clock;
    double _lastCallbackAt;
    std::atomic<KTDeckLinkCaptureState> _state;
    NSString *_activeDeviceName;
    NSString *_activeFormatName;
    std::atomic<NSInteger> _restartCount;
}

/// Frames stop for this long while the device is still there: restart.
static const double kStallTimeout = 3;
/// Input in use by another app, or refused: try again after this.
static const double kRetryInterval = 2;

- (instancetype)initWithDeviceIdentifier:(NSString *)identifier {
    if ((self = [super init])) {
        _wantedIdentifier = [identifier copy];
        _queue = dispatch_queue_create("kuhtake.decklink.capture", DISPATCH_QUEUE_SERIAL);
        _state = KTDeckLinkCaptureStateWaitingForDevice;
    }
    return self;
}

- (void)dealloc {
    // Not via `_queue`: the last reference may go away on it.
    [self shutDown];
}

- (KTDeckLinkCaptureState)state {
    return _state.load();
}

- (NSString *)activeDeviceName {
    std::lock_guard<std::mutex> guard(_mutex);
    return _activeDeviceName;
}

- (NSString *)activeFormatName {
    std::lock_guard<std::mutex> guard(_mutex);
    return _activeFormatName;
}

- (NSInteger)restartCount {
    return _restartCount.load();
}

- (void)setState:(KTDeckLinkCaptureState)state {
    if (_state.exchange(state) == state) return;
    void (^handler)(KTDeckLinkCaptureState) = self.stateHandler;
    if (handler) handler(state);
}

- (void)start {
    __weak KTDeckLinkCapture *weakSelf = self;
    dispatch_async(_queue, ^{
        KTDeckLinkCapture *capture = weakSelf;
        if (!capture || capture->_isStarted) return;
        capture->_isStarted = YES;
        EnsureDiscovery();
        capture->_devicesObserver = [NSNotificationCenter.defaultCenter addObserverForName:KTDeckLinkDevicesDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *) {
            KTDeckLinkCapture *observer = weakSelf;
            if (!observer) return;
            dispatch_async(observer->_queue, ^{ [weakSelf supervise:YES]; });
        }];
        capture->_watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, capture->_queue);
        dispatch_source_set_timer(capture->_watchdog, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(capture->_watchdog, ^{ [weakSelf supervise:NO]; });
        dispatch_resume(capture->_watchdog);
        [capture supervise:YES];
    });
}

- (void)stop {
    dispatch_sync(_queue, ^{ [self shutDown]; });
}

/// On `_queue` (or in `dealloc`, when nothing else can run).
- (void)shutDown {
    if (!_isStarted) return;
    _isStarted = NO;
    if (_watchdog) dispatch_source_cancel(_watchdog);
    _watchdog = nil;
    if (_devicesObserver) [NSNotificationCenter.defaultCenter removeObserver:_devicesObserver];
    _devicesObserver = nil;
    [self close];
}

/// On `_queue`: opens the device when it's there and nothing runs, closes
/// it when it's gone, restarts a stream that stopped delivering.
/// `devicesChanged`: after a notification — retry at once.
- (void)supervise:(BOOL)devicesChanged {
    if (!_isStarted) return;
    double now = HostNow();
    if (_input) {
        if (!IsListed(_deckLink)) {
            os_log(Log(), "Device gone — waiting for it to come back");
            _restartCount++;
            [self close];
            [self setState:KTDeckLinkCaptureStateWaitingForDevice];
        } else {
            double lastCallback;
            {
                std::lock_guard<std::mutex> guard(_mutex);
                lastCallback = _lastCallbackAt;
            }
            if (now - lastCallback > kStallTimeout) {
                os_log(Log(), "No frames for %.1f s — restarting the input", now - lastCallback);
                _restartCount++;
                [self close];
            }
        }
    }
    if (!_input && (devicesChanged || now >= _retryAt)) {
        [self open];
    }
}

/// On `_queue`. The SDK's capture sequence: callback, video input with
/// automatic format detection, audio input, start.
- (void)open {
    NSString *displayName = nil;
    IDeckLink *deckLink = CopyDevice(_wantedIdentifier, &displayName);
    if (!deckLink && _wantedIdentifier) {
        // A device picked earlier isn't there — any other will do.
        deckLink = CopyDevice(nil, &displayName);
    }
    if (!deckLink) {
        [self setState:KTDeckLinkCaptureStateWaitingForDevice];
        return;
    }
    IDeckLinkInput *input = nullptr;
    if (deckLink->QueryInterface(IID_IDeckLinkInput, (void **)&input) != S_OK) {
        deckLink->Release();
        [self failWithState:KTDeckLinkCaptureStateFailed reason:@"no input interface" result:E_NOINTERFACE];
        return;
    }
    bool detectsFormat = false;
    IDeckLinkProfileAttributes *attributes = nullptr;
    if (deckLink->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attributes) == S_OK) {
        if (attributes->GetFlag(BMDDeckLinkSupportsInputFormatDetection, &detectsFormat) != S_OK) detectsFormat = false;
        attributes->Release();
    }

    // The detected format replaces this as soon as a signal is seen.
    BMDDisplayMode mode = bmdModeHD1080p25;
    BMDPixelFormat pixelFormat = bmdFormat8BitYUV;
    {
        std::lock_guard<std::mutex> guard(_mutex);
        _isOpen = YES;
        _mode = mode;
        _pixelFormat = pixelFormat;
        _clock.reset();
        _lastCallbackAt = HostNow();
        _activeDeviceName = displayName;
    }
    InputCallback *callback = new InputCallback(self);
    HRESULT result = input->SetCallback(callback);
    if (result == S_OK) {
        result = input->EnableVideoInput(mode, pixelFormat, detectsFormat ? bmdVideoInputEnableFormatDetection : bmdVideoInputFlagDefault);
    }
    if (result == S_OK) {
        // Channels 1+2 of the embedded audio, at full resolution.
        result = input->EnableAudioInput(bmdAudioSampleRate48kHz, bmdAudioSampleType32bitInteger, 2);
    }
    if (result == S_OK) {
        result = input->StartStreams();
    }
    _deckLink = deckLink;
    _input = input;
    _callback = callback;
    if (result != S_OK) {
        [self close];
        // E_ACCESSDENIED: another application captures from this input.
        BOOL inUse = result == E_ACCESSDENIED;
        [self failWithState:inUse ? KTDeckLinkCaptureStateInUse : KTDeckLinkCaptureStateFailed reason:inUse ? @"input in use by another application" : @"could not start the input" result:result];
        return;
    }
    os_log(Log(), "Capturing from %{public}@ (format detection %{public}s)", displayName, detectsFormat ? "on" : "off");
    [self setState:KTDeckLinkCaptureStateStarting];
}

- (void)failWithState:(KTDeckLinkCaptureState)state reason:(NSString *)reason result:(HRESULT)result {
    os_log_error(Log(), "Capture failed: %{public}@ (0x%08x) — retrying in %.0f s", reason, (unsigned)result, kRetryInterval);
    _retryAt = HostNow() + kRetryInterval;
    [self setState:state];
}

/// On `_queue`. Returns once no callback runs any more.
- (void)close {
    {
        std::lock_guard<std::mutex> guard(_mutex);
        _isOpen = NO;
        _activeDeviceName = nil;
        _activeFormatName = nil;
    }
    if (_input) {
        _input->StopStreams();
        _input->SetCallback(nullptr);
        _input->DisableAudioInput();
        _input->DisableVideoInput();
        _input->Release();
        _input = nullptr;
    }
    if (_callback) {
        _callback->Release();
        _callback = nullptr;
    }
    if (_deckLink) {
        _deckLink->Release();
        _deckLink = nullptr;
    }
}

// MARK: Callbacks (capture thread)

/// The SDK's AutomaticModeDetection sample: pause, re-enable with the
/// detected mode and pixel format, flush, start — only when either
/// actually changed. (The driver repeats "colorspace changed" for every
/// frame while the requested pixel format differs from the signal's, e.g.
/// 8-bit requested for a 10-bit signal; that's intended — the hardware
/// converts — and must not restart anything.)
- (void)handleFormatChange:(BMDVideoInputFormatChangedEvents)events mode:(IDeckLinkDisplayMode *)mode flags:(BMDDetectedVideoInputFormatFlags)flags {
    std::lock_guard<std::mutex> guard(_mutex);
    if (!_isOpen || !_input) return;
    BMDDisplayMode newMode = mode->GetDisplayMode();
    BMDPixelFormat newPixelFormat = (flags & bmdDetectedVideoInputRGB444) ? bmdFormat8BitBGRA : bmdFormat8BitYUV;
    if (newMode == _mode && newPixelFormat == _pixelFormat) return;

    CFStringRef name = nullptr;
    NSString *modeName = mode->GetName(&name) == S_OK ? TakeString(name) : @"?";
    os_log(Log(), "Input format: %{public}@ %{public}s", modeName, newPixelFormat == bmdFormat8BitBGRA ? "RGB" : "YUV 4:2:2");
    _input->PauseStreams();
    HRESULT result = _input->EnableVideoInput(newMode, newPixelFormat, bmdVideoInputEnableFormatDetection);
    _input->FlushStreams();
    _input->StartStreams();
    if (result == S_OK) {
        _mode = newMode;
        _pixelFormat = newPixelFormat;
        _activeFormatName = [NSString stringWithFormat:@"%@ · %s", modeName, newPixelFormat == bmdFormat8BitBGRA ? "RGB 4:4:4" : "YUV 4:2:2"];
    } else {
        os_log_error(Log(), "Could not switch to the detected format (0x%08x)", (unsigned)result);
    }
    // The stream's clock may start over.
    _clock.reset();
}

- (void)handleVideoFrame:(IDeckLinkVideoInputFrame *)videoFrame audioPacket:(IDeckLinkAudioInputPacket *)audioPacket {
    double arrival = HostNow();
    std::lock_guard<std::mutex> guard(_mutex);
    if (!_isOpen) return;
    _lastCallbackAt = arrival;

    double frameDuration = 0;
    if (videoFrame) {
        if (videoFrame->GetFlags() & bmdFrameHasNoInputSource) {
            // Frames keep coming without a signal — nothing to show or hear.
            [self setState:KTDeckLinkCaptureStateNoSignal];
            return;
        }
        BMDTimeValue streamTime = 0, duration = 0;
        if (videoFrame->GetStreamTime(&streamTime, &duration, 1000000000) == S_OK) {
            double start = streamTime / 1e9;
            frameDuration = duration / 1e9;
            // The frame is complete (and handed over) only after its
            // duration; the offset covers that plus the delivery.
            double offset = _clock.update(arrival, arrival - start);
            [self deliverVideoFrame:videoFrame time:start + offset - frameDuration arrival:arrival];
        }
        if (!_activeFormatName) [self describeCurrentMode];
        [self setState:KTDeckLinkCaptureStateRunning];
    }
    if (audioPacket) {
        BMDTimeValue packetTime = 0;
        void *bytes = nullptr;
        long frames = audioPacket->GetSampleFrameCount();
        if (frames > 0 && audioPacket->GetPacketTime(&packetTime, 1000000000) == S_OK && audioPacket->GetBytes(&bytes) == S_OK && bytes) {
            double start = packetTime / 1e9;
            double offset = _clock.isEmpty() ? _clock.update(arrival, arrival - start) : _clock.offset();
            if (frameDuration == 0) frameDuration = frames / 48000.0;
            double time = MIN(start + offset - frameDuration, arrival);
            void (^handler)(const int32_t *, NSInteger, NSInteger, double) = self.audioHandler;
            if (handler) handler((const int32_t *)bytes, frames, 2, time);
        }
    }
}

/// Under `_mutex`: names the mode that was requested at open time (no
/// format change event comes when the signal already matches it).
- (void)describeCurrentMode {
    IDeckLinkDisplayMode *mode = nullptr;
    if (!_input || _input->GetDisplayMode(_mode, &mode) != S_OK || !mode) return;
    CFStringRef name = nullptr;
    NSString *modeName = mode->GetName(&name) == S_OK ? TakeString(name) : @"?";
    mode->Release();
    _activeFormatName = [NSString stringWithFormat:@"%@ · %s", modeName, _pixelFormat == bmdFormat8BitBGRA ? "RGB 4:4:4" : "YUV 4:2:2"];
}

- (void)deliverVideoFrame:(IDeckLinkVideoInputFrame *)videoFrame time:(double)time arrival:(double)arrival {
    void (^handler)(CVPixelBufferRef, double) = self.videoHandler;
    if (!handler) return;
    IDeckLinkMacVideoBuffer *macBuffer = nullptr;
    if (videoFrame->QueryInterface(IID_IDeckLinkMacVideoBuffer, (void **)&macBuffer) != S_OK) return;
    void *pixelBuffer = nullptr;
    HRESULT result = macBuffer->CreateCVPixelBufferRef(&pixelBuffer);
    macBuffer->Release();
    if (result != S_OK || !pixelBuffer) return;
    CVPixelBufferRef buffer = (CVPixelBufferRef)pixelBuffer;
    // SD is Rec. 601, everything else Rec. 709 — tagged so Core Image
    // converts the colors correctly.
    BOOL isSD = videoFrame->GetHeight() <= 576;
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, isSD ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, isSD ? kCVImageBufferColorPrimaries_SMPTE_C : kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    handler(buffer, MIN(time, arrival));
    CVPixelBufferRelease(buffer);
}

@end
