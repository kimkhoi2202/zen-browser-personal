/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Gecko glue for the native Picture-in-Picture chrome. This file uses manual
// reference counting like the rest of widget/cocoa; the AppKit chrome itself
// (ZenPipNativeChrome.mm) is compiled with ARC and has no Gecko dependencies.

#import <Cocoa/Cocoa.h>

#include "nsZenPipNativePlayer.h"

#include "ZenPipGeometry.h"
#include "ZenPipNativeChrome.h"

#include "mozilla/RefPtr.h"
#include "mozilla/WidgetUtils.h"
#include "nsCOMPtr.h"
#include "nsIWidget.h"
#include "nsObjCExceptions.h"
#include "nsPIDOMWindow.h"
#include "nsString.h"
#include "nsThreadUtils.h"

using namespace zen::pip;

namespace zen {

namespace {

NSWindow* NativeWindowFor(mozIDOMWindowProxy* aWindow) {
  if (!aWindow) {
    return nil;
  }
  nsCOMPtr<nsPIDOMWindowOuter> outer = nsPIDOMWindowOuter::From(aWindow);
  RefPtr<nsIWidget> widget =
      mozilla::widget::WidgetUtils::DOMWindowToWidget(outer);
  if (!widget) {
    return nil;
  }
  return static_cast<NSWindow*>(widget->GetNativeData(NS_NATIVE_WINDOW));
}

NSString* ToNSString(const nsACString& aString) {
  return [[[NSString alloc] initWithBytes:aString.BeginReading()
                                   length:aString.Length()
                                 encoding:NSUTF8StringEncoding] autorelease];
}

NSDictionary* ParseJSONObject(const nsACString& aJSON) {
  if (aJSON.IsEmpty()) {
    return nil;
  }
  NSData* data = [NSData dataWithBytes:aJSON.BeginReading() length:aJSON.Length()];
  id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

double NumberOr(NSDictionary* aDict, NSString* aKey, double aFallback) {
  id value = aDict[aKey];
  return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : aFallback;
}

Dock DockFromName(NSString* aName) {
  Dock dock;
  if (![aName isKindOfClass:[NSString class]]) {
    return {HEdge::Right, VEdge::Bottom};
  }
  if ([aName containsString:@"left"]) {
    dock.h = HEdge::Left;
  } else if ([aName containsString:@"right"]) {
    dock.h = HEdge::Right;
  }
  if ([aName containsString:@"bottom"]) {
    dock.v = VEdge::Bottom;
  } else if ([aName containsString:@"top"]) {
    dock.v = VEdge::Top;
  }
  return dock;
}

Box ToRect(NSRect aRect) {
  return {aRect.origin.x, aRect.origin.y, aRect.size.width, aRect.size.height};
}

}  // namespace

class nsZenPipNativeControls final : public nsIZenPipNativeControls,
                                     public ChromeHost {
 public:
  NS_DECL_ISUPPORTS
  NS_DECL_NSIZENPIPNATIVECONTROLS

  nsZenPipNativeControls(NSWindow* aWindow,
                         nsIZenPipNativeControlsListener* aListener)
      : mListener(aListener) {
    mChrome = [[ZenPipPlayerChrome alloc] initWithPlayerWindow:aWindow host:this];
  }

  bool IsAttached() const { return !!mChrome; }

  void OnChromeAction(const char* aAction, double aValue,
                      const char* aDetail) override {
    nsAutoCString action(aAction);
    nsAutoCString detail(aDetail ? aDetail : "");
    bool closing = action.EqualsLiteral("window-will-close");
    // Never re-enter JS from inside AppKit event handling: the listener may
    // close the window we are being called from.
    NS_DispatchToCurrentThread(NS_NewRunnableFunction(
        "zen::nsZenPipNativeControls::OnChromeAction",
        [self = RefPtr{this}, action, aValue, detail, closing] {
          if (nsCOMPtr<nsIZenPipNativeControlsListener> listener = self->mListener) {
            listener->OnAction(action, aValue, detail);
          }
          if (closing) {
            self->Destroy();
          }
        }));
  }

 private:
  ~nsZenPipNativeControls() { Destroy(); }

  ZenPipPlayerChrome* mChrome = nil;  // strong (manually retained)
  nsCOMPtr<nsIZenPipNativeControlsListener> mListener;
};

NS_IMPL_ISUPPORTS(nsZenPipNativeControls, nsIZenPipNativeControls)

NS_IMETHODIMP
nsZenPipNativeControls::SetPlaying(bool aPlaying) {
  [mChrome setPlaying:aPlaying];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::SetMuted(bool aMuted) {
  [mChrome setMuted:aMuted];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::SetPlaybackRate(double aRate) {
  [mChrome setPlaybackRate:aRate];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::SetTimeline(double aCurrentTime, double aDuration,
                                    bool aSeekable, bool aLive) {
  [mChrome setCurrentTime:aCurrentTime
                 duration:aDuration
                 seekable:aSeekable
                     live:aLive];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::SetLiveEdge(bool aAtLiveEdge) {
  [mChrome setAtLiveEdge:aAtLiveEdge];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::SetCaptions(bool aAvailable, bool aEnabled) {
  [mChrome setCaptionsAvailable:aAvailable enabled:aEnabled];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::SetCaptionSize(const nsACString& aSize) {
  [mChrome setCaptionSize:ToNSString(aSize)];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::SetStrings(const nsACString& aStringsJSON) {
  NSDictionary* strings = ParseJSONObject(aStringsJSON);
  if (!strings) {
    return NS_ERROR_INVALID_ARG;
  }
  NSMutableDictionary<NSString*, NSString*>* clean = [NSMutableDictionary dictionary];
  for (id key in strings) {
    id value = strings[key];
    if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
      clean[key] = value;
    }
  }
  [mChrome setStrings:clean];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::SetVideoSize(double aWidth, double aHeight) {
  [mChrome setVideoSize:NSMakeSize(aWidth, aHeight)];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::SetSourceWindow(mozIDOMWindowProxy* aSourceWindow) {
  [mChrome setSourceWindow:NativeWindowFor(aSourceWindow)];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::SetConfiguration(const nsACString& aConfigJSON) {
  NSDictionary* config = ParseJSONObject(aConfigJSON);
  if (!config) {
    return NS_ERROR_INVALID_ARG;
  }
  [mChrome setConfiguration:config];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::RevealControls(bool aSticky) {
  [mChrome revealControlsSticky:aSticky];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::FocusControls() {
  [mChrome focusControls];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::Minimize() {
  [mChrome minimize];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::Restore() {
  [mChrome restore];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::GetDebugState(nsACString& aState) {
  NS_OBJC_BEGIN_TRY_BLOCK_RETURN;
  if (!mChrome) {
    aState.AssignLiteral("{\"attached\":false}");
    return NS_OK;
  }
  NSData* data = [NSJSONSerialization dataWithJSONObject:[mChrome debugState]
                                                 options:NSJSONWritingSortedKeys
                                                   error:nil];
  if (!data) {
    return NS_ERROR_FAILURE;
  }
  aState.Assign(static_cast<const char*>(data.bytes), data.length);
  return NS_OK;
  NS_OBJC_END_TRY_BLOCK_RETURN(NS_ERROR_FAILURE);
}

NS_IMETHODIMP
nsZenPipNativeControls::TestDrag(double aDx, double aDy, double aDuration,
                                 double aReleaseX, double aReleaseY) {
  [mChrome testDragBy:NSMakePoint(aDx, aDy)
             duration:aDuration
              release:NSMakePoint(aReleaseX, aReleaseY)];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::TestResize(const nsACString& aHandle, double aDx,
                                   double aDy) {
  [mChrome testResizeHandle:ToNSString(aHandle) by:NSMakePoint(aDx, aDy)];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::TestClick(const nsACString& aControl, bool* aClicked) {
  *aClicked = [mChrome testClickControl:ToNSString(aControl)];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::TestKey(uint16_t aKeyCode, const nsACString& aCharacters,
                                uint32_t aModifiers) {
  [mChrome testKey:aKeyCode
        characters:ToNSString(aCharacters)
         modifiers:(NSEventModifierFlags)aModifiers];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::TestDoubleClick(const nsACString& aWhere, bool* aQueued) {
  *aQueued = [mChrome testDoubleClick:ToNSString(aWhere)];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativeControls::Destroy() {
  NS_OBJC_BEGIN_TRY_IGNORE_BLOCK;
  if (mChrome) {
    ZenPipPlayerChrome* chrome = mChrome;
    mChrome = nil;
    [chrome invalidate];
    [chrome release];
  }
  NS_OBJC_END_TRY_IGNORE_BLOCK;
  // Breaks the JS <-> native reference cycle.
  mListener = nullptr;
  return NS_OK;
}

NS_IMPL_ISUPPORTS(nsZenPipNativePlayer, nsIZenPipNativePlayer)

NS_IMETHODIMP
nsZenPipNativePlayer::GetIsSupported(bool* aSupported) {
  *aSupported = true;
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativePlayer::GetHasLiquidGlass(bool* aHasGlass) {
  *aHasGlass = [ZenPipPlayerChrome hasLiquidGlass];
  return NS_OK;
}

NS_IMETHODIMP
nsZenPipNativePlayer::Attach(mozIDOMWindowProxy* aPlayerWindow,
                             nsIZenPipNativeControlsListener* aListener,
                             nsIZenPipNativeControls** aControls) {
  NS_ENSURE_ARG_POINTER(aListener);
  NS_OBJC_BEGIN_TRY_BLOCK_RETURN;
  NSWindow* window = NativeWindowFor(aPlayerWindow);
  NS_ENSURE_TRUE(window, NS_ERROR_NOT_AVAILABLE);
  RefPtr<nsZenPipNativeControls> controls =
      new nsZenPipNativeControls(window, aListener);
  NS_ENSURE_TRUE(controls->IsAttached(), NS_ERROR_FAILURE);
  controls.forget(aControls);
  return NS_OK;
  NS_OBJC_END_TRY_BLOCK_RETURN(NS_ERROR_FAILURE);
}

NS_IMETHODIMP
nsZenPipNativePlayer::InitialFrame(mozIDOMWindowProxy* aSourceWindow,
                                   double aVideoWidth, double aVideoHeight,
                                   const nsACString& aPlacementJSON,
                                   double aEdgeGap, nsTArray<double>& aFrame) {
  NS_OBJC_BEGIN_TRY_BLOCK_RETURN;
  NSArray<NSScreen*>* screens = NSScreen.screens;
  NS_ENSURE_TRUE(screens.count, NS_ERROR_NOT_AVAILABLE);

  // The display that holds most of the source browser window.
  NSWindow* source = NativeWindowFor(aSourceWindow);
  NSScreen* screen = source.screen;
  if (!screen) {
    std::vector<Box> frames;
    for (NSScreen* s in screens) {
      frames.push_back(ToRect(s.frame));
    }
    screen = source ? screens[ScreenIndexForRect(ToRect(source.frame), frames)]
                    : NSScreen.mainScreen;
  }
  Box area = AllowedArea(ToRect(screen.visibleFrame), std::max(0.0, aEdgeGap));

  double aspect = (aVideoWidth > 0 && aVideoHeight > 0)
                      ? aVideoWidth / aVideoHeight
                      : 16.0 / 9.0;
  NSDictionary* saved = ParseJSONObject(aPlacementJSON);
  Placement placement;
  placement.dock = DockFromName(saved[@"dock"]);
  placement.fx = std::clamp(NumberOr(saved, @"fx", 1), 0.0, 1.0);
  placement.fy = std::clamp(NumberOr(saved, @"fy", 0), 0.0, 1.0);
  // A third of the display width by default, like the stock player.
  double width = NumberOr(saved, @"width", area.width / 3);
  Vec2 size = ClampSize(width, aspect, area, SizeLimits{});
  Vec2 origin = OriginForPlacement(placement, size, area);

  // AppKit (y up from the primary display's bottom) to Gecko desktop
  // coordinates (y down from the primary display's top).
  double primaryTop = NSMaxY(screens.firstObject.frame);
  aFrame.AppendElement(origin.x);
  aFrame.AppendElement(primaryTop - (origin.y + size.y));
  aFrame.AppendElement(size.x);
  aFrame.AppendElement(size.y);
  return NS_OK;
  NS_OBJC_END_TRY_BLOCK_RETURN(NS_ERROR_FAILURE);
}

}  // namespace zen
