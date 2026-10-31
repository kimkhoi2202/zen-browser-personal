/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef mozilla_ZenPipNativeChrome_h_
#define mozilla_ZenPipNativeChrome_h_

// Native macOS chrome for the Picture-in-Picture player window: AppKit Liquid
// Glass controls (NSGlassEffectView, SF Symbols, NSSlider), the physical
// drag/flick/resize motion and the display containment.
//
// This interface is deliberately free of Gecko types. The implementation is
// pure AppKit (compiled with ARC) and only talks to its owner through
// zen::pip::ChromeHost, so the same code runs inside the browser and in the
// standalone test harness (tests/harness).

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

namespace zen::pip {

// Receives user intents from the native chrome. Called on the main thread,
// synchronously from AppKit event handling; implementations that may tear the
// player down in response must defer that work.
//
// Actions (value / detail):
//   "toggle-play", "close", "return", "toggle-mute", "toggle-captions"
//   "seek-relative"    value: seconds (negative = back)
//   "scrub-start" / "scrub" / "scrub-end"   value: position in [0, 1]
//   "set-rate"         value: playback rate
//   "caption-size"     detail: "small" | "medium" | "large"
//   "key"              value: macOS virtual key code,
//                      detail: JSON {key, shift, alt, ctrl, meta}
//   "controls"         value: 1 when shown, 0 when hidden,
//                      detail: JSON {timelineTop} (CSS px from the top)
//   "placement"        detail: JSON {dock, fx, fy, width, height}
//   "tucked"           value: 1 when minimized to the edge, 0 when restored
//   "window-will-close"
class ChromeHost {
 public:
  virtual void OnChromeAction(const char* aAction, double aValue,
                              const char* aDetail) = 0;

 protected:
  virtual ~ChromeHost() = default;
};

}  // namespace zen::pip

@interface ZenPipPlayerChrome : NSObject

// Whether real Liquid Glass (NSGlassEffectView, macOS 26+) is available.
// Older systems get the same controls on NSVisualEffectView materials.
+ (BOOL)hasLiquidGlass;

// Attaches the chrome above the window's existing content. The window keeps
// its own content view; the chrome adds one overlay subview on top of it.
- (nullable instancetype)initWithPlayerWindow:(NSWindow*)aWindow
                                         host:(zen::pip::ChromeHost*)aHost;

- (void)setPlaying:(BOOL)aPlaying;
- (void)setMuted:(BOOL)aMuted;
- (void)setPlaybackRate:(double)aRate;
- (void)setCurrentTime:(double)aCurrentTime
              duration:(double)aDuration
              seekable:(BOOL)aSeekable
                  live:(BOOL)aLive;
- (void)setCaptionsAvailable:(BOOL)aAvailable enabled:(BOOL)aEnabled;
- (void)setCaptionSize:(NSString*)aSize;
// Localized labels (see ZenPipNativeControls.sys.mjs for the keys).
- (void)setStrings:(NSDictionary<NSString*, NSString*>*)aStrings;
// Intrinsic video size; the player keeps its anchor and adopts the aspect.
- (void)setVideoSize:(NSSize)aSize;
// The browser window hosting the source tab. The player stays fully inside
// the usable area of the display that window is on, and follows it.
- (void)setSourceWindow:(nullable NSWindow*)aWindow;
// Tunables: edgeGap, springResponse, springDamping, decelerationRate,
// flickSpeed, magnetDistance, idleHideDelay, carryWithTwoFingers.
- (void)setConfiguration:(NSDictionary<NSString*, id>*)aConfiguration;

- (void)revealControlsSticky:(BOOL)aSticky;
// Moves keyboard focus onto the native controls (Tab from the player).
- (void)focusControls;
- (void)minimize;
- (void)restore;

// Introspection for tests and diagnostics.
- (NSDictionary<NSString*, id>*)debugState;
// Test hooks that drive the real code paths: a drag/flick of the window, a
// resize from a handle, and a click on a named control.
- (void)testDragBy:(NSPoint)aDelta
          duration:(NSTimeInterval)aDuration
           release:(NSPoint)aReleaseVelocity;
- (void)testResizeHandle:(NSString*)aHandle by:(NSPoint)aDelta;
// Two-finger carry: synthesized continuous scroll events (began, changed,
// ended) through the real scroll handler; `aDelta` is the finger travel.
- (void)testCarryBy:(NSPoint)aDelta;
- (BOOL)testClickControl:(NSString*)aName;
- (void)testKey:(unsigned short)aKeyCode
     characters:(NSString*)aCharacters
      modifiers:(NSEventModifierFlags)aModifiers;

// Removes the overlay, observers, timers, display link and the minimized
// panel. Safe to call more than once; also runs when the window closes.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

#endif  // mozilla_ZenPipNativeChrome_h_
