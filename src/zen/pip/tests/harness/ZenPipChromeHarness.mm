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
        std::vector<std::pair<NSString*, NSRect>> shown;
        for (NSDictionary* c in state[@"controls"]) {
          if (![c[@"hidden"] boolValue]) {
            [visible addObject:c[@"name"]];
            NSArray* fr = c[@"frame"];
            CGFloat d = MIN([fr[2] doubleValue], [fr[3] doubleValue]);
            check(d >= 24, [NSString stringWithFormat:@"%gx%g %@ hit target %.0fpt >= 24",
                                                     s.width, s.height, c[@"name"], d]);
            shown.push_back({c[@"name"], NSMakeRect([fr[0] doubleValue], [fr[1] doubleValue],
                                                    [fr[2] doubleValue], [fr[3] doubleValue])});
          }
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
        check(!overlap, [NSString stringWithFormat:@"%gx%g no two visible controls overlap",
                                                  s.width, s.height]);
        Print([NSString stringWithFormat:@"LAYOUT %gx%g WINDOW %ld visible=%@", s.width,
                                         s.height, (long)panel.windowNumber,
                                         [visible componentsJoinedByString:@","]]);
        // ZEN_PIP_HARNESS_CAPTURE=<prefix> saves <prefix>-<W>x<H>.png per size.
        if (const char* prefix = getenv("ZEN_PIP_HARNESS_CAPTURE")) {
          NSString* path = [NSString stringWithFormat:@"%s-%gx%g.png", prefix, s.width, s.height];
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
        // Dragging on until the pointer is well onto B: hops and settles there.
        double across = half + 14 + 120;
        [chrome testDragBy:NSMakePoint(dir.x * across, dir.y * across)
                  duration:0.4
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
        double back = toEdge + 120;
        [chrome testDragBy:NSMakePoint(-dir.x * back, -dir.y * back) duration:0.4 release:NSZeroPoint];
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
