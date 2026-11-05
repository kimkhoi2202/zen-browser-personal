/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Standalone harness for ZenPipNativeChrome (no Gecko). It hosts the exact
// chrome the browser uses over an AVPlayer video inside a non-activating
// floating panel, so rendering, layout and window motion can be checked
// against the real WindowServer and real displays. Build with build.sh.
//
//   ZenPipChromeHarness <video> visual [screenIndex] [width height]
//   ZenPipChromeHarness <video> layout [fast]
//   ZenPipChromeHarness <video> keys
//   ZenPipChromeHarness <video> clicks
//   ZenPipChromeHarness <video> motion
//
// "layout" (on-demand, live and live DVR timelines), "keys" (Tab order),
// "clicks" (presses, double-clicks and drags on the border and the video,
// controls on the border, the speed menu) and "motion" exit non-zero if any
// check fails. Video playback is muted.
// ZEN_PIP_HARNESS_MENU=<png> in "clicks" also saves the open speed menu.

#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>

#include <cstdio>
#include <functional>
#include <string>
#include <vector>

#import "ZenPipNativeChrome.h"

using zen::pip::ChromeHost;

static void Print(NSString* aLine) {
  std::printf("%s\n", aLine.UTF8String);
  std::fflush(stdout);
}

static NSString* JSON(id aObject) {
  NSData* d = [NSJSONSerialization dataWithJSONObject:aObject
                                              options:NSJSONWritingSortedKeys
                                                error:nil];
  return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

// Plays the role of player.js: mirrors playback state back into the chrome.
class HarnessHost final : public ChromeHost {
 public:
  ZenPipPlayerChrome* __weak chrome = nil;
  AVPlayer* player = nil;
  bool playing = true, muted = true, captions = false;
  double rate = 1;
  std::vector<std::string> log;

  void OnChromeAction(const char* aAction, double aValue,
                      const char* aDetail) override {
    std::string action(aAction);
    log.push_back(action);
    Print([NSString stringWithFormat:@"ACTION %s %g %s", aAction, aValue, aDetail]);
    if (action == "toggle-play") {
      playing = !playing;
      playing ? [player play] : [player pause];
      [chrome setPlaying:playing];
    } else if (action == "seek-relative") {
      CMTime t = CMTimeAdd(player.currentTime, CMTimeMakeWithSeconds(aValue, 600));
      [player seekToTime:t];
    } else if (action == "toggle-mute") {
      muted = !muted;
      [chrome setMuted:muted];
    } else if (action == "set-rate") {
      rate = aValue;
      [chrome setPlaybackRate:rate];
    } else if (action == "toggle-captions") {
      captions = !captions;
      [chrome setCaptionsAvailable:YES enabled:captions];
    } else if (action == "go-live") {
      [player seekToTime:CMTimeMakeWithSeconds(177, 600)];
      [chrome setAtLiveEdge:YES];
    }
  }
};

// Never the key window: the clicks the harness queues would otherwise make it
// key and send whatever the user is typing in another app to the player.
// Key events in the checks go straight to the window (testKey).
@interface HarnessPanel : NSPanel
@end
@implementation HarnessPanel
- (BOOL)canBecomeKeyWindow {
  return NO;
}
@end

static NSPanel* MakePlayerPanel(NSRect aFrame) {
  NSPanel* panel = [[HarnessPanel alloc]
      initWithContentRect:aFrame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable |
                          NSWindowStyleMaskFullSizeContentView |
                          NSWindowStyleMaskNonactivatingPanel
                  backing:NSBackingStoreBuffered
                    defer:NO];
  panel.titlebarAppearsTransparent = YES;
  panel.titleVisibility = NSWindowTitleHidden;
  panel.level = NSFloatingWindowLevel;
  panel.releasedWhenClosed = NO;
  panel.hidesOnDeactivate = NO;
  panel.becomesKeyOnlyIfNeeded = NO;
  panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                             NSWindowCollectionBehaviorFullScreenAuxiliary;
  panel.contentAspectRatio = aFrame.size;
  return panel;
}

static void Spin(NSTimeInterval aSeconds) {
  [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:aSeconds]];
}

// Like Spin, but also dispatches queued events the way the application's
// event loop does (through -[NSApplication sendEvent:] and its monitors).
static void Pump(NSTimeInterval aSeconds) {
  NSDate* until = [NSDate dateWithTimeIntervalSinceNow:aSeconds];
  while (until.timeIntervalSinceNow > 0) {
    NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                        untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
                                           inMode:NSDefaultRunLoopMode
                                          dequeue:YES];
    if (event) {
      [NSApp sendEvent:event];
    }
  }
}

static void WaitUntilSettled(ZenPipPlayerChrome* aChrome) {
  for (int i = 0; i < 400; i++) {
    Spin(0.01);
    if (![[aChrome debugState][@"animating"] boolValue]) {
      return;
    }
  }
}

int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc < 3) {
      std::fprintf(stderr, "usage: %s <video> visual|layout|motion ...\n", argv[0]);
      return 2;
    }
    NSString* mode = @(argv[2]);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    NSArray<NSScreen*>* screens = NSScreen.screens;
    NSUInteger screenIndex = argc > 3 ? (NSUInteger)atoi(argv[3]) : 0;
    NSScreen* screen = screens[MIN(screenIndex, screens.count - 1)];
    CGFloat width = argc > 5 ? atof(argv[4]) : 640;
    CGFloat height = argc > 5 ? atof(argv[5]) : 360;

    // A stand-in for the browser window that hosts the source tab.
    NSRect vf = screen.visibleFrame;
    NSWindow* source = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(NSMidX(vf) - 300, NSMidY(vf) - 200, 600, 400)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered
                      defer:NO];
    source.releasedWhenClosed = NO;
    source.alphaValue = 0;  // never visible; only its display matters
    [source orderBack:nil];

    NSPanel* panel = MakePlayerPanel(
        NSMakeRect(NSMaxX(vf) - width - 14, NSMinY(vf) + 14, width, height));
    NSView* content = panel.contentView;
    content.wantsLayer = YES;
    NSView* video = [[NSView alloc] initWithFrame:content.bounds];
    video.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    video.wantsLayer = YES;
    AVPlayer* player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:@(argv[1])]];
    player.muted = YES;
    AVPlayerLayer* playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
    playerLayer.frame = video.bounds;
    playerLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [video.layer addSublayer:playerLayer];
    [content addSubview:video];
    [player seekToTime:CMTimeMake(95, 1)];
    [player play];

    HarnessHost host;
    host.player = player;
    ZenPipPlayerChrome* chrome = [[ZenPipPlayerChrome alloc] initWithPlayerWindow:panel
                                                                             host:&host];
    host.chrome = chrome;
    [chrome setStrings:@{@"close" : @"Close", @"minimize" : @"Minimize"}];
    [chrome setVideoSize:NSMakeSize(1280, 720)];
    [chrome setSourceWindow:source];
    [chrome setPlaying:YES];
    [chrome setMuted:NO];
    [chrome setCaptionsAvailable:YES enabled:NO];
    [chrome setCurrentTime:95 duration:180 seekable:YES live:NO];
    [panel orderFrontRegardless];

    // Keep the timeline in step with the AVPlayer like timeupdate would. The
    // layout mode also simulates the two kinds of live stream the bridge
    // reports: without DVR (no duration, not seekable) and with a DVR window
    // (here the whole video, with the live edge at its end).
    enum class Timeline { OnDemand, Live, LiveDVR };
    __block Timeline timeline = Timeline::OnDemand;
    [NSTimer scheduledTimerWithTimeInterval:0.25
                                    repeats:YES
                                      block:^(NSTimer*) {
                                        double t = CMTimeGetSeconds(player.currentTime);
                                        if (timeline == Timeline::Live) {
                                          [chrome setCurrentTime:t
                                                        duration:INFINITY
                                                        seekable:NO
                                                            live:YES];
                                        } else {
                                          [chrome setCurrentTime:t
                                                        duration:180
                                                        seekable:YES
                                                            live:timeline == Timeline::LiveDVR];
                                        }
                                      }];

    int failures = 0;
    auto check = [&](bool aOk, NSString* aWhat) {
      Print([NSString stringWithFormat:@"%@ %@", aOk ? @"ok  " : @"FAIL", aWhat]);
      failures += aOk ? 0 : 1;
    };

    if ([mode isEqualToString:@"visual"]) {
      [chrome revealControlsSticky:YES];
      Spin(1.2);
      Print([NSString stringWithFormat:@"WINDOW %ld", (long)panel.windowNumber]);
      Print([NSString stringWithFormat:@"STATE %@", JSON([chrome debugState])]);
      // ZEN_PIP_HARNESS_CAPTURE=<png> saves a screenshot of the player window.
      if (const char* capture = getenv("ZEN_PIP_HARNESS_CAPTURE")) {
        NSTask* task = [NSTask
            launchedTaskWithLaunchPath:@"/usr/sbin/screencapture"
                             arguments:@[ @"-x", @"-o",
                                          [NSString stringWithFormat:@"-l%ld",
                                                                     (long)panel.windowNumber],
                                          @(capture) ]];
        [task waitUntilExit];
      }
      Spin(argc > 6 ? atof(argv[6]) : 4);
    } else if ([mode isEqualToString:@"layout"]) {
      [chrome revealControlsSticky:YES];
      auto frameOf = [](NSArray* fr) {
        return NSMakeRect([fr[0] doubleValue], [fr[1] doubleValue], [fr[2] doubleValue],
                          [fr[3] doubleValue]);
      };
      auto controlNamed = [](NSDictionary* aState, NSString* aName) -> NSDictionary* {
        for (NSDictionary* c in aState[@"controls"]) {
          if ([c[@"name"] isEqualToString:aName]) {
            return c;
          }
        }
        return nil;
      };
      for (Timeline kind : {Timeline::OnDemand, Timeline::Live, Timeline::LiveDVR}) {
        timeline = kind;
        NSString* label = kind == Timeline::OnDemand ? @""
                          : kind == Timeline::Live   ? @"live "
                                                     : @"live DVR ";
        [chrome setAtLiveEdge:YES];
        for (NSValue* sizeValue in @[ [NSValue valueWithSize:NSMakeSize(200, 112.5)],
                                      [NSValue valueWithSize:NSMakeSize(260, 146.25)],
                                      [NSValue valueWithSize:NSMakeSize(320, 180)],
                                      [NSValue valueWithSize:NSMakeSize(480, 270)],
                                      [NSValue valueWithSize:NSMakeSize(720, 405)] ]) {
          NSSize s = sizeValue.sizeValue;
          NSRect f = panel.frame;
          [panel setFrame:NSMakeRect(NSMaxX(f) - s.width, NSMinY(f), s.width, s.height)
                  display:YES];
          Spin(0.6);
          NSDictionary* state = [chrome debugState];
          NSString* where = [NSString stringWithFormat:@"%@%gx%g", label, s.width, s.height];
          NSMutableArray* visible = [NSMutableArray array];
          std::vector<std::pair<NSString*, NSRect>> shown;
          for (NSDictionary* c in state[@"controls"]) {
            if (![c[@"hidden"] boolValue]) {
              [visible addObject:c[@"name"]];
              NSRect fr = frameOf(c[@"frame"]);
              // A status badge isn't a hit target.
              if (![c[@"statusOnly"] boolValue]) {
                CGFloat d = MIN(fr.size.width, fr.size.height);
                check(d >= 24, [NSString stringWithFormat:@"%@ %@ hit target %.0fpt >= 24",
                                                         where, c[@"name"], d]);
              }
              shown.push_back({c[@"name"], fr});
            }
          }
          BOOL timelineShown = ![state[@"timeline"][@"hidden"] boolValue];
          if (timelineShown) {
            [visible addObject:@"timeline"];
            shown.push_back({@"timeline", frameOf(state[@"timeline"][@"frame"])});
          }
          bool overlap = false;
          for (size_t i = 0; i < shown.size(); i++) {
            for (size_t j = i + 1; j < shown.size(); j++) {
              if (NSIntersectsRect(shown[i].second, shown[j].second)) {
                overlap = true;
                Print([NSString stringWithFormat:@"  overlap: %@ / %@", shown[i].first,
                                                 shown[j].first]);
              }
            }
          }
          check(!overlap,
                [NSString stringWithFormat:@"%@ no two visible controls overlap", where]);
          // Top row, left to right: speed, captions, sound ... back to tab,
          // minimize, close (in the corner). All are circles of one size.
          {
            NSMutableArray* row = [NSMutableArray array];
            NSMutableArray* sizes = [NSMutableArray array];
            for (NSString* name in @[ @"speed", @"captions", @"sound", @"return", @"minimize",
                                      @"close" ]) {
              NSDictionary* c = controlNamed(state, name);
              if (c && ![c[@"hidden"] boolValue]) {
                NSRect fr = frameOf(c[@"frame"]);
                [row addObject:@[ @(NSMinX(fr)), name ]];
                [sizes addObject:[NSString stringWithFormat:@"%.0fx%.0f", fr.size.width,
                                                            fr.size.height]];
              }
            }
            NSArray* byX = [row sortedArrayUsingComparator:^NSComparisonResult(NSArray* a,
                                                                               NSArray* b) {
              return [a[0] compare:b[0]];
            }];
            NSMutableArray* names = [NSMutableArray array];
            NSMutableArray* sortedNames = [NSMutableArray array];
            for (NSUInteger i = 0; i < row.count; i++) {
              [names addObject:row[i][1]];
              [sortedNames addObject:byX[i][1]];
            }
            // Close sits as far from the right edge as the first control
            // sits from the left one.
            CGFloat leftInset = [byX.firstObject[0] doubleValue];
            NSRect close = frameOf(controlNamed(state, @"close")[@"frame"]);
            check([names isEqualToArray:sortedNames] && [NSSet setWithArray:sizes].count == 1 &&
                      [sortedNames.lastObject isEqualToString:@"close"] &&
                      std::abs((s.width - NSMaxX(close)) - leftInset) < 1,
                  [NSString stringWithFormat:@"%@ top row %@ (%@), close in the corner", where,
                                             [sortedNames componentsJoinedByString:@" "],
                                             [sizes componentsJoinedByString:@" "]]);
          }
          NSDictionary* live = controlNamed(state, @"live");
          BOOL liveShown = live && ![live[@"hidden"] boolValue];
          if (kind == Timeline::OnDemand) {
            check(!liveShown && timelineShown,
                  [NSString stringWithFormat:@"%@ timeline without a Live badge", where]);
          } else if (kind == Timeline::Live) {
            check(liveShown && [live[@"statusOnly"] boolValue] && !timelineShown &&
                      [state[@"liveDotRed"] boolValue] &&
                      [controlNamed(state, @"back15")[@"hidden"] boolValue],
                  [NSString stringWithFormat:@"%@ red Live status badge only, no timeline "
                                             @"or skip buttons",
                                             where]);
          } else {
            check(liveShown && ![live[@"statusOnly"] boolValue] && timelineShown &&
                      NSMinX(frameOf(state[@"timeline"][@"frame"])) >=
                          NSMaxX(frameOf(live[@"frame"])) &&
                      ![state[@"timeline"][@"labelsShown"] boolValue],
                  [NSString stringWithFormat:@"%@ Live button left of a timeline without times",
                                             where]);
          }
          Print([NSString stringWithFormat:@"LAYOUT %@ WINDOW %ld visible=%@", where,
                                           (long)panel.windowNumber,
                                           [visible componentsJoinedByString:@","]]);
          // ZEN_PIP_HARNESS_CAPTURE=<prefix> saves <prefix>-[live-|live-dvr-]<W>x<H>.png.
          if (const char* prefix = getenv("ZEN_PIP_HARNESS_CAPTURE")) {
            NSString* kindName = kind == Timeline::OnDemand ? @""
                                 : kind == Timeline::Live   ? @"live-"
                                                            : @"live-dvr-";
            NSString* path = [NSString
                stringWithFormat:@"%s-%@%gx%g.png", prefix, kindName, s.width, s.height];
            NSTask* task = [NSTask
                launchedTaskWithLaunchPath:@"/usr/sbin/screencapture"
                                 arguments:@[ @"-x", @"-o",
                                              [NSString stringWithFormat:@"-l%ld",
                                                                         (long)panel.windowNumber],
                                              path ]];
            [task waitUntilExit];
          }
          Spin(argc > 3 ? 0 : 1.5);
        }
        // The badge acts only when the stream can be scrubbed: behind the live
        // edge its dot turns grey and a click returns to the edge.
        size_t before = host.log.size();
        if (kind == Timeline::Live) {
          check(![chrome testClickControl:@"live"] && host.log.size() == before,
                @"live: the status badge can't be clicked");
        } else if (kind == Timeline::LiveDVR) {
          [chrome setAtLiveEdge:NO];
          Spin(0.1);
          NSDictionary* behind = [chrome debugState];
          check(![behind[@"liveDotRed"] boolValue] &&
                    [behind[@"timeline"][@"accessibilityValue"] hasSuffix:@"behind live"],
                [NSString stringWithFormat:@"live DVR: behind the live edge the dot is grey "
                                           @"(VoiceOver: %@)",
                                           behind[@"timeline"][@"accessibilityValue"]]);
          check([chrome testClickControl:@"live"] && host.log.size() > before &&
                    host.log.back() == "go-live",
                @"live DVR: the Live button asks for the live edge");
          Spin(0.1);
          NSDictionary* edge = [chrome debugState];
          check([edge[@"liveDotRed"] boolValue] &&
                    [edge[@"timeline"][@"accessibilityValue"] isEqualToString:@"Live"],
                @"live DVR: back at the live edge the dot is red (VoiceOver: Live)");
        }
      }
      timeline = Timeline::OnDemand;
      Print([NSString stringWithFormat:@"SUMMARY %d failure(s)", failures]);
    } else if ([mode isEqualToString:@"keys"]) {
      // Tab and Shift-Tab through the controls with real key events, the way
      // a keyboard user moves: reading order, wrapping around, both ways.
      [chrome revealControlsSticky:YES];
      Spin(0.6);
      auto press = [&](NSEventModifierFlags aMods) {
        [chrome testKey:48 characters:@"\t" modifiers:aMods];
        Spin(0.05);
        return (NSString*)([chrome debugState][@"focusedControl"] ?: @"");
      };
      NSArray* cycle = @[ @"playPause", @"forward15", @"timeline", @"speed", @"captions",
                          @"sound", @"return", @"minimize", @"close", @"back15",
                          @"playPause" ];
      NSMutableArray* forward = [NSMutableArray array];
      for (NSUInteger i = 0; i < cycle.count; i++) {
        [forward addObject:press(0)];
      }
      check([forward isEqualToArray:cycle],
            [NSString stringWithFormat:@"Tab: %@", [forward componentsJoinedByString:@" -> "]]);
      NSMutableArray* backward = [NSMutableArray array];
      for (NSUInteger i = 1; i < cycle.count; i++) {
        [backward addObject:press(NSEventModifierFlagShift)];
      }
      NSArray* expected =
          [[[cycle subarrayWithRange:NSMakeRange(0, cycle.count - 1)] reverseObjectEnumerator]
              allObjects];
      check([backward isEqualToArray:expected],
            [NSString stringWithFormat:@"Shift-Tab: %@",
                                       [backward componentsJoinedByString:@" -> "]]);
      // Live streams: the Go to live button joins the cycle before the
      // timeline; a status-only badge (with no timeline) is skipped.
      for (Timeline kind : {Timeline::LiveDVR, Timeline::Live}) {
        timeline = kind;
        Spin(0.6);
        while (![press(0) isEqualToString:@"playPause"]) {
        }
        NSArray* after = @[ press(0), press(0), press(0) ];
        NSArray* want = kind == Timeline::LiveDVR
                            ? @[ @"forward15", @"live", @"timeline" ]
                            : @[ @"speed", @"captions", @"sound" ];
        check([after isEqualToArray:want],
              [NSString stringWithFormat:@"%@ after play/pause: %@",
                                         kind == Timeline::LiveDVR ? @"live DVR" : @"live",
                                         [after componentsJoinedByString:@" -> "]]);
      }
      timeline = Timeline::OnDemand;
      Print([NSString stringWithFormat:@"SUMMARY %d failure(s)", failures]);
    } else if ([mode isEqualToString:@"clicks"]) {
      [chrome revealControlsSticky:YES];
      Pump(0.8);
      WaitUntilSettled(chrome);
      // Real input queued through the normal dispatch (testClicks). A press on
      // the resize border resizes the player the same way however many clicks
      // came before it; a double-click there changes nothing (AppKit would
      // grow the window toward the screen corner); a double-click on the
      // video toggles playback.
      auto loggedSince = [&](size_t aFrom, const char* aAction) {
        for (size_t i = aFrom; i < host.log.size(); i++) {
          if (host.log[i] == aAction) {
            return true;
          }
        }
        return false;
      };
      auto queue = [&](NSString* aSpec) {
        BOOL queued = [chrome testClicks:aSpec];
        Pump(1.0);
        WaitUntilSettled(chrome);
        return queued;
      };
      auto same = [](NSRect a, NSRect b, CGFloat aTolerance) {
        return std::abs(NSMinX(a) - NSMinX(b)) <= aTolerance &&
               std::abs(NSMinY(a) - NSMinY(b)) <= aTolerance &&
               std::abs(NSMaxX(a) - NSMaxX(b)) <= aTolerance &&
               std::abs(NSMaxY(a) - NSMaxY(b)) <= aTolerance;
      };
      auto rectOf = [](NSArray* r) {
        return NSMakeRect([r[0] doubleValue], [r[1] doubleValue], [r[2] doubleValue],
                          [r[3] doubleValue]);
      };
      NSRect allowed = rectOf([chrome debugState][@"allowedArea"]);
      auto place = [&](NSRect aFrame) {
        [panel setFrame:aFrame display:YES];
        panel.contentAspectRatio = aFrame.size;
        Pump(0.3);
        WaitUntilSettled(chrome);
        return panel.frame;
      };
      struct Handle {
        NSString* place;
        NSPoint drag;  // outward
        int sx, sy;    // which sides it moves when the player is free
      };
      const std::vector<Handle> handles = {
          {@"top-left", {-30, 30}, -1, 1},     {@"top-right", {30, 30}, 1, 1},
          {@"bottom-left", {-30, -30}, -1, -1}, {@"bottom-right", {30, -30}, 1, -1},
          {@"left", {-30, 0}, -1, 0},           {@"right", {30, 0}, 1, 0},
          {@"top", {0, 30}, 0, 1},              {@"bottom", {0, -30}, 0, -1},
      };
      // A free player (well away from the edges) keeps the side opposite the
      // handle; one in a corner keeps that corner (the requirements).
      NSRect freeFrame = NSMakeRect(NSMaxX(allowed) - 480 - 110, NSMinY(allowed) + 110, 480, 270);
      NSRect dockedFrame = NSMakeRect(NSMaxX(allowed) - 480, NSMinY(allowed), 480, 270);
      for (bool docked : {false, true}) {
        NSString* where = docked ? @"docked bottom-right" : @"free";
        for (const Handle& h : handles) {
          // Corners 4 pt in are inside AppKit's own corner area; edges 4 pt in
          // are only inside the chrome's band. Also 1 pt in (AppKit's edge
          // area) and 2 pt outside the window for the edges, and 12 pt in
          // (the inner part of the corner square) for the bottom corners; at
          // the top that is on the speed and close buttons.
          bool corner = h.sx != 0 && h.sy != 0;
          NSArray* insets = !corner      ? @[ @"4", @"1", @"-2" ]
                            : h.sy < 0 ? @[ @"4", @"12" ]
                                       : @[ @"4" ];
          for (NSString* inset in insets) {
            NSRect start = place(docked ? dockedFrame : freeFrame);
            NSRect frames[3];
            bool queued = true;
            size_t from = host.log.size();
            for (int clicks = 1; clicks <= 3; clicks++) {
              place(start);
              queued &= queue([NSString stringWithFormat:@"%@ inset=%@ clicks=%d drag=%g,%g",
                                                         h.place, inset, clicks, h.drag.x,
                                                         h.drag.y]);
              frames[clicks - 1] = panel.frame;
            }
            NSRect f = frames[0];
            bool resized = f.size.width > start.size.width + 20;
            bool aspect = std::abs(f.size.width / f.size.height -
                                   start.size.width / start.size.height) < 0.01;
            bool anchored;
            // Window frames are whole points, so a centered side can be half
            // a point off.
            if (docked) {
              anchored = std::abs(NSMaxX(f) - NSMaxX(start)) <= 1 &&
                         std::abs(NSMinY(f) - NSMinY(start)) <= 1;
            } else {
              auto keeps = [&](int aSign, CGFloat aMin, CGFloat aMax, CGFloat aMid, CGFloat aMinS,
                               CGFloat aMaxS, CGFloat aMidS) {
                return aSign > 0   ? std::abs(aMin - aMinS) <= 1
                       : aSign < 0 ? std::abs(aMax - aMaxS) <= 1
                                   : std::abs(aMid - aMidS) <= 1;
              };
              anchored = keeps(h.sx, NSMinX(f), NSMaxX(f), NSMidX(f), NSMinX(start),
                               NSMaxX(start), NSMidX(start)) &&
                         keeps(h.sy, NSMinY(f), NSMaxY(f), NSMidY(f), NSMinY(start),
                               NSMaxY(start), NSMidY(start));
            }
            bool inside = NSContainsRect(NSInsetRect(allowed, -0.5, -0.5), f);
            bool sameForAll = same(frames[0], frames[1], 0.01) && same(frames[0], frames[2], 0.01);
            check(queued && resized && aspect && anchored && inside && sameForAll &&
                      !loggedSince(from, "toggle-play"),
                  [NSString stringWithFormat:@"%@: %@ (%@ pt in) press, double-click and "
                                             @"triple-click + drag resize alike %@ -> %@%@%@%@",
                                             where, h.place, inset, NSStringFromSize(start.size),
                                             NSStringFromRect(f), anchored ? @"" : @" NOT ANCHORED",
                                             inside ? @"" : @" OUTSIDE",
                                             sameForAll ? @""
                                                        : [NSString stringWithFormat:@" DIFFER %@ %@",
                                                                                     NSStringFromRect(frames[1]),
                                                                                     NSStringFromRect(frames[2])]]);
          }
        }
        // Double-clicks without a drag change nothing, also two quick presses
        // on a corner (AppKit times those itself).
        for (NSString* spec : @[ @"top-left clicks=2", @"top-right clicks=2", @"bottom-left clicks=2",
                                 @"bottom-right clicks=2", @"bottom-right inset=12 clicks=2",
                                 @"top-left inset=1 clicks=3", @"right inset=1 clicks=2",
                                 @"top inset=-2 clicks=2" ]) {
          NSRect start = place(docked ? dockedFrame : freeFrame);
          size_t from = host.log.size();
          BOOL queued = queue(spec);
          NSRect after = panel.frame;
          check(queued && NSEqualRects(start, after) && !loggedSince(from, "toggle-play"),
                [NSString stringWithFormat:@"%@: \"%@\" changes nothing (%@ -> %@)", where, spec,
                                           NSStringFromRect(start), NSStringFromRect(after)]);
        }
      }
      {
        // 12 pt in from the top right is on the close button, inside the
        // corner square: the press goes to the button.
        NSRect start = place(freeFrame);
        size_t from = host.log.size();
        BOOL queued = queue(@"top-right inset=12");
        check(queued && loggedSince(from, "close") && NSEqualRects(start, panel.frame),
              @"a press on the close button inside the corner square closes, no resize");
      }
      {
        // On the video itself: the center holds play/pause while the controls
        // show. Exactly one toggle (two would be clicks on that button).
        NSRect start = place(freeFrame);
        NSString* onVideo = [NSString stringWithFormat:@"%g,%g clicks=2", round(start.size.width * 0.2),
                                                       round(start.size.height * 0.5)];
        size_t from = host.log.size();
        queue(onVideo);
        size_t toggles = 0;
        for (size_t i = from; i < host.log.size(); i++) {
          toggles += host.log[i] == "toggle-play";
        }
        check(toggles == 1 && NSEqualRects(start, panel.frame),
              [NSString stringWithFormat:@"double-click on the video (%@) toggles playback once", onVideo]);
        queue(onVideo);
      }
      // A small player brings the controls into the resize border: a press on
      // a drawn control still reaches it, the empty corner of its square
      // resizes.
      {
        NSRect start = place(NSMakeRect(NSMinX(freeFrame), NSMinY(freeFrame), 240, 135));
        NSDictionary* close = nil;
        for (NSDictionary* c in [chrome debugState][@"controls"]) {
          if ([c[@"name"] isEqualToString:@"close"]) {
            close = c;
          }
        }
        NSRect box = rectOf(close[@"frame"]);
        CGFloat fromTop = start.size.height - (NSMaxY(box) - 1);
        size_t from = host.log.size();
        BOOL queued = queue([NSString stringWithFormat:@"%g,%g", NSMidX(box), NSMaxY(box) - 1]);
        check(queued && fromTop < 9 && loggedSince(from, "close") && NSEqualRects(start, panel.frame),
              [NSString stringWithFormat:@"a press on the close button %.0f pt from the top edge "
                                         @"closes, no resize",
                                         fromTop]);
        start = place(start);
        from = host.log.size();
        queued = queue([NSString stringWithFormat:@"%g,%g clicks=2 drag=20,20", NSMaxX(box) - 1,
                                                  NSMaxY(box) - 1]);
        check(queued && !loggedSince(from, "close") && panel.frame.size.width > start.size.width + 10,
              [NSString stringWithFormat:@"a double-click + drag on the empty corner of its square "
                                         @"resizes (%@ -> %@)",
                                         NSStringFromSize(start.size), NSStringFromSize(panel.frame.size)]);
        place(freeFrame);
      }

      // The speed button: a gauge whose needle shows the speed, and a menu
      // with the speeds (the current one checked).
      auto speed = [&]() { return (NSDictionary*)[chrome debugState][@"speed"]; };
      auto checkedRates = [&](NSDictionary* aSpeed) {
        NSMutableArray* rates = [NSMutableArray array];
        for (NSDictionary* item in aSpeed[@"menu"]) {
          if ([item[@"checked"] boolValue]) {
            [rates addObject:item[@"rate"]];
          }
        }
        return rates;
      };
      NSDictionary* s1 = speed();
      NSArray* rates = [s1[@"menu"] valueForKey:@"rate"];
      check([s1[@"symbol"] isEqualToString:@"gauge.with.dots.needle.50percent"] &&
                [rates isEqualToArray:@[ @0.5, @0.75, @1, @1.25, @1.5, @1.75, @2 ]] &&
                [checkedRates(s1) isEqualToArray:@[ @1 ]] &&
                [s1[@"menuTitle"] isEqualToString:@"Playback speed"],
            [NSString stringWithFormat:@"speed: gauge at normal speed (%@), menu \"%@\" %@",
                                       s1[@"symbol"], s1[@"menuTitle"],
                                       [[s1[@"menu"] valueForKey:@"title"]
                                           componentsJoinedByString:@" "]]);
      struct Pick {
        NSString* name;
        double rate;
        NSString* symbol;
      };
      for (const Pick& pick : std::vector<Pick>{
               {@"speed", 1.25, @"gauge.with.dots.needle.67percent"},
               {@"speed:0.5", 0.5, @"gauge.with.dots.needle.0percent"},
               {@"speed:0.75", 0.75, @"gauge.with.dots.needle.33percent"},
               {@"speed:2", 2, @"gauge.with.dots.needle.100percent"},
               {@"speed:1", 1, @"gauge.with.dots.needle.50percent"},
           }) {
        BOOL picked = [chrome testClickControl:pick.name];
        NSDictionary* s = speed();
        check(picked && std::abs(host.rate - pick.rate) < 0.001 &&
                  [s[@"symbol"] isEqualToString:pick.symbol] &&
                  [checkedRates(s) isEqualToArray:@[ @(pick.rate) ]],
              [NSString stringWithFormat:@"speed menu %@ -> %g× (%@, %@)", pick.name, host.rate,
                                         s[@"symbol"], s[@"accessibilityValue"]]);
      }
      [chrome setPlaybackRate:1.1];
      NSDictionary* custom = speed();
      check([custom[@"menu"] count] == 8 && [checkedRates(custom) isEqualToArray:@[ @1.1 ]] &&
                [custom[@"symbol"] isEqualToString:@"gauge.with.dots.needle.67percent"],
            [NSString stringWithFormat:@"a speed the site chose (1.1×) is listed and checked: %@",
                                       [[custom[@"menu"] valueForKey:@"title"]
                                           componentsJoinedByString:@" "]]);
      [chrome testClickControl:@"speed:1"];

      // ZEN_PIP_HARNESS_MENU=<png>: open the real menu from the button and save
      // it over a plain backdrop (nothing else on screen gets captured).
      if (const char* menuCapture = getenv("ZEN_PIP_HARNESS_MENU")) {
        NSRect f = NSIntersectionRect(NSInsetRect(panel.frame, -16, -16), NSInsetRect(panel.screen.frame, 2, 2));
        NSWindow* backdrop = [[NSWindow alloc] initWithContentRect:f
                                                         styleMask:NSWindowStyleMaskBorderless
                                                           backing:NSBackingStoreBuffered
                                                             defer:NO];
        backdrop.releasedWhenClosed = NO;
        backdrop.backgroundColor = [NSColor colorWithWhite:0.16 alpha:1];
        backdrop.level = panel.level - 1;
        [backdrop orderFrontRegardless];
        std::function<NSButton*(NSView*)> find = [&](NSView* aView) -> NSButton* {
          for (NSView* v in aView.subviews) {
            if ([v isKindOfClass:[NSButton class]] &&
                [v.accessibilityLabel isEqualToString:@"Playback speed"]) {
              return (NSButton*)v;
            }
            if (NSButton* b = find(v)) {
              return b;
            }
          }
          return nil;
        };
        NSButton* button = find(panel.contentView);
        __block NSMenu* opened = nil;
        id observer = [NSNotificationCenter.defaultCenter
            addObserverForName:NSMenuDidBeginTrackingNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification* aNote) {
                      opened = aNote.object;
                    }];
        CGFloat mainHeight = NSScreen.screens[0].frame.size.height;
        NSString* region = [NSString stringWithFormat:@"%.0f,%.0f,%.0f,%.0f", NSMinX(f),
                                                      mainHeight - NSMaxY(f), f.size.width,
                                                      f.size.height];
        NSString* path = @(menuCapture);
        NSTimer* timer = [NSTimer
            timerWithTimeInterval:0.9
                          repeats:NO
                            block:^(NSTimer*) {
                              NSTask* task = [NSTask
                                  launchedTaskWithLaunchPath:@"/usr/sbin/screencapture"
                                                   arguments:@[ @"-x", @"-R", region, path ]];
                              [task waitUntilExit];
                              Print([NSString stringWithFormat:@"MENU capture %@ -> status %d",
                                                               region, task.terminationStatus]);
                              [opened cancelTracking];
                            }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        [button performClick:nil];  // returns once the menu closes
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        check(button && opened && [NSFileManager.defaultManager fileExistsAtPath:path],
              [NSString stringWithFormat:@"the speed button opens its menu (%@)", path]);
        [backdrop close];
      }
      Print([NSString stringWithFormat:@"SUMMARY %d failure(s)", failures]);
    } else if ([mode isEqualToString:@"motion"]) {
      struct Throw {
        const char* name;
        NSPoint delta;
        NSPoint velocity;
      };
      std::vector<Throw> throws = {
          {"slow placement mid-screen", {-420, 260}, {0, 0}},
          {"throw down-right", {80, -40}, {2600, -1900}},
          {"throw up-left", {-80, 40}, {-2600, 1900}},
          {"throw up-right", {40, 40}, {2400, 2200}},
          {"throw down-left", {-40, -40}, {-2400, -2200}},
          {"violent throw off the right edge", {300, 0}, {9000, 0}},
          {"violent throw toward the menu bar", {0, 200}, {0, 9000}},
          {"drag far past the bottom-left", {-6000, -6000}, {0, 0}},
          {"gentle nudge along the bottom", {30, 0}, {700, 0}},
      };
      for (NSUInteger si = 0; si < screens.count; si++) {
        NSScreen* target = screens[si];
        NSRect tvf = target.visibleFrame;
        [source setFrame:NSMakeRect(NSMidX(tvf) - 300, NSMidY(tvf) - 200, 600, 400)
                 display:NO];
        Spin(0.2);
        [chrome setSourceWindow:nil];
        [chrome setSourceWindow:source];
        Spin(0.6);
        WaitUntilSettled(chrome);
        NSDictionary* s0 = [chrome debugState];
        check([s0[@"insideVisibleFrame"] boolValue] &&
                  [s0[@"playerScreen"] isEqualToString:target.localizedName],
              [NSString stringWithFormat:@"follows source window onto %@ (%@)",
                                         target.localizedName, s0[@"windowFrame"]]);
        for (const Throw& t : throws) {
          [chrome testDragBy:t.delta duration:0.25 release:t.velocity];
          // Sample mid-flight too: containment must hold at every frame.
          bool alwaysInside = true;
          for (int i = 0; i < 150; i++) {
            Spin(1.0 / 120);
            NSDictionary* mid = [chrome debugState];
            alwaysInside = alwaysInside && [mid[@"insideVisibleFrame"] boolValue];
            if (![mid[@"animating"] boolValue]) {
              break;
            }
          }
          WaitUntilSettled(chrome);
          NSDictionary* s = [chrome debugState];
          bool ok = alwaysInside && [s[@"insideAllowedArea"] boolValue] &&
                    [s[@"playerScreen"] isEqualToString:target.localizedName];
          check(ok, [NSString stringWithFormat:@"[%@] %s -> dock=%@ frame=%@", target.localizedName,
                                               t.name, s[@"dock"], s[@"windowFrame"]]);
        }
        // Anchored resize from a corner keeps the docked corner.
        [chrome testDragBy:NSMakePoint(60, -60) duration:0.2 release:NSMakePoint(2600, -2400)];
        WaitUntilSettled(chrome);
        NSArray* before = [chrome debugState][@"windowFrame"];
        [chrome testResizeHandle:@"top-left" by:NSMakePoint(-160, 90)];
        Spin(0.3);
        NSDictionary* after = [chrome debugState];
        NSArray* fa = after[@"windowFrame"];
        double rightBefore = [before[0] doubleValue] + [before[2] doubleValue];
        double rightAfter = [fa[0] doubleValue] + [fa[2] doubleValue];
        check(std::abs(rightBefore - rightAfter) < 0.6 &&
                  std::abs([before[1] doubleValue] - [fa[1] doubleValue]) < 0.6 &&
                  [fa[2] doubleValue] > [before[2] doubleValue] &&
                  std::abs([fa[2] doubleValue] / [fa[3] doubleValue] - 16.0 / 9.0) < 0.01,
              [NSString stringWithFormat:@"[%@] corner-anchored resize %@ -> %@",
                                         target.localizedName, before, fa]);
        [chrome testResizeHandle:@"top-left" by:NSMakePoint(160, -90)];
        Spin(0.3);
      }

      // Dragging onto another display: holds at the shared edge, hops across
      // once the pointer is on the other display, then stays there (even when
      // the source window moves) until dragged back.
      if (screens.count >= 2) {
        NSScreen* a = screens[0];
        NSScreen* b = screens[1];
        NSRect fa = a.frame, fb = b.frame;
        NSPoint dir = NSMinX(fb) >= NSMaxX(fa) - 1   ? NSMakePoint(1, 0)
                      : NSMaxX(fb) <= NSMinX(fa) + 1 ? NSMakePoint(-1, 0)
                      : NSMinY(fb) >= NSMaxY(fa) - 1 ? NSMakePoint(0, 1)
                                                      : NSMakePoint(0, -1);
        NSRect avf = a.visibleFrame, bvf = b.visibleFrame;
        auto moveSource = [&](NSRect aVisible) {
          [source setFrame:NSMakeRect(NSMidX(aVisible) - 300, NSMidY(aVisible) - 200, 600, 400)
                   display:NO];
          Spin(0.2);
          [chrome setSourceWindow:nil];
          [chrome setSourceWindow:source];
          Spin(0.8);
          WaitUntilSettled(chrome);
        };
        moveSource(avf);
        // Throw it against the edge facing display B (stays on A).
        [chrome testDragBy:NSMakePoint(dir.x * 60, dir.y * 60)
                  duration:0.2
                   release:NSMakePoint(dir.x * 2600 + (dir.x ? 0 : 400), dir.y * 2600 + (dir.y ? 0 : -400))];
        WaitUntilSettled(chrome);
        NSDictionary* docked = [chrome debugState];
        NSArray* df = docked[@"windowFrame"];
        double w = [df[2] doubleValue], h = [df[3] doubleValue];
        double half = dir.x ? w / 2 : h / 2;
        check([docked[@"playerScreen"] isEqualToString:a.localizedName],
              [NSString stringWithFormat:@"docked against the edge shared with %@ (%@)",
                                         b.localizedName, df]);
        // Pushing at the edge with the pointer still on A: no hop.
        [chrome testDragBy:NSMakePoint(dir.x * (half - 24), dir.y * (half - 24))
                  duration:0.3
                   release:NSZeroPoint];
        WaitUntilSettled(chrome);
        NSDictionary* held = [chrome debugState];
        check([held[@"playerScreen"] isEqualToString:a.localizedName] &&
                  ![held[@"homePinned"] boolValue] && [held[@"insideAllowedArea"] boolValue],
              [NSString stringWithFormat:@"pushing at the edge holds on %@ (%@)", a.localizedName,
                                         held[@"windowFrame"]]);
        // A quick push or throw into the corner shared with B, the pointer
        // well onto B: the player lands in that corner of A.
        double across = half + 10 + 160;
        [chrome testDragBy:NSMakePoint(dir.x * across, dir.y * across)
                  duration:0.12
                   release:NSMakePoint(dir.x * 2400 + (dir.x ? 0 : 300),
                                       dir.y * 2400 + (dir.y ? 0 : -300))];
        WaitUntilSettled(chrome);
        NSDictionary* corner = [chrome debugState];
        NSString* side = dir.x > 0 ? @"right" : dir.x < 0 ? @"left" : dir.y > 0 ? @"top" : @"bottom";
        check([corner[@"playerScreen"] isEqualToString:a.localizedName] &&
                  ![corner[@"homePinned"] boolValue] && [corner[@"insideAllowedArea"] boolValue] &&
                  [corner[@"dock"] rangeOfString:side].location != NSNotFound,
              [NSString stringWithFormat:@"a quick push into the corner shared with %@ lands in %@'s %@ corner (%@)",
                                         b.localizedName, a.localizedName, corner[@"dock"],
                                         corner[@"windowFrame"]]);
        // Holding it there with the pointer resting on B: hops after the hold.
        [chrome testDragBy:NSMakePoint(dir.x * across, dir.y * across)
                     duration:0.1
            restBeforeRelease:0.45];
        WaitUntilSettled(chrome);
        NSDictionary* rested = [chrome debugState];
        check([rested[@"playerScreen"] isEqualToString:b.localizedName] &&
                  [rested[@"homePinned"] boolValue] && [rested[@"insideAllowedArea"] boolValue],
              [NSString stringWithFormat:@"holding it at the edge with the pointer on %@ moves it there (%@)",
                                         b.localizedName, rested[@"windowFrame"]]);
        // Back to A the same way, then carry it across in one continuous drag.
        {
          NSArray* rf = rested[@"windowFrame"];
          double toEdgeNow = dir.x > 0 ? ([rf[0] doubleValue] + w / 2) - NSMinX(fb)
                             : dir.x < 0 ? NSMaxX(fb) - ([rf[0] doubleValue] + w / 2)
                             : dir.y > 0 ? ([rf[1] doubleValue] + h / 2) - NSMinY(fb)
                                         : NSMaxY(fb) - ([rf[1] doubleValue] + h / 2);
          double backNow = toEdgeNow + 10 + 160;
          [chrome testDragBy:NSMakePoint(-dir.x * backNow, -dir.y * backNow)
                       duration:0.1
              restBeforeRelease:0.45];
          WaitUntilSettled(chrome);
          [chrome testDragBy:NSMakePoint(dir.x * 60, dir.y * 60)
                    duration:0.2
                     release:NSMakePoint(dir.x * 2600 + (dir.x ? 0 : 400),
                                         dir.y * 2600 + (dir.y ? 0 : -400))];
          WaitUntilSettled(chrome);
        }
        // A continuous drag well onto B: holds at the edge, then follows.
        double carryAcross = half + 10 + 320;
        [chrome testDragBy:NSMakePoint(dir.x * carryAcross, dir.y * carryAcross)
                  duration:1.0
                   release:NSZeroPoint];
        bool alwaysOnOne = true;
        for (int i = 0; i < 150; i++) {
          Spin(1.0 / 120);
          NSDictionary* mid = [chrome debugState];
          alwaysOnOne = alwaysOnOne && [mid[@"insideVisibleFrame"] boolValue];
          if (![mid[@"animating"] boolValue]) break;
        }
        WaitUntilSettled(chrome);
        Spin(0.3);
        NSDictionary* moved = [chrome debugState];
        check(alwaysOnOne && [moved[@"playerScreen"] isEqualToString:b.localizedName] &&
                  [moved[@"homePinned"] boolValue] && [moved[@"insideAllowedArea"] boolValue],
              [NSString stringWithFormat:@"dragging onto %@ moves the player there (%@, pinned=%@)",
                                         b.localizedName, moved[@"windowFrame"],
                                         moved[@"homePinned"]]);
        // The source window moving between displays no longer moves it.
        moveSource(bvf);
        moveSource(avf);
        NSDictionary* stays = [chrome debugState];
        check([stays[@"playerScreen"] isEqualToString:b.localizedName] &&
                  [stays[@"insideAllowedArea"] boolValue],
              [NSString stringWithFormat:@"stays on %@ while the source window moves (%@)",
                                         b.localizedName, stays[@"windowFrame"]]);
        // Two-finger carry moves it by the finger travel (no jump).
        NSArray* c0 = stays[@"windowFrame"];
        [chrome testCarryBy:NSMakePoint(dir.x ? 0 : 90, dir.x ? 90 : 0)];
        WaitUntilSettled(chrome);
        NSArray* c1 = [chrome debugState][@"windowFrame"];
        double cdx = [c1[0] doubleValue] - [c0[0] doubleValue];
        double cdy = [c1[1] doubleValue] - [c0[1] doubleValue];
        check(std::abs(std::hypot(cdx, cdy) - 90) < 30 && [[chrome debugState][@"insideAllowedArea"] boolValue],
              [NSString stringWithFormat:@"two-finger carry moves by the finger travel (%.0f, %.0f)",
                                         cdx, cdy]);
        // Drag back onto A: it hops back and follows the source window again.
        NSDictionary* beforeBack = [chrome debugState];
        NSArray* bf = beforeBack[@"windowFrame"];
        // Distance from the player's center to the shared edge, plus margin.
        double toEdge = dir.x > 0 ? ([bf[0] doubleValue] + w / 2) - NSMinX(fb)
                        : dir.x < 0 ? NSMaxX(fb) - ([bf[0] doubleValue] + w / 2)
                        : dir.y > 0 ? ([bf[1] doubleValue] + h / 2) - NSMinY(fb)
                                    : NSMaxY(fb) - ([bf[1] doubleValue] + h / 2);
        double back = toEdge + 10 + 320;
        [chrome testDragBy:NSMakePoint(-dir.x * back, -dir.y * back) duration:1.0 release:NSZeroPoint];
        WaitUntilSettled(chrome);
        Spin(0.3);
        NSDictionary* home = [chrome debugState];
        check([home[@"playerScreen"] isEqualToString:a.localizedName] &&
                  ![home[@"homePinned"] boolValue] && [home[@"insideAllowedArea"] boolValue],
              [NSString stringWithFormat:@"dragging back onto %@ returns it (%@)", a.localizedName,
                                         home[@"windowFrame"]]);
        moveSource(bvf);
        NSDictionary* follows = [chrome debugState];
        check([follows[@"playerScreen"] isEqualToString:b.localizedName],
              [NSString stringWithFormat:@"after returning it follows the source window again (%@)",
                                         follows[@"playerScreen"]]);
        moveSource(avf);
      }
      // Minimize tucks into a fully visible pill and restores the player.
      [chrome minimize];
      Spin(0.5);
      NSDictionary* tucked = [chrome debugState];
      check([tucked[@"tucked"] boolValue] && ![tucked[@"windowVisible"] boolValue] &&
                [tucked[@"tuckPanelVisible"] boolValue],
            [NSString stringWithFormat:@"minimize tucks to %@", tucked[@"tuckPanelFrame"]]);
      check([chrome testClickControl:@"restore"], @"restore pill is clickable");
      Spin(0.5);
      NSDictionary* restored = [chrome debugState];
      check(![restored[@"tucked"] boolValue] && [restored[@"windowVisible"] boolValue] &&
                [restored[@"insideAllowedArea"] boolValue],
            @"restore brings the player back inside the area");
      // Real NSButton target/action round trips.
      for (NSString* name in @[ @"playPause", @"back15", @"forward15", @"sound", @"captions" ]) {
        size_t before = host.log.size();
        check([chrome testClickControl:name] && host.log.size() > before,
              [NSString stringWithFormat:@"button %@ -> %s", name,
                                         host.log.empty() ? "" : host.log.back().c_str()]);
      }
      Print([NSString stringWithFormat:@"SUMMARY %d failure(s)", failures]);
    }

    [chrome invalidate];
    [panel close];
    [source close];
    return failures ? 1 : 0;
  }
}
