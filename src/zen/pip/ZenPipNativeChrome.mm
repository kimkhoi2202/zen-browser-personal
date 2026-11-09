/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Compiled with ARC (see moz.build). Pure AppKit: no Gecko headers here.

#import "ZenPipNativeChrome.h"

#import <CoreText/CoreText.h>
#import <MediaAccessibility/MediaAccessibility.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <iterator>
#include <optional>
#include <vector>

#include "ZenPipGeometry.h"

#if !__has_feature(objc_arc)
#  error "ZenPipNativeChrome.mm must be compiled with -fobjc-arc"
#endif

// NSGlassEffectView.effectIsInteractive is new in macOS 27. Gecko builds
// against Mozilla's pinned 26.5 SDK, so declare it when the SDK lacks it; it
// is only ever used behind a runtime availability check.
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 270000
@interface NSGlassEffectView (ZenPipMacOS27)
@property BOOL effectIsInteractive API_AVAILABLE(macos(27.0));
@end
#endif

using namespace zen::pip;

namespace {

// Reference player width at which the controls use their nominal sizes; they
// scale between 72% and 118% of that, never below usable hit targets.
constexpr CGFloat kReferenceWidth = 640;
// The resize border: 9 pt bands along the edges and 18 pt squares at the
// corners. It covers AppKit's own resize areas (up to about 7 pt in from the
// edges near the corners and 13 pt in along a corner's diagonal on macOS 27).
constexpr CGFloat kResizeBand = 9;
constexpr CGFloat kResizeCornerBand = 18;
constexpr CGFloat kDragThreshold = 3;
// How close (pt) a frame must be to an edge of its area to count as docked.
constexpr double kDockTolerance = 2;
// Crossing onto another display while dragging: the drag must push past the
// edge by a quarter of the player (within these bounds, in points) with the
// pointer at least kCrossDisplayPointerInset inside the other display, and
// keep that up for kCrossDisplayHold seconds. Until then the player stays at
// the edge of its display, so throwing or pushing it into a corner shared
// with another display always lands in that corner.
constexpr double kCrossDisplayPushFraction = 0.25;
constexpr double kCrossDisplayPushMin = 48;
constexpr double kCrossDisplayPushMax = 160;
constexpr CGFloat kCrossDisplayPointerInset = 16;
constexpr NSTimeInterval kCrossDisplayHold = 0.22;
// Released while pushed this far (a fraction of its width) past the left or
// right edge of its display, with no display beyond that edge, the player
// stashes into the edge.
constexpr double kStashPushFraction = 0.4;
// The tab a stashed player leaves at the screen edge.
constexpr CGFloat kTabWidth = 22;
constexpr CGFloat kTabHeight = 60;
constexpr CGFloat kTabGap = 8;  // between the tabs of several players
constexpr NSTimeInterval kInitialRevealDuration = 2.5;
// Buffering shows a spinner only once it lasts, so short stalls don't flash.
constexpr NSTimeInterval kSpinnerDelay = 0.4;
// Motion. Exits are quicker than entrances; the controls fading after a
// while without activity are softer than the ones the pointer left.
constexpr NSTimeInterval kRevealDuration = 0.15;
constexpr NSTimeInterval kHideDuration = 0.15;
constexpr NSTimeInterval kIdleHideDuration = 0.25;
constexpr NSTimeInterval kPointerLeftGrace = 0.3;
constexpr NSTimeInterval kEntranceDuration = 0.25;
constexpr NSTimeInterval kExitFadeDuration = 0.15;
constexpr NSTimeInterval kShrinkDuration = 0.25;
constexpr NSTimeInterval kStashDuration = 0.2;
constexpr NSTimeInterval kUnstashDuration = 0.25;
// Apple's dark dimming layer for Clear glass over bright content (HIG
// "Materials": "consider adding a dark dimming layer of 35% opacity").
constexpr CGFloat kDimmingOpacity = 0.35;
// The speeds the speed menu offers.
constexpr double kSpeedMenuRates[] = {0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0};

// macOS virtual key codes.
constexpr unsigned short kKeyReturn = 36;
constexpr unsigned short kKeyTab = 48;
constexpr unsigned short kKeySpace = 49;
constexpr unsigned short kKeyEscape = 53;
constexpr unsigned short kKeyW = 13;
constexpr unsigned short kKeyP = 35;
constexpr unsigned short kKeyM = 46;
constexpr unsigned short kKeyEnter = 76;
constexpr unsigned short kKeyHome = 115;
constexpr unsigned short kKeyEnd = 119;
constexpr unsigned short kKeyLeft = 123;
constexpr unsigned short kKeyRight = 124;

struct Config {
  double edgeGap = 10;
  SpringParams spring;
  ReleaseParams release;
  SizeLimits limits;
  NSTimeInterval idleHideDelay = 2.4;
  bool carryWithTwoFingers = true;
  bool rightToLeft = false;
};

struct Appearance {
  bool reduceMotion = false;
  bool increaseContrast = false;
  bool voiceOver = false;
};

Appearance CurrentAppearance() {
  NSWorkspace* ws = NSWorkspace.sharedWorkspace;
  return {ws.accessibilityDisplayShouldReduceMotion,
          ws.accessibilityDisplayShouldIncreaseContrast, ws.isVoiceOverEnabled};
}

Box ToRect(NSRect aRect) {
  return {aRect.origin.x, aRect.origin.y, aRect.size.width, aRect.size.height};
}

NSRect ToNSRect(const Box& aRect) {
  return NSMakeRect(aRect.x, aRect.y, aRect.width, aRect.height);
}

// Where the pointer was for a mouse event, in screen coordinates. Taken from
// the event's global location rather than its window location, because the
// player may have moved or resized since the window location was computed.
NSPoint EventScreenLocation(NSEvent* aEvent) {
  CGEventRef event = aEvent.CGEvent;
  NSScreen* primary = NSScreen.screens.firstObject;
  if (!event || !primary) {
    return NSEvent.mouseLocation;
  }
  // Quartz puts the origin at the top left of the primary display.
  CGPoint p = CGEventGetLocation(event);
  return NSMakePoint(p.x, NSMaxY(primary.frame) - p.y);
}

CGDirectDisplayID DisplayID(NSScreen* aScreen) {
  return [aScreen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
}

// The usable area of every display, in NSScreen.screens order.
std::vector<Box> ScreenAreas(double aGap) {
  std::vector<Box> areas;
  for (NSScreen* screen in NSScreen.screens) {
    areas.push_back(AllowedArea(ToRect(screen.visibleFrame), aGap));
  }
  return areas;
}

NSString* FormatTime(double aSeconds) {
  if (!std::isfinite(aSeconds) || aSeconds < 0) {
    aSeconds = 0;
  }
  long total = lround(floor(aSeconds));
  long h = total / 3600, m = (total % 3600) / 60, s = total % 60;
  return h ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", h, m, s]
           : [NSString stringWithFormat:@"%ld:%02ld", m, s];
}

NSString* FormatRate(double aRate) {
  static NSNumberFormatter* formatter = [] {
    NSNumberFormatter* f = [[NSNumberFormatter alloc] init];
    f.minimumFractionDigits = 0;
    f.maximumFractionDigits = 2;
    f.minimumIntegerDigits = 1;
    return f;
  }();
  return [[formatter stringFromNumber:@(aRate)] stringByAppendingString:@"×"];
}

bool SameRate(double aA, double aB) { return std::abs(aA - aB) < 0.001; }

// Fills a localized template's %1$@ and %2$@.
NSString* FillTemplate(NSString* aTemplate, NSString* aFirst,
                       NSString* _Nullable aSecond = nil) {
  NSString* filled = [aTemplate stringByReplacingOccurrencesOfString:@"%1$@"
                                                          withString:aFirst];
  return aSecond ? [filled stringByReplacingOccurrencesOfString:@"%2$@"
                                                     withString:aSecond]
                 : filled;
}

// `aVariableValue` in [0, 1] fills a variable symbol (macOS 13+) that far.
NSImage* Symbol(NSString* aName, CGFloat aPointSize, NSFontWeight aWeight,
                double aVariableValue = -1) {
  NSImage* image = nil;
  if (aVariableValue >= 0) {
    if (@available(macOS 13.0, *)) {
      image = [NSImage imageWithSystemSymbolName:aName
                                   variableValue:aVariableValue
                        accessibilityDescription:nil];
    }
  }
  if (!image) {
    image = [NSImage imageWithSystemSymbolName:aName
                      accessibilityDescription:nil];
  }
  NSImageSymbolConfiguration* config = [NSImageSymbolConfiguration
      configurationWithPointSize:aPointSize
                          weight:aWeight
                           scale:NSImageSymbolScaleMedium];
  return [image imageWithSymbolConfiguration:config];
}

NSString* JSONString(NSDictionary* aObject) {
  NSData* data = [NSJSONSerialization dataWithJSONObject:aObject
                                                 options:0
                                                   error:nil];
  return data ? [[NSString alloc] initWithData:data
                                      encoding:NSUTF8StringEncoding]
              : @"{}";
}

CAMediaTimingFunction* EaseOut() {  // quartic
  return [CAMediaTimingFunction functionWithControlPoints:0.165:0.84:0.44:1];
}

CAMediaTimingFunction* EaseIn() {  // cubic
  return [CAMediaTimingFunction functionWithControlPoints:
                                                     0.55:0.055:0.675:0.19];
}

CAMediaTimingFunction* EaseInOut() {  // cubic
  return [CAMediaTimingFunction functionWithControlPoints:0.645:0.045:0.355:1];
}

// A light tick on Force Touch trackpads (nothing on other devices).
void PerformAlignmentFeedback() {
  [NSHapticFeedbackManager.defaultPerformer
      performFeedbackPattern:NSHapticFeedbackPatternAlignment
             performanceTime:NSHapticFeedbackPerformanceTimeNow];
}

// "rgba(...)" for a MediaAccessibility color (+1 reference, released here)
// and its separate opacity setting.
NSString* CSSColor(CGColorRef aColor, CGFloat aOpacity) {
  NSColor* color = aColor
                       ? [[NSColor colorWithCGColor:aColor]
                             colorUsingColorSpace:NSColorSpace.sRGBColorSpace]
                       : nil;
  if (aColor) {
    CFRelease(aColor);
  }
  if (!color) {
    return @"transparent";
  }
  return [NSString
      stringWithFormat:@"rgba(%ld, %ld, %ld, %.3f)",
                       lround(std::clamp<CGFloat>(color.redComponent, 0, 1) *
                              255),
                       lround(std::clamp<CGFloat>(color.greenComponent, 0, 1) *
                              255),
                       lround(std::clamp<CGFloat>(color.blueComponent, 0, 1) *
                              255),
                       std::clamp<CGFloat>(color.alphaComponent * aOpacity, 0,
                                           1)];
}

// The user's system caption style (System Settings > Accessibility >
// Captions), as CSS-ready values, so Picture-in-Picture captions look like
// they do in Apple's own players (which read the same MediaAccessibility
// preferences).
NSDictionary* SystemCaptionStyle() {
  const MACaptionAppearanceDomain domain = kMACaptionAppearanceDomainUser;
  NSString* text =
      CSSColor(MACaptionAppearanceCopyForegroundColor(domain, nullptr),
               MACaptionAppearanceGetForegroundOpacity(domain, nullptr));
  CGFloat windowOpacity = MACaptionAppearanceGetWindowOpacity(domain, nullptr);
  CGFloat backgroundOpacity =
      MACaptionAppearanceGetBackgroundOpacity(domain, nullptr);
  NSString* window = CSSColor(
      MACaptionAppearanceCopyWindowColor(domain, nullptr), windowOpacity);
  NSString* background =
      CSSColor(MACaptionAppearanceCopyBackgroundColor(domain, nullptr),
               backgroundOpacity);
  // One box behind the text: Apple's caption "window" when it is visible,
  // otherwise the per-line text background.
  NSString* box = windowOpacity > 0.01       ? window
                  : backgroundOpacity > 0.01 ? background
                                             : @"transparent";

  NSString* family = @"system-ui";
  double weight = 500;
  if (CTFontDescriptorRef font = MACaptionAppearanceCopyFontDescriptorForStyle(
          domain, nullptr, kMACaptionAppearanceFontStyleDefault)) {
    NSString* name = CFBridgingRelease(
        CTFontDescriptorCopyAttribute(font, kCTFontFamilyNameAttribute));
    if (name.length && ![name hasPrefix:@"."]) {
      NSString* quoted = [[name stringByReplacingOccurrencesOfString:@"\\"
                                                          withString:@"\\\\"]
          stringByReplacingOccurrencesOfString:@"\""
                                    withString:@"\\\""];
      family = [NSString stringWithFormat:@"\"%@\", system-ui", quoted];
    }
    CTFontRef ctFont = CTFontCreateWithFontDescriptor(font, 16, nullptr);
    NSDictionary* traits = CFBridgingRelease(CTFontCopyTraits(ctFont));
    CFRelease(ctFont);
    CFRelease(font);
    // CoreText weight (-1..1) to the nearest CSS weight.
    double ct = [traits[(id)kCTFontWeightTrait] doubleValue];
    const double ctWeights[] = {-0.8, -0.6, -0.4, 0,   0.23,
                                0.3,  0.4,  0.56, 0.62};
    double best = 1e9;
    for (int i = 0; i < 9; i++) {
      if (std::abs(ctWeights[i] - ct) < best) {
        best = std::abs(ctWeights[i] - ct);
        weight = 100 * (i + 1);
      }
    }
  }

  NSString* shadow = @"none";
  switch (MACaptionAppearanceGetTextEdgeStyle(domain, nullptr)) {
    case kMACaptionAppearanceTextEdgeStyleRaised:
      shadow = @"-0.05em -0.05em 0.08em rgba(0, 0, 0, 0.9)";
      break;
    case kMACaptionAppearanceTextEdgeStyleDepressed:
      shadow = @"0.05em 0.05em 0.08em rgba(0, 0, 0, 0.9)";
      break;
    case kMACaptionAppearanceTextEdgeStyleUniform:
      shadow =
          @"0 0 0.05em #000, 0 0 0.05em #000, 0 0 0.05em #000, 0 0 0.05em #000";
      break;
    case kMACaptionAppearanceTextEdgeStyleDropShadow:
      shadow = @"0 0.06em 0.12em rgba(0, 0, 0, 0.9)";
      break;
    default:
      break;
  }
  return @{
    @"color" : text,
    @"box" : box,
    @"radius" : @(std::clamp<CGFloat>(
        MACaptionAppearanceGetWindowRoundedCornerRadius(domain, nullptr), 0,
        24)),
    @"font" : family,
    @"weight" : @(weight),
    @"shadow" : shadow,
    @"scale" : @(std::clamp<CGFloat>(
        MACaptionAppearanceGetRelativeCharacterSize(domain, nullptr), 0.5,
        2.0)),
  };
}

NSString* DockName(const Dock& aDock) {
  NSString* h = aDock.h == HEdge::Left    ? @"left"
                : aDock.h == HEdge::Right ? @"right"
                                          : @"";
  NSString* v = aDock.v == VEdge::Bottom ? @"bottom"
                : aDock.v == VEdge::Top  ? @"top"
                                         : @"";
  if (!h.length && !v.length) {
    return @"free";
  }
  if (h.length && v.length) {
    return [NSString stringWithFormat:@"%@-%@", v, h];
  }
  return h.length ? h : v;
}

// The Live badge's dot, a ring when `aFilled` is NO, followed by `aGap` points
// of space before the label.
NSImage* LiveDotImage(NSColor* aColor, CGFloat aDiameter, CGFloat aGap,
                      BOOL aFilled) {
  NSImage* image = [NSImage
       imageWithSize:NSMakeSize(aDiameter + aGap, aDiameter)
             flipped:NO
      drawingHandler:^BOOL(NSRect) {
        CGFloat line =
            aFilled ? 0 : std::max<CGFloat>(1.5, round(aDiameter * 0.2));
        NSBezierPath* dot = [NSBezierPath
            bezierPathWithOvalInRect:NSInsetRect(
                                         NSMakeRect(0, 0, aDiameter, aDiameter),
                                         line / 2, line / 2)];
        if (aFilled) {
          [aColor setFill];
          [dot fill];
        } else {
          [aColor setStroke];
          dot.lineWidth = line;
          [dot stroke];
        }
        return YES;
      }];
  [image setTemplate:NO];  // keeps its color inside the white-tinted button
  return image;
}

// A Liquid Glass shape around `aContent`: NSGlassEffectView on macOS 26+, a
// HUD NSVisualEffectView before. Over video the chrome uses the Clear variant
// above a 35% dimming layer, with bold, bright, untinted symbols (HIG
// "Materials", WWDC25 "Meet Liquid Glass"); Regular is for glass over
// arbitrary content. The system itself applies the Liquid Glass look
// setting, Reduce Transparency and Increase Contrast to both.
NSView* MakeGlass(NSView* aContent, BOOL aClear) {
  NSView* glass;
  if (@available(macOS 26.0, *)) {
    NSGlassEffectView* view =
        [[NSGlassEffectView alloc] initWithFrame:aContent.frame];
    view.style =
        aClear ? NSGlassEffectViewStyleClear : NSGlassEffectViewStyleRegular;
    view.contentView = aContent;
    glass = view;
  } else {
    NSVisualEffectView* view =
        [[NSVisualEffectView alloc] initWithFrame:aContent.frame];
    view.material = NSVisualEffectMaterialHUDWindow;
    view.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    view.state = NSVisualEffectStateActive;
    view.wantsLayer = YES;
    view.layer.masksToBounds = YES;
    [view addSubview:aContent];
    glass = view;
  }
  glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  return glass;
}

void SetGlassCornerRadius(NSView* aGlass, CGFloat aRadius) {
  if (@available(macOS 26.0, *)) {
    ((NSGlassEffectView*)aGlass).cornerRadius = aRadius;
  } else {
    aGlass.layer.cornerRadius = aRadius;
  }
}

// Interactive glass reacts to the pointer and to presses (macOS 27+).
void SetGlassInteractive(NSView* aGlass, BOOL aInteractive) {
  if (@available(macOS 27.0, *)) {
    ((NSGlassEffectView*)aGlass).effectIsInteractive = aInteractive;
  }
}

// The Command shortcuts the player handles itself: ⌘W closes it, ⌘← ⌘→ and
// ⌘Home ⌘End seek, ⌘⌥⇧P toggles Picture-in-Picture.
bool IsPlayerCommandKey(NSEvent* aEvent) {
  unsigned short code = aEvent.keyCode;
  NSEventModifierFlags mods = aEvent.modifierFlags;
  return code == kKeyW || code == kKeyLeft || code == kKeyRight ||
         code == kKeyHome || code == kKeyEnd ||
         (code == kKeyP && (mods & NSEventModifierFlagOption) &&
          (mods & NSEventModifierFlagShift));
}

}  // namespace

#pragma mark - Controls

// Borderless button hosted inside a glass shape. It takes the first click even
// though the player is a non-activating panel, and can be focused with Tab
// regardless of the system "Keyboard navigation" setting.
@interface ZenPipButtonCore : NSButton
@property(nonatomic) CGFloat focusCornerRadius;
@end

@implementation ZenPipButtonCore
- (BOOL)acceptsFirstMouse:(NSEvent*)aEvent {
  return YES;
}
- (BOOL)canBecomeKeyView {
  return self.isEnabled && !self.refusesFirstResponder &&
         !self.isHiddenOrHasHiddenAncestor;
}
// Space presses the focused control even when the system "Keyboard
// navigation" setting is off (AppKit only does it when it is on).
- (void)keyDown:(NSEvent*)aEvent {
  NSEventModifierFlags mods =
      aEvent.modifierFlags &
      (NSEventModifierFlagCommand | NSEventModifierFlagControl |
       NSEventModifierFlagOption);
  if (aEvent.keyCode == kKeySpace && !mods && self.isEnabled) {
    [self performClick:nil];
    return;
  }
  [super keyDown:aEvent];
}
- (NSRect)focusRingMaskBounds {
  return self.bounds;
}
- (void)drawFocusRingMask {
  [[NSBezierPath bezierPathWithRoundedRect:self.bounds
                                   xRadius:self.focusCornerRadius
                                   yRadius:self.focusCornerRadius] fill];
}
@end

// The timeline's track, drawn like Yab's: a thin line, white up to the
// position and lighter up to what has loaded, with the knob only while the
// pointer is on the timeline, it is dragged or it has keyboard focus.
@interface ZenPipSliderCell : NSSliderCell
@property(nonatomic) double loadedFraction;  // negative when unknown
@property(nonatomic) BOOL showsKnob;
@end

@implementation ZenPipSliderCell
- (void)drawBarInside:(NSRect)aRect flipped:(BOOL)aFlipped {
  CGFloat height = self.showsKnob ? 4 : 3;
  NSRect track = NSMakeRect(NSMinX(aRect), round(NSMidY(aRect) - height / 2),
                            NSWidth(aRect), height);
  auto fill = [&](CGFloat aWidth, CGFloat aAlpha) {
    NSRect part = track;
    part.size.width = std::clamp<CGFloat>(aWidth, 0, NSWidth(track));
    [[NSColor colorWithWhite:1 alpha:aAlpha] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:part
                                     xRadius:height / 2
                                     yRadius:height / 2] fill];
  };
  CGFloat played = NSMidX([self knobRectFlipped:aFlipped]) - NSMinX(track);
  fill(NSWidth(track), 0.3);
  if (self.loadedFraction >= 0) {
    fill(round(NSWidth(track) * self.loadedFraction), 0.5);
  }
  fill(played, 1);
}
- (void)drawKnob:(NSRect)aKnobRect {
  if (!self.showsKnob) {
    return;
  }
  CGFloat d = 12;
  NSRect knob = NSMakeRect(round(NSMidX(aKnobRect) - d / 2),
                           round(NSMidY(aKnobRect) - d / 2), d, d);
  [NSGraphicsContext saveGraphicsState];
  NSShadow* shadow = [[NSShadow alloc] init];
  shadow.shadowBlurRadius = 3;
  shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
  [shadow set];
  [NSColor.whiteColor setFill];
  [[NSBezierPath bezierPathWithOvalInRect:knob] fill];
  [NSGraphicsContext restoreGraphicsState];
}
@end

@interface ZenPipSlider : NSSlider
@end

@implementation ZenPipSlider {
  BOOL mHovered;
}
+ (Class)cellClass {
  return [ZenPipSliderCell class];
}
- (instancetype)initWithFrame:(NSRect)aFrame {
  if (!(self = [super initWithFrame:aFrame])) {
    return nil;
  }
  [self addTrackingArea:[[NSTrackingArea alloc]
                            initWithRect:NSZeroRect
                                 options:NSTrackingMouseEnteredAndExited |
                                         NSTrackingActiveAlways |
                                         NSTrackingInVisibleRect
                                   owner:self
                                userInfo:nil]];
  return self;
}
- (void)updateKnob {
  ZenPipSliderCell* cell = (ZenPipSliderCell*)self.cell;
  BOOL shows = mHovered || self.window.firstResponder == self;
  if (cell.showsKnob != shows) {
    cell.showsKnob = shows;
    self.needsDisplay = YES;
  }
}
- (void)mouseEntered:(NSEvent*)aEvent {
  mHovered = YES;
  [self updateKnob];
}
- (void)mouseExited:(NSEvent*)aEvent {
  mHovered = NO;
  [self updateKnob];
}
- (BOOL)becomeFirstResponder {
  BOOL became = [super becomeFirstResponder];
  [self updateKnob];
  return became;
}
- (BOOL)resignFirstResponder {
  BOOL resigned = [super resignFirstResponder];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateKnob];
  });
  return resigned;
}
- (BOOL)acceptsFirstMouse:(NSEvent*)aEvent {
  return YES;
}
- (BOOL)canBecomeKeyView {
  return self.isEnabled && !self.isHiddenOrHasHiddenAncestor;
}
// Tab goes up to the overlay, which moves focus in reading order (the slider
// would otherwise follow AppKit's key-view loop, see -keyboardOrder).
- (void)keyDown:(NSEvent*)aEvent {
  if (aEvent.keyCode == kKeyTab) {
    [self.nextResponder keyDown:aEvent];
    return;
  }
  [super keyDown:aEvent];
}
@end

// The buffering spinner drawn over the play button; clicks go to the button.
@interface ZenPipSpinner : NSProgressIndicator
@end

@implementation ZenPipSpinner
- (NSView*)hitTest:(NSPoint)aPoint {
  return nil;
}
@end

// A circular or capsule Liquid Glass control: a glass shape whose content view
// is a native button.
@interface ZenPipGlassControl : NSView
@property(nonatomic, readonly) ZenPipButtonCore* button;
@property(nonatomic, readonly) NSView* material;
// Shows information only (a status badge): not focusable, announced as text,
// and clicks or drags on it go to the player like on the video.
@property(nonatomic) BOOL statusOnly;
- (instancetype)initWithTarget:(id)aTarget
                        action:(SEL)aAction
                    clearGlass:(BOOL)aClear;
@end

@implementation ZenPipGlassControl

- (instancetype)initWithTarget:(id)aTarget
                        action:(SEL)aAction
                    clearGlass:(BOOL)aClear {
  if (!(self = [super initWithFrame:NSMakeRect(0, 0, 32, 32)])) {
    return nil;
  }
  _button = [[ZenPipButtonCore alloc] initWithFrame:self.bounds];
  _button.bordered = NO;
  _button.imagePosition = NSImageOnly;
  _button.imageScaling = NSImageScaleNone;
  _button.contentTintColor = NSColor.whiteColor;
  _button.target = aTarget;
  _button.action = aAction;
  _button.focusRingType = NSFocusRingTypeDefault;
  _material = MakeGlass(_button, aClear);
  SetGlassInteractive(_material, YES);
  [self addSubview:_material];
  self.accessibilityElement = NO;
  return self;
}

- (void)setStatusOnly:(BOOL)aStatusOnly {
  if (aStatusOnly == _statusOnly) {
    return;
  }
  _statusOnly = aStatusOnly;
  _button.refusesFirstResponder = aStatusOnly;
  _button.accessibilityRole =
      aStatusOnly ? NSAccessibilityStaticTextRole : NSAccessibilityButtonRole;
  SetGlassInteractive(_material, !aStatusOnly);
}

- (NSView*)hitTest:(NSPoint)aPoint {
  return _statusOnly ? nil : [super hitTest:aPoint];
}

- (void)setFrameSize:(NSSize)aSize {
  [super setFrameSize:aSize];
  CGFloat radius = std::min(aSize.width, aSize.height) / 2;
  _button.focusCornerRadius = radius;
  SetGlassCornerRadius(_material, radius);
  _material.frame = self.bounds;
  _button.frame = _material.bounds;
}
@end

// Bottom glass capsule: elapsed time, native slider, duration.
@interface ZenPipTimeline : NSView
@property(nonatomic, readonly) ZenPipSlider* slider;
@property(nonatomic, readonly) NSTextField* elapsed;
@property(nonatomic, readonly) NSTextField* duration;
@property(nonatomic, readonly) NSView* material;
@property(nonatomic) BOOL showsLabels;
@property(nonatomic) CGFloat fontSize;
- (instancetype)initWithTarget:(id)aTarget action:(SEL)aAction;
@end

static NSTextField* MakeTimeLabel() {
  NSTextField* label = [NSTextField labelWithString:@"0:00"];
  label.textColor = NSColor.whiteColor;
  label.lineBreakMode = NSLineBreakByClipping;
  label.accessibilityElement = NO;  // the slider reports the time
  return label;
}

@implementation ZenPipTimeline {
  NSView* mContent;
}

- (instancetype)initWithTarget:(id)aTarget action:(SEL)aAction {
  if (!(self = [super initWithFrame:NSMakeRect(0, 0, 300, 30)])) {
    return nil;
  }
  mContent = [[NSView alloc] initWithFrame:self.bounds];
  _elapsed = MakeTimeLabel();
  _duration = MakeTimeLabel();
  _duration.alignment = NSTextAlignmentRight;
  _slider = [ZenPipSlider sliderWithValue:0
                                 minValue:0
                                 maxValue:1
                                   target:aTarget
                                   action:aAction];
  _slider.continuous = YES;
  ((ZenPipSliderCell*)_slider.cell).loadedFraction = -1;
  [mContent addSubview:_elapsed];
  [mContent addSubview:_slider];
  [mContent addSubview:_duration];
  _showsLabels = YES;
  _fontSize = 12;
  _material = MakeGlass(mContent, YES);
  [self addSubview:_material];
  self.accessibilityElement = NO;
  return self;
}

- (void)setFrameSize:(NSSize)aSize {
  [super setFrameSize:aSize];
  [self layoutContent];
}

- (void)setShowsLabels:(BOOL)aShows {
  _showsLabels = aShows;
  [self layoutContent];
}

- (void)layoutContent {
  NSSize size = self.bounds.size;
  CGFloat radius = size.height / 2;
  SetGlassCornerRadius(_material, radius);
  _material.frame = self.bounds;
  mContent.frame = _material.bounds;

  NSFont* font = [NSFont monospacedDigitSystemFontOfSize:_fontSize
                                                  weight:NSFontWeightSemibold];
  _elapsed.font = font;
  _duration.font = font;
  CGFloat pad = std::max<CGFloat>(10, radius * 0.8);
  CGFloat labelH = ceil(font.ascender - font.descender + 2);
  CGFloat labelY = round((size.height - labelH) / 2);
  CGFloat labelW = 0;
  if (_showsLabels) {
    // Both labels are as wide as the longer one, so the slider never moves
    // while the time ticks (the digits are monospaced).
    NSString* widest =
        _duration.stringValue.length > _elapsed.stringValue.length
            ? _duration.stringValue
            : _elapsed.stringValue;
    labelW =
        ceil([widest sizeWithAttributes:@{NSFontAttributeName : font}].width) +
        2;
  }
  _elapsed.hidden = !_showsLabels;
  _duration.hidden = !_showsLabels || _duration.stringValue.length == 0;
  _elapsed.frame = NSMakeRect(pad, labelY, labelW, labelH);
  _duration.frame =
      NSMakeRect(size.width - pad - labelW, labelY, labelW, labelH);
  CGFloat gap = _showsLabels ? std::max<CGFloat>(8, pad * 0.7) : 0;
  CGFloat sliderX = pad + labelW + gap;
  CGFloat sliderW = std::max<CGFloat>(0, size.width - 2 * sliderX);
  CGFloat sliderH = std::min<CGFloat>(size.height, 20);
  _slider.frame =
      NSMakeRect(sliderX, round((size.height - sliderH) / 2), sliderW, sliderH);
}
@end

// What the overlay and the stash tab forward to the chrome.
@interface ZenPipPlayerChrome () <NSMenuDelegate, NSMenuItemValidation>
- (void)overlayMouseMoved:(NSEvent*)aEvent;
- (void)overlayMouseExited;
- (void)overlayScroll:(NSEvent*)aEvent;
- (void)overlayMagnify:(NSEvent*)aEvent;
- (void)overlayKeyDown:(NSEvent*)aEvent;
- (void)overlayLayout;
- (void)overlayUpdateCursor:(NSEvent*)aEvent;
- (void)tabPressed;
- (void)tabMovedTo:(CGFloat)aY;
@end

#pragma mark - Stash tab

// The tab a stashed player leaves at the screen edge. A click on it, or Space
// or Return once it has keyboard focus (Command-` reaches it), brings the
// player back; dragging moves it along the edge.
@interface ZenPipStashTabView : NSView
@property(nonatomic, weak) ZenPipPlayerChrome* chrome;
@property(nonatomic, readonly) NSImageView* chevron;
@end

@implementation ZenPipStashTabView {
  NSView* mMaterial;
  NSPoint mPressPoint;
  CGFloat mPressY;
  BOOL mDragged;
}

- (instancetype)initWithFrame:(NSRect)aFrame {
  if (!(self = [super initWithFrame:aFrame])) {
    return nil;
  }
  _chevron = [[NSImageView alloc] initWithFrame:self.bounds];
  _chevron.imageScaling = NSImageScaleNone;
  _chevron.contentTintColor = NSColor.whiteColor;
  // Over arbitrary desktop content, not video: Regular glass.
  mMaterial = MakeGlass(_chevron, NO);
  mMaterial.frame = self.bounds;
  SetGlassCornerRadius(mMaterial, aFrame.size.width / 2);
  _chevron.frame = mMaterial.bounds;
  [self addSubview:mMaterial];
  return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)aEvent {
  return YES;
}
- (BOOL)acceptsFirstResponder {
  return YES;
}
// Clicks don't take the keyboard from the app the user is in.
- (BOOL)needsPanelToBecomeKey {
  return NO;
}
- (NSRect)focusRingMaskBounds {
  return self.bounds;
}
- (void)drawFocusRingMask {
  CGFloat radius = self.bounds.size.width / 2;
  [[NSBezierPath bezierPathWithRoundedRect:self.bounds
                                   xRadius:radius
                                   yRadius:radius] fill];
}

- (BOOL)isAccessibilityElement {
  return YES;
}
- (NSAccessibilityRole)accessibilityRole {
  return NSAccessibilityButtonRole;
}
- (BOOL)accessibilityPerformPress {
  [_chrome tabPressed];
  return YES;
}

- (void)mouseDown:(NSEvent*)aEvent {
  mPressPoint = EventScreenLocation(aEvent);
  mPressY = NSMinY(self.window.frame);
  mDragged = NO;
}
- (void)mouseDragged:(NSEvent*)aEvent {
  NSPoint p = EventScreenLocation(aEvent);
  if (!mDragged && std::abs(p.y - mPressPoint.y) < kDragThreshold) {
    return;
  }
  mDragged = YES;
  [_chrome tabMovedTo:mPressY + p.y - mPressPoint.y];
}
- (void)mouseUp:(NSEvent*)aEvent {
  if (!mDragged) {
    [_chrome tabPressed];
  }
}
- (void)keyDown:(NSEvent*)aEvent {
  unsigned short code = aEvent.keyCode;
  if (code == kKeySpace || code == kKeyReturn || code == kKeyEnter) {
    [_chrome tabPressed];
    return;
  }
  [super keyDown:aEvent];
}
@end

@interface ZenPipStashTab : NSPanel
@property(nonatomic, readonly) ZenPipStashTabView* tabView;
- (instancetype)initWithChrome:(ZenPipPlayerChrome*)aChrome;
@end

@implementation ZenPipStashTab
- (instancetype)initWithChrome:(ZenPipPlayerChrome*)aChrome {
  if (!(self =
            [super initWithContentRect:NSMakeRect(0, 0, kTabWidth, kTabHeight)
                             styleMask:NSWindowStyleMaskBorderless |
                                       NSWindowStyleMaskNonactivatingPanel
                               backing:NSBackingStoreBuffered
                                 defer:YES])) {
    return nil;
  }
  self.releasedWhenClosed = NO;
  self.opaque = NO;
  self.backgroundColor = NSColor.clearColor;
  self.hasShadow = YES;
  self.level = NSFloatingWindowLevel;
  self.hidesOnDeactivate = NO;
  self.canHide = NO;
  self.movable = NO;
  self.becomesKeyOnlyIfNeeded = YES;
  self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                            NSWindowCollectionBehaviorFullScreenAuxiliary;
  self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  _tabView = [[ZenPipStashTabView alloc]
      initWithFrame:NSMakeRect(0, 0, kTabWidth, kTabHeight)];
  _tabView.chrome = aChrome;
  self.contentView = _tabView;
  return self;
}
// Borderless panels can't become key by default; keyboard users reach the
// tab through window cycling.
- (BOOL)canBecomeKeyWindow {
  return YES;
}
- (void)becomeKeyWindow {
  [super becomeKeyWindow];
  [self makeFirstResponder:_tabView];
}
@end

#pragma mark - Overlay view

@interface ZenPipOverlayView : NSView
@property(nonatomic, weak) ZenPipPlayerChrome* chrome;
@end

@implementation ZenPipOverlayView

- (instancetype)initWithFrame:(NSRect)aFrame {
  if (!(self = [super initWithFrame:aFrame])) {
    return nil;
  }
  [self addTrackingArea:[[NSTrackingArea alloc]
                            initWithRect:NSZeroRect
                                 options:NSTrackingMouseEnteredAndExited |
                                         NSTrackingMouseMoved |
                                         NSTrackingActiveAlways |
                                         NSTrackingInVisibleRect |
                                         NSTrackingCursorUpdate
                                   owner:self
                                userInfo:nil]];
  return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)aEvent {
  return YES;
}
- (BOOL)acceptsFirstResponder {
  return YES;
}

// Clicks on buttons and the slider go to those controls; everywhere else
// (video, scrim, glass backgrounds, labels) is the drag surface.
- (NSView*)hitTest:(NSPoint)aPoint {
  NSView* hit = [super hitTest:aPoint];
  if (!hit) {
    return nil;
  }
  for (NSView* view = hit; view && view != self; view = view.superview) {
    if ([view isKindOfClass:[NSButton class]] ||
        [view isKindOfClass:[NSSlider class]]) {
      return hit;
    }
  }
  return self;
}

- (void)mouseEntered:(NSEvent*)aEvent {
  [_chrome overlayMouseMoved:aEvent];
}
- (void)mouseMoved:(NSEvent*)aEvent {
  [_chrome overlayMouseMoved:aEvent];
}
- (void)mouseExited:(NSEvent*)aEvent {
  [_chrome overlayMouseExited];
}
- (void)cursorUpdate:(NSEvent*)aEvent {
  [_chrome overlayUpdateCursor:aEvent];
}
- (void)scrollWheel:(NSEvent*)aEvent {
  [_chrome overlayScroll:aEvent];
}
- (void)magnifyWithEvent:(NSEvent*)aEvent {
  [_chrome overlayMagnify:aEvent];
}
- (void)keyDown:(NSEvent*)aEvent {
  [_chrome overlayKeyDown:aEvent];
}
- (void)layout {
  [super layout];
  [_chrome overlayLayout];
}
- (void)setFrameSize:(NSSize)aSize {
  [super setFrameSize:aSize];
  self.needsLayout = YES;
}
@end

// Passes clicks on empty space through to the overlay (the drag surface).
@interface ZenPipPassthroughView : NSView
@end

@implementation ZenPipPassthroughView
- (NSView*)hitTest:(NSPoint)aPoint {
  NSView* hit = [super hitTest:aPoint];
  return hit == self ? nil : hit;
}
@end

#pragma mark - Player chrome

typedef NS_ENUM(NSInteger, ZenPipGesture) {
  ZenPipGestureNone,
  ZenPipGesturePending,  // pressed, not yet past the drag threshold
  ZenPipGestureDrag,
  ZenPipGestureResize,
  ZenPipGestureCarry,  // two-finger scroll
  ZenPipGesturePinch,
};

static void* const kVoiceOverContext = (void*)&kVoiceOverContext;

// Every attached player, so that several of them keep out of each other's
// way (corners, stash tabs).
static NSHashTable<ZenPipPlayerChrome*>* AllPlayers() {
  static NSHashTable* players = [NSHashTable weakObjectsHashTable];
  return players;
}

@implementation ZenPipPlayerChrome {
  ChromeHost* mHost;
  __weak NSWindow* mWindow;
  __weak NSWindow* mSourceWindow;
  __weak NSResponder* mPreviousFirstResponder;
  BOOL mWasMovable;
  BOOL mObserving;
  BOOL mInvalidated;

  Config mConfig;
  Appearance mAppearance;
  // Test-only overrides of the system accessibility display options.
  NSDictionary<NSString*, NSNumber*>* mSimulatedAppearance;
  NSDictionary<NSString*, NSString*>* mStrings;

  ZenPipOverlayView* mOverlay;
  NSView* mScrim;
  NSView* mControlsRoot;  // NSGlassEffectContainerView (26+) or plain view
  ZenPipPassthroughView* mControls;
  ZenPipGlassControl* mSpeed;
  ZenPipGlassControl* mCaptions;
  ZenPipGlassControl* mSound;
  ZenPipGlassControl* mReturn;
  ZenPipGlassControl* mMinimize;
  ZenPipGlassControl* mClose;
  ZenPipGlassControl* mBack;
  ZenPipGlassControl* mPlay;
  ZenPipGlassControl* mForward;
  // "● Live" for live streams: a status badge, or a "go to live" button beside
  // the timeline when the stream can be scrubbed.
  ZenPipGlassControl* mLiveBadge;
  ZenPipSpinner* mSpinner;
  ZenPipTimeline* mTimeline;
  CGFloat mSymbolScale;  // the symbols were last drawn at
  // Takes every press in the player outside its controls (see -filterPress:).
  id mPressMonitor;
  BOOL mOwnsPress;  // its drags and its release come here too

  // Playback state mirrored from the original video.
  BOOL mPlaying;
  BOOL mMuted;
  double mVolume;
  double mRate;
  double mCurrentTime;
  double mDuration;
  BOOL mSeekable;
  BOOL mLive;
  BOOL mAtLiveEdge;  // a scrubbable live stream plays at its live edge
  BOOL mBuffering;
  BOOL mShowsSpinner;
  BOOL mEnded;
  BOOL mCaptionsAvailable;
  BOOL mCaptionsEnabled;
  NSString* mCaptionSize;
  double mAspect;
  BOOL mAspectPending;  // the video changed size while the player was busy
  NSTimer* mSpinnerTimer;

  // Controls visibility.
  BOOL mControlsVisible;
  BOOL mPointerInside;
  BOOL mSticky;
  BOOL mScrubbing;
  BOOL mMenuOpen;
  NSTimer* mHideTimer;
  CFTimeInterval mHideAt;  // when the controls may hide, absent other reasons

  // Motion.
  ZenPipGesture mGesture;
  BOOL mGestureMoved;  // past the drag threshold; otherwise a click
  BOOL mCaughtMoving;  // the press stopped the player mid-flight
  NSPoint mGestureStartMouse;
  NSRect mGestureStartFrame;
  ResizeHandle mResizeHandle;
  Dock mGestureDock;
  double mPinchScale;
  BOOL mPushingEdge;  // the drag pushes past an edge of the display
  HEdge mStashArmed;  // released now, the player would stash on that side
  std::vector<PointerSample> mSamples;
  Spring2D mSpring;
  CFTimeInterval mSpringStart;
  CADisplayLink* mDisplayLink API_AVAILABLE(macos(14.0));
  NSTimer* mFallbackAnimationTimer;
  NSInteger mFrameAnimations;  // AppKit frame animations in flight
  BOOL mSettingFrame;          // the chrome itself is moving the window
  Dock mRestDock;              // where it last came, or is coming, to rest
  BOOL mExiting;

  // Stashed into a side of its display, leaving a tab.
  BOOL mStashed;
  HEdge mStashSide;
  NSRect mFrameBeforeStash;
  ZenPipStashTab* mTab;

  // Display the user dragged the player onto (0: follow the source window).
  CGDirectDisplayID mHomeDisplay;
  // Pushing at the edge toward another display: since when (event time), and
  // a one-shot timer that ends the hold for a pointer at rest.
  NSTimeInterval mEdgeHoldStart;
  BOOL mEdgeHoldElapsed;
  NSTimer* mEdgeHoldTimer;
  NSPoint mLastGesturePoint;
}

+ (BOOL)hasLiquidGlass {
  if (@available(macOS 26.0, *)) {
    return YES;
  }
  return NO;
}

- (nullable instancetype)initWithPlayerWindow:(NSWindow*)aWindow
                                         host:(ChromeHost*)aHost {
  NSView* content = aWindow.contentView;
  if (!content || !aHost || !(self = [super init])) {
    return nil;
  }
  mHost = aHost;
  mWindow = aWindow;
  mRate = 1;
  mVolume = 1;
  mAtLiveEdge = YES;
  mDuration = NAN;
  NSSize size = aWindow.frame.size;
  mAspect = size.height > 0 ? size.width / size.height : 16.0 / 9;
  mCaptionSize = @"medium";
  mStrings = @{};
  mAppearance = CurrentAppearance();

  [self buildOverlayInView:content];

  // The chrome moves the window itself (with physics and containment), so
  // the system must not start its own window drags from the titlebar area.
  mWasMovable = aWindow.movable;
  aWindow.movable = NO;
  // The player stays on screen when Zen is hidden (Command-H), so the video
  // stays in view while the user works in another app.
  aWindow.canHide = NO;
  for (NSWindowButton b :
       {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton}) {
    [aWindow standardWindowButton:b].hidden = YES;
  }
  mPreviousFirstResponder = aWindow.firstResponder;
  [aWindow makeFirstResponder:mOverlay];

  __weak ZenPipPlayerChrome* weakSelf = self;
  mPressMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown |
                                           NSEventMaskLeftMouseDragged |
                                           NSEventMaskLeftMouseUp
                                   handler:^NSEvent*(NSEvent* aEvent) {
                                     ZenPipPlayerChrome* chrome = weakSelf;
                                     return chrome ? [chrome filterPress:aEvent]
                                                   : aEvent;
                                   }];

  [AllPlayers() addObject:self];
  [self observeNotifications];
  [self refreshAllControls];
  [self settleAnimated:NO];
  [self moveClearOfOtherPlayers];
  // Before the first reveal, so captions are placed with the system style.
  [self notifyCaptionStyle];
  [self revealControlsFor:kInitialRevealDuration];
  return self;
}

- (void)notifyCaptionStyle {
  [self notifyHost:"caption-style"
             value:0
            detail:JSONString(SystemCaptionStyle())];
}

- (void)dealloc {
  [self invalidate];
}

#pragma mark Building

- (ZenPipGlassControl*)addControl:(SEL)aAction {
  ZenPipGlassControl* control =
      [[ZenPipGlassControl alloc] initWithTarget:self
                                          action:aAction
                                      clearGlass:YES];
  [mControls addSubview:control];
  return control;
}

- (void)buildOverlayInView:(NSView*)aContent {
  mOverlay = [[ZenPipOverlayView alloc] initWithFrame:aContent.bounds];
  mOverlay.chrome = self;
  mOverlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  mOverlay.wantsLayer = YES;
  mOverlay.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  mOverlay.accessibilityElement = NO;

  // Shown with the controls (see kDimmingOpacity).
  mScrim = [[NSView alloc] initWithFrame:mOverlay.bounds];
  mScrim.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  mScrim.wantsLayer = YES;
  CALayer* dimming = [CALayer layer];
  dimming.backgroundColor =
      [NSColor colorWithWhite:0 alpha:kDimmingOpacity].CGColor;
  mScrim.layer = dimming;
  mScrim.alphaValue = 0;
  mScrim.hidden = YES;
  [mOverlay addSubview:mScrim];

  mControls = [[ZenPipPassthroughView alloc] initWithFrame:mOverlay.bounds];
  mControls.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  if (@available(macOS 26.0, *)) {
    // Batches the glass shapes into fewer render passes; spacing 0 keeps the
    // separate circles from melting into each other.
    NSGlassEffectContainerView* container =
        [[NSGlassEffectContainerView alloc] initWithFrame:mOverlay.bounds];
    container.spacing = 0;
    container.contentView = mControls;
    mControlsRoot = container;
  } else {
    mControlsRoot = [[NSView alloc] initWithFrame:mOverlay.bounds];
    [mControlsRoot addSubview:mControls];
  }
  mControlsRoot.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  mControlsRoot.alphaValue = 0;
  mControlsRoot.hidden = YES;
  [mOverlay addSubview:mControlsRoot];

  // Created in reading order, which VoiceOver follows: playback options
  // (speed, captions, sound), window controls (back to tab, minimize, close).
  mSpeed = [self addControl:@selector(onSpeed:)];
  mSpeed.button.imagePosition = NSNoImage;
  mCaptions = [self addControl:@selector(onCaptions:)];
  mSound = [self addControl:@selector(onSound:)];
  mReturn = [self addControl:@selector(onReturn:)];
  mMinimize = [self addControl:@selector(onMinimize:)];
  mClose = [self addControl:@selector(onClose:)];
  mBack = [self addControl:@selector(onBack:)];
  mPlay = [self addControl:@selector(onPlay:)];
  mForward = [self addControl:@selector(onForward:)];
  mLiveBadge = [self addControl:@selector(onLive:)];
  mLiveBadge.hidden = YES;
  mLiveBadge.button.imageHugsTitle = YES;
  mTimeline = [[ZenPipTimeline alloc] initWithTarget:self
                                              action:@selector(onScrub:)];
  [mControls addSubview:mTimeline];

  mSpinner = [[ZenPipSpinner alloc] initWithFrame:NSZeroRect];
  mSpinner.style = NSProgressIndicatorStyleSpinning;
  mSpinner.displayedWhenStopped = NO;
  mSpinner.appearance = mOverlay.appearance;
  [mPlay addSubview:mSpinner];

  // Captions get extra options from a context menu (right/control click).
  NSMenu* captionsMenu = [[NSMenu alloc] init];
  captionsMenu.delegate = self;
  mCaptions.button.menu = captionsMenu;

  [aContent addSubview:mOverlay positioned:NSWindowAbove relativeTo:nil];
}

#pragma mark Notifications

- (void)observeNotifications {
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  NSWindow* window = mWindow;
  [nc addObserver:self
         selector:@selector(windowWillClose:)
             name:NSWindowWillCloseNotification
           object:window];
  [nc addObserver:self
         selector:@selector(windowFrameChanged:)
             name:NSWindowDidMoveNotification
           object:window];
  [nc addObserver:self
         selector:@selector(windowFrameChanged:)
             name:NSWindowDidResizeNotification
           object:window];
  [nc addObserver:self
         selector:@selector(windowOcclusionChanged:)
             name:NSWindowDidChangeOcclusionStateNotification
           object:window];
  // Display added/removed/rearranged, resolution, Dock or menu bar changes.
  [nc addObserver:self
         selector:@selector(screensChanged:)
             name:NSApplicationDidChangeScreenParametersNotification
           object:nil];
  // System Settings > Accessibility > Captions changed.
  [nc addObserver:self
         selector:@selector(notifyCaptionStyle)
             name:(__bridge NSString*)
                      kMACaptionAppearanceSettingsChangedNotification
           object:nil];
  [NSWorkspace.sharedWorkspace.notificationCenter
      addObserver:self
         selector:@selector(appearanceChanged)
             name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
           object:nil];
  [NSWorkspace.sharedWorkspace addObserver:self
                                forKeyPath:@"voiceOverEnabled"
                                   options:0
                                   context:kVoiceOverContext];
  mObserving = YES;
}

- (void)observeValueForKeyPath:(NSString*)aKeyPath
                      ofObject:(id)aObject
                        change:(NSDictionary*)aChange
                       context:(void*)aContext {
  if (aContext != kVoiceOverContext) {
    [super observeValueForKeyPath:aKeyPath
                         ofObject:aObject
                           change:aChange
                          context:aContext];
    return;
  }
  [self appearanceChanged];
}

- (void)windowWillClose:(NSNotification*)aNote {
  [self notifyHost:"window-will-close" value:0 detail:nil];
  [self invalidate];
}

// Something other than the chrome moved or resized the player (a window
// manager, Accessibility, the Window > Zoom command): back inside its area.
- (void)windowFrameChanged:(NSNotification*)aNote {
  if (mSettingFrame || mGesture != ZenPipGestureNone || mStashed || mExiting ||
      [self isAnimating]) {
    return;
  }
  [NSObject
      cancelPreviousPerformRequestsWithTarget:self
                                     selector:@selector(
                                                  settleAfterExternalChange)
                                       object:nil];
  [self performSelector:@selector(settleAfterExternalChange)
             withObject:nil
             afterDelay:0.15];
}

- (void)settleAfterExternalChange {
  mRestDock =
      DetectDock(ToRect(mWindow.frame), [self allowedArea], kDockTolerance);
  [self settleAnimated:YES];
}

- (void)screensChanged:(NSNotification*)aNote {
  if (mStashed) {
    [self placeTabAt:NSMinY(mTab.frame)];
  } else {
    [self settleAnimated:YES];
  }
}

- (void)appearanceChanged {
  mAppearance = CurrentAppearance();
  if (NSNumber* v = mSimulatedAppearance[@"reduceMotion"]) {
    mAppearance.reduceMotion = v.boolValue;
  }
  if (NSNumber* v = mSimulatedAppearance[@"increaseContrast"]) {
    mAppearance.increaseContrast = v.boolValue;
  }
  [self refreshAllControls];
  if (mAppearance.voiceOver) {
    [self showControls];
  } else {
    [self scheduleHide];
  }
}

// The visual reading order, which Tab follows. Since macOS 26 AppKit inserts
// the controls' own subviews (button images, the slider's hosted SwiftUI
// view) into the key-view loop, so Tab moves through this list itself rather
// than through nextKeyView.
- (NSArray<NSView*>*)keyboardOrder {
  return @[
    mSpeed.button, mCaptions.button, mSound.button, mReturn.button,
    mMinimize.button, mClose.button, mBack.button, mPlay.button,
    mForward.button, mLiveBadge.button, mTimeline.slider
  ];
}

// Moves keyboard focus to the next (or previous) control that can take it,
// wrapping around. From outside the controls, Tab starts at play/pause.
- (void)moveKeyboardFocusBackwards:(BOOL)aBackwards {
  NSWindow* window = mWindow;
  if (mStashed) {
    return;
  }
  [self showControls];
  NSArray<NSView*>* order = [self keyboardOrder];
  NSResponder* responder = window.firstResponder;
  NSInteger current = NSNotFound;
  for (NSUInteger i = 0; i < order.count; i++) {
    if ([responder isKindOfClass:[NSView class]] &&
        [(NSView*)responder isDescendantOf:order[i]]) {
      current = i;
      break;
    }
  }
  NSInteger count = order.count;
  NSInteger start =
      current != NSNotFound ? current : [order indexOfObject:mPlay.button];
  if (current == NSNotFound && !aBackwards) {
    start -= 1;  // land on play/pause itself
  }
  for (NSInteger step = 1; step <= count; step++) {
    NSView* candidate =
        order[((start + (aBackwards ? -step : step)) % count + count) % count];
    if (candidate.canBecomeKeyView) {
      [window makeFirstResponder:candidate];
      return;
    }
  }
}

// Names used by debugState, focusedControlName and the test hooks.
- (NSDictionary<NSString*, ZenPipGlassControl*>*)namedControls {
  return @{
    @"close" : mClose,
    @"minimize" : mMinimize,
    @"speed" : mSpeed,
    @"captions" : mCaptions,
    @"sound" : mSound,
    @"return" : mReturn,
    @"back15" : mBack,
    @"playPause" : mPlay,
    @"forward15" : mForward,
    @"live" : mLiveBadge
  };
}

#pragma mark Host

- (void)notifyHost:(const char*)aAction
             value:(double)aValue
            detail:(NSString*)aDetail {
  if (mHost && !mInvalidated) {
    mHost->OnChromeAction(aAction, aValue, aDetail ? aDetail.UTF8String : "");
  }
}

- (NSString*)string:(NSString*)aKey fallback:(NSString*)aFallback {
  NSString* value = mStrings[aKey];
  return value.length ? value : aFallback;
}

#pragma mark State setters

- (void)setPlaying:(BOOL)aPlaying {
  if (mPlaying == aPlaying) {
    return;
  }
  mPlaying = aPlaying;
  [self refreshPlayButton];
  if (!aPlaying) {
    [self showControls];
  }
  [self scheduleHide];
}

- (void)setMuted:(BOOL)aMuted {
  mMuted = aMuted;
  [self refreshSoundButton];
}

- (void)setVolume:(double)aVolume {
  if (!std::isfinite(aVolume)) {
    return;
  }
  mVolume = std::clamp(aVolume, 0.0, 1.0);
  [self refreshSoundButton];
}

- (void)setPlaybackRate:(double)aRate {
  if (!std::isfinite(aRate) || aRate <= 0) {
    return;
  }
  mRate = aRate;
  [self refreshSpeedButton];
  mOverlay.needsLayout = YES;  // the speed capsule fits its number
}

- (void)setBuffering:(BOOL)aBuffering ended:(BOOL)aEnded {
  if (aEnded != mEnded) {
    mEnded = aEnded;
    [self refreshPlayButton];
  }
  if (aBuffering == mBuffering) {
    return;
  }
  mBuffering = aBuffering;
  [mSpinnerTimer invalidate];
  mSpinnerTimer = nil;
  if (!aBuffering) {
    [self showSpinner:NO];
    return;
  }
  __weak ZenPipPlayerChrome* weakSelf = self;
  mSpinnerTimer =
      [NSTimer scheduledTimerWithTimeInterval:kSpinnerDelay
                                      repeats:NO
                                        block:^(NSTimer*) {
                                          ZenPipPlayerChrome* chrome = weakSelf;
                                          if (chrome && chrome->mBuffering) {
                                            [chrome showSpinner:YES];
                                          }
                                        }];
}

- (void)setLoadedFraction:(double)aFraction {
  ZenPipSliderCell* cell = (ZenPipSliderCell*)mTimeline.slider.cell;
  if (std::abs(cell.loadedFraction - aFraction) < 0.005) {
    return;
  }
  cell.loadedFraction =
      std::isfinite(aFraction) ? std::min(aFraction, 1.0) : -1;
  mTimeline.slider.needsDisplay = YES;
}

- (void)showSpinner:(BOOL)aShow {
  if (aShow == mShowsSpinner) {
    return;
  }
  mShowsSpinner = aShow;
  if (aShow) {
    [mSpinner startAnimation:nil];
  } else {
    [mSpinner stopAnimation:nil];
  }
  [self refreshPlayButton];
}

- (void)setCurrentTime:(double)aCurrentTime
              duration:(double)aDuration
              seekable:(BOOL)aSeekable
                  live:(BOOL)aLive {
  BOOL layoutChange =
      aSeekable != mSeekable || aLive != mLive ||
      FormatTime(aDuration).length != FormatTime(mDuration).length;
  mCurrentTime = aCurrentTime;
  mDuration = aDuration;
  mSeekable = aSeekable;
  mLive = aLive;
  if (layoutChange) {
    [self refreshLiveBadge];
    mOverlay.needsLayout = YES;
  } else if (!mControlsVisible) {
    return;  // nothing visible to update; refreshed when shown
  }
  [self refreshTimeline];
}

- (void)setAtLiveEdge:(BOOL)aAtLiveEdge {
  if (aAtLiveEdge == mAtLiveEdge) {
    return;
  }
  mAtLiveEdge = aAtLiveEdge;
  [self refreshLiveBadge];
  [self refreshTimeline];
}

- (void)setCaptionsAvailable:(BOOL)aAvailable enabled:(BOOL)aEnabled {
  mCaptionsAvailable = aAvailable;
  mCaptionsEnabled = aEnabled;
  [self refreshCaptionsButton];
}

- (void)setCaptionSize:(NSString*)aSize {
  mCaptionSize = aSize.length ? [aSize copy] : @"medium";
}

- (void)setStrings:(NSDictionary<NSString*, NSString*>*)aStrings {
  mStrings = [aStrings copy] ?: @{};
  [self refreshAllControls];
}

- (void)setVideoSize:(NSSize)aSize {
  if (aSize.width <= 0 || aSize.height <= 0) {
    return;
  }
  double aspect = aSize.width / aSize.height;
  if (std::abs(aspect - mAspect) < 0.002) {
    return;
  }
  mAspect = aspect;
  mAspectPending = YES;
  [self applyVideoAspect];
}

// Adopts the video's aspect, keeping about the same area and the anchor. It
// waits while the player is being dragged, resized, animated or stashed, and
// runs when that ends.
- (void)applyVideoAspect {
  NSWindow* window = mWindow;
  if (!mAspectPending || !window || mStashed || mExiting ||
      mGesture != ZenPipGestureNone || [self isAnimating]) {
    return;
  }
  mAspectPending = NO;
  Box frame = ToRect(window.frame);
  Box area = [self allowedArea];
  double width = std::sqrt(frame.width * frame.height * mAspect);
  Box resized =
      ScaleFrame(frame, width / frame.width, mAspect,
                 DetectDock(frame, area, kDockTolerance), area, mConfig.limits);
  [self setPlayerFrame:ToNSRect(resized)];
  window.contentAspectRatio = NSMakeSize(resized.width, resized.height);
  [self settleAnimated:YES];
}

- (void)setSourceWindow:(nullable NSWindow*)aWindow {
  NSWindow* previous = mSourceWindow;
  if (previous == aWindow) {
    return;
  }
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  if (previous) {
    [nc removeObserver:self
                  name:NSWindowDidChangeScreenNotification
                object:previous];
  }
  NSScreen* oldScreen = [self sourceScreen];
  mSourceWindow = aWindow;
  if (aWindow) {
    [nc addObserver:self
           selector:@selector(sourceScreenChanged)
               name:NSWindowDidChangeScreenNotification
             object:aWindow];
  }
  if (oldScreen != [self sourceScreen]) {
    [self sourceScreenChanged];
  } else {
    [self settleAnimated:YES];
  }
}

- (void)setConfiguration:(NSDictionary<NSString*, id>*)aConfiguration {
  auto number = [&](NSString* aKey, double aFallback) {
    id value = aConfiguration[aKey];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue]
                                                  : aFallback;
  };
  mConfig.edgeGap = std::clamp(number(@"edgeGap", mConfig.edgeGap), 0.0, 64.0);
  mConfig.idleHideDelay =
      std::clamp(number(@"idleHideDelay", mConfig.idleHideDelay), 0.8, 30.0);
  mConfig.carryWithTwoFingers =
      number(@"carryWithTwoFingers", mConfig.carryWithTwoFingers) != 0;
  mConfig.rightToLeft = number(@"rightToLeft", mConfig.rightToLeft) != 0;
  id simulated = aConfiguration[@"simulateAccessibility"];
  if ([simulated isKindOfClass:[NSDictionary class]]) {
    mSimulatedAppearance = [simulated copy];
    [self appearanceChanged];
  }
  mOverlay.needsLayout = YES;
  [self settleAnimated:NO];
}

#pragma mark Control refresh

- (CGFloat)symbolScale {
  return std::clamp<CGFloat>(mOverlay.bounds.size.width / kReferenceWidth, 0.72,
                             1.18);
}

- (NSFontWeight)symbolWeight {
  return mAppearance.increaseContrast ? NSFontWeightBold : NSFontWeightSemibold;
}

// Symbols and labels for the current state, size, strings and accessibility
// settings.
- (void)refreshAllControls {
  mSymbolScale = [self symbolScale];
  [self refreshLiveBadge];
  [self refreshPlayButton];
  [self refreshSoundButton];
  [self refreshSpeedButton];
  [self refreshCaptionsButton];
  [self refreshTimeline];
  [self configureButton:mClose symbol:@"xmark" key:@"close" fallback:@"Close"];
  [self configureButton:mMinimize
                 symbol:@"minus"
                    key:@"minimize"
               fallback:@"Minimize"];
  [self configureButton:mReturn
                 symbol:@"pip.exit"
                    key:@"returnToTab"
               fallback:@"Back to tab"];
  [self configureButton:mBack
                 symbol:@"gobackward.15"
                    key:@"back15"
               fallback:@"Back 15 seconds"];
  [self configureButton:mForward
                 symbol:@"goforward.15"
                    key:@"forward15"
               fallback:@"Forward 15 seconds"];
  [self refreshTab];
  mOverlay.needsLayout = YES;
}

- (void)configureButton:(ZenPipGlassControl*)aControl
                 symbol:(NSString*)aSymbol
                    key:(NSString*)aKey
               fallback:(NSString*)aFallback {
  [self configureButton:aControl
                 symbol:aSymbol
          variableValue:-1
                    key:aKey
               fallback:aFallback];
}

- (void)configureButton:(ZenPipGlassControl*)aControl
                 symbol:(NSString*)aSymbol
          variableValue:(double)aValue
                    key:(NSString*)aKey
               fallback:(NSString*)aFallback {
  CGFloat s = mSymbolScale;
  CGFloat point = aControl == mPlay                             ? 23 * s
                  : (aControl == mBack || aControl == mForward) ? 17 * s
                                                                : 13 * s;
  NSString* label = [self string:aKey fallback:aFallback];
  aControl.button.image = Symbol(aSymbol, std::max<CGFloat>(point, 11),
                                 [self symbolWeight], aValue);
  aControl.button.accessibilityLabel = label;
  aControl.button.toolTip = label;
}

- (void)refreshPlayButton {
  if (mPlaying) {
    [self configureButton:mPlay
                   symbol:@"pause.fill"
                      key:@"pause"
                 fallback:@"Pause"];
  } else if (mEnded) {
    [self configureButton:mPlay
                   symbol:@"arrow.counterclockwise"
                      key:@"replay"
                 fallback:@"Replay"];
  } else {
    [self configureButton:mPlay
                   symbol:@"play.fill"
                      key:@"play"
                 fallback:@"Play"];
  }
  if (mShowsSpinner) {
    mPlay.button.image = nil;  // the spinner takes the symbol's place
  }
}

- (void)refreshSoundButton {
  NSString* key = mMuted ? @"unmute" : @"mute";
  NSString* fallback = mMuted ? @"Unmute" : @"Mute";
  if (mMuted || mVolume <= 0) {
    [self configureButton:mSound
                   symbol:@"speaker.slash.fill"
                      key:key
                 fallback:fallback];
  } else {
    // The waves fill with the volume.
    [self configureButton:mSound
                   symbol:@"speaker.wave.3.fill"
            variableValue:mVolume
                      key:key
                 fallback:fallback];
  }
}

- (void)refreshCaptionsButton {
  NSString* key = !mCaptionsAvailable ? @"subtitlesUnavailable"
                  : mCaptionsEnabled  ? @"subtitlesOff"
                                      : @"subtitlesOn";
  NSString* fallback = !mCaptionsAvailable ? @"No subtitles"
                       : mCaptionsEnabled  ? @"Hide subtitles"
                                           : @"Show subtitles";
  [self configureButton:mCaptions
                 symbol:mCaptionsEnabled && mCaptionsAvailable
                            ? @"captions.bubble.fill"
                            : @"captions.bubble"
                    key:key
               fallback:fallback];
  mCaptions.button.enabled = mCaptionsAvailable;
  mCaptions.alphaValue = mCaptionsAvailable ? 1 : 0.45;
}

// The speed button shows the speed itself ("1×", "1.5×").
- (void)refreshSpeedButton {
  NSString* rate = FormatRate(mRate);
  NSFont* font = [NSFont
      monospacedDigitSystemFontOfSize:std::max<CGFloat>(12.5 * mSymbolScale, 11)
                               weight:[self symbolWeight]];
  mSpeed.button.attributedTitle = [[NSAttributedString alloc]
      initWithString:rate
          attributes:@{
            NSFontAttributeName : font,
            NSForegroundColorAttributeName : NSColor.whiteColor
          }];
  NSString* label = [self string:@"speed" fallback:@"Playback speed"];
  mSpeed.button.accessibilityLabel = label;
  mSpeed.button.accessibilityValueDescription = rate;
  mSpeed.button.toolTip = label;
}

- (CGFloat)speedWidthForHeight:(CGFloat)aHeight {
  return std::max(aHeight, ceil(mSpeed.button.attributedTitle.size.width) +
                               round(aHeight * 0.35));
}

- (BOOL)isSeekable {
  return mSeekable && std::isfinite(mDuration) && mDuration > 0;
}

// Speeds above normal can't do anything at a live stream's live edge.
- (BOOL)isRateBlocked:(double)aRate {
  return mLive && (![self isSeekable] || mAtLiveEdge) && aRate > 1 &&
         !SameRate(aRate, 1);
}

- (void)refreshTimeline {
  if ([self isSeekable]) {
    if (!mScrubbing) {
      mTimeline.slider.doubleValue =
          std::clamp(mCurrentTime / mDuration, 0.0, 1.0);
    }
    double shownTime =
        mScrubbing ? mTimeline.slider.doubleValue * mDuration : mCurrentTime;
    mTimeline.elapsed.stringValue = FormatTime(shownTime);
    mTimeline.duration.stringValue = FormatTime(mDuration);
    mTimeline.slider.hidden = NO;
    mTimeline.slider.accessibilityLabel = [self string:@"timeline"
                                              fallback:@"Playback position"];
    if (mLive) {
      // A DVR window: like YouTube, no times on screen (the window's start is
      // arbitrary); VoiceOver hears how far behind live the position is.
      mTimeline.slider.accessibilityValueDescription =
          mAtLiveEdge && !mScrubbing
              ? [self string:@"live" fallback:@"Live"]
              : FillTemplate([self string:@"behindLive"
                                 fallback:@"%1$@ behind live"],
                             FormatTime(std::max(0.0, mDuration - shownTime)));
    } else {
      mTimeline.slider.accessibilityValueDescription =
          FillTemplate([self string:@"timePosition" fallback:@"%1$@ of %2$@"],
                       FormatTime(shownTime), FormatTime(mDuration));
    }
  } else {
    mTimeline.slider.hidden = YES;
    mTimeline.elapsed.stringValue = mLive
                                        ? [self string:@"live" fallback:@"Live"]
                                        : FormatTime(mCurrentTime);
    mTimeline.duration.stringValue = @"";
  }
}

// The Live badge follows YouTube's live button: red at the live edge, grey
// when behind; it only acts as a button when the stream can be scrubbed.
- (void)refreshLiveBadge {
  BOOL scrubbable = mLive && [self isSeekable];
  BOOL atEdge = !scrubbable || mAtLiveEdge;
  CGFloat point = std::max<CGFloat>(12.5 * mSymbolScale, 11);
  NSFont* font = [NSFont systemFontOfSize:point weight:[self symbolWeight]];
  NSString* live = [self string:@"live" fallback:@"Live"];
  NSString* goLive = [self string:@"goLive" fallback:@"Go to live"];
  // A filled dot at the edge and a ring behind it, so the two differ by
  // shape as well as color.
  mLiveBadge.button.image = LiveDotImage(
      atEdge ? NSColor.systemRedColor : [NSColor colorWithWhite:1 alpha:0.6],
      round(point * 0.56), round(point * 0.4), atEdge);
  mLiveBadge.button.imagePosition = NSImageLeft;
  mLiveBadge.button.attributedTitle = [[NSAttributedString alloc]
      initWithString:live
          attributes:@{
            NSFontAttributeName : font,
            NSForegroundColorAttributeName : NSColor.whiteColor
          }];
  mLiveBadge.statusOnly = !scrubbable;
  mLiveBadge.button.accessibilityLabel = scrubbable ? goLive : live;
  mLiveBadge.button.accessibilityValueDescription =
      scrubbable && atEdge ? live : nil;
  mLiveBadge.button.toolTip = scrubbable ? goLive : nil;
}

#pragma mark Layout

- (void)overlayLayout {
  NSSize size = mOverlay.bounds.size;
  CGFloat W = size.width, H = size.height;
  if ([self symbolScale] != mSymbolScale) {
    [self refreshAllControls];  // symbols are drawn for the current size
  }
  CGFloat s = mSymbolScale;
  CGFloat inset = std::max<CGFloat>(7, round(10 * s));
  CGFloat topD = std::max<CGFloat>(26, round(30 * s));
  CGFloat spacing = std::max<CGFloat>(6, round(8 * s));
  CGFloat playD = std::max<CGFloat>(40, round(56 * s));
  CGFloat skipD = std::max<CGFloat>(30, round(42 * s));
  CGFloat centerGap = round(30 * s);
  BOOL seekable = [self isSeekable];
  CGFloat timelineH = std::max<CGFloat>(H < 150 ? 22 : 26, round(32 * s));
  if (mLive && seekable) {
    timelineH = std::max<CGFloat>(timelineH, 24);  // the Live badge is a button
  }
  BOOL showSkip = seekable && W >= 250 && H >= 150;
  // A live stream that can't be scrubbed plays at its own pace.
  BOOL showSpeed = W >= 300 && !(mLive && !seekable);
  BOOL showCaptions = W >= 270;
  BOOL showMinimize = W >= 230;

  // The corners stay concentric with the controls in them.
  [self applyCornerRadius:topD / 2 + inset];

  // Bottom row. A live stream shows its Live badge at the left; the timeline
  // follows only when the stream can be scrubbed.
  CGFloat rowX = inset;
  mLiveBadge.hidden = !mLive;
  if (mLive) {
    CGFloat contentW = mLiveBadge.button.image.size.width +
                       mLiveBadge.button.attributedTitle.size.width;
    mLiveBadge.frame =
        NSMakeRect(inset, inset, ceil(contentW) + round(24 * s), timelineH);
    rowX = NSMaxX(mLiveBadge.frame) + spacing;
  }
  BOOL showTimeline = mLive ? seekable : (seekable || std::isfinite(mDuration));
  BOOL showLabels = !mLive && (W >= 290 || !seekable);

  // Top row: playback options from the leading edge, window controls against
  // the trailing edge with close in the corner. Right-to-left languages
  // mirror it; the timeline and the transport row keep their direction, as
  // in other media players.
  BOOL rtl = mConfig.rightToLeft;
  CGFloat topY = H - inset - topD;
  CGFloat lead = inset;
  for (ZenPipGlassControl* c in @[ mSpeed, mCaptions, mSound ]) {
    BOOL show = c == mSpeed ? showSpeed : c == mCaptions ? showCaptions : YES;
    c.hidden = !show;
    if (!show) {
      continue;
    }
    CGFloat w = c == mSpeed ? [self speedWidthForHeight:topD] : topD;
    c.frame = NSMakeRect(rtl ? W - lead - w : lead, topY, w, topD);
    lead += w + spacing;
  }
  mMinimize.hidden = !showMinimize;
  CGFloat trail = inset;
  for (ZenPipGlassControl* c in @[ mClose, mMinimize, mReturn ]) {
    if (c.isHidden) {
      continue;
    }
    c.frame = NSMakeRect(rtl ? trail : W - trail - topD, topY, topD, topD);
    trail += topD + spacing;
  }

  // Center the transport row in the space between the top row and the
  // timeline so small players never overlap them.
  CGFloat cy =
      seekable || mLive ? round((inset + timelineH + topY) / 2) : round(H / 2);
  mPlay.frame =
      NSMakeRect(round(W / 2 - playD / 2), round(cy - playD / 2), playD, playD);
  mBack.hidden = !showSkip;
  mForward.hidden = !showSkip;
  mBack.frame = NSMakeRect(NSMinX(mPlay.frame) - centerGap - skipD,
                           round(cy - skipD / 2), skipD, skipD);
  mForward.frame = NSMakeRect(NSMaxX(mPlay.frame) + centerGap,
                              round(cy - skipD / 2), skipD, skipD);
  CGFloat spin = round(playD * 0.42);
  mSpinner.controlSize = spin >= 24 ? NSControlSizeRegular : NSControlSizeSmall;
  mSpinner.frame = NSMakeRect(round((playD - spin) / 2),
                              round((playD - spin) / 2), spin, spin);

  mTimeline.fontSize = std::max<CGFloat>(10.5, round(12 * s * 2) / 2);
  mTimeline.showsLabels = showLabels;
  mTimeline.frame = NSMakeRect(rowX, inset, W - inset - rowX, timelineH);
  mTimeline.hidden = !showTimeline;
}

// Rounds the player's corners with `aRadius` (instead of the system's
// smaller window radius), so that the glass controls in them are concentric
// with the corners. The window must be transparent around them; in the
// browser the player's stylesheet keeps it so, as Gecko re-derives that from
// the page.
- (void)applyCornerRadius:(CGFloat)aRadius {
  NSWindow* window = mWindow;
  NSView* content = window.contentView;
  if (!content) {
    return;
  }
  content.wantsLayer = YES;
  CALayer* layer = content.layer;
  if (layer.masksToBounds && std::abs(layer.cornerRadius - aRadius) < 0.5) {
    return;
  }
  window.opaque = NO;
  window.backgroundColor = NSColor.clearColor;
  layer.cornerRadius = aRadius;
  layer.cornerCurve = kCACornerCurveContinuous;
  layer.masksToBounds = YES;
  [window invalidateShadow];
}

// Where the timeline's top edge is, in points from the top of the player (the
// Live badge shares its row).
- (CGFloat)timelineTopFromWindowTop {
  return mOverlay.bounds.size.height - NSMaxY(mTimeline.frame) - 6;
}

#pragma mark Controls visibility

- (BOOL)keyboardFocusInControls {
  NSResponder* responder = mWindow.firstResponder;
  return [responder isKindOfClass:[NSView class]] &&
         [(NSView*)responder isDescendantOf:mControls];
}

- (BOOL)shouldKeepControlsVisible {
  return mSticky || mScrubbing || mMenuOpen || mAppearance.voiceOver ||
         [self keyboardFocusInControls] || (!mPlaying && mPointerInside) ||
         [self pointerOverControl];
}

- (BOOL)pointerOverControl {
  NSWindow* window = mWindow;
  if (!window || !mPointerInside || !mControlsVisible) {
    return NO;
  }
  NSPoint p = [mOverlay convertPoint:window.mouseLocationOutsideOfEventStream
                            fromView:nil];
  NSView* hit = [mOverlay hitTest:[mOverlay convertPoint:p
                                                  toView:mOverlay.superview]];
  return hit && hit != mOverlay;
}

- (void)showControls {
  if (mControlsVisible || mStashed || mExiting) {
    return;
  }
  mControlsVisible = YES;
  [self refreshTimeline];
  mControlsRoot.hidden = NO;
  mScrim.hidden = NO;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = kRevealDuration;
    ctx.timingFunction = EaseOut();
    mControlsRoot.animator.alphaValue = 1;
    mScrim.animator.alphaValue = 1;
  }];
  [self notifyHost:"controls"
             value:1
            detail:JSONString(
                       @{@"timelineTop" : @([self timelineTopFromWindowTop])})];
}

// Hides the controls, quickly when the pointer left the player and more
// softly when it rests on it.
- (void)hideControls {
  if (!mControlsVisible) {
    return;
  }
  mControlsVisible = NO;
  __weak ZenPipPlayerChrome* weakSelf = self;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = mPointerInside ? kIdleHideDuration : kHideDuration;
        ctx.timingFunction = EaseIn();
        mControlsRoot.animator.alphaValue = 0;
        mScrim.animator.alphaValue = 0;
      }
      completionHandler:^{
        ZenPipPlayerChrome* chrome = weakSelf;
        if (chrome && !chrome->mControlsVisible) {
          // Hidden glass costs nothing to composite.
          chrome->mControlsRoot.hidden = YES;
          chrome->mScrim.hidden = YES;
        }
      }];
  if (mPointerInside) {
    [NSCursor setHiddenUntilMouseMoves:YES];
  }
  [self notifyHost:"controls" value:0 detail:@"{}"];
}

- (void)noteActivity {
  [self showControls];
  [self hideAfter:mConfig.idleHideDelay];
}

// The controls hide `aDelay` from now, unless something keeps them up then
// (see -shouldKeepControlsVisible).
- (void)hideAfter:(NSTimeInterval)aDelay {
  mHideAt = CACurrentMediaTime() + aDelay;
  if (mHideTimer && mHideTimer.fireDate.timeIntervalSinceNow > aDelay + 0.05) {
    [mHideTimer invalidate];
    mHideTimer = nil;
  }
  [self scheduleHide];
}

// One timer at a time; it re-checks the deadline when it fires.
- (void)scheduleHide {
  if (mHideTimer || mInvalidated) {
    return;
  }
  __weak ZenPipPlayerChrome* weakSelf = self;
  mHideTimer =
      [NSTimer timerWithTimeInterval:std::max<NSTimeInterval>(
                                         0.05, mHideAt - CACurrentMediaTime())
                             repeats:NO
                               block:^(NSTimer*) {
                                 [weakSelf hideTimerFired];
                               }];
  mHideTimer.tolerance = 0.1;
  [NSRunLoop.mainRunLoop addTimer:mHideTimer forMode:NSRunLoopCommonModes];
}

- (void)hideTimerFired {
  mHideTimer = nil;
  if (CACurrentMediaTime() < mHideAt - 0.05) {
    [self scheduleHide];
    return;
  }
  if ([self shouldKeepControlsVisible]) {
    return;  // re-armed when the reason ends (activity, play, scrub end...)
  }
  [self hideControls];
}

- (void)revealControlsFor:(NSTimeInterval)aDuration {
  [self showControls];
  [self hideAfter:aDuration];
}

- (void)revealControlsSticky:(BOOL)aSticky {
  mSticky = aSticky;
  if (aSticky) {
    [self showControls];
  } else {
    [self noteActivity];
  }
}

- (void)focusControls {
  if (mStashed) {
    return;
  }
  [self showControls];
  [mWindow makeFirstResponder:mPlay.button];
}

#pragma mark Actions

- (void)onClose:(id)aSender {
  [self notifyHost:"close" value:0 detail:nil];
}
- (void)onMinimize:(id)aSender {
  [self minimize];
}
- (void)onReturn:(id)aSender {
  [self notifyHost:"return" value:0 detail:nil];
}
- (void)onPlay:(id)aSender {
  [self notifyHost:"toggle-play" value:0 detail:nil];
  [self noteActivity];
}
- (void)onBack:(id)aSender {
  [self notifyHost:"seek-relative" value:-15 detail:nil];
  [self noteActivity];
}
- (void)onForward:(id)aSender {
  [self notifyHost:"seek-relative" value:15 detail:nil];
  [self noteActivity];
}
- (void)onLive:(id)aSender {
  if (mLiveBadge.statusOnly) {
    return;
  }
  [self notifyHost:"go-live" value:0 detail:nil];
  [self noteActivity];
}
- (void)onSound:(id)aSender {
  [self notifyHost:"toggle-mute" value:0 detail:nil];
  [self noteActivity];
}
- (void)onCaptions:(id)aSender {
  [self notifyHost:"toggle-captions" value:0 detail:nil];
  [self noteActivity];
}

// The speed button's drop-down: a "Playback speed" heading over the speeds,
// with the current one checked (also when the site chose a speed of its own).
- (NSMenu*)speedMenu {
  NSMenu* menu = [[NSMenu alloc] init];
  menu.delegate = self;
  NSString* title = [self string:@"speed" fallback:@"Playback speed"];
  if (@available(macOS 14.0, *)) {
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:title]];
  } else {
    [menu addItem:[[NSMenuItem alloc] initWithTitle:title
                                             action:nil
                                      keyEquivalent:@""]];
  }
  std::vector<double> rates(std::begin(kSpeedMenuRates),
                            std::end(kSpeedMenuRates));
  if (std::none_of(rates.begin(), rates.end(),
                   [&](double r) { return SameRate(r, mRate); })) {
    rates.push_back(mRate);
    std::sort(rates.begin(), rates.end());
  }
  for (double rate : rates) {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:FormatRate(rate)
                                                  action:@selector(onRateItem:)
                                           keyEquivalent:@""];
    item.target = self;
    item.representedObject = @(rate);
    item.state =
        SameRate(rate, mRate) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:item];
  }
  return menu;
}

- (void)onSpeed:(id)aSender {
  // The menu tracks in a nested event loop, while Gecko keeps running: the
  // player can close and drop its chrome before it returns.
  ZenPipPlayerChrome* keepAlive = self;
  NSButton* button = mSpeed.button;
  // Drops down from the button's bottom-left corner (NSButton is flipped).
  [[self speedMenu]
      popUpMenuPositioningItem:nil
                    atLocation:NSMakePoint(0, NSHeight(button.bounds) + 4)
                        inView:button];
  if (!keepAlive->mInvalidated) {
    [keepAlive noteActivity];
  }
}

- (void)onRateItem:(NSMenuItem*)aItem {
  [self notifyHost:"set-rate"
             value:[aItem.representedObject doubleValue]
            detail:nil];
}

- (void)menuNeedsUpdate:(NSMenu*)aMenu {
  if (aMenu != mCaptions.button.menu) {
    return;
  }
  [aMenu removeAllItems];
  NSMenuItem* toggle = [[NSMenuItem alloc]
      initWithTitle:[self string:@"subtitlesMenu" fallback:@"Subtitles"]
             action:@selector(onCaptions:)
      keyEquivalent:@""];
  toggle.target = self;
  toggle.state =
      mCaptionsEnabled ? NSControlStateValueOn : NSControlStateValueOff;
  [aMenu addItem:toggle];
  [aMenu addItem:[NSMenuItem separatorItem]];
  [aMenu addItem:[[NSMenuItem alloc] initWithTitle:[self string:@"captionsSize"
                                                       fallback:@"Font size"]
                                            action:nil
                                     keyEquivalent:@""]];
  for (NSString* size in @[ @"small", @"medium", @"large" ]) {
    NSString* key = [@"captionSize-" stringByAppendingString:size];
    NSMenuItem* item = [[NSMenuItem alloc]
        initWithTitle:[self string:key fallback:size.capitalizedString]
               action:@selector(onCaptionSizeItem:)
        keyEquivalent:@""];
    item.target = self;
    item.representedObject = size;
    item.state = [size isEqualToString:mCaptionSize] ? NSControlStateValueOn
                                                     : NSControlStateValueOff;
    item.indentationLevel = 1;
    [aMenu addItem:item];
  }
}

- (BOOL)validateMenuItem:(NSMenuItem*)aItem {
  if (aItem.action == @selector(onCaptions:)) {
    return mCaptionsAvailable;
  }
  if (aItem.action == @selector(onRateItem:)) {
    return ![self isRateBlocked:[aItem.representedObject doubleValue]];
  }
  return YES;
}

- (void)onCaptionSizeItem:(NSMenuItem*)aItem {
  mCaptionSize = aItem.representedObject;
  [self notifyHost:"caption-size" value:0 detail:mCaptionSize];
}

- (void)menuWillOpen:(NSMenu*)aMenu {
  mMenuOpen = YES;
  [self showControls];
}

- (void)menuDidClose:(NSMenu*)aMenu {
  mMenuOpen = NO;
  [self noteActivity];
}

- (void)onScrub:(NSSlider*)aSlider {
  NSEventType type = NSApp.currentEvent.type;
  double position = std::clamp(aSlider.doubleValue, 0.0, 1.0);
  BOOL tracking =
      type == NSEventTypeLeftMouseDown || type == NSEventTypeLeftMouseDragged;
  if (tracking && !mScrubbing) {
    mScrubbing = YES;
    [self notifyHost:"scrub-start" value:position detail:nil];
  }
  if (mScrubbing) {
    [self notifyHost:tracking ? "scrub" : "scrub-end"
               value:position
              detail:nil];
    if (!tracking) {
      mScrubbing = NO;
    }
  } else {
    // Keyboard or accessibility adjustment: a single discrete seek.
    [self notifyHost:"scrub-start" value:position detail:nil];
    [self notifyHost:"scrub-end" value:position detail:nil];
  }
  if (std::isfinite(mDuration)) {
    mCurrentTime = position * mDuration;
  }
  [self refreshTimeline];
  [self noteActivity];
}

#pragma mark Keyboard

- (void)overlayKeyDown:(NSEvent*)aEvent {
  NSEventModifierFlags mods = aEvent.modifierFlags;
  unsigned short code = aEvent.keyCode;
  if (code == kKeyTab) {
    // Unhandled Tabs from a focused control bubble up to us: move along the
    // reading order instead of jumping back to the first control.
    [self moveKeyboardFocusBackwards:(mods & NSEventModifierFlagShift) != 0];
    [self noteActivity];
    return;
  }
  if (code == kKeyEscape && [self keyboardFocusInControls]) {
    [mWindow makeFirstResponder:mOverlay];
    [self noteActivity];
    return;
  }
  BOOL command = (mods & NSEventModifierFlagCommand) != 0;
  if (command && code == kKeyM) {
    [self minimize];  // like Command-M on any window
    return;
  }
  // The application menu takes the Command shortcuts the player has no use
  // for (⌘Q, ⌘H, ⌘,), as in any other Zen window.
  if (command && !IsPlayerCommandKey(aEvent) && mHost &&
      mHost->PerformMenuKeyEquivalent(aEvent)) {
    return;
  }
  NSString* key = aEvent.charactersIgnoringModifiers ?: @"";
  NSDictionary* detail = @{
    @"key" : key,
    @"shift" : @((mods & NSEventModifierFlagShift) != 0),
    @"alt" : @((mods & NSEventModifierFlagOption) != 0),
    @"ctrl" : @((mods & NSEventModifierFlagControl) != 0),
    @"meta" : @((mods & NSEventModifierFlagCommand) != 0),
  };
  [self notifyHost:"key" value:code detail:JSONString(detail)];
  [self noteActivity];
}

#pragma mark Geometry helpers

- (nullable NSScreen*)sourceScreen {
  NSWindow* source = mSourceWindow;
  if (source.screen) {
    return source.screen;
  }
  NSArray<NSScreen*>* screens = NSScreen.screens;
  if (source && screens.count) {
    // Off-screen or minimized: the display nearest to its frame.
    std::vector<Box> frames;
    for (NSScreen* screen in screens) {
      frames.push_back(ToRect(screen.frame));
    }
    return screens[ScreenIndexForRect(ToRect(source.frame), frames)];
  }
  return mWindow.screen ?: NSScreen.mainScreen;
}

// The display the player lives on: the one the user dragged it onto, as long
// as it is connected; otherwise the source window's display.
- (nullable NSScreen*)homeScreen {
  if (mHomeDisplay) {
    for (NSScreen* screen in NSScreen.screens) {
      if (DisplayID(screen) == mHomeDisplay) {
        return screen;
      }
    }
  }
  return [self sourceScreen];
}

- (BOOL)homeIsPinned {
  NSScreen* home = [self homeScreen];
  return mHomeDisplay && home && DisplayID(home) == mHomeDisplay;
}

- (Box)visibleFrame {
  NSScreen* screen = [self homeScreen];
  return screen ? ToRect(screen.visibleFrame) : Box{0, 0, 1440, 900};
}

- (Box)allowedArea {
  return AllowedArea([self visibleFrame], mConfig.edgeGap);
}

// Whether another display continues past the left or right edge of the
// player's display beside `aFrame` (the player would cross onto it).
- (BOOL)hasDisplayBeyond:(HEdge)aSide of:(const Box&)aFrame {
  NSScreen* home = [self homeScreen];
  NSRect h = home.frame;
  for (NSScreen* screen in NSScreen.screens) {
    NSRect f = screen.frame;
    if (DisplayID(screen) == DisplayID(home) || NSMaxY(f) <= aFrame.MinY() ||
        NSMinY(f) >= aFrame.MaxY()) {
      continue;
    }
    if (aSide == HEdge::Left ? std::abs(NSMaxX(f) - NSMinX(h)) < 2
                             : std::abs(NSMinX(f) - NSMaxX(h)) < 2) {
      return YES;
    }
  }
  return NO;
}

// The frames of the other players that are on screen.
- (std::vector<Box>)otherPlayerFrames {
  std::vector<Box> frames;
  for (ZenPipPlayerChrome* other in AllPlayers()) {
    NSWindow* window = other->mWindow;
    if (other != self && window.isVisible && !other->mStashed) {
      frames.push_back(ToRect(window.frame));
    }
  }
  return frames;
}

// A new player opened over another one moves to a free corner.
- (void)moveClearOfOtherPlayers {
  Box frame = ToRect(mWindow.frame);
  std::vector<Box> others = [self otherPlayerFrames];
  if (std::none_of(others.begin(), others.end(), [&](const Box& aOther) {
        return aOther.IntersectionArea(frame) > 0;
      })) {
    return;
  }
  Corner corner = NearestFreeCorner(frame.Center(), frame.Size(),
                                    [self allowedArea], others);
  mRestDock = corner.dock;
  [self setWindowOrigin:corner.origin];
}

- (void)setWindowOrigin:(Vec2)aOrigin {
  mSettingFrame = YES;
  [mWindow setFrameOrigin:NSMakePoint(aOrigin.x, aOrigin.y)];
  mSettingFrame = NO;
}

- (void)setPlayerFrame:(NSRect)aFrame {
  mSettingFrame = YES;
  [mWindow setFrame:aFrame display:YES];
  mSettingFrame = NO;
}

// Re-establishes containment on the player's display: the same size limits
// and, after the usable area changed (Dock or menu bar shown, hidden or
// moved, a display rearranged), the same edges it rests against.
- (void)settleAnimated:(BOOL)aAnimated {
  NSWindow* window = mWindow;
  if (!window || mStashed || mExiting || mGesture != ZenPipGestureNone ||
      mFrameAnimations > 0) {
    return;
  }
  Box area = [self allowedArea];
  Box frame = ToRect(window.frame);
  if (area.IntersectionArea(frame) <= 0) {
    // On another display (e.g. the one it was on disconnected): carry its
    // placement over.
    std::vector<Box> areas = ScreenAreas(mConfig.edgeGap);
    Box from = areas.empty() ? frame : areas[ScreenIndexForRect(frame, areas)];
    [self hopWithPlacement:PlacementForFrame(frame, from, kDockTolerance)
                  animated:aAnimated];
    return;
  }
  Vec2 size = ClampSize(frame.width, mAspect, area, mConfig.limits);
  if (std::abs(size.x - frame.width) > 0.5 ||
      std::abs(size.y - frame.height) > 0.5) {
    [self stopAnimation];
    frame = ScaleFrame(frame, size.x / frame.width, mAspect, mRestDock, area,
                       mConfig.limits);
    [self setPlayerFrame:ToNSRect(frame)];
  }
  Vec2 target =
      OriginForDock(mRestDock, ClampOrigin(frame.Origin(), frame.Size(), area),
                    frame.Size(), area);
  if ((target - frame.Origin()).Length() < 0.5) {
    if (![self isAnimating]) {
      [self reportPlacement];
    }
    return;
  }
  [self animateTo:target velocity:{} animated:aAnimated];
}

- (void)sourceScreenChanged {
  NSWindow* window = mWindow;
  if (!window || mStashed || mExiting) {
    return;
  }
  if ([self homeIsPinned]) {
    // The user put the player on another display; it stays there.
    [self settleAnimated:YES];
    return;
  }
  Box frame = ToRect(window.frame);
  std::vector<Box> areas = ScreenAreas(mConfig.edgeGap);
  Box from = areas.empty() ? frame : areas[ScreenIndexForRect(frame, areas)];
  [self hopWithPlacement:PlacementForFrame(frame, from, kDockTolerance)
                animated:YES];
}

// Moves the player onto its home display with the same placement.
- (void)hopWithPlacement:(const Placement&)aPlacement animated:(BOOL)aAnimated {
  Box area = [self allowedArea];
  Vec2 size =
      ClampSize(mWindow.frame.size.width, mAspect, area, mConfig.limits);
  Vec2 target = OriginForPlacement(aPlacement, size, area);
  mRestDock = aPlacement.dock;
  NSRect destination = NSMakeRect(target.x, target.y, size.x, size.y);
  if (aAnimated) {
    [self hopToFrame:destination];
  } else {
    [self setPlayerFrame:destination];
    [self reportPlacement];
  }
}

// Crossing displays: fade out, move, fade back in (no flight across, so the
// player is never split between two displays).
- (void)hopToFrame:(NSRect)aDestination {
  NSWindow* window = mWindow;
  [self stopAnimation];
  if (mAppearance.reduceMotion) {
    [self setPlayerFrame:aDestination];
    [self reportPlacement];
    return;
  }
  __weak ZenPipPlayerChrome* weakSelf = self;
  mFrameAnimations++;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = 0.12;
        ctx.timingFunction = EaseIn();
        window.animator.alphaValue = 0;
      }
      completionHandler:^{
        ZenPipPlayerChrome* chrome = weakSelf;
        if (!chrome) {
          return;
        }
        [chrome setPlayerFrame:aDestination];
        [chrome fadeInAfterHop];
        chrome->mFrameAnimations--;
        [chrome reportPlacement];
      }];
}

- (void)fadeInAfterHop {
  NSWindow* window = mWindow;
  if (mAppearance.reduceMotion || mExiting) {
    window.alphaValue = 1;
    return;
  }
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.18;
    ctx.timingFunction = EaseOut();
    window.animator.alphaValue = 1;
  }];
}

- (void)reportPlacement {
  NSWindow* window = mWindow;
  if (!window || mStashed || mExiting) {
    return;
  }
  Box frame = ToRect(window.frame);
  Placement p = PlacementForFrame(frame, [self allowedArea], kDockTolerance);
  mRestDock = p.dock;
  [self notifyHost:"placement"
             value:0
            detail:JSONString(@{
              @"dock" : DockName(p.dock),
              @"fx" : @(p.fx),
              @"fy" : @(p.fy),
              @"width" : @(frame.width),
              @"height" : @(frame.height)
            })];
  [self applyVideoAspect];
}

#pragma mark Animation

- (BOOL)isAnimating {
  if (@available(macOS 14.0, *)) {
    if (mDisplayLink) {
      return YES;
    }
  }
  return mFallbackAnimationTimer || mFrameAnimations > 0;
}

- (void)animateTo:(Vec2)aTarget
         velocity:(Vec2)aVelocity
         animated:(BOOL)aAnimated {
  NSWindow* window = mWindow;
  [self stopAnimation];
  Vec2 from = ToRect(window.frame).Origin();
  if (!aAnimated || mAppearance.reduceMotion ||
      (from - aTarget).Length() < 0.5) {
    [self setWindowOrigin:aTarget];
    [self reportPlacement];
    return;
  }
  // Bounded inertia: never fling harder than the spring can absorb before
  // the target, so the player glides in instead of slamming into the edge.
  double omega = 2 * M_PI / mConfig.spring.response;
  auto bound = [&](double aV, double aDistance) {
    double limit = omega * std::abs(aDistance) * 1.15 + 120;
    bool toward = aV * aDistance > 0;
    return toward ? std::clamp(aV, -limit, limit)
                  : std::clamp(aV, -2500.0, 2500.0);
  };
  Vec2 toTarget = aTarget - from;
  mSpring.Start(
      from, {bound(aVelocity.x, toTarget.x), bound(aVelocity.y, toTarget.y)},
      aTarget, mConfig.spring);
  mSpringStart = CACurrentMediaTime();
  if (@available(macOS 14.0, *)) {
    mDisplayLink = [mOverlay displayLinkWithTarget:self
                                          selector:@selector(animationStep:)];
    [mDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                       forMode:NSRunLoopCommonModes];
  } else {
    __weak ZenPipPlayerChrome* weakSelf = self;
    mFallbackAnimationTimer =
        [NSTimer timerWithTimeInterval:1.0 / 60
                               repeats:YES
                                 block:^(NSTimer*) {
                                   [weakSelf animationStep:nil];
                                 }];
    [NSRunLoop.mainRunLoop addTimer:mFallbackAnimationTimer
                            forMode:NSRunLoopCommonModes];
  }
}

- (void)animationStep:(id)aLink {
  NSWindow* window = mWindow;
  if (!window) {
    [self stopAnimation];
    return;
  }
  double t = CACurrentMediaTime() - mSpringStart;
  Vec2 size = ToRect(window.frame).Size();
  if (mSpring.IsSettled(t) || t > 3) {
    // The area may have changed during the flight.
    [self stopAnimation];
    [self setWindowOrigin:ClampOrigin(mSpring.Target(), size,
                                      [self allowedArea])];
    [self reportPlacement];
    return;
  }
  Vec2 position, velocity;
  mSpring.Sample(t, &position, &velocity);
  // Even mid-flight the frame never leaves the display's usable area.
  [self setWindowOrigin:ClampOrigin(position, size, [self visibleFrame])];
}

- (void)stopAnimation {
  if (@available(macOS 14.0, *)) {
    [mDisplayLink invalidate];
    mDisplayLink = nil;
  }
  [mFallbackAnimationTimer invalidate];
  mFallbackAnimationTimer = nil;
}

// Animates the window's frame, and its alpha unless `aAlpha` is negative.
- (void)animateFrame:(NSRect)aFrame
               alpha:(CGFloat)aAlpha
            duration:(NSTimeInterval)aDuration
               curve:(CAMediaTimingFunction*)aCurve
          completion:(void (^_Nullable)(ZenPipPlayerChrome* aChrome))aDone {
  NSWindow* window = mWindow;
  __weak ZenPipPlayerChrome* weakSelf = self;
  mFrameAnimations++;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = aDuration;
        ctx.timingFunction = aCurve;
        [window.animator setFrame:aFrame display:YES];
        if (aAlpha >= 0) {
          window.animator.alphaValue = aAlpha;
        }
      }
      completionHandler:^{
        ZenPipPlayerChrome* chrome = weakSelf;
        if (!chrome) {
          return;
        }
        chrome->mFrameAnimations--;
        if (aDone) {
          aDone(chrome);
        }
      }];
}

#pragma mark Pointer gestures

// The resize handle at a point in overlay coordinates: the resize border (see
// kResizeBand), including just outside the window, except where a control is
// drawn on it.
- (std::optional<ResizeHandle>)resizeHandleAt:(NSPoint)aPoint {
  NSSize size = mOverlay.bounds.size;
  if (size.width < 120 || size.height < 80) {
    return std::nullopt;
  }
  BOOL left = aPoint.x<kResizeBand, right = aPoint.x> size.width - kResizeBand;
  BOOL bottom = aPoint.y<kResizeBand, top = aPoint.y> size.height - kResizeBand;
  BOOL cLeft = aPoint.x<kResizeCornerBand, cRight = aPoint.x> size.width -
               kResizeCornerBand;
  BOOL cBottom = aPoint.y<kResizeCornerBand, cTop = aPoint.y> size.height -
                 kResizeCornerBand;
  BOOL corner = (cLeft || cRight) && (cBottom || cTop);
  if (!(left || right || bottom || top || corner) ||
      [self controlDrawnAt:aPoint]) {
    return std::nullopt;
  }
  if (cLeft && cBottom) return ResizeHandle::BottomLeft;
  if (cRight && cBottom) return ResizeHandle::BottomRight;
  if (cLeft && cTop) return ResizeHandle::TopLeft;
  if (cRight && cTop) return ResizeHandle::TopRight;
  if (left) return ResizeHandle::Left;
  if (right) return ResizeHandle::Right;
  if (bottom) return ResizeHandle::Bottom;
  return ResizeHandle::Top;
}

// The button or slider under a point in overlay coordinates, if any.
- (nullable NSView*)controlAt:(NSPoint)aPoint {
  NSView* parent = mOverlay.superview;
  NSView* control = parent ? [mOverlay hitTest:[mOverlay convertPoint:aPoint
                                                               toView:parent]]
                           : nil;
  while (control && control != mOverlay &&
         ![control isKindOfClass:[NSButton class]] &&
         ![control isKindOfClass:[NSSlider class]]) {
    control = control.superview;
  }
  return control == mOverlay ? nil : control;
}

// Whether a control is drawn at a point in overlay coordinates: inside a
// button's circle or capsule or the slider's track, not merely inside the
// rectangle around it. Small players bring the controls within the resize
// border; their empty corners still resize.
- (BOOL)controlDrawnAt:(NSPoint)aPoint {
  NSView* control = [self controlAt:aPoint];
  if (!control) {
    return NO;
  }
  NSRect r = [mOverlay convertRect:control.bounds fromView:control];
  CGFloat radius = std::min(r.size.width, r.size.height) / 2;
  return [[NSBezierPath bezierPathWithRoundedRect:r
                                          xRadius:radius
                                          yRadius:radius] containsPoint:aPoint];
}

// The local event monitor's filter (see init). The chrome handles every left
// press in the player outside its controls itself, with its drags and its
// release, so AppKit sees none of them: AppKit makes the window key on every
// press (a drag from another app would take the keyboard), and resizes from
// its own border areas with its own anchoring, growing the window toward the
// screen corner when two presses land on a corner within the double-click
// interval. Presses on the buttons and the slider pass through.
- (nullable NSEvent*)filterPress:(NSEvent*)aEvent {
  if (aEvent.type != NSEventTypeLeftMouseDown) {
    if (!mOwnsPress) {
      return aEvent;
    }
    NSPoint pointer = EventScreenLocation(aEvent);
    if (aEvent.type == NSEventTypeLeftMouseUp) {
      mOwnsPress = NO;
      [self gestureEndedAt:pointer
                      time:aEvent.timestamp
                clickCount:aEvent.clickCount
                 modifiers:aEvent.modifierFlags];
    } else {
      [self gestureMovedTo:pointer time:aEvent.timestamp];
    }
    return nil;
  }
  mOwnsPress = NO;
  NSWindow* window = mWindow;
  if (mInvalidated || mExiting || !window || aEvent.window != window) {
    return aEvent;
  }
  NSPoint local = [mOverlay convertPoint:aEvent.locationInWindow fromView:nil];
  std::optional<ResizeHandle> handle = [self resizeHandleAt:local];
  if (!handle && [self controlAt:local]) {
    return aEvent;
  }
  mOwnsPress = YES;
  [self beginGestureAt:EventScreenLocation(aEvent) time:aEvent.timestamp];
  if (handle) {
    mGesture = ZenPipGestureResize;
    mResizeHandle = *handle;
    [[self cursorForHandle:*handle] set];
  } else {
    mGesture = ZenPipGesturePending;
  }
  [self noteActivity];
  return nil;
}

- (NSCursor*)cursorForHandle:(ResizeHandle)aHandle {
  if (@available(macOS 15.0, *)) {
    NSCursorFrameResizePosition position;
    switch (aHandle) {
      case ResizeHandle::Left:
        position = NSCursorFrameResizePositionLeft;
        break;
      case ResizeHandle::Right:
        position = NSCursorFrameResizePositionRight;
        break;
      case ResizeHandle::Bottom:
        position = NSCursorFrameResizePositionBottom;
        break;
      case ResizeHandle::Top:
        position = NSCursorFrameResizePositionTop;
        break;
      case ResizeHandle::BottomLeft:
        position = NSCursorFrameResizePositionBottomLeft;
        break;
      case ResizeHandle::BottomRight:
        position = NSCursorFrameResizePositionBottomRight;
        break;
      case ResizeHandle::TopLeft:
        position = NSCursorFrameResizePositionTopLeft;
        break;
      case ResizeHandle::TopRight:
        position = NSCursorFrameResizePositionTopRight;
        break;
    }
    return [NSCursor
        frameResizeCursorFromPosition:position
                         inDirections:NSCursorFrameResizeDirectionsAll];
  }
  switch (aHandle) {
    case ResizeHandle::Left:
    case ResizeHandle::Right:
      return NSCursor.resizeLeftRightCursor;
    case ResizeHandle::Bottom:
    case ResizeHandle::Top:
      return NSCursor.resizeUpDownCursor;
    default:
      return NSCursor.crosshairCursor;
  }
}

- (void)overlayUpdateCursor:(NSEvent*)aEvent {
  if (mGesture == ZenPipGestureResize) {
    [[self cursorForHandle:mResizeHandle] set];
    return;
  }
  std::optional<ResizeHandle> handle =
      [self resizeHandleAt:[mOverlay convertPoint:aEvent.locationInWindow
                                         fromView:nil]];
  [(handle ? [self cursorForHandle:*handle] : NSCursor.arrowCursor) set];
}

- (void)overlayMouseMoved:(NSEvent*)aEvent {
  mPointerInside = YES;
  if (mGesture == ZenPipGestureNone) {
    [self overlayUpdateCursor:aEvent];
  }
  [self noteActivity];
}

- (void)overlayMouseExited {
  mPointerInside = NO;
  if (mGesture == ZenPipGestureNone) {
    [NSCursor.arrowCursor set];
    [self hideAfter:kPointerLeftGrace];
  }
}

// New input catches the player wherever it currently is.
- (void)beginGestureAt:(NSPoint)aScreenPoint time:(NSTimeInterval)aTime {
  NSWindow* window = mWindow;
  mCaughtMoving = [self isAnimating] && mFrameAnimations == 0;
  [self stopAnimation];
  [self cancelEdgeHold];
  mGestureMoved = NO;
  mPushingEdge = NO;
  mStashArmed = HEdge::None;
  mGestureStartMouse = aScreenPoint;
  mGestureStartFrame = window.frame;
  mGestureDock =
      DetectDock(ToRect(window.frame), [self allowedArea], kDockTolerance);
  mSamples.clear();
  mSamples.push_back({aTime, {aScreenPoint.x, aScreenPoint.y}});
}

- (void)gestureMovedTo:(NSPoint)aScreenPoint time:(NSTimeInterval)aTime {
  NSPoint delta = NSMakePoint(aScreenPoint.x - mGestureStartMouse.x,
                              aScreenPoint.y - mGestureStartMouse.y);
  mSamples.push_back({aTime, {aScreenPoint.x, aScreenPoint.y}});
  if (mSamples.size() > 32) {
    mSamples.erase(mSamples.begin(), mSamples.begin() + 16);
  }
  if (!mGestureMoved && std::hypot(delta.x, delta.y) >= kDragThreshold) {
    mGestureMoved = YES;
    if (mGesture == ZenPipGesturePending) {
      mGesture = ZenPipGestureDrag;
    }
  }
  if (mGesture == ZenPipGestureDrag || mGesture == ZenPipGestureCarry) {
    Vec2 size = ToRect(mGestureStartFrame).Size();
    Vec2 desired{mGestureStartFrame.origin.x + delta.x,
                 mGestureStartFrame.origin.y + delta.y};
    // A two-finger carry has no pointer on screen; the player's center is.
    NSPoint pointer =
        mGesture == ZenPipGestureCarry
            ? NSMakePoint(desired.x + size.x / 2, desired.y + size.y / 2)
            : aScreenPoint;
    mLastGesturePoint = aScreenPoint;
    BOOL hopped = [self followDrag:desired
                              size:size
                     ontoDisplayAt:pointer
                              time:aTime];
    Box area = [self allowedArea];
    [self notePush:desired - ClampOrigin(desired, size, area)
              size:size
                at:desired];
    Vec2 origin = RubberBandOrigin(desired, size, area, [self visibleFrame]);
    [self setWindowOrigin:origin];
    if (hopped) {
      // Carry on from here so the player moves 1:1 with the pointer on its
      // new display instead of waiting at the edge.
      mGestureStartMouse = aScreenPoint;
      mGestureStartFrame.origin = NSMakePoint(origin.x, origin.y);
      mStashArmed = HEdge::None;
      [self fadeInAfterHop];
    }
  } else if (mGesture == ZenPipGestureResize) {
    Box resized = ResizeFrame(ToRect(mGestureStartFrame), mResizeHandle,
                              {delta.x, delta.y}, mAspect, mGestureDock,
                              [self allowedArea], mConfig.limits);
    [self setPlayerFrame:ToNSRect(resized)];
  }
}

// A drag pushing past the edges of the display by `aPush`: a tick when it
// reaches an edge and holds there, and another one once it is pushed far
// enough sideways, into a side with no display beyond, to stash on release.
- (void)notePush:(Vec2)aPush size:(Vec2)aSize at:(Vec2)aOrigin {
  BOOL pushing = aPush.Length() > 0.5;
  if (pushing && !mPushingEdge) {
    PerformAlignmentFeedback();
  }
  mPushingEdge = pushing;
  HEdge armed = HEdge::None;
  // Sideways only: a push into a corner docks there.
  if (std::abs(aPush.x) >= kStashPushFraction * aSize.x &&
      std::abs(aPush.y) < kStashPushFraction * aSize.y / 2) {
    HEdge side = aPush.x < 0 ? HEdge::Left : HEdge::Right;
    if (![self hasDisplayBeyond:side of:Box::FromOriginSize(aOrigin, aSize)]) {
      armed = side;
    }
  }
  if (armed != HEdge::None && armed != mStashArmed) {
    PerformAlignmentFeedback();
  }
  mStashArmed = armed;
}

// Dragging past the edge of the player's display onto another display moves
// it there. It stays at the edge of its display first: it hops only once the
// pointer is well onto the other display, the push is deliberate and has
// lasted kCrossDisplayHold. Throwing or pushing it into a corner or edge it
// shares with another display therefore always lands there.
- (BOOL)followDrag:(Vec2)aDesired
              size:(Vec2)aSize
     ontoDisplayAt:(NSPoint)aPointer
              time:(NSTimeInterval)aTime {
  NSScreen* home = [self homeScreen];
  NSScreen* target = nil;
  for (NSScreen* screen in NSScreen.screens) {
    if (DisplayID(screen) != DisplayID(home) &&
        NSPointInRect(aPointer,
                      NSInsetRect(screen.frame, kCrossDisplayPointerInset,
                                  kCrossDisplayPointerInset))) {
      target = screen;
      break;
    }
  }
  Vec2 push = aDesired - ClampOrigin(aDesired, aSize, [self allowedArea]);
  bool horizontal = std::abs(push.x) >= std::abs(push.y);
  double needed =
      std::clamp(kCrossDisplayPushFraction * (horizontal ? aSize.x : aSize.y),
                 kCrossDisplayPushMin, kCrossDisplayPushMax);
  if (!target || std::max(std::abs(push.x), std::abs(push.y)) < needed) {
    [self cancelEdgeHold];
    return NO;
  }
  if (!mEdgeHoldTimer) {
    mEdgeHoldStart = aTime;
    // With the pointer at rest no further event would end the hold.
    __weak ZenPipPlayerChrome* weakSelf = self;
    mEdgeHoldTimer = [NSTimer
        scheduledTimerWithTimeInterval:kCrossDisplayHold
                               repeats:NO
                                 block:^(NSTimer*) {
                                   ZenPipPlayerChrome* chrome = weakSelf;
                                   if (chrome &&
                                       (chrome->mGesture == ZenPipGestureDrag ||
                                        chrome->mGesture ==
                                            ZenPipGestureCarry)) {
                                     chrome->mEdgeHoldElapsed = YES;
                                     [chrome
                                         gestureMovedTo:chrome
                                                            ->mLastGesturePoint
                                                   time:NSProcessInfo
                                                            .processInfo
                                                            .systemUptime];
                                   }
                                 }];
    return NO;
  }
  if (!mEdgeHoldElapsed && aTime - mEdgeHoldStart < kCrossDisplayHold) {
    return NO;
  }
  [self cancelEdgeHold];
  // Back on the source window's display it follows that window again.
  mHomeDisplay = DisplayID(target) == DisplayID([self sourceScreen])
                     ? 0
                     : DisplayID(target);
  return YES;
}

- (void)cancelEdgeHold {
  mEdgeHoldElapsed = NO;
  [mEdgeHoldTimer invalidate];
  mEdgeHoldTimer = nil;
}

- (void)gestureEndedAt:(NSPoint)aScreenPoint
                  time:(NSTimeInterval)aTime
            clickCount:(NSInteger)aClickCount {
  [self gestureEndedAt:aScreenPoint
                  time:aTime
            clickCount:aClickCount
             modifiers:0];
}

- (void)gestureEndedAt:(NSPoint)aScreenPoint
                  time:(NSTimeInterval)aTime
            clickCount:(NSInteger)aClickCount
             modifiers:(NSEventModifierFlags)aModifiers {
  NSWindow* window = mWindow;
  ZenPipGesture gesture = mGesture;
  mGesture = ZenPipGestureNone;
  [self cancelEdgeHold];
  if (!window) {
    return;
  }
  if (!mGestureMoved &&
      (gesture == ZenPipGesturePending || gesture == ZenPipGestureResize)) {
    // A click. Only clicks take the keyboard (as on any window, a
    // Command-click doesn't); a double-click on the video toggles playback.
    if (!(aModifiers & NSEventModifierFlagCommand)) {
      if (window.canBecomeKeyWindow && !window.isKeyWindow) {
        [window makeKeyWindow];
      }
      [window makeFirstResponder:mOverlay];
    }
    if (aClickCount == 2 && gesture == ZenPipGesturePending) {
      [self notifyHost:"toggle-play" value:0 detail:nil];
    }
    if (mCaughtMoving) {
      [self releaseWithVelocity:{}];  // caught mid-flight: come to rest here
    }
    [self noteActivity];
    return;
  }
  if (gesture == ZenPipGestureResize) {
    window.contentAspectRatio = window.frame.size;
    [self reportPlacement];
    return;
  }
  if (gesture == ZenPipGestureDrag || gesture == ZenPipGestureCarry) {
    HEdge stash = mStashArmed;
    mStashArmed = HEdge::None;
    if (stash != HEdge::None) {
      [self stashToward:stash];
      return;
    }
    if (gesture == ZenPipGestureDrag) {
      mSamples.push_back({aTime, {aScreenPoint.x, aScreenPoint.y}});
    }
    [self releaseWithVelocity:ReleaseVelocity(mSamples, aTime)];
  }
}

// A slow release stays where it is (snapping to edges within the magnet
// distance); a throw glides into the corner it heads for, keeping clear of
// other players.
- (void)releaseWithVelocity:(Vec2)aVelocity {
  ReleaseResult result =
      ResolveRelease(ToRect(mWindow.frame), aVelocity, [self allowedArea],
                     mConfig.release, [self otherPlayerFrames]);
  mRestDock = result.dock;
  [self animateTo:result.target velocity:aVelocity animated:YES];
}

- (void)overlayScroll:(NSEvent*)aEvent {
  if (!mConfig.carryWithTwoFingers || !aEvent.hasPreciseScrollingDeltas ||
      mStashed) {
    return;
  }
  NSEventPhase phase = aEvent.phase;
  if (aEvent.momentumPhase != NSEventPhaseNone) {
    return;  // our own spring handles inertia after the fingers lift
  }
  if (phase == NSEventPhaseBegan) {
    // The carry tracks a virtual pointer that starts at the origin and
    // accumulates the finger deltas.
    [self beginGestureAt:NSZeroPoint time:aEvent.timestamp];
    mGesture = ZenPipGestureCarry;
    mGestureMoved = YES;
    [self noteActivity];
    return;
  }
  if (mGesture != ZenPipGestureCarry) {
    return;
  }
  // Move with the fingers regardless of the scroll-direction preference.
  double sign = aEvent.isDirectionInvertedFromDevice ? 1 : -1;
  NSPoint carried =
      NSMakePoint(mSamples.back().position.x + sign * aEvent.scrollingDeltaX,
                  mSamples.back().position.y - sign * aEvent.scrollingDeltaY);
  if (phase == NSEventPhaseChanged) {
    [self gestureMovedTo:carried time:aEvent.timestamp];
  } else if (phase == NSEventPhaseEnded || phase == NSEventPhaseCancelled) {
    [self gestureEndedAt:carried time:aEvent.timestamp clickCount:0];
  }
}

- (void)overlayMagnify:(NSEvent*)aEvent {
  NSWindow* window = mWindow;
  if (!window || mStashed) {
    return;
  }
  if (aEvent.phase == NSEventPhaseBegan) {
    [self beginGestureAt:NSEvent.mouseLocation time:aEvent.timestamp];
    mGesture = ZenPipGesturePinch;
    mPinchScale = 1;
  } else if (mGesture != ZenPipGesturePinch) {
    return;
  }
  mPinchScale = std::clamp(mPinchScale * (1 + aEvent.magnification), 0.2, 5.0);
  Box scaled = ScaleFrame(ToRect(mGestureStartFrame), mPinchScale, mAspect,
                          mGestureDock, [self allowedArea], mConfig.limits);
  [self setPlayerFrame:ToNSRect(scaled)];
  if (aEvent.phase == NSEventPhaseEnded ||
      aEvent.phase == NSEventPhaseCancelled) {
    mGesture = ZenPipGestureNone;
    window.contentAspectRatio = window.frame.size;
    [self reportPlacement];
  }
  [self noteActivity];
}

#pragma mark Stash

// The side the player stashes into: the nearer of the left and right sides of
// its display, unless only the farther one has no display beyond it.
- (HEdge)stashSide {
  Box frame = ToRect(mWindow.frame);
  HEdge nearer = frame.Center().x >= [self allowedArea].Center().x
                     ? HEdge::Right
                     : HEdge::Left;
  HEdge farther = nearer == HEdge::Right ? HEdge::Left : HEdge::Right;
  if ([self hasDisplayBeyond:nearer of:frame] &&
      ![self hasDisplayBeyond:farther of:frame]) {
    return farther;
  }
  return nearer;
}

- (void)minimize {
  [self stashToward:[self stashSide]];
}

// The frame just past a side of the player's display, at the height of
// `aFrame`.
- (NSRect)offscreenFrameFor:(NSRect)aFrame side:(HEdge)aSide {
  NSRect screen = [self homeScreen].frame;
  NSRect frame = aFrame;
  frame.origin.x = aSide == HEdge::Right
                       ? NSMaxX(screen) + 1
                       : NSMinX(screen) - aFrame.size.width - 1;
  return frame;
}

// Slides the player off a side of its display, leaving a tab there, the way
// macOS stashes its own Picture-in-Picture. Where another display continues
// past that side, and with Reduce Motion, it fades out instead.
- (void)stashToward:(HEdge)aSide {
  NSWindow* window = mWindow;
  if (!window || mStashed || mExiting) {
    return;
  }
  [self stopAnimation];
  mPointerInside =
      NO;  // the pointer is on the minimize button: keep the cursor
  [self hideControls];
  mStashed = YES;
  mStashSide = aSide;
  NSRect frame = window.frame;
  mFrameBeforeStash = frame;
  if (!mTab) {
    mTab = [[ZenPipStashTab alloc] initWithChrome:self];
  }
  [self refreshTab];
  [self placeTabAt:NSMidY(frame) - kTabHeight / 2];
  ZenPipStashTab* tab = mTab;
  tab.alphaValue = 0;
  [tab orderFrontRegardless];
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = kStashDuration;
    ctx.timingFunction = EaseOut();
    tab.animator.alphaValue = 1;
  }];
  BOOL slide = !mAppearance.reduceMotion &&
               ![self hasDisplayBeyond:aSide of:ToRect(frame)];
  [self animateFrame:slide ? [self offscreenFrameFor:frame side:aSide] : frame
               alpha:slide ? -1 : 0
            duration:kStashDuration
               curve:EaseIn()
          completion:^(ZenPipPlayerChrome* aChrome) {
            NSWindow* w = aChrome->mWindow;
            if (aChrome->mStashed) {
              // Ordered out, the player is no longer composited at all.
              [w orderOut:nil];
              w.alphaValue = 1;
            }
          }];
}

- (void)restore {
  NSWindow* window = mWindow;
  if (!window || !mStashed || mExiting) {
    return;
  }
  mStashed = NO;
  [self hideTab];
  // Back beside the tab, which may have been dragged along the edge.
  Box area = [self allowedArea];
  Vec2 size =
      ClampSize(mFrameBeforeStash.size.width, mAspect, area, mConfig.limits);
  Vec2 origin =
      ClampOrigin({mFrameBeforeStash.origin.x, NSMidY(mTab.frame) - size.y / 2},
                  size, area);
  NSRect target = NSMakeRect(origin.x, origin.y, size.x, size.y);
  BOOL slide = !mAppearance.reduceMotion &&
               ![self hasDisplayBeyond:mStashSide of:ToRect(target)];
  [self setPlayerFrame:slide ? [self offscreenFrameFor:target side:mStashSide]
                             : target];
  window.alphaValue = slide ? 1 : 0;
  [window orderFrontRegardless];
  [self animateFrame:target
               alpha:1
            duration:kUnstashDuration
               curve:EaseOut()
          completion:^(ZenPipPlayerChrome* aChrome) {
            [aChrome reportPlacement];
          }];
  [self revealControlsFor:kInitialRevealDuration];
}

- (void)hideTab {
  __weak ZenPipPlayerChrome* weakSelf = self;
  ZenPipStashTab* tab = mTab;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = kHideDuration;
        ctx.timingFunction = EaseIn();
        tab.animator.alphaValue = 0;
      }
      completionHandler:^{
        ZenPipPlayerChrome* chrome = weakSelf;
        if (chrome && !chrome->mStashed) {
          [tab orderOut:nil];
        }
      }];
}

// Puts the tab against the stash side of the player's display at about `aY`,
// clear of the tabs of other stashed players.
- (void)placeTabAt:(CGFloat)aY {
  Box visible = [self visibleFrame];
  CGFloat x =
      mStashSide == HEdge::Right ? visible.MaxX() - kTabWidth : visible.MinX();
  std::vector<double> taken;
  for (ZenPipPlayerChrome* other in AllPlayers()) {
    ZenPipStashTab* tab = other->mTab;
    if (other != self && other->mStashed &&
        std::abs(NSMinX(tab.frame) - x) < 1) {
      taken.push_back(NSMinY(tab.frame));
    }
  }
  CGFloat y = NearestFreeSlot(aY, kTabHeight + kTabGap, visible.MinY(),
                              visible.MaxY() - kTabHeight, taken);
  [mTab setFrame:NSMakeRect(x, y, kTabWidth, kTabHeight) display:YES];
}

- (void)refreshTab {
  if (!mTab) {
    return;
  }
  NSString* label = [self string:@"restore"
                        fallback:@"Show Picture-in-Picture"];
  ZenPipStashTabView* view = mTab.tabView;
  view.accessibilityLabel = label;
  view.toolTip = label;
  view.chevron.image =
      Symbol(mStashSide == HEdge::Left ? @"chevron.compact.right"
                                       : @"chevron.compact.left",
             15, [self symbolWeight]);
}

- (void)tabPressed {
  // Restored from the keyboard, the player keeps the keyboard; a click on
  // the tab leaves it with the app the user is in.
  BOOL fromKeyboard = mTab.isKeyWindow;
  [self restore];
  if (fromKeyboard) {
    [mWindow makeKeyWindow];
    [self focusControls];
  }
}

- (void)tabMovedTo:(CGFloat)aY {
  [self placeTabAt:aY];
}

- (void)windowOcclusionChanged:(NSNotification*)aNote {
  NSWindow* window = mWindow;
  // Something else showed the stashed player again (Gecko focusing it, the
  // Window menu).
  if (mStashed && mFrameAnimations == 0 && window.isVisible &&
      window.alphaValue > 0.5 &&
      (window.occlusionState & NSWindowOcclusionStateVisible)) {
    mStashed = NO;
    [self hideTab];
    [self settleAnimated:YES];
  }
}

#pragma mark Transitions

- (BOOL)rectIsOnHomeScreen:(NSRect)aRect {
  NSScreen* home = [self homeScreen];
  return !NSIsEmptyRect(aRect) && home && NSIntersectsRect(aRect, home.frame);
}

- (void)playEntranceFrom:(NSRect)aRect {
  NSWindow* window = mWindow;
  if (!window || mExiting || mStashed) {
    return;
  }
  NSRect target = window.frame;
  if (!mAppearance.reduceMotion && [self rectIsOnHomeScreen:aRect]) {
    [self setPlayerFrame:aRect];
    [self animateFrame:target
                 alpha:-1
              duration:kEntranceDuration
                 curve:EaseOut()
            completion:^(ZenPipPlayerChrome* aChrome) {
              [aChrome settleAnimated:NO];
            }];
    return;
  }
  window.alphaValue = 0;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = kEntranceDuration;
    ctx.timingFunction = EaseOut();
    window.animator.alphaValue = 1;
  }];
}

- (void)playExitTo:(NSRect)aRect {
  NSWindow* window = mWindow;
  if (mExiting) {
    return;  // the first exit notifies
  }
  mExiting = YES;
  [self stopAnimation];
  [self cancelEdgeHold];
  mGesture = ZenPipGestureNone;
  mOwnsPress = NO;
  if (!window || mStashed) {
    [mTab orderOut:nil];
    [self notifyHost:"exit-done" value:0 detail:nil];
    return;
  }
  BOOL shrink = !mAppearance.reduceMotion && [self rectIsOnHomeScreen:aRect];
  [self animateFrame:shrink ? aRect : window.frame
               alpha:0
            duration:shrink ? kShrinkDuration : kExitFadeDuration
               curve:shrink ? EaseInOut() : EaseIn()
          completion:^(ZenPipPlayerChrome* aChrome) {
            [aChrome notifyHost:"exit-done" value:0 detail:nil];
          }];
}

#pragma mark Diagnostics and tests

- (NSString*)glassStyleOf:(NSView*)aMaterial {
  if (@available(macOS 26.0, *)) {
    return ((NSGlassEffectView*)aMaterial).style == NSGlassEffectViewStyleClear
               ? @"clear"
               : @"regular";
  }
  return @"visual-effect";
}

- (BOOL)glassIsTinted:(NSView*)aMaterial {
  if (@available(macOS 26.0, *)) {
    return ((NSGlassEffectView*)aMaterial).tintColor != nil;
  }
  return NO;
}

- (BOOL)glassIsInteractive:(NSView*)aMaterial {
  if (@available(macOS 27.0, *)) {
    return ((NSGlassEffectView*)aMaterial).effectIsInteractive;
  }
  return NO;
}

- (NSDictionary<NSString*, id>*)debugState {
  NSWindow* window = mWindow;
  NSWindow* source = mSourceWindow;
  auto rect = [](NSRect r) {
    return @[ @(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height) ];
  };
  NSMutableArray* controls = [NSMutableArray array];
  NSDictionary<NSString*, ZenPipGlassControl*>* names = [self namedControls];
  for (NSString* name in names) {
    ZenPipGlassControl* c = names[name];
    [controls addObject:@{
      @"name" : name,
      @"material" : NSStringFromClass(c.material.class),
      @"controlClass" : NSStringFromClass(c.button.superclass),
      @"frame" : rect(c.frame),
      @"hidden" : @(c.isHidden),
      @"enabled" : @(c.button.isEnabled),
      @"accessibilityLabel" : c.button.accessibilityLabel ?: @"",
      @"symbol" : c.button.image.accessibilityDescription ?: @"",
      @"title" : c.button.title ?: @"",
      @"interactiveGlass" : @([self glassIsInteractive:c.material]),
      @"statusOnly" : @(c.statusOnly),
    }];
  }
  NSMutableArray* speedItems = [NSMutableArray array];
  NSMenu* speedMenu = [self speedMenu];
  for (NSMenuItem* item in speedMenu.itemArray) {
    if (item.representedObject) {
      [speedItems addObject:@{
        @"title" : item.title,
        @"rate" : item.representedObject,
        @"checked" : @(item.state == NSControlStateValueOn),
        @"enabled" : @([self validateMenuItem:item]),
      }];
    }
  }
  NSScreen* screen = [self sourceScreen];
  return @{
    @"speed" : @{
      @"title" : mSpeed.button.title ?: @"",
      @"tooltip" : mSpeed.button.toolTip ?: @"",
      @"accessibilityValue" : mSpeed.button.accessibilityValueDescription
          ?: @"",
      @"menuTitle" : speedMenu.numberOfItems ? [speedMenu itemAtIndex:0].title
                                             : @"",
      @"menu" : speedItems,
    },
    @"liquidGlass" : @([ZenPipPlayerChrome hasLiquidGlass]),
    @"containerClass" : NSStringFromClass(mControlsRoot.class),
    @"timelineMaterial" : NSStringFromClass(mTimeline.material.class),
    @"sliderClass" : NSStringFromClass(mTimeline.slider.superclass),
    @"controls" : controls,
    @"controlsVisible" : @(mControlsVisible),
    @"windowFrame" : window ? rect(window.frame) : @[],
    @"windowNumber" : @(window.windowNumber),
    @"windowVisible" : @(window.isVisible),
    @"windowMovableBySystem" : @(window.movable),
    @"windowHidesWithApp" : @(window.canHide),
    @"cornerRadius" : @(window.contentView.layer.cornerRadius),
    @"windowOpaque" : @(window.isOpaque),
    @"sourceWindowFrame" : source ? rect(source.frame) : @[],
    @"sourceScreen" : screen ? screen.localizedName : @"",
    @"sourceScreenFrame" : screen ? rect(screen.frame) : @[],
    @"sourceVisibleFrame" : screen ? rect(screen.visibleFrame) : @[],
    @"playerScreen" : window.screen ? window.screen.localizedName : @"",
    @"homeScreen" : [self homeScreen].localizedName ?: @"",
    @"homePinned" : @([self homeIsPinned]),
    @"allowedArea" : rect(ToNSRect([self allowedArea])),
    @"insideAllowedArea" :
        @([self allowedArea].Contains(ToRect(window.frame), 0.75)),
    @"insideVisibleFrame" :
        @([self visibleFrame].Contains(ToRect(window.frame), 0.75)),
    @"dock" : DockName(
        DetectDock(ToRect(window.frame), [self allowedArea], kDockTolerance)),
    @"restDock" : DockName(mRestDock),
    @"animating" : @([self isAnimating]),
    @"tucked" : @(mStashed),
    @"stashSide" : mStashSide == HEdge::Left ? @"left" : @"right",
    @"tuckPanelVisible" : @(mTab.isVisible),
    @"tuckPanelFrame" : mTab ? rect(mTab.frame) : @[],
    @"aspect" : @(mAspect),
    @"spinnerVisible" : @(mShowsSpinner),
    @"timeline" : @{
      @"hidden" : @(mTimeline.isHidden),
      @"elapsed" : mTimeline.elapsed.stringValue ?: @"",
      @"duration" : mTimeline.duration.stringValue ?: @"",
      @"position" : @(mTimeline.slider.doubleValue),
      @"frame" : rect(mTimeline.frame),
      @"labelsShown" : @(mTimeline.showsLabels),
      @"accessibilityValue" : mTimeline.slider.accessibilityValueDescription
          ?: @"",
    },
    @"state" : @{
      @"playing" : @(mPlaying),
      @"muted" : @(mMuted),
      @"volume" : @(mVolume),
      @"rate" : @(mRate),
      @"buffering" : @(mBuffering),
      @"ended" : @(mEnded),
      @"captionsAvailable" : @(mCaptionsAvailable),
      @"captionsEnabled" : @(mCaptionsEnabled),
      @"live" : @(mLive),
      @"seekable" : @(mSeekable),
      @"atLiveEdge" : @(mAtLiveEdge),
    },
    @"liveDotRed" : @(mLive && (!mSeekable || mAtLiveEdge)),
    @"accessibility" : @{
      @"reduceMotion" : @(mAppearance.reduceMotion),
      @"increaseContrast" : @(mAppearance.increaseContrast),
      @"voiceOver" : @(mAppearance.voiceOver),
    },
    @"firstResponder" : NSStringFromClass([window.firstResponder class]) ?: @"",
    @"keyWindow" : @(window.isKeyWindow),
    @"focusedControl" : [self focusedControlName] ?: @"",
    @"glassStyle" : [self glassStyleOf:mPlay.material],
    @"glassTinted" : @([self glassIsTinted:mPlay.material]),
    @"dimmingOpacity" : @(CGColorGetAlpha(mScrim.layer.backgroundColor)),
    @"scrimVisible" : @(!mScrim.isHidden && mScrim.alphaValue > 0),
  };
}

- (nullable NSString*)focusedControlName {
  NSResponder* responder = mWindow.firstResponder;
  if (![responder isKindOfClass:[NSView class]]) {
    return nil;
  }
  NSView* view = (NSView*)responder;
  if ([view isDescendantOf:mTimeline.slider]) {
    return @"timeline";
  }
  NSDictionary<NSString*, ZenPipGlassControl*>* names = [self namedControls];
  for (NSString* name in names) {
    if ([view isDescendantOf:((ZenPipGlassControl*)names[name]).button]) {
      return name;
    }
  }
  return nil;
}

- (void)testKey:(unsigned short)aKeyCode
     characters:(NSString*)aCharacters
      modifiers:(NSEventModifierFlags)aModifiers {
  NSWindow* window = mWindow;
  if (!window) {
    return;
  }
  // Dispatched through the window like a real key press, so it reaches the
  // current first responder (the overlay or a focused control).
  NSEvent* event =
      [NSEvent keyEventWithType:NSEventTypeKeyDown
                             location:NSZeroPoint
                        modifierFlags:aModifiers
                            timestamp:NSProcessInfo.processInfo.systemUptime
                         windowNumber:window.windowNumber
                              context:nil
                           characters:aCharacters
          charactersIgnoringModifiers:aCharacters
                            isARepeat:NO
                              keyCode:aKeyCode];
  [window sendEvent:event];
}

- (BOOL)testClicks:(NSString*)aSpec {
  NSWindow* window = mWindow;
  if (!window) {
    return NO;
  }
  NSMutableArray<NSString*>* words = [NSMutableArray array];
  for (NSString* word in [aSpec componentsSeparatedByString:@" "]) {
    if (word.length) {
      [words addObject:word];
    }
  }
  NSInteger clicks = 1;
  CGFloat inset = 4;
  NSPoint drag = NSZeroPoint;
  for (NSUInteger i = 1; i < words.count; i++) {
    NSArray<NSString*>* pair = [words[i] componentsSeparatedByString:@"="];
    if (pair.count != 2) {
      return NO;
    }
    if ([pair[0] isEqualToString:@"clicks"]) {
      clicks = pair[1].integerValue;
    } else if ([pair[0] isEqualToString:@"inset"]) {
      inset = pair[1].doubleValue;
    } else if ([pair[0] isEqualToString:@"drag"]) {
      NSArray<NSString*>* xy = [pair[1] componentsSeparatedByString:@","];
      if (xy.count != 2) {
        return NO;
      }
      drag = NSMakePoint(xy[0].doubleValue, xy[1].doubleValue);
    } else {
      return NO;
    }
  }
  NSSize size = window.frame.size;
  CGFloat l = inset, r = size.width - inset, b = inset, t = size.height - inset;
  CGFloat mx = size.width / 2, my = size.height / 2;
  NSDictionary<NSString*, NSValue*>* places = @{
    @"top-left" : [NSValue valueWithPoint:NSMakePoint(l, t)],
    @"top-right" : [NSValue valueWithPoint:NSMakePoint(r, t)],
    @"bottom-left" : [NSValue valueWithPoint:NSMakePoint(l, b)],
    @"bottom-right" : [NSValue valueWithPoint:NSMakePoint(r, b)],
    @"left" : [NSValue valueWithPoint:NSMakePoint(l, my)],
    @"right" : [NSValue valueWithPoint:NSMakePoint(r, my)],
    @"top" : [NSValue valueWithPoint:NSMakePoint(mx, t)],
    @"bottom" : [NSValue valueWithPoint:NSMakePoint(mx, b)],
    @"center" : [NSValue valueWithPoint:NSMakePoint(mx, my)],
  };
  NSValue* place = words.count ? places[words[0]] : nil;
  NSArray<NSString*>* xy =
      words.count ? [words[0] componentsSeparatedByString:@","] : @[];
  if (!place && xy.count == 2) {
    place = [NSValue
        valueWithPoint:NSMakePoint(xy[0].doubleValue, xy[1].doubleValue)];
  }
  if (!place || clicks < 1 || clicks > 4) {
    return NO;
  }

  // The presses 0.12 s apart (well within the double-click interval), the
  // last one dragged in 12 steps, all at screen positions.
  struct Step {
    NSEventType type;
    NSPoint screen;
    NSInteger count;
    NSTimeInterval at;
  };
  __block std::vector<Step> steps;
  NSPoint start = [window convertPointToScreen:place.pointValue];
  NSTimeInterval at = 0;
  for (NSInteger click = 1; click <= clicks; click++) {
    steps.push_back({NSEventTypeLeftMouseDown, start, click, at});
    NSPoint end = start;
    if (click == clicks && (drag.x != 0 || drag.y != 0)) {
      constexpr int kDragSteps = 12;
      for (int i = 1; i <= kDragSteps; i++) {
        end = NSMakePoint(start.x + drag.x * i / kDragSteps,
                          start.y + drag.y * i / kDragSteps);
        steps.push_back(
            {NSEventTypeLeftMouseDragged, end, click, at + 0.03 + 0.012 * i});
      }
      at += 0.03 + 0.012 * kDragSteps;
    }
    steps.push_back({NSEventTypeLeftMouseUp, end, click, at + 0.04});
    at += 0.12;
  }
  // Posted one at a time, like real input arriving, each located from the
  // window's frame at that moment (the player may already have moved or
  // resized under the pointer). They pass through the application's normal
  // dispatch, its event monitors and AppKit's own tracking loops.
  __weak NSWindow* weakWindow = window;
  NSTimeInterval t0 = NSProcessInfo.processInfo.systemUptime;
  __block size_t next = 0;
  NSTimer* timer = [NSTimer
      timerWithTimeInterval:1.0 / 240
                    repeats:YES
                      block:^(NSTimer* aTimer) {
                        NSWindow* w = weakWindow;
                        NSTimeInterval now =
                            NSProcessInfo.processInfo.systemUptime;
                        if (w && next < steps.size() &&
                            steps[next].at <= now - t0) {
                          const Step& s = steps[next++];
                          NSEvent* event = [NSEvent
                              mouseEventWithType:s.type
                                        location:
                                            [w convertPointFromScreen:s.screen]
                                   modifierFlags:0
                                       timestamp:now
                                    windowNumber:w.windowNumber
                                         context:nil
                                     eventNumber:0
                                      clickCount:s.count
                                        pressure:s.type ==
                                                         NSEventTypeLeftMouseUp
                                                     ? 0
                                                     : 1];
                          [NSApp postEvent:event atStart:NO];
                        }
                        if (!w || next >= steps.size()) {
                          [aTimer invalidate];
                        }
                      }];
  [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
  return YES;
}

- (void)testDragBy:(NSPoint)aDelta
          duration:(NSTimeInterval)aDuration
           release:(NSPoint)aReleaseVelocity {
  NSWindow* window = mWindow;
  if (!window) {
    return;
  }
  // Grab the center of the player and move along a straight line at 120 Hz
  // through the same code path real mouse-dragged events use.
  NSPoint start = NSMakePoint(NSMidX(window.frame), NSMidY(window.frame));
  NSTimeInterval t0 = NSProcessInfo.processInfo.systemUptime;
  [self beginGestureAt:start time:t0];
  mGesture = ZenPipGesturePending;
  int steps = std::max(2, (int)lround(aDuration * 120));
  for (int i = 1; i <= steps; i++) {
    double f = (double)i / steps;
    [self gestureMovedTo:NSMakePoint(start.x + aDelta.x * f,
                                     start.y + aDelta.y * f)
                    time:t0 + aDuration * f];
  }
  // The last 80 ms of samples define the release velocity.
  NSTimeInterval tEnd = t0 + aDuration;
  NSPoint end = NSMakePoint(start.x + aDelta.x, start.y + aDelta.y);
  mSamples.clear();
  mSamples.push_back(
      {tEnd - 0.05,
       {end.x - aReleaseVelocity.x * 0.05, end.y - aReleaseVelocity.y * 0.05}});
  mSamples.push_back({tEnd, {end.x, end.y}});
  if (mGesture != ZenPipGestureDrag) {
    mGesture = ZenPipGestureDrag;
  }
  [self gestureEndedAt:end time:tEnd + 0.004 clickCount:0];
}

- (void)testDragBy:(NSPoint)aDelta
             duration:(NSTimeInterval)aDuration
    restBeforeRelease:(NSTimeInterval)aRest {
  NSWindow* window = mWindow;
  if (!window) {
    return;
  }
  NSPoint start = NSMakePoint(NSMidX(window.frame), NSMidY(window.frame));
  NSTimeInterval t0 = NSProcessInfo.processInfo.systemUptime;
  [self beginGestureAt:start time:t0];
  mGesture = ZenPipGesturePending;
  int steps = std::max(2, (int)lround(aDuration * 120));
  for (int i = 1; i <= steps; i++) {
    double f = (double)i / steps;
    [self gestureMovedTo:NSMakePoint(start.x + aDelta.x * f,
                                     start.y + aDelta.y * f)
                    time:t0 + aDuration * f];
  }
  [NSRunLoop.mainRunLoop
      runUntilDate:[NSDate dateWithTimeIntervalSinceNow:aRest]];
  NSPoint end = mLastGesturePoint;
  NSTimeInterval tEnd =
      std::max(NSProcessInfo.processInfo.systemUptime, t0 + aDuration + aRest);
  mSamples.clear();
  mSamples.push_back({tEnd - 0.05, {end.x, end.y}});
  mSamples.push_back({tEnd, {end.x, end.y}});
  [self gestureEndedAt:end time:tEnd + 0.004 clickCount:0];
}

- (void)testCarryBy:(NSPoint)aDelta {
  // 16 ms apart, then the fingers rest 150 ms before lifting, so the release
  // is a placement rather than a throw.
  uint64_t t = (uint64_t)(NSProcessInfo.processInfo.systemUptime * 1e9);
  auto send = [&](CGScrollPhase aPhase, double aDx, double aDy,
                  uint64_t aAdvance) {
    t += aAdvance;
    CGEventRef cg = CGEventCreateScrollWheelEvent2(
        nullptr, kCGScrollEventUnitPixel, 2, (int32_t)lround(aDy),
        (int32_t)lround(aDx), 0);
    if (!cg) {
      return;
    }
    CGEventSetIntegerValueField(cg, kCGScrollWheelEventIsContinuous, 1);
    CGEventSetIntegerValueField(cg, kCGScrollWheelEventScrollPhase, aPhase);
    CGEventSetTimestamp(cg, t);
    NSEvent* event = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    [self overlayScroll:event];
  };
  send(kCGScrollPhaseBegan, 0, 0, 0);
  for (int i = 0; i < 10; i++) {
    send(kCGScrollPhaseChanged, aDelta.x / 10, aDelta.y / 10, 16000000);
  }
  send(kCGScrollPhaseEnded, 0, 0, 150000000);
}

- (void)testResizeHandle:(NSString*)aHandle by:(NSPoint)aDelta {
  NSWindow* window = mWindow;
  if (!window) {
    return;
  }
  NSDictionary* handles = @{
    @"left" : @((int)ResizeHandle::Left),
    @"right" : @((int)ResizeHandle::Right),
    @"top" : @((int)ResizeHandle::Top),
    @"bottom" : @((int)ResizeHandle::Bottom),
    @"top-left" : @((int)ResizeHandle::TopLeft),
    @"top-right" : @((int)ResizeHandle::TopRight),
    @"bottom-left" : @((int)ResizeHandle::BottomLeft),
    @"bottom-right" : @((int)ResizeHandle::BottomRight),
  };
  NSNumber* handle = handles[aHandle];
  if (!handle) {
    return;
  }
  NSTimeInterval t0 = NSProcessInfo.processInfo.systemUptime;
  [self beginGestureAt:NSEvent.mouseLocation time:t0];
  mGesture = ZenPipGestureResize;
  mResizeHandle = (ResizeHandle)handle.intValue;
  NSPoint start = mGestureStartMouse;
  for (int i = 1; i <= 12; i++) {
    double f = i / 12.0;
    [self gestureMovedTo:NSMakePoint(start.x + aDelta.x * f,
                                     start.y + aDelta.y * f)
                    time:t0 + 0.2 * f];
  }
  [self gestureEndedAt:NSMakePoint(start.x + aDelta.x, start.y + aDelta.y)
                  time:t0 + 0.25
            clickCount:0];
}

- (BOOL)testClickControl:(NSString*)aName {
  NSDictionary<NSString*, ZenPipGlassControl*>* names = [self namedControls];
  BOOL speedWithRate = [aName hasPrefix:@"speed:"];
  ZenPipGlassControl* control = speedWithRate ? mSpeed : names[aName];
  if ([aName hasPrefix:@"timeline:"]) {
    // Moves the real NSSlider and fires its action, like a keyboard or
    // VoiceOver adjustment would.
    if (mTimeline.isHidden || mTimeline.slider.isHidden) {
      return NO;
    }
    [self showControls];
    mTimeline.slider.doubleValue =
        std::clamp([[aName substringFromIndex:9] doubleValue], 0.0, 1.0);
    [mTimeline.slider sendAction:mTimeline.slider.action
                              to:mTimeline.slider.target];
    return YES;
  }
  if ([aName isEqualToString:@"restore"]) {
    if (!mTab.isVisible) {
      return NO;
    }
    [self tabPressed];
    return YES;
  }
  if (!control || control.isHidden || !control.button.isEnabled ||
      control.statusOnly) {
    return NO;
  }
  if (control == mSpeed) {
    // The menu is modal, so pick from the same menu without opening it:
    // "speed" takes the speed after the checked one, "speed:<rate>" that one.
    [self showControls];
    NSMenu* menu = [self speedMenu];
    NSMutableArray<NSNumber*>* rateItems = [NSMutableArray array];
    NSInteger checked = -1;
    for (NSInteger i = 0; i < menu.numberOfItems; i++) {
      NSMenuItem* item = [menu itemAtIndex:i];
      if (!item.representedObject) {
        continue;
      }
      if (item.state == NSControlStateValueOn) {
        checked = (NSInteger)rateItems.count;
      }
      [rateItems addObject:@(i)];
    }
    NSInteger pick = -1;
    if (speedWithRate) {
      double want = [[aName substringFromIndex:6] doubleValue];
      for (NSUInteger j = 0; j < rateItems.count; j++) {
        NSMenuItem* item = [menu itemAtIndex:rateItems[j].integerValue];
        if (SameRate([item.representedObject doubleValue], want)) {
          pick = rateItems[j].integerValue;
        }
      }
    } else if (rateItems.count) {
      pick =
          rateItems[(NSUInteger)(checked + 1) % rateItems.count].integerValue;
    }
    if (pick < 0) {
      return NO;
    }
    [menu performActionForItemAtIndex:pick];
    return YES;
  }
  [self showControls];
  [control.button performClick:nil];
  return YES;
}

#pragma mark Teardown

- (void)invalidate {
  if (mInvalidated) {
    return;
  }
  mInvalidated = YES;
  [AllPlayers() removeObject:self];
  if (mPressMonitor) {
    [NSEvent removeMonitor:mPressMonitor];
    mPressMonitor = nil;
  }
  [self stopAnimation];
  [self cancelEdgeHold];
  [mHideTimer invalidate];
  mHideTimer = nil;
  [mSpinnerTimer invalidate];
  mSpinnerTimer = nil;
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
  if (mObserving) {
    mObserving = NO;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace removeObserver:self
                                     forKeyPath:@"voiceOverEnabled"
                                        context:kVoiceOverContext];
  }
  [mTab orderOut:nil];
  [mTab close];
  mTab = nil;
  NSWindow* window = mWindow;
  if (window) {
    window.movable = mWasMovable;
    if (!mExiting) {
      window.alphaValue = 1;
    }
    BOOL ownsFocus =
        window.firstResponder == mOverlay || [self keyboardFocusInControls];
    if (ownsFocus && window.isVisible) {
      // Hand keyboard focus back to Gecko once the current event is done, and
      // only if the window is still around (not while it is being torn down).
      __weak NSWindow* weakWindow = window;
      __weak NSResponder* previous = mPreviousFirstResponder;
      dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow* w = weakWindow;
        NSResponder* r = previous;
        if (w.isVisible && [r isKindOfClass:[NSView class]] &&
            ((NSView*)r).window == w) {
          [w makeFirstResponder:r];
        }
      });
    }
  }
  mOverlay.chrome = nil;
  [mOverlay removeFromSuperview];
  mOverlay = nil;
  mHost = nullptr;
}

@end
