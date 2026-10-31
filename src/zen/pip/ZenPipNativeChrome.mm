/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Compiled with ARC (see moz.build). Pure AppKit: no Gecko headers here.

#import "ZenPipNativeChrome.h"

#import <CoreText/CoreText.h>
#import <MediaAccessibility/MediaAccessibility.h>
#import <QuartzCore/QuartzCore.h>

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
constexpr CGFloat kResizeBand = 9;
constexpr CGFloat kResizeCornerBand = 18;
constexpr CGFloat kDragThreshold = 3;
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
constexpr NSTimeInterval kInitialRevealDuration = 2.5;
// Apple's dark dimming layer for Clear glass over bright content (HIG
// "Materials": "consider adding a dark dimming layer of 35% opacity").
constexpr CGFloat kDimmingOpacity = 0.35;

struct Config {
  double edgeGap = 10;
  SpringParams spring{0.42, 0.86};
  ReleaseParams release;
  SizeLimits limits;
  NSTimeInterval idleHideDelay = 2.4;
  bool carryWithTwoFingers = true;
};

struct Appearance {
  bool reduceMotion = false;
  bool reduceTransparency = false;
  bool increaseContrast = false;
  bool voiceOver = false;
};

Appearance CurrentAppearance() {
  NSWorkspace* ws = NSWorkspace.sharedWorkspace;
  Appearance a;
  a.reduceMotion = ws.accessibilityDisplayShouldReduceMotion;
  a.reduceTransparency = ws.accessibilityDisplayShouldReduceTransparency;
  a.increaseContrast = ws.accessibilityDisplayShouldIncreaseContrast;
  a.voiceOver = ws.isVoiceOverEnabled;
  return a;
}

Box ToRect(NSRect aRect) {
  return {aRect.origin.x, aRect.origin.y, aRect.size.width, aRect.size.height};
}

CGDirectDisplayID DisplayID(NSScreen* aScreen) {
  return [aScreen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
}

NSRect ToNSRect(const Box& aRect) {
  return NSMakeRect(aRect.x, aRect.y, aRect.width, aRect.height);
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
  NSNumberFormatter* f = [[NSNumberFormatter alloc] init];
  f.minimumFractionDigits = 0;
  f.maximumFractionDigits = 2;
  f.minimumIntegerDigits = 1;
  return [[f stringFromNumber:@(aRate)] stringByAppendingString:@"×"];
}

NSImage* Symbol(NSString* aName, CGFloat aPointSize, NSFontWeight aWeight) {
  NSImage* image = [NSImage imageWithSystemSymbolName:aName
                             accessibilityDescription:nil];
  NSImageSymbolConfiguration* config =
      [NSImageSymbolConfiguration configurationWithPointSize:aPointSize
                                                      weight:aWeight
                                                       scale:NSImageSymbolScaleMedium];
  return [image imageWithSymbolConfiguration:config];
}

NSString* JSONString(NSDictionary* aObject) {
  NSData* data = [NSJSONSerialization dataWithJSONObject:aObject
                                                 options:0
                                                   error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
              : @"{}";
}

// "rgba(...)" for a MediaAccessibility color (+1 reference, released here)
// and its separate opacity setting.
NSString* CSSColor(CGColorRef aColor, CGFloat aOpacity) {
  NSColor* color = aColor ? [[NSColor colorWithCGColor:aColor]
                                colorUsingColorSpace:NSColorSpace.sRGBColorSpace]
                          : nil;
  if (aColor) {
    CFRelease(aColor);
  }
  if (!color) {
    return @"transparent";
  }
  return [NSString stringWithFormat:@"rgba(%ld, %ld, %ld, %.3f)",
                                    lround(std::clamp<CGFloat>(color.redComponent, 0, 1) * 255),
                                    lround(std::clamp<CGFloat>(color.greenComponent, 0, 1) * 255),
                                    lround(std::clamp<CGFloat>(color.blueComponent, 0, 1) * 255),
                                    std::clamp<CGFloat>(color.alphaComponent * aOpacity, 0, 1)];
}

// The user's system caption style (System Settings > Accessibility >
// Captions), as CSS-ready values, so Picture-in-Picture captions look like
// they do in Apple's own players (which read the same MediaAccessibility
// preferences).
NSDictionary* SystemCaptionStyle() {
  const MACaptionAppearanceDomain domain = kMACaptionAppearanceDomainUser;
  NSString* text = CSSColor(MACaptionAppearanceCopyForegroundColor(domain, nullptr),
                            MACaptionAppearanceGetForegroundOpacity(domain, nullptr));
  CGFloat windowOpacity = MACaptionAppearanceGetWindowOpacity(domain, nullptr);
  CGFloat backgroundOpacity = MACaptionAppearanceGetBackgroundOpacity(domain, nullptr);
  NSString* window = CSSColor(MACaptionAppearanceCopyWindowColor(domain, nullptr), windowOpacity);
  NSString* background =
      CSSColor(MACaptionAppearanceCopyBackgroundColor(domain, nullptr), backgroundOpacity);
  // One box behind the text: Apple's caption "window" when it is visible,
  // otherwise the per-line text background.
  NSString* box = windowOpacity > 0.01       ? window
                  : backgroundOpacity > 0.01 ? background
                                             : @"transparent";

  NSString* family = @"system-ui";
  double weight = 500;
  if (CTFontDescriptorRef font = MACaptionAppearanceCopyFontDescriptorForStyle(
          domain, nullptr, kMACaptionAppearanceFontStyleDefault)) {
    NSString* name = CFBridgingRelease(CTFontDescriptorCopyAttribute(font, kCTFontFamilyNameAttribute));
    if (name.length && ![name hasPrefix:@"."]) {
      NSString* quoted = [[name stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
          stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
      family = [NSString stringWithFormat:@"\"%@\", system-ui", quoted];
    }
    CTFontRef ctFont = CTFontCreateWithFontDescriptor(font, 16, nullptr);
    NSDictionary* traits = CFBridgingRelease(CTFontCopyTraits(ctFont));
    CFRelease(ctFont);
    CFRelease(font);
    // CoreText weight (-1..1) to the nearest CSS weight.
    double ct = [traits[(id)kCTFontWeightTrait] doubleValue];
    const double ctWeights[] = {-0.8, -0.6, -0.4, 0, 0.23, 0.3, 0.4, 0.56, 0.62};
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
      shadow = @"0 0 0.05em #000, 0 0 0.05em #000, 0 0 0.05em #000, 0 0 0.05em #000";
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
        MACaptionAppearanceGetWindowRoundedCornerRadius(domain, nullptr), 0, 24)),
    @"font" : family,
    @"weight" : @(weight),
    @"shadow" : shadow,
    @"scale" : @(std::clamp<CGFloat>(MACaptionAppearanceGetRelativeCharacterSize(domain, nullptr),
                                     0.5, 2.0)),
  };
}

NSString* DockName(const Dock& aDock) {
  NSString* h = aDock.h == HEdge::Left ? @"left"
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

// The Live badge's dot, followed by `aGap` points of space before the label.
NSImage* LiveDotImage(NSColor* aColor, CGFloat aDiameter, CGFloat aGap) {
  NSImage* image = [NSImage imageWithSize:NSMakeSize(aDiameter + aGap, aDiameter)
                                  flipped:NO
                           drawingHandler:^BOOL(NSRect) {
                             [aColor setFill];
                             [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, aDiameter,
                                                                                aDiameter)] fill];
                             return YES;
                           }];
  [image setTemplate:NO];  // keeps its color inside the white-tinted button
  return image;
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
  return self.isEnabled && !self.refusesFirstResponder && !self.isHiddenOrHasHiddenAncestor;
}
- (BOOL)mouseDownCanMoveWindow {
  return NO;
}
// Space presses the focused control even when the system "Keyboard
// navigation" setting is off (AppKit only does it when it is on).
- (void)keyDown:(NSEvent*)aEvent {
  NSEventModifierFlags mods = aEvent.modifierFlags & (NSEventModifierFlagCommand |
                                                      NSEventModifierFlagControl |
                                                      NSEventModifierFlagOption);
  if (aEvent.keyCode == 49 /* Space */ && !mods && self.isEnabled) {
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

@interface ZenPipSlider : NSSlider
@end

@implementation ZenPipSlider
- (BOOL)acceptsFirstMouse:(NSEvent*)aEvent {
  return YES;
}
- (BOOL)canBecomeKeyView {
  return self.isEnabled && !self.isHiddenOrHasHiddenAncestor;
}
- (BOOL)mouseDownCanMoveWindow {
  return NO;
}
@end

// Apple's guidance for glass over media (HIG "Materials", WWDC25 "Meet Liquid
// Glass"): the Clear variant above a 35% dark dimming layer, carrying bold,
// bright symbols, and untinted (tint is reserved for emphasizing a primary
// action). Regular is for glass over arbitrary content. The system applies the
// Liquid Glass look setting, Reduce Transparency and Increase Contrast to
// both variants itself.
static void ApplyGlass(NSView* aMaterial, BOOL aClear) {
  if (@available(macOS 26.0, *)) {
    NSGlassEffectView* glass = (NSGlassEffectView*)aMaterial;
    glass.style = aClear ? NSGlassEffectViewStyleClear : NSGlassEffectViewStyleRegular;
    glass.tintColor = nil;
  }
}

// A circular or capsule Liquid Glass control: an NSGlassEffectView whose
// content view is a native button (NSVisualEffectView before macOS 26).
@interface ZenPipGlassControl : NSView
@property(nonatomic, readonly) ZenPipButtonCore* button;
@property(nonatomic, readonly) NSView* material;
@property(nonatomic) BOOL capsule;
// Shows information only (a status badge): not focusable, announced as text,
// and clicks or drags on it go to the player like on the video.
@property(nonatomic) BOOL statusOnly;
- (instancetype)initWithTarget:(id)aTarget action:(SEL)aAction;
- (void)setClearGlass:(BOOL)aClear;
@end

@implementation ZenPipGlassControl

- (instancetype)initWithTarget:(id)aTarget action:(SEL)aAction {
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
  _button.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _button.focusRingType = NSFocusRingTypeDefault;

  if (@available(macOS 26.0, *)) {
    NSGlassEffectView* glass = [[NSGlassEffectView alloc] initWithFrame:self.bounds];
    glass.style = NSGlassEffectViewStyleClear;
    glass.contentView = _button;
    if (@available(macOS 27.0, *)) {
      if ([glass respondsToSelector:@selector(setEffectIsInteractive:)]) {
        glass.effectIsInteractive = YES;
      }
    }
    _material = glass;
  } else {
    NSVisualEffectView* effect = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
    effect.material = NSVisualEffectMaterialHUDWindow;
    effect.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    effect.state = NSVisualEffectStateActive;
    effect.wantsLayer = YES;
    effect.layer.masksToBounds = YES;
    [effect addSubview:_button];
    _material = effect;
  }
  _material.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self addSubview:_material];
  self.accessibilityElement = NO;
  return self;
}

- (void)setClearGlass:(BOOL)aClear {
  ApplyGlass(_material, aClear);
}

- (void)setStatusOnly:(BOOL)aStatusOnly {
  if (aStatusOnly == _statusOnly) {
    return;
  }
  _statusOnly = aStatusOnly;
  _button.refusesFirstResponder = aStatusOnly;
  _button.accessibilityRole = aStatusOnly ? NSAccessibilityStaticTextRole : NSAccessibilityButtonRole;
  if (@available(macOS 27.0, *)) {
    if ([_material respondsToSelector:@selector(setEffectIsInteractive:)]) {
      ((NSGlassEffectView*)_material).effectIsInteractive = !aStatusOnly;
    }
  }
}

- (NSView*)hitTest:(NSPoint)aPoint {
  return _statusOnly ? nil : [super hitTest:aPoint];
}

- (void)setFrameSize:(NSSize)aSize {
  [super setFrameSize:aSize];
  CGFloat radius = std::min(aSize.width, aSize.height) / 2;
  _button.focusCornerRadius = radius;
  if (@available(macOS 26.0, *)) {
    ((NSGlassEffectView*)_material).cornerRadius = radius;
  } else {
    _material.layer.cornerRadius = radius;
  }
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
- (void)setClearGlass:(BOOL)aClear;
@end

@implementation ZenPipTimeline {
  NSView* mContent;
}

static NSTextField* MakeTimeLabel() {
  NSTextField* label = [NSTextField labelWithString:@"0:00"];
  label.textColor = NSColor.whiteColor;
  label.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
  label.lineBreakMode = NSLineBreakByClipping;
  label.accessibilityElement = NO;  // the slider reports the time
  return label;
}

- (instancetype)initWithTarget:(id)aTarget action:(SEL)aAction {
  if (!(self = [super initWithFrame:NSMakeRect(0, 0, 300, 30)])) {
    return nil;
  }
  mContent = [[NSView alloc] initWithFrame:self.bounds];
  mContent.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _elapsed = MakeTimeLabel();
  _duration = MakeTimeLabel();
  _duration.alignment = NSTextAlignmentRight;
  _slider = [ZenPipSlider sliderWithValue:0 minValue:0 maxValue:1
                                   target:aTarget action:aAction];
  _slider.continuous = YES;
  _slider.controlSize = NSControlSizeSmall;
  _slider.trackFillColor = NSColor.whiteColor;
  [mContent addSubview:_elapsed];
  [mContent addSubview:_slider];
  [mContent addSubview:_duration];
  _showsLabels = YES;
  _fontSize = 12;

  if (@available(macOS 26.0, *)) {
    NSGlassEffectView* glass = [[NSGlassEffectView alloc] initWithFrame:self.bounds];
    glass.style = NSGlassEffectViewStyleClear;
    glass.contentView = mContent;
    _material = glass;
  } else {
    NSVisualEffectView* effect = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
    effect.material = NSVisualEffectMaterialHUDWindow;
    effect.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    effect.state = NSVisualEffectStateActive;
    effect.wantsLayer = YES;
    effect.layer.masksToBounds = YES;
    [effect addSubview:mContent];
    _material = effect;
  }
  _material.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self addSubview:_material];
  self.accessibilityElement = NO;
  return self;
}

- (void)setClearGlass:(BOOL)aClear {
  ApplyGlass(_material, aClear);
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
  if (@available(macOS 26.0, *)) {
    ((NSGlassEffectView*)_material).cornerRadius = radius;
  } else {
    _material.layer.cornerRadius = radius;
  }
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
    NSString* widest = _duration.stringValue.length > _elapsed.stringValue.length
                           ? _duration.stringValue
                           : _elapsed.stringValue;
    labelW = ceil([[widest stringByReplacingOccurrencesOfString:@"[0-9]"
                                                      withString:@"0"
                                                         options:NSRegularExpressionSearch
                                                           range:NSMakeRange(0, widest.length)]
                      sizeWithAttributes:@{NSFontAttributeName : font}]
                      .width) +
             2;
  }
  _elapsed.hidden = !_showsLabels;
  _duration.hidden = !_showsLabels || _duration.stringValue.length == 0;
  _elapsed.frame = NSMakeRect(pad, labelY, labelW, labelH);
  _duration.frame = NSMakeRect(size.width - pad - labelW, labelY, labelW, labelH);
  CGFloat gap = _showsLabels ? std::max<CGFloat>(8, pad * 0.7) : 0;
  CGFloat sliderX = pad + labelW + gap;
  CGFloat sliderW = std::max<CGFloat>(0, size.width - 2 * sliderX);
  CGFloat sliderH = std::min<CGFloat>(size.height, 20);
  _slider.frame = NSMakeRect(sliderX, round((size.height - sliderH) / 2), sliderW, sliderH);
}
@end

#pragma mark - Minimized panel

@interface ZenPipTuckPanel : NSPanel
@property(nonatomic, readonly) ZenPipGlassControl* control;
- (instancetype)initWithTarget:(id)aTarget action:(SEL)aAction;
@end

@implementation ZenPipTuckPanel
- (instancetype)initWithTarget:(id)aTarget action:(SEL)aAction {
  if (!(self = [super initWithContentRect:NSMakeRect(0, 0, 48, 48)
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
  self.movable = NO;
  self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                            NSWindowCollectionBehaviorFullScreenAuxiliary |
                            NSWindowCollectionBehaviorIgnoresCycle;
  self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  _control = [[ZenPipGlassControl alloc] initWithTarget:aTarget action:aAction];
  _control.button.image = Symbol(@"pip.enter", 17, NSFontWeightSemibold);
  _control.frame = NSMakeRect(0, 0, 48, 48);
  // Sits over arbitrary desktop content, not video: Regular glass.
  [_control setClearGlass:NO];
  self.contentView = _control;
  return self;
}
- (BOOL)canBecomeKeyWindow {
  return NO;
}
- (BOOL)canBecomeMainWindow {
  return NO;
}
@end

#pragma mark - Overlay view

@class ZenPipPlayerChrome;

@interface ZenPipPlayerChrome (Internal)
- (void)overlayMouseDown:(NSEvent*)aEvent;
- (void)overlayMouseDragged:(NSEvent*)aEvent;
- (void)overlayMouseUp:(NSEvent*)aEvent;
- (void)overlayMouseMoved:(NSEvent*)aEvent inside:(BOOL)aInside;
- (void)overlayMouseExited;
- (void)overlayScroll:(NSEvent*)aEvent;
- (void)overlayMagnify:(NSEvent*)aEvent;
- (BOOL)overlayKeyDown:(NSEvent*)aEvent;
- (void)overlayLayout;
- (void)overlayUpdateCursor:(NSEvent*)aEvent;
@end

@interface ZenPipOverlayView : NSView
@property(nonatomic, weak) ZenPipPlayerChrome* chrome;
@end

@implementation ZenPipOverlayView {
  NSTrackingArea* mTrackingArea;
}

- (BOOL)isFlipped {
  return NO;
}
- (BOOL)acceptsFirstMouse:(NSEvent*)aEvent {
  return YES;
}
- (BOOL)acceptsFirstResponder {
  return YES;
}
- (BOOL)mouseDownCanMoveWindow {
  return NO;
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

- (void)updateTrackingAreas {
  if (mTrackingArea) {
    [self removeTrackingArea:mTrackingArea];
  }
  mTrackingArea = [[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                   NSTrackingActiveAlways | NSTrackingInVisibleRect |
                   NSTrackingCursorUpdate
             owner:self
          userInfo:nil];
  [self addTrackingArea:mTrackingArea];
  [super updateTrackingAreas];
}

- (void)removeAllTracking {
  if (mTrackingArea) {
    [self removeTrackingArea:mTrackingArea];
    mTrackingArea = nil;
  }
}

- (void)mouseEntered:(NSEvent*)aEvent {
  [_chrome overlayMouseMoved:aEvent inside:YES];
}
- (void)mouseMoved:(NSEvent*)aEvent {
  [_chrome overlayMouseMoved:aEvent inside:YES];
}
- (void)mouseExited:(NSEvent*)aEvent {
  [_chrome overlayMouseExited];
}
- (void)cursorUpdate:(NSEvent*)aEvent {
  [_chrome overlayUpdateCursor:aEvent];
}
- (void)mouseDown:(NSEvent*)aEvent {
  [_chrome overlayMouseDown:aEvent];
}
- (void)mouseDragged:(NSEvent*)aEvent {
  [_chrome overlayMouseDragged:aEvent];
}
- (void)mouseUp:(NSEvent*)aEvent {
  [_chrome overlayMouseUp:aEvent];
}
- (void)scrollWheel:(NSEvent*)aEvent {
  [_chrome overlayScroll:aEvent];
}
- (void)magnifyWithEvent:(NSEvent*)aEvent {
  [_chrome overlayMagnify:aEvent];
}
- (void)keyDown:(NSEvent*)aEvent {
  if (![_chrome overlayKeyDown:aEvent]) {
    [super keyDown:aEvent];
  }
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
  ZenPipGesturePending,  // mouse down, not yet past the drag threshold
  ZenPipGestureDrag,
  ZenPipGestureResize,
  ZenPipGestureCarry,  // two-finger scroll
  ZenPipGesturePinch,
};

@implementation ZenPipPlayerChrome {
  ChromeHost* mHost;
  __weak NSWindow* mWindow;
  __weak NSWindow* mSourceWindow;
  __weak NSResponder* mPreviousFirstResponder;
  BOOL mWasMovable;
  BOOL mInvalidated;

  Config mConfig;
  Appearance mAppearance;
  NSDictionary<NSString*, NSString*>* mStrings;

  ZenPipOverlayView* mOverlay;
  NSView* mScrim;
  NSView* mControlsRoot;     // NSGlassEffectContainerView (26+) or plain view
  ZenPipPassthroughView* mControls;
  ZenPipGlassControl* mClose;
  ZenPipGlassControl* mMinimize;
  ZenPipGlassControl* mSpeed;
  ZenPipGlassControl* mCaptions;
  ZenPipGlassControl* mSound;
  ZenPipGlassControl* mReturn;
  ZenPipGlassControl* mBack;
  ZenPipGlassControl* mPlay;
  ZenPipGlassControl* mForward;
  // "● Live" for live streams: a status badge, or a "go to live" button beside
  // the timeline when the stream can be scrubbed.
  ZenPipGlassControl* mLiveBadge;
  ZenPipTimeline* mTimeline;
  ZenPipTuckPanel* mTuckPanel;

  // Playback state mirrored from the original video.
  BOOL mPlaying;
  BOOL mMuted;
  double mRate;
  double mCurrentTime;
  double mDuration;
  BOOL mSeekable;
  BOOL mLive;
  // A scrubbable live stream is playing at its live edge (red dot).
  BOOL mAtLiveEdge;
  BOOL mLiveDotRed;  // as last drawn
  BOOL mCaptionsAvailable;
  BOOL mCaptionsEnabled;
  NSString* mCaptionSize;
  double mAspect;

  // Controls visibility.
  BOOL mControlsVisible;
  BOOL mPointerInside;
  BOOL mSticky;
  BOOL mScrubbing;
  BOOL mMenuOpen;
  NSTimer* mHideTimer;
  CFTimeInterval mLastActivity;

  // Motion.
  ZenPipGesture mGesture;
  NSPoint mGestureStartMouse;
  NSRect mGestureStartFrame;
  ResizeHandle mResizeHandle;
  Dock mGestureDock;
  double mPinchScale;
  std::vector<PointerSample> mSamples;
  Spring2D mSpring;
  CFTimeInterval mSpringStart;
  CADisplayLink* mDisplayLink API_AVAILABLE(macos(14.0));
  NSTimer* mFallbackAnimationTimer;
  BOOL mAnimating;
  BOOL mIgnoreMomentum;
  BOOL mTucked;
  BOOL mTuckTransition;
  NSRect mFrameBeforeTuck;
  Dock mLastDock;

  NSMutableArray<id>* mObservers;
  NSMutableArray<id>* mWorkspaceObservers;
  // Test-only overrides of the system accessibility display options (set via
  // setConfiguration; never used in normal operation).
  NSDictionary<NSString*, NSNumber*>* mSimulatedAppearance;
  // Display the user dragged the player onto (0: follow the source window).
  CGDirectDisplayID mHomeDisplay;
  // Pushing at the edge toward another display: since when (event time, 0 if
  // not), and a one-shot check at the end of the hold for a pointer at rest.
  NSTimeInterval mEdgeHoldStart;
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
  if (!aWindow || !aHost || !content) {
    return nil;
  }
  if (!(self = [super init])) {
    return nil;
  }
  mHost = aHost;
  mWindow = aWindow;
  mRate = 1;
  mAtLiveEdge = YES;
  mDuration = NAN;
  mAspect = aWindow.frame.size.height > 0
                ? aWindow.frame.size.width / aWindow.frame.size.height
                : 16.0 / 9.0;
  mCaptionSize = @"medium";
  mStrings = @{};
  mAppearance = CurrentAppearance();
  mObservers = [NSMutableArray array];
  mWorkspaceObservers = [NSMutableArray array];

  [self buildOverlayInView:content];

  // The chrome moves the window itself (with physics and containment), so
  // the system must not start its own window drags from the titlebar area.
  mWasMovable = aWindow.movable;
  aWindow.movable = NO;
  for (NSWindowButton b : {NSWindowCloseButton, NSWindowMiniaturizeButton,
                           NSWindowZoomButton}) {
    [aWindow standardWindowButton:b].hidden = YES;
  }
  mPreviousFirstResponder = aWindow.firstResponder;
  [aWindow makeFirstResponder:mOverlay];

  [self observeNotifications];
  [self applyAppearance];
  [self refreshAllControls];
  [self settleAnimated:NO];
  // Before the first reveal, so captions are placed with the system style.
  [self notifyCaptionStyle];
  [self revealControlsFor:kInitialRevealDuration];
  return self;
}

- (void)notifyCaptionStyle {
  [self notifyHost:"caption-style" value:0 detail:JSONString(SystemCaptionStyle())];
}

- (void)dealloc {
  [self invalidate];
}

#pragma mark Building

- (ZenPipGlassControl*)addControl:(SEL)aAction {
  ZenPipGlassControl* control = [[ZenPipGlassControl alloc] initWithTarget:self
                                                                    action:aAction];
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

  // Apple's dark dimming layer under Clear glass over bright media: a uniform
  // 35% black, shown with the controls.
  mScrim = [[NSView alloc] initWithFrame:mOverlay.bounds];
  mScrim.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  mScrim.wantsLayer = YES;
  CALayer* dimming = [CALayer layer];
  dimming.backgroundColor = [NSColor colorWithWhite:0 alpha:kDimmingOpacity].CGColor;
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

  // Created in reading order, which VoiceOver follows: window controls on the
  // left (close, back to tab, minimize), playback options on the right.
  mClose = [self addControl:@selector(onClose:)];
  mReturn = [self addControl:@selector(onReturn:)];
  mMinimize = [self addControl:@selector(onMinimize:)];
  mSpeed = [self addControl:@selector(onSpeed:)];
  mSpeed.capsule = YES;
  mCaptions = [self addControl:@selector(onCaptions:)];
  mSound = [self addControl:@selector(onSound:)];
  mBack = [self addControl:@selector(onBack:)];
  mPlay = [self addControl:@selector(onPlay:)];
  mForward = [self addControl:@selector(onForward:)];
  mLiveBadge = [self addControl:@selector(onLive:)];
  mLiveBadge.capsule = YES;
  mLiveBadge.hidden = YES;
  mLiveBadge.button.imageHugsTitle = YES;
  mTimeline = [[ZenPipTimeline alloc] initWithTarget:self action:@selector(onScrub:)];
  [mControls addSubview:mTimeline];

  // Captions get extra options from a context menu (right/control click).
  NSMenu* captionsMenu = [[NSMenu alloc] init];
  captionsMenu.delegate = (id<NSMenuDelegate>)self;
  mCaptions.button.menu = captionsMenu;

  // Keyboard order follows the visual reading order.
  NSArray<NSView*>* order = @[
    mClose.button, mReturn.button, mMinimize.button, mSpeed.button,
    mCaptions.button, mSound.button, mBack.button, mPlay.button,
    mForward.button, mLiveBadge.button, mTimeline.slider
  ];
  for (NSUInteger i = 0; i < order.count; i++) {
    order[i].nextKeyView = order[(i + 1) % order.count];
  }

  [aContent addSubview:mOverlay positioned:NSWindowAbove relativeTo:nil];
}

#pragma mark Notifications

- (void)observeNotifications {
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  __weak ZenPipPlayerChrome* weakSelf = self;
  NSWindow* window = mWindow;
  [mObservers addObject:[nc addObserverForName:NSWindowWillCloseNotification
                                        object:window
                                         queue:nil
                                    usingBlock:^(NSNotification*) {
                                      ZenPipPlayerChrome* chrome = weakSelf;
                                      if (chrome) {
                                        [chrome notifyHost:"window-will-close"
                                                     value:0
                                                    detail:nil];
                                        [chrome invalidate];
                                      }
                                    }]];
  // A system edge resize (outside our own handles) re-anchors when done.
  [mObservers addObject:[nc addObserverForName:NSWindowDidEndLiveResizeNotification
                                        object:window
                                         queue:nil
                                    usingBlock:^(NSNotification*) {
                                      [weakSelf settleAnimated:YES];
                                    }]];
  [mObservers addObject:[nc addObserverForName:NSWindowDidChangeOcclusionStateNotification
                                        object:window
                                         queue:nil
                                    usingBlock:^(NSNotification*) {
                                      [weakSelf windowVisibilityChanged];
                                    }]];
  // Display added/removed/rearranged, resolution or Dock changes.
  [mObservers addObject:[nc addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                        object:nil
                                         queue:nil
                                    usingBlock:^(NSNotification*) {
                                      [weakSelf settleAnimated:YES];
                                    }]];
  // System Settings > Accessibility > Captions changed.
  [mObservers
      addObject:[nc addObserverForName:(__bridge NSString*)kMACaptionAppearanceSettingsChangedNotification
                                object:nil
                                 queue:nil
                            usingBlock:^(NSNotification*) {
                              [weakSelf notifyCaptionStyle];
                            }]];

  NSNotificationCenter* wnc = NSWorkspace.sharedWorkspace.notificationCenter;
  [mWorkspaceObservers
      addObject:[wnc addObserverForName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                                 object:nil
                                  queue:nil
                             usingBlock:^(NSNotification*) {
                               [weakSelf appearanceChanged];
                             }]];
  [NSWorkspace.sharedWorkspace addObserver:self
                                forKeyPath:@"voiceOverEnabled"
                                   options:0
                                   context:nullptr];
}

- (void)observeValueForKeyPath:(NSString*)aKeyPath
                      ofObject:(id)aObject
                        change:(NSDictionary*)aChange
                       context:(void*)aContext {
  [self appearanceChanged];
}

- (Appearance)effectiveAppearance {
  Appearance a = CurrentAppearance();
  if (NSNumber* v = mSimulatedAppearance[@"reduceMotion"]) a.reduceMotion = v.boolValue;
  if (NSNumber* v = mSimulatedAppearance[@"reduceTransparency"]) a.reduceTransparency = v.boolValue;
  if (NSNumber* v = mSimulatedAppearance[@"increaseContrast"]) a.increaseContrast = v.boolValue;
  return a;
}

- (void)appearanceChanged {
  mAppearance = [self effectiveAppearance];
  [self applyAppearance];
  if (mAppearance.voiceOver) {
    [self showControls];
  } else {
    [self scheduleHide];
  }
}

- (void)applyAppearance {
  // Clear glass in every mode (see ApplyGlass): the system itself makes it
  // frostier for Reduce Transparency and black/white with a border for
  // Increase Contrast. Only the symbol weight follows Increase Contrast here.
  for (ZenPipGlassControl* c in [self allGlassControls]) {
    [c setClearGlass:YES];
  }
  [mTimeline setClearGlass:YES];
  [mTuckPanel.control setClearGlass:NO];
  [self refreshAllControls];
}

- (NSArray<ZenPipGlassControl*>*)allGlassControls {
  return @[ mClose, mMinimize, mSpeed, mCaptions, mSound, mReturn, mBack, mPlay,
            mForward, mLiveBadge ];
}

// Names used by debugState, focusedControlName and the test hooks.
- (NSDictionary<NSString*, ZenPipGlassControl*>*)namedControls {
  return @{
    @"close" : mClose, @"minimize" : mMinimize, @"speed" : mSpeed,
    @"captions" : mCaptions, @"sound" : mSound, @"return" : mReturn,
    @"back15" : mBack, @"playPause" : mPlay, @"forward15" : mForward,
    @"live" : mLiveBadge
  };
}

#pragma mark Host

- (void)notifyHost:(const char*)aAction value:(double)aValue detail:(NSString*)aDetail {
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

- (void)setPlaybackRate:(double)aRate {
  if (!std::isfinite(aRate) || aRate <= 0) {
    return;
  }
  mRate = aRate;
  [self refreshSpeedButton];
  mOverlay.needsLayout = YES;
}

- (void)setCurrentTime:(double)aCurrentTime
              duration:(double)aDuration
              seekable:(BOOL)aSeekable
                  live:(BOOL)aLive {
  BOOL layoutChange = aSeekable != mSeekable || aLive != mLive ||
                      FormatTime(aDuration).length != FormatTime(mDuration).length;
  mCurrentTime = aCurrentTime;
  mDuration = aDuration;
  mSeekable = aSeekable;
  mLive = aLive;
  if (!mControlsVisible && !layoutChange) {
    return;  // nothing visible to update; refreshed when shown
  }
  [self refreshTimeline];
  if (layoutChange) {
    mOverlay.needsLayout = YES;
  }
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
  NSWindow* window = mWindow;
  if (!window || mTucked) {
    return;
  }
  // Keep roughly the same area and the same anchor.
  Box frame = ToRect(window.frame);
  Box area = [self allowedArea];
  Dock dock = DetectDock(frame, area, 2);
  double width = std::sqrt(frame.width * frame.height * aspect);
  Box resized = ScaleFrame(frame, width / frame.width, aspect, dock, area,
                            mConfig.limits);
  [self stopAnimation];
  [window setFrame:ToNSRect(resized) display:YES];
  window.contentAspectRatio = NSMakeSize(resized.width, resized.height);
  [self settleAnimated:YES];
}

- (void)setSourceWindow:(nullable NSWindow*)aWindow {
  if (mSourceWindow == aWindow) {
    return;
  }
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  NSScreen* oldScreen = [self sourceScreen];
  mSourceWindow = aWindow;
  if (aWindow) {
    __weak ZenPipPlayerChrome* weakSelf = self;
    [mObservers addObject:[nc addObserverForName:NSWindowDidChangeScreenNotification
                                          object:aWindow
                                           queue:nil
                                      usingBlock:^(NSNotification* aNote) {
                                        ZenPipPlayerChrome* chrome = weakSelf;
                                        if (chrome && aNote.object == chrome->mSourceWindow) {
                                          [chrome sourceScreenChanged];
                                        }
                                      }]];
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
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : aFallback;
  };
  mConfig.edgeGap = std::clamp(number(@"edgeGap", mConfig.edgeGap), 0.0, 64.0);
  mConfig.spring.response =
      std::clamp(number(@"springResponse", mConfig.spring.response), 0.1, 2.0);
  mConfig.spring.dampingRatio =
      std::clamp(number(@"springDamping", mConfig.spring.dampingRatio), 0.3, 1.5);
  mConfig.release.decelerationRate = std::clamp(
      number(@"decelerationRate", mConfig.release.decelerationRate), 0.9, 0.9995);
  mConfig.release.flickSpeed =
      std::clamp(number(@"flickSpeed", mConfig.release.flickSpeed), 50.0, 5000.0);
  mConfig.release.magnetDistance = std::clamp(
      number(@"magnetDistance", mConfig.release.magnetDistance), 0.0, 200.0);
  mConfig.idleHideDelay =
      std::clamp(number(@"idleHideDelay", mConfig.idleHideDelay), 0.8, 30.0);
  mConfig.carryWithTwoFingers =
      number(@"carryWithTwoFingers", mConfig.carryWithTwoFingers ? 1 : 0) != 0;
  id simulated = aConfiguration[@"simulateAccessibility"];
  if ([simulated isKindOfClass:[NSDictionary class]]) {
    mSimulatedAppearance = [simulated copy];
    [self appearanceChanged];
  }
  [self settleAnimated:NO];
}

#pragma mark Control refresh

- (void)refreshAllControls {
  [self refreshLiveBadge];
  [self refreshPlayButton];
  [self refreshSoundButton];
  [self refreshSpeedButton];
  [self refreshCaptionsButton];
  [self refreshTimeline];
  [self configureButton:mClose symbol:@"xmark" key:@"close" fallback:@"Close"];
  [self configureButton:mMinimize symbol:@"minus" key:@"minimize" fallback:@"Minimize"];
  [self configureButton:mReturn symbol:@"pip.exit" key:@"returnToTab" fallback:@"Back to tab"];
  [self configureButton:mBack symbol:@"gobackward.15" key:@"back15"
               fallback:@"Back 15 seconds"];
  [self configureButton:mForward symbol:@"goforward.15" key:@"forward15"
               fallback:@"Forward 15 seconds"];
  if (mTuckPanel) {
    NSString* label = [self string:@"restore" fallback:@"Show Picture-in-Picture"];
    mTuckPanel.control.button.accessibilityLabel = label;
    mTuckPanel.control.button.toolTip = label;
  }
  mOverlay.needsLayout = YES;
}

- (CGFloat)symbolScale {
  return std::clamp<CGFloat>(mOverlay.bounds.size.width / kReferenceWidth, 0.72, 1.18);
}

- (void)configureButton:(ZenPipGlassControl*)aControl
                 symbol:(NSString*)aSymbol
                    key:(NSString*)aKey
               fallback:(NSString*)aFallback {
  CGFloat s = [self symbolScale];
  CGFloat point = aControl == mPlay      ? 23 * s
                  : (aControl == mBack || aControl == mForward) ? 17 * s
                                                               : 13 * s;
  NSFontWeight weight = mAppearance.increaseContrast ? NSFontWeightBold
                                                     : NSFontWeightSemibold;
  NSImage* image = Symbol(aSymbol, std::max<CGFloat>(point, 11), weight);
  NSString* label = [self string:aKey fallback:aFallback];
  aControl.button.image = image;
  aControl.button.title = image ? @"" : label;
  aControl.button.accessibilityLabel = label;
  aControl.button.toolTip = label;
}

- (void)refreshPlayButton {
  if (mPlaying) {
    [self configureButton:mPlay symbol:@"pause.fill" key:@"pause" fallback:@"Pause"];
  } else {
    [self configureButton:mPlay symbol:@"play.fill" key:@"play" fallback:@"Play"];
  }
}

- (void)refreshSoundButton {
  if (mMuted) {
    [self configureButton:mSound symbol:@"speaker.slash.fill" key:@"unmute"
                 fallback:@"Unmute"];
  } else {
    [self configureButton:mSound symbol:@"speaker.wave.2.fill" key:@"mute"
                 fallback:@"Mute"];
  }
}

- (void)refreshCaptionsButton {
  NSString* key = !mCaptionsAvailable ? @"captionsUnavailable"
                  : mCaptionsEnabled  ? @"captionsOff"
                                      : @"captionsOn";
  NSString* fallback = !mCaptionsAvailable ? @"Captions unavailable"
                       : mCaptionsEnabled  ? @"Hide captions"
                                           : @"Show captions";
  [self configureButton:mCaptions
                 symbol:mCaptionsEnabled && mCaptionsAvailable ? @"captions.bubble.fill"
                                                               : @"captions.bubble"
                    key:key
               fallback:fallback];
  mCaptions.button.enabled = mCaptionsAvailable;
  mCaptions.alphaValue = mCaptionsAvailable ? 1 : 0.45;
}

- (void)refreshSpeedButton {
  CGFloat s = [self symbolScale];
  NSString* title = FormatRate(mRate);
  NSFont* font = [NSFont monospacedDigitSystemFontOfSize:std::max<CGFloat>(12.5 * s, 11)
                                                  weight:mAppearance.increaseContrast
                                                             ? NSFontWeightBold
                                                             : NSFontWeightSemibold];
  mSpeed.button.image = nil;
  mSpeed.button.imagePosition = NSNoImage;
  mSpeed.button.attributedTitle = [[NSAttributedString alloc]
      initWithString:title
          attributes:@{
            NSFontAttributeName : font,
            NSForegroundColorAttributeName : NSColor.whiteColor
          }];
  NSString* label = [self string:@"speed" fallback:@"Playback speed"];
  mSpeed.button.accessibilityLabel = label;
  mSpeed.button.accessibilityValueDescription = title;
  mSpeed.button.toolTip = [NSString stringWithFormat:@"%@ (%@)", label, title];
}

- (void)refreshTimeline {
  BOOL showTimeline = mSeekable && std::isfinite(mDuration) && mDuration > 0;
  if (showTimeline) {
    if (!mScrubbing) {
      mTimeline.slider.doubleValue = std::clamp(mCurrentTime / mDuration, 0.0, 1.0);
    }
    double shownTime = mScrubbing ? mTimeline.slider.doubleValue * mDuration : mCurrentTime;
    mTimeline.elapsed.stringValue = FormatTime(shownTime);
    mTimeline.duration.stringValue = FormatTime(mDuration);
    mTimeline.slider.hidden = NO;
    mTimeline.slider.accessibilityLabel = [self string:@"timeline" fallback:@"Playback position"];
    if (mLive) {
      // A DVR window: like YouTube, no times on screen (the window's start is
      // arbitrary); VoiceOver hears how far behind live the position is.
      mTimeline.slider.accessibilityValueDescription =
          mAtLiveEdge && !mScrubbing
              ? [self string:@"live" fallback:@"Live"]
              : [NSString stringWithFormat:@"%@ %@", FormatTime(std::max(0.0, mDuration - shownTime)),
                                           [self string:@"behindLive" fallback:@"behind live"]];
    } else {
      NSString* of = [self string:@"timeOf" fallback:@"of"];
      mTimeline.slider.accessibilityValueDescription =
          [NSString stringWithFormat:@"%@ %@ %@", FormatTime(shownTime), of,
                                     FormatTime(mDuration)];
    }
  } else {
    mTimeline.slider.hidden = YES;
    mTimeline.elapsed.stringValue =
        mLive ? [self string:@"live" fallback:@"Live"] : FormatTime(mCurrentTime);
    mTimeline.duration.stringValue = @"";
  }
}

// The Live badge follows YouTube's live button: red dot at the live edge,
// grey when behind; it only acts as a button when the stream can be scrubbed.
- (void)refreshLiveBadge {
  BOOL scrubbable = mLive && mSeekable && std::isfinite(mDuration) && mDuration > 0;
  BOOL atEdge = !scrubbable || mAtLiveEdge;
  mLiveDotRed = atEdge;
  CGFloat point = std::max<CGFloat>(12.5 * [self symbolScale], 11);
  NSFont* font = [NSFont systemFontOfSize:point
                                   weight:mAppearance.increaseContrast ? NSFontWeightBold
                                                                       : NSFontWeightSemibold];
  NSString* live = [self string:@"live" fallback:@"Live"];
  NSString* goLive = [self string:@"goLive" fallback:@"Go to live"];
  mLiveBadge.button.image =
      LiveDotImage(atEdge ? NSColor.systemRedColor : [NSColor colorWithWhite:1 alpha:0.5],
                   round(point * 0.56), round(point * 0.4));
  mLiveBadge.button.imagePosition = NSImageLeft;
  mLiveBadge.button.attributedTitle = [[NSAttributedString alloc]
      initWithString:live
          attributes:@{
            NSFontAttributeName : font,
            NSForegroundColorAttributeName : NSColor.whiteColor
          }];
  mLiveBadge.statusOnly = !scrubbable;
  mLiveBadge.button.accessibilityLabel = scrubbable ? goLive : live;
  mLiveBadge.button.accessibilityValueDescription = scrubbable && atEdge ? live : nil;
  mLiveBadge.button.toolTip = scrubbable ? goLive : nil;
}

#pragma mark Layout

- (void)overlayLayout {
  NSSize size = mOverlay.bounds.size;
  CGFloat W = size.width, H = size.height;
  CGFloat s = [self symbolScale];
  CGFloat inset = std::max<CGFloat>(7, round(10 * s));
  CGFloat topD = std::max<CGFloat>(26, round(30 * s));
  CGFloat spacing = std::max<CGFloat>(6, round(8 * s));
  CGFloat playD = std::max<CGFloat>(40, round(56 * s));
  CGFloat skipD = std::max<CGFloat>(30, round(42 * s));
  CGFloat centerGap = round(30 * s);
  BOOL seekable = mSeekable && std::isfinite(mDuration) && mDuration > 0;
  CGFloat timelineH = std::max<CGFloat>(H < 150 ? 22 : 26, round(32 * s));
  if (mLive && seekable) {
    timelineH = std::max<CGFloat>(timelineH, 24);  // the Live badge is a button
  }
  BOOL showSkip = seekable && W >= 250 && H >= 150;
  BOOL showSpeed = W >= 300;
  BOOL showCaptions = W >= 270;
  BOOL showMinimize = W >= 230;

  // Bottom row. A live stream shows its Live badge at the left; the timeline
  // follows only when the stream can be scrubbed.
  CGFloat rowX = inset;
  mLiveBadge.hidden = !mLive;
  if (mLive) {
    [self refreshLiveBadge];
    CGFloat contentW = mLiveBadge.button.image.size.width +
                       mLiveBadge.button.attributedTitle.size.width;
    mLiveBadge.frame =
        NSMakeRect(inset, inset, ceil(contentW) + round(24 * s), timelineH);
    rowX = NSMaxX(mLiveBadge.frame) + spacing;
  }
  BOOL showTimeline = mLive ? seekable : (seekable || std::isfinite(mDuration));
  BOOL showLabels = !mLive && (W >= 290 || !seekable);

  CGFloat topY = H - inset - topD;
  mClose.frame = NSMakeRect(inset, topY, topD, topD);
  mReturn.frame = NSMakeRect(inset + topD + spacing, topY, topD, topD);
  mMinimize.hidden = !showMinimize;
  mMinimize.frame = NSMakeRect(inset + 2 * (topD + spacing), topY, topD, topD);

  CGFloat x = W - inset;
  for (ZenPipGlassControl* c in @[ mSound, mCaptions, mSpeed ]) {
    BOOL show = c == mSpeed ? showSpeed : c == mCaptions ? showCaptions : YES;
    c.hidden = !show;
    if (!show) {
      continue;
    }
    CGFloat w = topD;
    if (c == mSpeed) {
      NSSize text = [mSpeed.button.attributedTitle size];
      w = std::max<CGFloat>(topD, ceil(text.width) + round(20 * s));
    }
    x -= w;
    c.frame = NSMakeRect(x, topY, w, topD);
    x -= spacing;
  }

  // Center the transport row in the space between the top row and the
  // timeline so small players never overlap them.
  CGFloat cy = seekable || mLive ? round((inset + timelineH + topY) / 2) : round(H / 2);
  mPlay.frame = NSMakeRect(round(W / 2 - playD / 2), round(cy - playD / 2), playD, playD);
  mBack.hidden = !showSkip;
  mForward.hidden = !showSkip;
  mBack.frame = NSMakeRect(NSMinX(mPlay.frame) - centerGap - skipD,
                           round(cy - skipD / 2), skipD, skipD);
  mForward.frame = NSMakeRect(NSMaxX(mPlay.frame) + centerGap, round(cy - skipD / 2),
                              skipD, skipD);

  mTimeline.fontSize = std::max<CGFloat>(10.5, round(12 * s * 2) / 2);
  mTimeline.showsLabels = showLabels;
  mTimeline.frame = NSMakeRect(rowX, inset, W - inset - rowX, timelineH);
  mTimeline.hidden = !showTimeline;

  // Symbols are sized for the current scale.
  [self refreshPlayButton];
  [self refreshSoundButton];
  [self refreshSpeedButton];
  [self refreshCaptionsButton];
  [self configureButton:mClose symbol:@"xmark" key:@"close" fallback:@"Close"];
  [self configureButton:mMinimize symbol:@"minus" key:@"minimize" fallback:@"Minimize"];
  [self configureButton:mReturn symbol:@"pip.exit" key:@"returnToTab" fallback:@"Back to tab"];
  [self configureButton:mBack symbol:@"gobackward.15" key:@"back15"
               fallback:@"Back 15 seconds"];
  [self configureButton:mForward symbol:@"goforward.15" key:@"forward15"
               fallback:@"Forward 15 seconds"];
}

- (CGFloat)timelineTopFromWindowTop {
  CGFloat top = mTimeline.isHidden ? 0 : NSMaxY(mTimeline.frame);
  if (!mLiveBadge.isHidden) {
    top = std::max(top, NSMaxY(mLiveBadge.frame));
  }
  return mOverlay.bounds.size.height - (top > 0 ? top : NSMaxY(mTimeline.frame)) - 6;
}

#pragma mark Controls visibility

- (BOOL)keyboardFocusInControls {
  NSResponder* responder = mWindow.firstResponder;
  return [responder isKindOfClass:[NSView class]] && responder != mOverlay &&
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
  NSView* hit = [mOverlay hitTest:[mOverlay convertPoint:p toView:mOverlay.superview]];
  return hit && hit != mOverlay;
}

- (void)showControls {
  mLastActivity = CACurrentMediaTime();
  if (mControlsVisible || mTucked) {
    return;
  }
  mControlsVisible = YES;
  [self refreshTimeline];
  mControlsRoot.hidden = NO;
  mScrim.hidden = NO;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.2;
    ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    mControlsRoot.animator.alphaValue = 1;
    mScrim.animator.alphaValue = 1;
  }];
  [self notifyHost:"controls"
             value:1
            detail:JSONString(@{@"timelineTop" : @([self timelineTopFromWindowTop])})];
}

- (void)hideControls {
  if (!mControlsVisible) {
    return;
  }
  mControlsVisible = NO;
  __weak ZenPipPlayerChrome* weakSelf = self;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = 0.32;
        ctx.timingFunction =
            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
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
  mLastActivity = CACurrentMediaTime();
  [self showControls];
  [self scheduleHide];
}

- (void)scheduleHide {
  if (mHideTimer || mInvalidated) {
    return;
  }
  __weak ZenPipPlayerChrome* weakSelf = self;
  NSTimeInterval delay =
      std::max<NSTimeInterval>(0.05, mLastActivity + mConfig.idleHideDelay - CACurrentMediaTime());
  mHideTimer = [NSTimer timerWithTimeInterval:delay
                                      repeats:NO
                                        block:^(NSTimer*) {
                                          [weakSelf hideTimerFired];
                                        }];
  mHideTimer.tolerance = 0.15;
  [NSRunLoop.mainRunLoop addTimer:mHideTimer forMode:NSRunLoopCommonModes];
}

- (void)hideTimerFired {
  mHideTimer = nil;
  if ([self shouldKeepControlsVisible]) {
    return;  // re-armed when the reason ends (activity, play, scrub end...)
  }
  if (CACurrentMediaTime() - mLastActivity < mConfig.idleHideDelay - 0.05) {
    [self scheduleHide];
    return;
  }
  [self hideControls];
}

- (void)revealControlsFor:(NSTimeInterval)aDuration {
  [self showControls];
  mLastActivity = CACurrentMediaTime() + aDuration - mConfig.idleHideDelay;
  [mHideTimer invalidate];
  mHideTimer = nil;
  [self scheduleHide];
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
  NSWindow* window = mWindow;
  if (!window || mTucked) {
    return;
  }
  [self showControls];
  [window makeFirstResponder:mPlay.button];
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

- (void)onSpeed:(id)aSender {
  NSMenu* menu = [[NSMenu alloc] init];
  menu.delegate = (id<NSMenuDelegate>)self;
  for (double rate : {0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0}) {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:FormatRate(rate)
                                                  action:@selector(onRateItem:)
                                           keyEquivalent:@""];
    item.target = self;
    item.representedObject = @(rate);
    item.state = std::abs(rate - mRate) < 0.001 ? NSControlStateValueOn
                                                : NSControlStateValueOff;
    [menu addItem:item];
  }
  NSButton* button = mSpeed.button;
  [menu popUpMenuPositioningItem:nil
                      atLocation:NSMakePoint(0, NSHeight(button.bounds) + 4)
                          inView:button];
  [self noteActivity];
}

- (void)onRateItem:(NSMenuItem*)aItem {
  [self notifyHost:"set-rate" value:[aItem.representedObject doubleValue] detail:nil];
}

- (void)menuNeedsUpdate:(NSMenu*)aMenu {
  if (aMenu != mCaptions.button.menu) {
    return;
  }
  [aMenu removeAllItems];
  NSMenuItem* toggle = [[NSMenuItem alloc]
      initWithTitle:[self string:@"captionsMenuShow" fallback:@"Show Captions"]
             action:@selector(onCaptions:)
      keyEquivalent:@""];
  toggle.target = self;
  toggle.state = mCaptionsEnabled ? NSControlStateValueOn : NSControlStateValueOff;
  toggle.enabled = mCaptionsAvailable;
  [aMenu addItem:toggle];
  [aMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* header = [[NSMenuItem alloc]
      initWithTitle:[self string:@"captionsSize" fallback:@"Font size"]
             action:nil
      keyEquivalent:@""];
  header.enabled = NO;
  [aMenu addItem:header];
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
  return aItem.action != @selector(onCaptions:) || mCaptionsAvailable;
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
  BOOL tracking = type == NSEventTypeLeftMouseDown || type == NSEventTypeLeftMouseDragged;
  if (tracking && !mScrubbing) {
    mScrubbing = YES;
    [self notifyHost:"scrub-start" value:position detail:nil];
  }
  if (mScrubbing) {
    [self notifyHost:tracking ? "scrub" : "scrub-end" value:position detail:nil];
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

- (BOOL)overlayKeyDown:(NSEvent*)aEvent {
  NSEventModifierFlags mods = aEvent.modifierFlags;
  unsigned short code = aEvent.keyCode;
  if (code == 48 /* Tab */) {
    // Unhandled Tabs from a focused control bubble up to us: move along the
    // key-view loop instead of jumping back to the first control.
    BOOL backwards = (mods & NSEventModifierFlagShift) != 0;
    if ([self keyboardFocusInControls]) {
      backwards ? [mWindow selectPreviousKeyView:nil] : [mWindow selectNextKeyView:nil];
    } else {
      [self focusControls];
      if (backwards) {
        [mWindow selectPreviousKeyView:nil];
      }
    }
    [self noteActivity];
    return YES;
  }
  if (code == 53 /* Escape */ && [self keyboardFocusInControls]) {
    [mWindow makeFirstResponder:mOverlay];
    [self noteActivity];
    return YES;
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
  return YES;
}

#pragma mark Geometry helpers

- (nullable NSScreen*)sourceScreen {
  NSWindow* source = mSourceWindow;
  if (source.screen) {
    return source.screen;
  }
  if (source) {
    // Off-screen or minimized: pick the display nearest to its frame.
    std::vector<Box> frames;
    NSArray<NSScreen*>* screens = NSScreen.screens;
    for (NSScreen* screen in screens) {
      frames.push_back(ToRect(screen.frame));
    }
    if (!frames.empty()) {
      return screens[ScreenIndexForRect(ToRect(source.frame), frames)];
    }
  }
  NSWindow* window = mWindow;
  return window.screen ?: NSScreen.mainScreen;
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
  if (!mHomeDisplay) {
    return NO;
  }
  NSScreen* home = [self homeScreen];
  return home && DisplayID(home) == mHomeDisplay;
}

- (Box)visibleFrame {
  NSScreen* screen = [self homeScreen];
  return screen ? ToRect(screen.visibleFrame) : Box{0, 0, 1440, 900};
}

- (Box)allowedArea {
  return AllowedArea([self visibleFrame], mConfig.edgeGap);
}

- (void)setWindowOrigin:(Vec2)aOrigin {
  NSWindow* window = mWindow;
  [window setFrameOrigin:NSMakePoint(aOrigin.x, aOrigin.y)];
}

// Re-establishes containment: same anchor, on the source window's display.
- (void)settleAnimated:(BOOL)aAnimated {
  NSWindow* window = mWindow;
  if (!window || mTucked || mGesture != ZenPipGestureNone || window.inLiveResize) {
    return;
  }
  Box area = [self allowedArea];
  Box frame = ToRect(window.frame);
  Vec2 size = ClampSize(frame.width, mAspect, area, mConfig.limits);
  if (std::abs(size.x - frame.width) > 0.5 || std::abs(size.y - frame.height) > 0.5) {
    Box resized = ScaleFrame(frame, size.x / frame.width, mAspect,
                              DetectDock(frame, area, 2), area, mConfig.limits);
    [window setFrame:ToNSRect(resized) display:YES];
    frame = resized;
  }
  // If the player is on another display, carry its placement over.
  Placement placement = PlacementForFrame(frame, area, 2);
  if (!Box(area).Contains(frame, 0.5) && area.IntersectionArea(frame) <= 0) {
    std::vector<Box> areas;
    for (NSScreen* screen in NSScreen.screens) {
      areas.push_back(AllowedArea(ToRect(screen.visibleFrame), mConfig.edgeGap));
    }
    if (!areas.empty()) {
      placement = PlacementForFrame(frame, areas[ScreenIndexForRect(frame, areas)], 2);
    }
  }
  Vec2 target = area.Contains(frame, 0.5) ? frame.Origin()
                                          : OriginForPlacement(placement, frame.Size(), area);
  if (area.Contains(frame, 0.5)) {
    [self reportPlacement];
    return;
  }
  if (aAnimated && area.IntersectionArea(frame) <= 0) {
    // Arriving from another display (e.g. the one it was on disconnected).
    [self hopToFrame:NSMakeRect(target.x, target.y, frame.width, frame.height)];
    return;
  }
  [self animateTo:target velocity:{} animated:aAnimated];
}

- (void)sourceScreenChanged {
  NSWindow* window = mWindow;
  if (!window || mTucked) {
    return;
  }
  if ([self homeIsPinned]) {
    // The user put the player on another display; it stays there.
    [self settleAnimated:YES];
    return;
  }
  Box frame = ToRect(window.frame);
  std::vector<Box> areas;
  for (NSScreen* screen in NSScreen.screens) {
    areas.push_back(AllowedArea(ToRect(screen.visibleFrame), mConfig.edgeGap));
  }
  Box from = areas.empty() ? frame : areas[ScreenIndexForRect(frame, areas)];
  Placement placement = PlacementForFrame(frame, from, 2);
  Box area = [self allowedArea];
  Vec2 size = ClampSize(frame.width, mAspect, area, mConfig.limits);
  Vec2 target = OriginForPlacement(placement, size, area);
  [self hopToFrame:NSMakeRect(target.x, target.y, size.x, size.y)];
}

// Crossing displays: fade out, move, fade back in (no flight across, so the
// player is never split between two displays).
- (void)hopToFrame:(NSRect)aDestination {
  NSWindow* window = mWindow;
  if (!window) {
    return;
  }
  [self stopAnimation];
  NSRect destination = aDestination;
  if (mAppearance.reduceMotion) {
    [window setFrame:destination display:YES];
    [self reportPlacement];
    return;
  }
  __weak ZenPipPlayerChrome* weakSelf = self;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = 0.12;
        window.animator.alphaValue = 0;
      }
      completionHandler:^{
        [window setFrame:destination display:YES];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
          ctx.duration = 0.2;
          window.animator.alphaValue = 1;
        }];
        [weakSelf reportPlacement];
      }];
}

- (void)reportPlacement {
  NSWindow* window = mWindow;
  if (!window || mTucked) {
    return;
  }
  Box area = [self allowedArea];
  Box frame = ToRect(window.frame);
  Placement p = PlacementForFrame(frame, area, 2);
  mLastDock = p.dock;
  [self notifyHost:"placement"
             value:0
            detail:JSONString(@{
              @"dock" : DockName(p.dock),
              @"fx" : @(p.fx),
              @"fy" : @(p.fy),
              @"width" : @(frame.width),
              @"height" : @(frame.height)
            })];
}

#pragma mark Animation

- (void)animateTo:(Vec2)aTarget velocity:(Vec2)aVelocity animated:(BOOL)aAnimated {
  NSWindow* window = mWindow;
  if (!window) {
    return;
  }
  [self stopAnimation];
  Vec2 from = ToRect(window.frame).Origin();
  if (!aAnimated || mAppearance.reduceMotion || (from - aTarget).Length() < 0.5) {
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
    return toward ? std::clamp(aV, -limit, limit) : std::clamp(aV, -2500.0, 2500.0);
  };
  Vec2 toTarget = aTarget - from;
  Vec2 velocity{bound(aVelocity.x, toTarget.x), bound(aVelocity.y, toTarget.y)};
  mSpring.Start(from, velocity, aTarget, mConfig.spring);
  mSpringStart = CACurrentMediaTime();
  mAnimating = YES;
  if (@available(macOS 14.0, *)) {
    mDisplayLink = [mOverlay displayLinkWithTarget:self selector:@selector(animationStep:)];
    [mDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  } else {
    __weak ZenPipPlayerChrome* weakSelf = self;
    mFallbackAnimationTimer = [NSTimer timerWithTimeInterval:1.0 / 60
                                                     repeats:YES
                                                       block:^(NSTimer*) {
                                                         [weakSelf animationStep:nil];
                                                       }];
    [NSRunLoop.mainRunLoop addTimer:mFallbackAnimationTimer forMode:NSRunLoopCommonModes];
  }
}

- (void)animationStep:(id)aLink {
  NSWindow* window = mWindow;
  if (!window || !mAnimating) {
    [self stopAnimation];
    return;
  }
  double t = CACurrentMediaTime() - mSpringStart;
  Vec2 position, velocity;
  mSpring.Sample(t, &position, &velocity);
  // Even mid-flight the frame never leaves the display's usable area.
  Box hard = [self visibleFrame];
  Vec2 size = ToRect(window.frame).Size();
  position = ClampOrigin(position, size, hard);
  if (mSpring.IsSettled(t) || t > 3) {
    [self setWindowOrigin:mSpring.Target()];
    [self stopAnimation];
    [self reportPlacement];
    return;
  }
  [self setWindowOrigin:position];
}

- (void)stopAnimation {
  mAnimating = NO;
  if (@available(macOS 14.0, *)) {
    [mDisplayLink invalidate];
    mDisplayLink = nil;
  }
  [mFallbackAnimationTimer invalidate];
  mFallbackAnimationTimer = nil;
}

- (Vec2)currentAnimationVelocity {
  if (!mAnimating) {
    return {};
  }
  Vec2 position, velocity;
  mSpring.Sample(CACurrentMediaTime() - mSpringStart, &position, &velocity);
  return velocity;
}

#pragma mark Pointer gestures

- (nullable NSNumber*)resizeHandleAt:(NSPoint)aPoint {
  NSSize size = mOverlay.bounds.size;
  if (size.width < 120 || size.height < 80) {
    return nil;
  }
  BOOL left = aPoint.x < kResizeBand, right = aPoint.x > size.width - kResizeBand;
  BOOL bottom = aPoint.y < kResizeBand, top = aPoint.y > size.height - kResizeBand;
  BOOL cLeft = aPoint.x < kResizeCornerBand, cRight = aPoint.x > size.width - kResizeCornerBand;
  BOOL cBottom = aPoint.y < kResizeCornerBand, cTop = aPoint.y > size.height - kResizeCornerBand;
  if ((left || bottom) && cLeft && cBottom) return @((int)ResizeHandle::BottomLeft);
  if ((right || bottom) && cRight && cBottom) return @((int)ResizeHandle::BottomRight);
  if ((left || top) && cLeft && cTop) return @((int)ResizeHandle::TopLeft);
  if ((right || top) && cRight && cTop) return @((int)ResizeHandle::TopRight);
  if (left) return @((int)ResizeHandle::Left);
  if (right) return @((int)ResizeHandle::Right);
  if (bottom) return @((int)ResizeHandle::Bottom);
  if (top) return @((int)ResizeHandle::Top);
  return nil;
}

- (NSCursor*)cursorForHandle:(ResizeHandle)aHandle {
  if (@available(macOS 15.0, *)) {
    NSCursorFrameResizePosition position;
    switch (aHandle) {
      case ResizeHandle::Left: position = NSCursorFrameResizePositionLeft; break;
      case ResizeHandle::Right: position = NSCursorFrameResizePositionRight; break;
      case ResizeHandle::Bottom: position = NSCursorFrameResizePositionBottom; break;
      case ResizeHandle::Top: position = NSCursorFrameResizePositionTop; break;
      case ResizeHandle::BottomLeft: position = NSCursorFrameResizePositionBottomLeft; break;
      case ResizeHandle::BottomRight: position = NSCursorFrameResizePositionBottomRight; break;
      case ResizeHandle::TopLeft: position = NSCursorFrameResizePositionTopLeft; break;
      case ResizeHandle::TopRight: position = NSCursorFrameResizePositionTopRight; break;
    }
    return [NSCursor frameResizeCursorFromPosition:position
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
  NSPoint p = [mOverlay convertPoint:aEvent.locationInWindow fromView:nil];
  NSNumber* handle = [self resizeHandleAt:p];
  if (handle) {
    [[self cursorForHandle:(ResizeHandle)handle.intValue] set];
  } else {
    [NSCursor.arrowCursor set];
  }
}

- (void)overlayMouseMoved:(NSEvent*)aEvent inside:(BOOL)aInside {
  mPointerInside = aInside;
  if (mGesture == ZenPipGestureNone) {
    [self overlayUpdateCursor:aEvent];
  }
  [self noteActivity];
}

- (void)overlayMouseExited {
  mPointerInside = NO;
  if (mGesture == ZenPipGestureNone) {
    [NSCursor.arrowCursor set];
    mLastActivity = CACurrentMediaTime() - mConfig.idleHideDelay + 0.6;
    [mHideTimer invalidate];
    mHideTimer = nil;
    [self scheduleHide];
  }
}

- (void)beginGestureAt:(NSPoint)aScreenPoint time:(NSTimeInterval)aTime {
  NSWindow* window = mWindow;
  // New input catches the player wherever it currently is.
  [self stopAnimation];
  [self cancelEdgeHold];
  mGestureStartMouse = aScreenPoint;
  mGestureStartFrame = window.frame;
  mGestureDock = DetectDock(ToRect(window.frame), [self allowedArea], 2);
  mSamples.clear();
  mSamples.push_back({aTime, {aScreenPoint.x, aScreenPoint.y}});
}

- (void)overlayMouseDown:(NSEvent*)aEvent {
  NSWindow* window = mWindow;
  if (!window) {
    return;
  }
  [window makeFirstResponder:mOverlay];
  [self beginGestureAt:NSEvent.mouseLocation time:aEvent.timestamp];
  NSPoint local = [mOverlay convertPoint:aEvent.locationInWindow fromView:nil];
  NSNumber* handle = [self resizeHandleAt:local];
  if (handle) {
    mGesture = ZenPipGestureResize;
    mResizeHandle = (ResizeHandle)handle.intValue;
  } else {
    mGesture = ZenPipGesturePending;
  }
  [self noteActivity];
}

- (void)overlayMouseDragged:(NSEvent*)aEvent {
  [self gestureMovedTo:NSEvent.mouseLocation time:aEvent.timestamp];
}

- (void)gestureMovedTo:(NSPoint)aScreenPoint time:(NSTimeInterval)aTime {
  NSWindow* window = mWindow;
  if (!window) {
    return;
  }
  NSPoint delta = NSMakePoint(aScreenPoint.x - mGestureStartMouse.x,
                              aScreenPoint.y - mGestureStartMouse.y);
  mSamples.push_back({aTime, {aScreenPoint.x, aScreenPoint.y}});
  if (mSamples.size() > 32) {
    mSamples.erase(mSamples.begin(), mSamples.begin() + 16);
  }
  if (mGesture == ZenPipGesturePending &&
      std::hypot(delta.x, delta.y) >= kDragThreshold) {
    mGesture = ZenPipGestureDrag;
  }
  if (mGesture == ZenPipGestureDrag || mGesture == ZenPipGestureCarry) {
    Vec2 size = ToRect(mGestureStartFrame).Size();
    Vec2 desired{mGestureStartFrame.origin.x + delta.x, mGestureStartFrame.origin.y + delta.y};
    // A two-finger carry has no pointer on screen; the player's center is.
    NSPoint pointer = mGesture == ZenPipGestureCarry
                          ? NSMakePoint(desired.x + size.x / 2, desired.y + size.y / 2)
                          : aScreenPoint;
    mLastGesturePoint = aScreenPoint;
    BOOL hopped = [self followDrag:desired size:size ontoDisplayAt:pointer time:aTime];
    Vec2 origin = RubberBandOrigin(desired, size, [self allowedArea], [self visibleFrame]);
    [self setWindowOrigin:origin];
    if (hopped) {
      // Carry on from here so the player moves 1:1 with the pointer on its
      // new display instead of waiting at the edge.
      mGestureStartMouse = aScreenPoint;
      mGestureStartFrame.origin = NSMakePoint(origin.x, origin.y);
      [self fadeInAfterHop];
    }
  } else if (mGesture == ZenPipGestureResize) {
    Box resized = ResizeFrame(ToRect(mGestureStartFrame), mResizeHandle,
                               {delta.x, delta.y}, mAspect, mGestureDock,
                               [self allowedArea], mConfig.limits);
    [window setFrame:ToNSRect(resized) display:YES];
  }
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
        NSPointInRect(aPointer, NSInsetRect(screen.frame, kCrossDisplayPointerInset,
                                            kCrossDisplayPointerInset))) {
      target = screen;
      break;
    }
  }
  Vec2 push = aDesired - ClampOrigin(aDesired, aSize, [self allowedArea]);
  bool horizontal = std::abs(push.x) >= std::abs(push.y);
  double needed = std::clamp(kCrossDisplayPushFraction * (horizontal ? aSize.x : aSize.y),
                             kCrossDisplayPushMin, kCrossDisplayPushMax);
  if (!target || std::max(std::abs(push.x), std::abs(push.y)) < needed) {
    [self cancelEdgeHold];
    return NO;
  }
  if (mEdgeHoldStart <= 0) {
    mEdgeHoldStart = aTime;
    // If the pointer then rests, nothing else would re-check: look again
    // once the hold is over.
    __weak ZenPipPlayerChrome* weakSelf = self;
    mEdgeHoldTimer = [NSTimer
        scheduledTimerWithTimeInterval:kCrossDisplayHold + 0.01
                               repeats:NO
                                 block:^(NSTimer*) {
                                   ZenPipPlayerChrome* chrome = weakSelf;
                                   if (chrome && chrome->mEdgeHoldStart > 0 &&
                                       (chrome->mGesture == ZenPipGestureDrag ||
                                        chrome->mGesture == ZenPipGestureCarry)) {
                                     chrome->mEdgeHoldTimer = nil;
                                     [chrome gestureMovedTo:chrome->mLastGesturePoint
                                                       time:std::max(
                                                                NSProcessInfo.processInfo
                                                                    .systemUptime,
                                                                chrome->mEdgeHoldStart +
                                                                    kCrossDisplayHold)];
                                   }
                                 }];
    return NO;
  }
  // The timer re-checks at exactly mEdgeHoldStart + kCrossDisplayHold; at
  // uptimes of days that sum loses enough precision to land a hair short.
  if (aTime - mEdgeHoldStart < kCrossDisplayHold - 1e-6) {
    return NO;
  }
  [self cancelEdgeHold];
  // Back on the source window's display it follows that window again.
  mHomeDisplay = DisplayID(target) == DisplayID([self sourceScreen]) ? 0 : DisplayID(target);
  return YES;
}

- (void)cancelEdgeHold {
  mEdgeHoldStart = 0;
  [mEdgeHoldTimer invalidate];
  mEdgeHoldTimer = nil;
}

- (void)fadeInAfterHop {
  NSWindow* window = mWindow;
  if (!window || mAppearance.reduceMotion) {
    return;
  }
  window.alphaValue = 0.35;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.18;
    ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    window.animator.alphaValue = 1;
  }];
}

- (void)overlayMouseUp:(NSEvent*)aEvent {
  [self gestureEndedAt:NSEvent.mouseLocation
                  time:aEvent.timestamp
            clickCount:aEvent.clickCount];
}

- (void)gestureEndedAt:(NSPoint)aScreenPoint
                  time:(NSTimeInterval)aTime
            clickCount:(NSInteger)aClickCount {
  NSWindow* window = mWindow;
  ZenPipGesture gesture = mGesture;
  mGesture = ZenPipGestureNone;
  [self cancelEdgeHold];
  if (!window) {
    return;
  }
  if (gesture == ZenPipGesturePending) {
    // A click on the video. Double-click toggles playback, like Yab.
    if (aClickCount == 2) {
      [self notifyHost:"toggle-play" value:0 detail:nil];
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
    PointerSample last{aTime, {aScreenPoint.x, aScreenPoint.y}};
    if (gesture == ZenPipGestureDrag) {
      mSamples.push_back(last);
    }
    Vec2 velocity = ReleaseVelocity(mSamples, aTime);
    ReleaseResult result = ResolveRelease(ToRect(window.frame), velocity,
                                          [self allowedArea], mConfig.release);
    [self animateTo:result.target velocity:velocity animated:YES];
  }
}

- (void)overlayScroll:(NSEvent*)aEvent {
  if (!mConfig.carryWithTwoFingers || !aEvent.hasPreciseScrollingDeltas) {
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
    [self noteActivity];
    return;
  }
  if (mGesture != ZenPipGestureCarry) {
    return;
  }
  // Move with the fingers regardless of the scroll-direction preference.
  double sign = aEvent.isDirectionInvertedFromDevice ? 1 : -1;
  NSPoint carried = NSMakePoint(
      (mSamples.empty() ? 0 : mSamples.back().position.x) + sign * aEvent.scrollingDeltaX,
      (mSamples.empty() ? 0 : mSamples.back().position.y) - sign * aEvent.scrollingDeltaY);
  if (phase == NSEventPhaseChanged) {
    [self gestureMovedTo:carried time:aEvent.timestamp];
  } else if (phase == NSEventPhaseEnded || phase == NSEventPhaseCancelled) {
    [self gestureEndedAt:carried time:aEvent.timestamp clickCount:0];
  }
}

- (void)overlayMagnify:(NSEvent*)aEvent {
  NSWindow* window = mWindow;
  if (!window) {
    return;
  }
  if (aEvent.phase == NSEventPhaseBegan) {
    [self stopAnimation];
    mGesture = ZenPipGesturePinch;
    mGestureStartFrame = window.frame;
    mGestureDock = DetectDock(ToRect(window.frame), [self allowedArea], 2);
    mPinchScale = 1;
  } else if (mGesture != ZenPipGesturePinch) {
    return;
  }
  mPinchScale = std::clamp(mPinchScale * (1 + aEvent.magnification), 0.2, 5.0);
  Box scaled = ScaleFrame(ToRect(mGestureStartFrame), mPinchScale, mAspect, mGestureDock,
                           [self allowedArea], mConfig.limits);
  [window setFrame:ToNSRect(scaled) display:YES];
  if (aEvent.phase == NSEventPhaseEnded || aEvent.phase == NSEventPhaseCancelled) {
    mGesture = ZenPipGestureNone;
    window.contentAspectRatio = window.frame.size;
    [self reportPlacement];
  }
  [self noteActivity];
}

#pragma mark Minimize

- (void)minimize {
  NSWindow* window = mWindow;
  if (!window || mTucked) {
    return;
  }
  [self stopAnimation];
  // The pointer is on the minimize button; don't hide the cursor for it.
  mPointerInside = NO;
  [self hideControls];
  mTucked = YES;
  mTuckTransition = YES;
  mFrameBeforeTuck = window.frame;
  if (!mTuckPanel) {
    mTuckPanel = [[ZenPipTuckPanel alloc] initWithTarget:self action:@selector(onRestore:)];
    [self applyAppearance];
    [self refreshAllControls];
  }
  Box area = [self allowedArea];
  Box frame = ToRect(window.frame);
  bool right = frame.Center().x >= area.Center().x;
  CGFloat d = 48;
  Vec2 origin = ClampOrigin(
      {right ? area.MaxX() - d : area.MinX(), frame.Center().y - d / 2}, {d, d}, area);
  [mTuckPanel setFrame:NSMakeRect(origin.x, origin.y, d, d) display:NO];
  mTuckPanel.alphaValue = 0;
  [mTuckPanel orderFrontRegardless];
  BOOL animate = !mAppearance.reduceMotion;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = animate ? 0.18 : 0;
        window.animator.alphaValue = 0;
        mTuckPanel.animator.alphaValue = 1;
      }
      completionHandler:^{
        if (window.alphaValue < 0.01) {
          // Ordered out, the player is no longer composited at all.
          [window orderOut:nil];
          window.alphaValue = 1;
        }
        self->mTuckTransition = NO;
      }];
  [self notifyHost:"tucked" value:1 detail:nil];
}

- (void)onRestore:(id)aSender {
  [self restore];
}

- (void)restore {
  NSWindow* window = mWindow;
  if (!window || !mTucked) {
    return;
  }
  mTucked = NO;
  Box area = [self allowedArea];
  Box frame = ToRect(mFrameBeforeTuck);
  Vec2 origin = ClampOrigin(frame.Origin(), frame.Size(), area);
  [window setFrame:NSMakeRect(origin.x, origin.y, frame.width, frame.height) display:NO];
  window.alphaValue = 0;
  [window orderFrontRegardless];
  ZenPipTuckPanel* panel = mTuckPanel;
  BOOL animate = !mAppearance.reduceMotion;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = animate ? 0.2 : 0;
        window.animator.alphaValue = 1;
        panel.animator.alphaValue = 0;
      }
      completionHandler:^{
        [panel orderOut:nil];
      }];
  [self notifyHost:"tucked" value:0 detail:nil];
  [self revealControlsFor:kInitialRevealDuration];
  [self settleAnimated:YES];
}

- (void)windowVisibilityChanged {
  NSWindow* window = mWindow;
  // Something else (e.g. Gecko focusing the player) showed it again.
  if (mTucked && !mTuckTransition && window.occlusionState & NSWindowOcclusionStateVisible &&
      window.isVisible && window.alphaValue > 0.5) {
    mTucked = NO;
    [mTuckPanel orderOut:nil];
    [self notifyHost:"tucked" value:0 detail:nil];
  }
}

#pragma mark Diagnostics and tests

- (NSString*)glassStyleOf:(NSView*)aMaterial {
  if (@available(macOS 26.0, *)) {
    if ([aMaterial isKindOfClass:[NSGlassEffectView class]]) {
      return ((NSGlassEffectView*)aMaterial).style == NSGlassEffectViewStyleClear ? @"clear"
                                                                                 : @"regular";
    }
  }
  return @"visual-effect";
}

- (BOOL)glassIsTinted:(NSView*)aMaterial {
  if (@available(macOS 26.0, *)) {
    if ([aMaterial isKindOfClass:[NSGlassEffectView class]]) {
      return ((NSGlassEffectView*)aMaterial).tintColor != nil;
    }
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
      @"symbol" : c.button.image.accessibilityDescription ?: c.button.title ?: @"",
      @"interactiveGlass" : @([self glassIsInteractive:c.material]),
      @"statusOnly" : @(c.statusOnly),
    }];
  }
  NSScreen* screen = [self sourceScreen];
  return @{
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
    @"sourceWindowFrame" : source ? rect(source.frame) : @[],
    @"sourceScreen" : screen ? screen.localizedName : @"",
    @"sourceScreenFrame" : screen ? rect(screen.frame) : @[],
    @"sourceVisibleFrame" : screen ? rect(screen.visibleFrame) : @[],
    @"playerScreen" : window.screen ? window.screen.localizedName : @"",
    @"homeScreen" : [self homeScreen].localizedName ?: @"",
    @"homePinned" : @([self homeIsPinned]),
    @"allowedArea" : rect(ToNSRect([self allowedArea])),
    @"insideAllowedArea" : @([self allowedArea].Contains(ToRect(window.frame), 0.75)),
    @"insideVisibleFrame" : @([self visibleFrame].Contains(ToRect(window.frame), 0.75)),
    @"dock" : DockName(DetectDock(ToRect(window.frame), [self allowedArea], 2)),
    @"animating" : @(mAnimating),
    @"tucked" : @(mTucked),
    @"tuckPanelVisible" : @(mTuckPanel.isVisible),
    @"tuckPanelFrame" : mTuckPanel ? rect(mTuckPanel.frame) : @[],
    @"aspect" : @(mAspect),
    @"timeline" : @{
      @"hidden" : @(mTimeline.isHidden),
      @"elapsed" : mTimeline.elapsed.stringValue ?: @"",
      @"duration" : mTimeline.duration.stringValue ?: @"",
      @"position" : @(mTimeline.slider.doubleValue),
      @"frame" : rect(mTimeline.frame),
      @"labelsShown" : @(mTimeline.showsLabels),
      @"accessibilityValue" : mTimeline.slider.accessibilityValueDescription ?: @"",
    },
    @"state" : @{
      @"playing" : @(mPlaying),
      @"muted" : @(mMuted),
      @"rate" : @(mRate),
      @"captionsAvailable" : @(mCaptionsAvailable),
      @"captionsEnabled" : @(mCaptionsEnabled),
      @"live" : @(mLive),
      @"seekable" : @(mSeekable),
      @"atLiveEdge" : @(mAtLiveEdge),
    },
    @"liveDotRed" : @(mLiveDotRed),
    @"accessibility" : @{
      @"reduceMotion" : @(mAppearance.reduceMotion),
      @"reduceTransparency" : @(mAppearance.reduceTransparency),
      @"increaseContrast" : @(mAppearance.increaseContrast),
      @"voiceOver" : @(mAppearance.voiceOver),
    },
    @"firstResponder" : NSStringFromClass([window.firstResponder class]) ?: @"",
    @"focusedControl" : [self focusedControlName] ?: @"",
    @"glassStyle" : [self glassStyleOf:mPlay.material],
    @"glassTinted" : @([self glassIsTinted:mPlay.material]),
    @"pillGlassStyle" : mTuckPanel ? [self glassStyleOf:mTuckPanel.control.material] : @"",
    @"dimmingOpacity" : @(CGColorGetAlpha(mScrim.layer.backgroundColor)),
    @"scrimVisible" : @(!mScrim.isHidden && mScrim.alphaValue > 0),
  };
}

- (nullable NSString*)focusedControlName {
  NSResponder* responder = mWindow.firstResponder;
  if (responder == mTimeline.slider) {
    return @"timeline";
  }
  NSDictionary<NSString*, ZenPipGlassControl*>* names = [self namedControls];
  for (NSString* name in names) {
    if (responder == ((ZenPipGlassControl*)names[name]).button) {
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
  NSEvent* event = [NSEvent keyEventWithType:NSEventTypeKeyDown
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

- (BOOL)glassIsInteractive:(NSView*)aMaterial {
  if (@available(macOS 27.0, *)) {
    if ([aMaterial isKindOfClass:[NSGlassEffectView class]] &&
        [aMaterial respondsToSelector:@selector(effectIsInteractive)]) {
      return ((NSGlassEffectView*)aMaterial).effectIsInteractive;
    }
  }
  return NO;
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
    [self gestureMovedTo:NSMakePoint(start.x + aDelta.x * f, start.y + aDelta.y * f)
                    time:t0 + aDuration * f];
  }
  // The last 80 ms of samples define the release velocity.
  NSTimeInterval tEnd = t0 + aDuration;
  NSPoint end = NSMakePoint(start.x + aDelta.x, start.y + aDelta.y);
  mSamples.clear();
  mSamples.push_back({tEnd - 0.05, {end.x - aReleaseVelocity.x * 0.05, end.y - aReleaseVelocity.y * 0.05}});
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
    [self gestureMovedTo:NSMakePoint(start.x + aDelta.x * f, start.y + aDelta.y * f)
                    time:t0 + aDuration * f];
  }
  [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:aRest]];
  NSPoint end = mLastGesturePoint;
  NSTimeInterval tEnd = std::max(NSProcessInfo.processInfo.systemUptime, t0 + aDuration + aRest);
  mSamples.clear();
  mSamples.push_back({tEnd - 0.05, {end.x, end.y}});
  mSamples.push_back({tEnd, {end.x, end.y}});
  [self gestureEndedAt:end time:tEnd + 0.004 clickCount:0];
}

- (void)testCarryBy:(NSPoint)aDelta {
  // 16 ms apart, then the fingers rest 150 ms before lifting, so the release
  // is a placement rather than a throw.
  uint64_t t = (uint64_t)(NSProcessInfo.processInfo.systemUptime * 1e9);
  auto send = [&](CGScrollPhase aPhase, double aDx, double aDy, uint64_t aAdvance) {
    t += aAdvance;
    CGEventRef cg = CGEventCreateScrollWheelEvent2(nullptr, kCGScrollEventUnitPixel, 2,
                                                   (int32_t)lround(aDy), (int32_t)lround(aDx), 0);
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
    @"left" : @((int)ResizeHandle::Left), @"right" : @((int)ResizeHandle::Right),
    @"top" : @((int)ResizeHandle::Top), @"bottom" : @((int)ResizeHandle::Bottom),
    @"top-left" : @((int)ResizeHandle::TopLeft), @"top-right" : @((int)ResizeHandle::TopRight),
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
    [self gestureMovedTo:NSMakePoint(start.x + aDelta.x * f, start.y + aDelta.y * f)
                    time:t0 + 0.2 * f];
  }
  [self gestureEndedAt:NSMakePoint(start.x + aDelta.x, start.y + aDelta.y)
                  time:t0 + 0.25
            clickCount:0];
}

- (BOOL)testClickControl:(NSString*)aName {
  NSDictionary<NSString*, ZenPipGlassControl*>* names = [self namedControls];
  ZenPipGlassControl* control = names[aName];
  if ([aName hasPrefix:@"timeline:"]) {
    // Moves the real NSSlider and fires its action, like a keyboard or
    // VoiceOver adjustment would.
    if (mTimeline.isHidden || mTimeline.slider.isHidden) {
      return NO;
    }
    [self showControls];
    mTimeline.slider.doubleValue =
        std::clamp([[aName substringFromIndex:9] doubleValue], 0.0, 1.0);
    [mTimeline.slider sendAction:mTimeline.slider.action to:mTimeline.slider.target];
    return YES;
  }
  if ([aName isEqualToString:@"restore"]) {
    if (!mTuckPanel.isVisible) {
      return NO;
    }
    [mTuckPanel.control.button performClick:nil];
    return YES;
  }
  if (!control || control.isHidden || !control.button.isEnabled || control.statusOnly) {
    return NO;
  }
  if (control == mSpeed) {
    // The rate menu is modal; exercise its item action instead.
    [self notifyHost:"set-rate" value:(mRate >= 2 ? 1 : mRate + 0.5) detail:nil];
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
  [self stopAnimation];
  [self cancelEdgeHold];
  [mHideTimer invalidate];
  mHideTimer = nil;
  for (id observer in mObservers) {
    [NSNotificationCenter.defaultCenter removeObserver:observer];
  }
  [mObservers removeAllObjects];
  for (id observer in mWorkspaceObservers) {
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];
  }
  [mWorkspaceObservers removeAllObjects];
  @try {
    [NSWorkspace.sharedWorkspace removeObserver:self forKeyPath:@"voiceOverEnabled"];
  } @catch (NSException*) {
  }
  [mTuckPanel orderOut:nil];
  [mTuckPanel close];
  mTuckPanel = nil;
  NSWindow* window = mWindow;
  if (window) {
    window.movable = mWasMovable;
    window.alphaValue = 1;
    NSResponder* firstResponder = window.firstResponder;
    BOOL ownsFocus = firstResponder == mOverlay ||
                     [firstResponder isKindOfClass:[ZenPipButtonCore class]] ||
                     [firstResponder isKindOfClass:[ZenPipSlider class]];
    if (ownsFocus && window.isVisible) {
      // Hand keyboard focus back to Gecko once the current event is done, and
      // only if the window is still around (not while it is being torn down).
      __weak NSWindow* weakWindow = window;
      __weak NSResponder* previous = mPreviousFirstResponder;
      dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow* w = weakWindow;
        NSResponder* r = previous;
        if (w.isVisible && r && [r isKindOfClass:[NSView class]] &&
            ((NSView*)r).window == w) {
          [w makeFirstResponder:r];
        }
      });
    }
  }
  [mOverlay removeAllTracking];
  mOverlay.chrome = nil;
  [mOverlay removeFromSuperview];
  mOverlay = nil;
  mHost = nullptr;
}

@end
