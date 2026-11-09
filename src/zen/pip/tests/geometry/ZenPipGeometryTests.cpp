/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Standalone unit tests for ZenPipGeometry.h (no Gecko needed):
//   clang++ -std=c++20 -O1 -Wall -Wextra -I../.. ZenPipGeometryTests.cpp \
//     -o /tmp/zen-pip-geometry-tests && /tmp/zen-pip-geometry-tests
// Display layouts are AppKit global coordinates (y up, primary at 0,0).

#include "ZenPipGeometry.h"

#include <cstdio>
#include <functional>
#include <string>

using namespace zen::pip;

static int sFailures = 0;
static int sChecks = 0;

#define CHECK(cond)                                                 \
  do {                                                              \
    sChecks++;                                                      \
    if (!(cond)) {                                                  \
      sFailures++;                                                  \
      std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    }                                                               \
  } while (0)

#define CHECK_NEAR(a, b, eps) CHECK(std::abs((a) - (b)) <= (eps))

struct Display {
  const char* name;
  Box frame;
  Box visible;
};

// Fits a size into an area, keeping its aspect ratio.
static Vec2 FitSize(Vec2 aSize, const Box& aArea) {
  double scale = std::min({1.0, aArea.width / aSize.x, aArea.height / aSize.y});
  return {aSize.x * scale, aSize.y * scale};
}

static Vec2 CornerOrigin(const Dock& aCorner, Vec2 aSize, const Box& aArea) {
  return OriginForDock(aCorner, {aArea.x, aArea.y}, aSize, aArea);
}

// Two displays as an NSScreen dump reports them.
static const Display kExternal{
    "external-primary", {0, 0, 2048, 1152}, {0, 0, 2048, 1122}};
static const Display kBuiltin{
    "builtin-right", {2048, 35, 1728, 1117}, {2048, 35, 1728, 1085}};
// Synthetic arrangements that cannot be created physically here.
static const Display kLeftOfPrimary{
    "left-negative-x", {-1920, -120, 1920, 1080}, {-1920, -120, 1920, 1080}};
static const Display kAbovePrimary{
    "above-positive-y", {-256, 1152, 2560, 1440}, {-256, 1152, 2560, 1415}};
static const Display kBelowPrimary{"below-negative-y",
                                   {300, -900, 1440, 900},
                                   {300, -830, 1440, 830}};  // Dock at bottom
static const Display kTiny{"tiny", {0, 0, 640, 400}, {0, 0, 640, 375}};

static const Display* kAllDisplays[] = {&kExternal,      &kBuiltin,
                                        &kLeftOfPrimary, &kAbovePrimary,
                                        &kBelowPrimary,  &kTiny};

static void Test(const char* aName, const std::function<void()>& aBody) {
  int before = sFailures;
  aBody();
  std::printf("%s %s\n", sFailures == before ? "ok  " : "FAIL", aName);
}

int main() {
  const double kGap = 14;

  Test("allowed area insets the visible frame by the gap", [&] {
    Box area = AllowedArea(kExternal.visible, kGap);
    CHECK_NEAR(area.x, 14, 1e-9);
    CHECK_NEAR(area.MaxY(), 1122 - 14, 1e-9);
    Box tiny = AllowedArea({0, 0, 40, 30}, kGap);
    CHECK(tiny.width >= 0 && tiny.height >= 0);
  });

  Test("clamp keeps frames fully inside every display, incl. negative origins",
       [&] {
         for (const Display* d : kAllDisplays) {
           Box area = AllowedArea(d->visible, kGap);
           Vec2 size = FitSize({480, 270}, area);
           for (Vec2 probe : {Vec2{-50000, -50000}, Vec2{50000, 50000},
                              Vec2{area.x - 1, area.MaxY()},
                              Vec2{area.Center().x, area.Center().y}}) {
             Vec2 o = ClampOrigin(probe, size, area);
             CHECK(area.Contains(Box::FromOriginSize(o, size)));
             CHECK(d->visible.Contains(Box::FromOriginSize(o, size)));
           }
         }
       });

  Test("screen choice follows the largest overlap, then the nearest display",
       [&] {
         std::vector<Box> screens{kExternal.frame, kBuiltin.frame,
                                  kLeftOfPrimary.frame, kAbovePrimary.frame};
         // A browser window mostly on the built-in display.
         CHECK(ScreenIndexForRect({1900, 200, 900, 700}, screens) == 1);
         // Straddling the primary and the left display, mostly left.
         CHECK(ScreenIndexForRect({-900, 100, 1000, 600}, screens) == 2);
         CHECK(ScreenIndexForRect({100, 1300, 800, 600}, screens) == 3);
         // Entirely off every display: nearest wins.
         CHECK(ScreenIndexForRect({4200, 300, 100, 100}, screens) == 1);
       });

  Test("slow release in open space stays where it was placed", [&] {
    Box area = AllowedArea(kExternal.visible, kGap);
    Box frame{800, 500, 480, 270};
    ReleaseResult r = ResolveRelease(frame, {40, -30}, area, ReleaseParams{});
    CHECK(!r.isThrow);
    CHECK_NEAR(r.target.x, 800, 1e-9);
    CHECK_NEAR(r.target.y, 500, 1e-9);
    CHECK(r.dock.h == HEdge::None && r.dock.v == VEdge::None);
  });

  Test("slow release near an edge is pulled onto it (magnet)", [&] {
    Box area = AllowedArea(kExternal.visible, kGap);
    Box frame{area.MaxX() - 480 - 20, 300, 480, 270};
    ReleaseResult r = ResolveRelease(frame, {}, area, ReleaseParams{});
    CHECK(r.dock.h == HEdge::Right);
    CHECK_NEAR(r.target.x + 480, area.MaxX(), 1e-9);
  });

  Test("slow release partly off the display is pulled fully back on", [&] {
    for (const Display* d : kAllDisplays) {
      Box area = AllowedArea(d->visible, kGap);
      Vec2 size = FitSize({480, 270}, area);
      Box frame = Box::FromOriginSize(
          {d->frame.MaxX() - 100, d->frame.MinY() - 80}, size);
      ReleaseResult r = ResolveRelease(frame, {}, area, ReleaseParams{});
      CHECK(area.Contains(Box::FromOriginSize(r.target, size)));
    }
  });

  Test("a throw lands in the corner it was heading for", [&] {
    Box area = AllowedArea(kExternal.visible, kGap);
    Box center{784, 426, 480, 270};
    struct {
      Vec2 velocity;
      HEdge h;
      VEdge v;
    } cases[] = {
        {{2200, -1600}, HEdge::Right, VEdge::Bottom},
        {{-2200, -1600}, HEdge::Left, VEdge::Bottom},
        {{-2200, 1600}, HEdge::Left, VEdge::Top},
        {{2200, 1600}, HEdge::Right, VEdge::Top},
    };
    for (auto& c : cases) {
      ReleaseResult r =
          ResolveRelease(center, c.velocity, area, ReleaseParams{});
      CHECK(r.isThrow);
      CHECK(r.dock.h == c.h && r.dock.v == c.v);
      CHECK(area.Contains(Box::FromOriginSize(r.target, center.Size())));
    }
  });

  Test("a gentle throw from a corner along the edge reaches the next corner",
       [&] {
         Box area = AllowedArea(kExternal.visible, kGap);
         Vec2 size{480, 270};
         Vec2 start = CornerOrigin({HEdge::Left, VEdge::Bottom}, size, area);
         ReleaseResult r = ResolveRelease(Box::FromOriginSize(start, size),
                                          {3000, 0}, area, ReleaseParams{});
         CHECK(r.dock.h == HEdge::Right && r.dock.v == VEdge::Bottom);
         // A weak nudge is not enough to cross the display.
         ReleaseResult weak = ResolveRelease(Box::FromOriginSize(start, size),
                                             {500, 0}, area, ReleaseParams{});
         CHECK(weak.dock.h == HEdge::Left);
       });

  Test("throws resolve inside the source display for every arrangement", [&] {
    for (const Display* d : kAllDisplays) {
      Box area = AllowedArea(d->visible, kGap);
      Vec2 size = FitSize({480, 270}, area);
      Box frame =
          Box::FromOriginSize(ClampOrigin(area.Center(), size, area), size);
      for (Vec2 v : {Vec2{9000, 9000}, Vec2{-9000, 9000}, Vec2{9000, -9000},
                     Vec2{-9000, -9000}}) {
        ReleaseResult r = ResolveRelease(frame, v, area, ReleaseParams{});
        Box landed = Box::FromOriginSize(r.target, size);
        CHECK(area.Contains(landed));
        CHECK(d->visible.Contains(landed));
      }
    }
  });

  Test("dragging past an edge resists but never leaves the visible frame", [&] {
    for (const Display* d : kAllDisplays) {
      Box area = AllowedArea(d->visible, kGap);
      Vec2 size = FitSize({480, 270}, area);
      for (Vec2 desired : {Vec2{-1e6, -1e6}, Vec2{1e6, 1e6}, Vec2{-1e6, 1e6}}) {
        Vec2 o = RubberBandOrigin(desired, size, area, d->visible);
        CHECK(d->visible.Contains(Box::FromOriginSize(o, size)));
      }
      Vec2 inside = ClampOrigin(area.Center(), size, area);
      Vec2 same = RubberBandOrigin(inside, size, area, d->visible);
      CHECK_NEAR(same.x, inside.x, 1e-9);
      CHECK_NEAR(same.y, inside.y, 1e-9);
    }
    Box area = AllowedArea(kExternal.visible, kGap);
    double small = RubberBandOrigin({area.x - 10, 400}, {480, 270}, area,
                                    kExternal.visible)
                       .x;
    double big = RubberBandOrigin({area.x - 400, 400}, {480, 270}, area,
                                  kExternal.visible)
                     .x;
    CHECK(small < area.x && big < small && big >= kExternal.visible.x);
  });

  Test(
      "resizing a cornered player keeps that corner and the aspect ratio", [&] {
        Box area = AllowedArea(kBuiltin.visible, kGap);
        double aspect = 16.0 / 9.0;
        Vec2 size{400, 225};
        Dock corner{HEdge::Right, VEdge::Bottom};
        Box start = Box::FromOriginSize(CornerOrigin(corner, size, area), size);
        for (ResizeHandle handle :
             {ResizeHandle::TopLeft, ResizeHandle::Left, ResizeHandle::Top,
              ResizeHandle::BottomRight, ResizeHandle::TopRight}) {
          for (Vec2 delta :
               {Vec2{-160, 90}, Vec2{120, -60}, Vec2{-4000, 4000}}) {
            Box r = ResizeFrame(start, handle, delta, aspect, corner, area,
                                SizeLimits{});
            CHECK_NEAR(r.MaxX(), area.MaxX(), 1e-6);
            CHECK_NEAR(r.MinY(), area.MinY(), 1e-6);
            CHECK_NEAR(r.width / r.height, aspect, 1e-9);
            CHECK(area.Contains(r));
          }
        }
        Box grown = ResizeFrame(start, ResizeHandle::TopLeft, {-160, 90},
                                aspect, corner, area, SizeLimits{});
        CHECK(grown.width > start.width);
      });

  Test("resizing a free player keeps the side opposite the handle", [&] {
    Box area = AllowedArea(kExternal.visible, kGap);
    Box start{700, 400, 400, 225};
    Box r = ResizeFrame(start, ResizeHandle::BottomRight, {80, -45}, 16.0 / 9.0,
                        Dock{}, area, SizeLimits{});
    CHECK_NEAR(r.MinX(), start.MinX(), 1e-9);
    CHECK_NEAR(r.MaxY(), start.MaxY(), 1e-9);
    CHECK_NEAR(r.width, 480, 1e-9);
    Box top = ResizeFrame(start, ResizeHandle::Top, {0, 45}, 16.0 / 9.0, Dock{},
                          area, SizeLimits{});
    CHECK_NEAR(top.MinY(), start.MinY(), 1e-9);
    CHECK_NEAR(top.Center().x, start.Center().x, 1e-9);
  });

  Test("size limits hold on large and tiny displays", [&] {
    for (const Display* d : kAllDisplays) {
      Box area = AllowedArea(d->visible, kGap);
      for (double w : {1.0, 120.0, 1e5}) {
        for (double aspect : {16.0 / 9.0, 4.0 / 3.0, 9.0 / 16.0, 2.39}) {
          Vec2 s = ClampSize(w, aspect, area, SizeLimits{});
          CHECK(s.x <= area.width + 1e-9 && s.y <= area.height + 1e-9);
          CHECK_NEAR(s.x / s.y, aspect, 1e-9);
        }
      }
    }
  });

  Test("pinch scaling anchors on the docked corner", [&] {
    Box area = AllowedArea(kExternal.visible, kGap);
    Dock corner{HEdge::Left, VEdge::Top};
    Vec2 size{400, 225};
    Box start = Box::FromOriginSize(CornerOrigin(corner, size, area), size);
    Box r = ScaleFrame(start, 1.4, 16.0 / 9.0, corner, area, SizeLimits{});
    CHECK_NEAR(r.MinX(), area.MinX(), 1e-9);
    CHECK_NEAR(r.MaxY(), area.MaxY(), 1e-9);
    CHECK_NEAR(r.width, 560, 1e-9);
  });

  Test("placement carries a corner across displays", [&] {
    Box from = AllowedArea(kExternal.visible, kGap);
    Box to = AllowedArea(kLeftOfPrimary.visible, kGap);
    Vec2 size{480, 270};
    Box frame = Box::FromOriginSize(
        CornerOrigin({HEdge::Right, VEdge::Bottom}, size, from), size);
    Placement p = PlacementForFrame(frame, from, 1.0);
    CHECK(p.dock.h == HEdge::Right && p.dock.v == VEdge::Bottom);
    Vec2 o = OriginForPlacement(p, size, to);
    CHECK_NEAR(o.x + size.x, to.MaxX(), 1e-9);
    CHECK_NEAR(o.y, to.MinY(), 1e-9);
    // A free placement keeps its relative position.
    Box mid{from.x + (from.width - 480) * 0.25,
            from.y + (from.height - 270) * 0.5, 480, 270};
    Placement free = PlacementForFrame(mid, from, 1.0);
    Vec2 m = OriginForPlacement(free, size, to);
    CHECK_NEAR((m.x - to.x) / (to.width - 480), 0.25, 1e-9);
  });

  Test("critically damped spring settles on target without overshoot", [&] {
    Spring2D spring;
    SpringParams params{0.42, 1.0};
    spring.Start({0, 0}, {0, 0}, {300, -200}, params);
    double prevDistance = 1e9;
    bool monotonic = true;
    for (double t = 0; t <= 1.5; t += 1.0 / 120) {
      Vec2 p, v;
      spring.Sample(t, &p, &v);
      double distance = (p - Vec2{300, -200}).Length();
      if (distance > prevDistance + 1e-9) {
        monotonic = false;
      }
      prevDistance = distance;
    }
    CHECK(monotonic);
    CHECK(spring.IsSettled(1.2));
  });

  Test("underdamped spring with release velocity settles quickly", [&] {
    Spring2D spring;
    spring.Start({0, 0}, {2500, -1800}, {900, -500}, SpringParams{});
    CHECK(!spring.IsSettled(0.1));
    CHECK(spring.IsSettled(1.4));
  });

  Test("throws avoid corners other players take", [&] {
    Box area = AllowedArea(kExternal.visible, kGap);
    Vec2 size{480, 270};
    Box start = Box::FromOriginSize({800, 400}, size);
    ReleaseResult free =
        ResolveRelease(start, {2400, -1600}, area, ReleaseParams{});
    CHECK(free.dock == (Dock{HEdge::Right, VEdge::Bottom}));
    Box other = Box::FromOriginSize(
        CornerOrigin({HEdge::Right, VEdge::Bottom}, size, area), size);
    ReleaseResult avoided =
        ResolveRelease(start, {2400, -1600}, area, ReleaseParams{}, {other});
    CHECK(!(avoided.dock == (Dock{HEdge::Right, VEdge::Bottom})));
    CHECK(Box::FromOriginSize(avoided.target, size).IntersectionArea(other) ==
          0);
    // With every corner taken it still lands in the nearest one.
    std::vector<Box> all;
    for (Dock corner :
         {Dock{HEdge::Left, VEdge::Bottom}, Dock{HEdge::Right, VEdge::Bottom},
          Dock{HEdge::Left, VEdge::Top}, Dock{HEdge::Right, VEdge::Top}}) {
      all.push_back(
          Box::FromOriginSize(CornerOrigin(corner, size, area), size));
    }
    CHECK(
        ResolveRelease(start, {2400, -1600}, area, ReleaseParams{}, all).dock ==
        (Dock{HEdge::Right, VEdge::Bottom}));
  });

  Test("free slots keep tabs apart along an edge", [&] {
    CHECK_NEAR(NearestFreeSlot(500, 68, 0, 1000, {}), 500, 1e-9);
    CHECK_NEAR(NearestFreeSlot(500, 68, 0, 1000, {520}), 452, 1e-9);
    CHECK_NEAR(NearestFreeSlot(500, 68, 0, 1000, {452, 520}), 588, 1e-9);
    CHECK_NEAR(NearestFreeSlot(-40, 68, 0, 1000, {0}), 68, 1e-9);
    CHECK_NEAR(NearestFreeSlot(2000, 68, 0, 1000, {}), 1000, 1e-9);
  });

  Test("release velocity uses recent samples and ignores a stop", [&] {
    std::vector<PointerSample> samples;
    for (int i = 0; i <= 20; i++) {
      double t = i / 120.0;
      samples.push_back({t, {1200 * t, -600 * t}});
    }
    Vec2 v = ReleaseVelocity(samples, samples.back().time + 0.005);
    CHECK_NEAR(v.x, 1200, 1e-6);
    CHECK_NEAR(v.y, -600, 1e-6);
    Vec2 stopped = ReleaseVelocity(samples, samples.back().time + 0.2);
    CHECK(stopped.Length() == 0);
  });

  std::printf("\n%d checks, %d failures\n", sChecks, sFailures);
  return sFailures ? 1 : 0;
}
