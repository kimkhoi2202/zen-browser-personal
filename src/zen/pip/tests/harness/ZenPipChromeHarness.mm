/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Standalone harness for ZenPipNativeChrome (no Gecko). It hosts the exact
// chrome the browser uses over an AVPlayer video inside a non-activating
// floating panel, so rendering, layout and window motion can be checked
// against the real WindowServer and real displays. Build with build.sh.
//
//   ZenPipChromeHarness <video> visual [screenIndex] [width height]
//   ZenPipChromeHarness <video> layout
//   ZenPipChromeHarness <video> motion
//
// "motion" exits non-zero if any check fails. Video playback is muted.

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
    }
  }
};

static NSPanel* MakePlayerPanel(NSRect aFrame) {
  NSPanel* panel = [[NSPanel alloc]
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

    // Keep the timeline in step with the AVPlayer like timeupdate would.
    [NSTimer scheduledTimerWithTimeInterval:0.25
                                    repeats:YES
                                      block:^(NSTimer*) {
                                        [chrome setCurrentTime:CMTimeGetSeconds(player.currentTime)
                                                      duration:180
                                                      seekable:YES
                                                          live:NO];
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
      Spin(argc > 6 ? atof(argv[6]) : 4);
    } else if ([mode isEqualToString:@"layout"]) {
      [chrome revealControlsSticky:YES];
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
        NSMutableArray* visible = [NSMutableArray array];
        for (NSDictionary* c in state[@"controls"]) {
          if (![c[@"hidden"] boolValue]) {
            [visible addObject:c[@"name"]];
            NSArray* fr = c[@"frame"];
            CGFloat d = MIN([fr[2] doubleValue], [fr[3] doubleValue]);
            check(d >= 24, [NSString stringWithFormat:@"%gx%g %@ hit target %.0fpt >= 24",
                                                     s.width, s.height, c[@"name"], d]);
          }
        }
        Print([NSString stringWithFormat:@"LAYOUT %gx%g WINDOW %ld visible=%@", s.width,
                                         s.height, (long)panel.windowNumber,
                                         [visible componentsJoinedByString:@","]]);
        Spin(argc > 3 ? 0 : 1.5);
      }
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
