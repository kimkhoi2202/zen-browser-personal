/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef mozilla_ZenPipGeometry_h_
#define mozilla_ZenPipGeometry_h_

// Placement, containment and motion math for the native Picture-in-Picture
// player. Everything here is plain C++ (no Gecko or AppKit types) so it can be
// unit tested on its own. Coordinates are AppKit global screen points: the
// origin is the bottom-left corner of the primary display and y grows upward.
// Displays left of / below the primary therefore have negative origins.

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

namespace zen::pip {

struct Vec2 {
  double x = 0;
  double y = 0;

  Vec2 operator+(const Vec2& aOther) const {
    return {x + aOther.x, y + aOther.y};
  }
  Vec2 operator-(const Vec2& aOther) const {
    return {x - aOther.x, y - aOther.y};
  }
  Vec2 operator*(double aScale) const { return {x * aScale, y * aScale}; }
  double Length() const { return std::hypot(x, y); }
};

struct Box {
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;

  double MinX() const { return x; }
  double MinY() const { return y; }
  double MaxX() const { return x + width; }
  double MaxY() const { return y + height; }
  Vec2 Origin() const { return {x, y}; }
  Vec2 Size() const { return {width, height}; }
  Vec2 Center() const { return {x + width / 2, y + height / 2}; }

  bool Contains(const Box& aOther, double aEpsilon = 1e-6) const {
    return aOther.MinX() >= MinX() - aEpsilon &&
           aOther.MaxX() <= MaxX() + aEpsilon &&
           aOther.MinY() >= MinY() - aEpsilon &&
           aOther.MaxY() <= MaxY() + aEpsilon;
  }

  double IntersectionArea(const Box& aOther) const {
    double w =
        std::min(MaxX(), aOther.MaxX()) - std::max(MinX(), aOther.MinX());
    double h =
        std::min(MaxY(), aOther.MaxY()) - std::max(MinY(), aOther.MinY());
    return (w > 0 && h > 0) ? w * h : 0;
  }

  static Box FromOriginSize(Vec2 aOrigin, Vec2 aSize) {
    return {aOrigin.x, aOrigin.y, aSize.x, aSize.y};
  }
};

// Which edges of the allowed area the player rests against. A corner is both
// a horizontal and a vertical edge; "free" placement has neither.
enum class HEdge : uint8_t { None, Left, Right };
enum class VEdge : uint8_t { None, Bottom, Top };

struct Dock {
  HEdge h = HEdge::None;
  VEdge v = VEdge::None;

  bool operator==(const Dock& aOther) const = default;
};

// Screen-independent description of where the player rests, used to carry a
// position across a display change or a resize. For docked axes the edge is
// authoritative; for free axes `fx`/`fy` hold the frame origin as a fraction
// of the travel range inside the allowed area.
struct Placement {
  Dock dock;
  double fx = 1;
  double fy = 0;
};

// The area the player frame must stay inside: the display's visible frame
// (menu bar and Dock excluded) inset by the edge gap. The gap is reduced if
// the display is too small for it.
inline Box AllowedArea(const Box& aVisibleFrame, double aGap) {
  double gapX = std::clamp(aGap, 0.0, std::max(0.0, aVisibleFrame.width / 4));
  double gapY = std::clamp(aGap, 0.0, std::max(0.0, aVisibleFrame.height / 4));
  return {aVisibleFrame.x + gapX, aVisibleFrame.y + gapY,
          aVisibleFrame.width - 2 * gapX, aVisibleFrame.height - 2 * gapY};
}

// Clamps an origin so that a frame of `aSize` lies fully inside `aArea`. If the
// frame is larger than the area on an axis it is centered on that axis.
inline Vec2 ClampOrigin(Vec2 aOrigin, Vec2 aSize, const Box& aArea) {
  auto clampAxis = [](double aValue, double aLength, double aMin,
                      double aRange) {
    if (aLength >= aRange) {
      return aMin + (aRange - aLength) / 2;
    }
    return std::clamp(aValue, aMin, aMin + aRange - aLength);
  };
  return {clampAxis(aOrigin.x, aSize.x, aArea.x, aArea.width),
          clampAxis(aOrigin.y, aSize.y, aArea.y, aArea.height)};
}

inline Vec2 OriginForDock(const Dock& aDock, Vec2 aOrigin, Vec2 aSize,
                          const Box& aArea) {
  Vec2 origin = aOrigin;
  if (aDock.h == HEdge::Left) {
    origin.x = aArea.MinX();
  } else if (aDock.h == HEdge::Right) {
    origin.x = aArea.MaxX() - aSize.x;
  }
  if (aDock.v == VEdge::Bottom) {
    origin.y = aArea.MinY();
  } else if (aDock.v == VEdge::Top) {
    origin.y = aArea.MaxY() - aSize.y;
  }
  return ClampOrigin(origin, aSize, aArea);
}

inline Dock DetectDock(const Box& aFrame, const Box& aArea, double aTolerance) {
  Dock dock;
  if (std::abs(aFrame.MinX() - aArea.MinX()) <= aTolerance) {
    dock.h = HEdge::Left;
  } else if (std::abs(aFrame.MaxX() - aArea.MaxX()) <= aTolerance) {
    dock.h = HEdge::Right;
  }
  if (std::abs(aFrame.MinY() - aArea.MinY()) <= aTolerance) {
    dock.v = VEdge::Bottom;
  } else if (std::abs(aFrame.MaxY() - aArea.MaxY()) <= aTolerance) {
    dock.v = VEdge::Top;
  }
  return dock;
}

inline Placement PlacementForFrame(const Box& aFrame, const Box& aArea,
                                   double aTolerance) {
  Placement placement;
  placement.dock = DetectDock(aFrame, aArea, aTolerance);
  double travelX = aArea.width - aFrame.width;
  double travelY = aArea.height - aFrame.height;
  placement.fx =
      travelX > 0
          ? std::clamp((aFrame.MinX() - aArea.MinX()) / travelX, 0.0, 1.0)
          : 0.5;
  placement.fy =
      travelY > 0
          ? std::clamp((aFrame.MinY() - aArea.MinY()) / travelY, 0.0, 1.0)
          : 0.5;
  return placement;
}

inline Vec2 OriginForPlacement(const Placement& aPlacement, Vec2 aSize,
                               const Box& aArea) {
  Vec2 origin{aArea.MinX() + aPlacement.fx * (aArea.width - aSize.x),
              aArea.MinY() + aPlacement.fy * (aArea.height - aSize.y)};
  return OriginForDock(aPlacement.dock, origin, aSize, aArea);
}

// Index of the display that should own `aRect`: the one with the largest
// overlap, otherwise the one whose visible frame is nearest to its center.
inline size_t ScreenIndexForRect(const Box& aRect,
                                 const std::vector<Box>& aScreens) {
  size_t best = 0;
  double bestArea = -1;
  for (size_t i = 0; i < aScreens.size(); i++) {
    double area = aScreens[i].IntersectionArea(aRect);
    if (area > bestArea) {
      bestArea = area;
      best = i;
    }
  }
  if (bestArea > 0) {
    return best;
  }
  Vec2 center = aRect.Center();
  double bestDistance = std::numeric_limits<double>::infinity();
  for (size_t i = 0; i < aScreens.size(); i++) {
    Vec2 nearest{std::clamp(center.x, aScreens[i].MinX(), aScreens[i].MaxX()),
                 std::clamp(center.y, aScreens[i].MinY(), aScreens[i].MaxY())};
    double distance = (nearest - center).Length();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = i;
    }
  }
  return best;
}

// Distance travelled by something released at `aVelocity` (points/second)
// that decelerates by `aDecelerationRate` every millisecond until it stops
// (the projection technique from Apple's WWDC18 "Designing Fluid Interfaces").
inline double ProjectDistance(double aVelocity, double aDecelerationRate) {
  aDecelerationRate = std::clamp(aDecelerationRate, 0.5, 0.9999);
  return (aVelocity / 1000.0) * aDecelerationRate / (1.0 - aDecelerationRate);
}

inline Vec2 Project(Vec2 aPosition, Vec2 aVelocity, double aDecelerationRate) {
  return {aPosition.x + ProjectDistance(aVelocity.x, aDecelerationRate),
          aPosition.y + ProjectDistance(aVelocity.y, aDecelerationRate)};
}

// Rubber-band resistance for dragging past an edge (the curve UIScrollView
// popularised): approaches `aDimension` asymptotically.
inline double RubberBand(double aOvershoot, double aDimension,
                         double aCoefficient = 0.55) {
  if (aOvershoot <= 0 || aDimension <= 0) {
    return 0;
  }
  return (1.0 - 1.0 / (aOvershoot * aCoefficient / aDimension + 1.0)) *
         aDimension;
}

// Origin for a frame dragged to `aDesired`. Inside `aArea` it follows the
// pointer exactly; beyond it, it resists with a rubber band whose stretch is
// capped by `aHardLimit` (normally the display's visible frame), so the player
// can never leave the display even mid-drag.
inline Vec2 RubberBandOrigin(Vec2 aDesired, Vec2 aSize, const Box& aArea,
                             const Box& aHardLimit) {
  auto axis = [](double aValue, double aLength, double aMin, double aMax,
                 double aHardMin, double aHardMax) {
    double hi = aMax - aLength;
    if (hi < aMin) {
      return (aMin + hi) / 2;
    }
    if (aValue < aMin) {
      double room = std::max(0.0, aMin - aHardMin);
      return aMin - RubberBand(aMin - aValue, room);
    }
    if (aValue > hi) {
      double room = std::max(0.0, aHardMax - (hi + aLength));
      return hi + RubberBand(aValue - hi, room);
    }
    return aValue;
  };
  return {axis(aDesired.x, aSize.x, aArea.MinX(), aArea.MaxX(),
               aHardLimit.MinX(), aHardLimit.MaxX()),
          axis(aDesired.y, aSize.y, aArea.MinY(), aArea.MaxY(),
               aHardLimit.MinY(), aHardLimit.MaxY())};
}

struct ReleaseParams {
  // Below this release speed (points/second) a release is a deliberate
  // placement; above it, it is a throw toward a corner.
  double flickSpeed = 320;
  // Per-millisecond deceleration used to project a throw (0.998 matches the
  // "normal" scroll deceleration on Apple platforms).
  double decelerationRate = 0.998;
  // Slow placements this close to an edge snap onto it.
  double magnetDistance = 36;
};

struct ReleaseResult {
  Vec2 target;
  Dock dock;
  bool isThrow = false;
};

struct Corner {
  Dock dock;
  Vec2 origin;
};

// The corner of `aArea` whose frame of `aSize` is nearest to `aPoint` (a
// frame center) while overlapping none of `aOccupied`; the nearest corner
// when every one overlaps.
inline Corner NearestFreeCorner(Vec2 aPoint, Vec2 aSize, const Box& aArea,
                                const std::vector<Box>& aOccupied = {}) {
  static constexpr Dock kCorners[] = {{HEdge::Left, VEdge::Bottom},
                                      {HEdge::Right, VEdge::Bottom},
                                      {HEdge::Left, VEdge::Top},
                                      {HEdge::Right, VEdge::Top}};
  Corner nearest, nearestFree;
  double best = std::numeric_limits<double>::infinity();
  double bestFree = best;
  for (const Dock& dock : kCorners) {
    Vec2 origin = OriginForDock(dock, {aArea.x, aArea.y}, aSize, aArea);
    Box frame = Box::FromOriginSize(origin, aSize);
    double distance = (frame.Center() - aPoint).Length();
    if (distance < best) {
      best = distance;
      nearest = {dock, origin};
    }
    bool free = std::none_of(
        aOccupied.begin(), aOccupied.end(),
        [&](const Box& aOther) { return aOther.IntersectionArea(frame) > 0; });
    if (free && distance < bestFree) {
      bestFree = distance;
      nearestFree = {dock, origin};
    }
  }
  return bestFree < std::numeric_limits<double>::infinity() ? nearestFree
                                                            : nearest;
}

// The position nearest to `aWanted` within [aMin, aMax] that stays at least
// `aSpacing` away from every position in `aTaken` (`aWanted` clamped when
// there is none), e.g. for tabs stacked along an edge.
inline double NearestFreeSlot(double aWanted, double aSpacing, double aMin,
                              double aMax, const std::vector<double>& aTaken) {
  double wanted = std::clamp(aWanted, aMin, std::max(aMin, aMax));
  std::vector<double> candidates{wanted};
  for (double taken : aTaken) {
    candidates.push_back(taken - aSpacing);
    candidates.push_back(taken + aSpacing);
  }
  double best = wanted;
  double bestDistance = std::numeric_limits<double>::infinity();
  for (double candidate : candidates) {
    bool clear = candidate >= aMin - 1e-6 && candidate <= aMax + 1e-6 &&
                 std::all_of(aTaken.begin(), aTaken.end(), [&](double aTaken) {
                   return std::abs(candidate - aTaken) >= aSpacing - 1e-6;
                 });
    if (clear && std::abs(candidate - wanted) < bestDistance) {
      bestDistance = std::abs(candidate - wanted);
      best = candidate;
    }
  }
  return best;
}

// Decides where a released player should come to rest: a slow release stays
// (snapping onto edges within the magnet distance), a throw glides into the
// corner it heads for, avoiding corners other players (`aOccupied`) take.
inline ReleaseResult ResolveRelease(const Box& aFrame, Vec2 aVelocity,
                                    const Box& aArea,
                                    const ReleaseParams& aParams,
                                    const std::vector<Box>& aOccupied = {}) {
  ReleaseResult result;
  Vec2 size = aFrame.Size();
  if (aVelocity.Length() < aParams.flickSpeed) {
    Vec2 origin = ClampOrigin(aFrame.Origin(), size, aArea);
    Box clamped = Box::FromOriginSize(origin, size);
    result.dock = DetectDock(clamped, aArea, aParams.magnetDistance);
    result.target = OriginForDock(result.dock, origin, size, aArea);
    return result;
  }
  result.isThrow = true;
  Corner corner = NearestFreeCorner(
      Project(aFrame.Center(), aVelocity, aParams.decelerationRate), size,
      aArea, aOccupied);
  result.dock = corner.dock;
  result.target = corner.origin;
  return result;
}

enum class ResizeHandle : uint8_t {
  Left,
  Right,
  Bottom,
  Top,
  BottomLeft,
  BottomRight,
  TopLeft,
  TopRight,
};

inline int HandleSignX(ResizeHandle aHandle) {
  switch (aHandle) {
    case ResizeHandle::Left:
    case ResizeHandle::BottomLeft:
    case ResizeHandle::TopLeft:
      return -1;
    case ResizeHandle::Right:
    case ResizeHandle::BottomRight:
    case ResizeHandle::TopRight:
      return 1;
    default:
      return 0;
  }
}

inline int HandleSignY(ResizeHandle aHandle) {
  switch (aHandle) {
    case ResizeHandle::Bottom:
    case ResizeHandle::BottomLeft:
    case ResizeHandle::BottomRight:
      return -1;
    case ResizeHandle::Top:
    case ResizeHandle::TopLeft:
    case ResizeHandle::TopRight:
      return 1;
    default:
      return 0;
  }
}

struct SizeLimits {
  double minWidth = 200;
  double minHeight = 112;
  // Fraction of the allowed area the player may cover on either axis.
  double maxFraction = 0.82;
};

inline Vec2 ClampSize(double aWidth, double aAspect, const Box& aArea,
                      const SizeLimits& aLimits) {
  double maxW = std::min(aArea.width * aLimits.maxFraction,
                         aArea.height * aLimits.maxFraction * aAspect);
  double minW = std::max(aLimits.minWidth, aLimits.minHeight * aAspect);
  // On a tiny display the minimum gives way so the player still fits.
  minW = std::min(minW, std::min(aArea.width, aArea.height * aAspect));
  double width = std::clamp(aWidth, minW, std::max(minW, maxW));
  return {width, width / aAspect};
}

// Aspect-locked resize. The anchor (the point that stays put) is the docked
// edge or corner when the player rests against one, otherwise the side
// opposite the grabbed handle; edge handles keep the perpendicular axis
// centered. `aDelta` is the pointer movement since the resize started.
inline Box ResizeFrame(const Box& aStart, ResizeHandle aHandle, Vec2 aDelta,
                       double aAspect, const Dock& aDock, const Box& aArea,
                       const SizeLimits& aLimits) {
  int sx = HandleSignX(aHandle);
  int sy = HandleSignY(aHandle);
  double byWidth = aStart.width + sx * aDelta.x;
  double byHeight = (aStart.height + sy * aDelta.y) * aAspect;
  double width;
  if (sx == 0) {
    width = byHeight;
  } else if (sy == 0) {
    width = byWidth;
  } else {
    // Corner handles follow whichever axis the pointer moved along most.
    width = std::abs(sx * aDelta.x) >= std::abs(sy * aDelta.y * aAspect)
                ? byWidth
                : byHeight;
  }
  Vec2 size = ClampSize(width, aAspect, aArea, aLimits);

  double x;
  if (aDock.h == HEdge::Left || (aDock.h == HEdge::None && sx > 0)) {
    x = aStart.MinX();
  } else if (aDock.h == HEdge::Right || (aDock.h == HEdge::None && sx < 0)) {
    x = aStart.MaxX() - size.x;
  } else {
    x = aStart.Center().x - size.x / 2;
  }
  double y;
  if (aDock.v == VEdge::Bottom || (aDock.v == VEdge::None && sy > 0)) {
    y = aStart.MinY();
  } else if (aDock.v == VEdge::Top || (aDock.v == VEdge::None && sy < 0)) {
    y = aStart.MaxY() - size.y;
  } else {
    y = aStart.Center().y - size.y / 2;
  }
  Vec2 origin = ClampOrigin({x, y}, size, aArea);
  return Box::FromOriginSize(origin, size);
}

// Scales the frame about its anchor (docked corner/edge, else its center), as
// for a pinch gesture.
inline Box ScaleFrame(const Box& aStart, double aScale, double aAspect,
                      const Dock& aDock, const Box& aArea,
                      const SizeLimits& aLimits) {
  Vec2 size = ClampSize(aStart.width * aScale, aAspect, aArea, aLimits);
  double x = aDock.h == HEdge::Left    ? aStart.MinX()
             : aDock.h == HEdge::Right ? aStart.MaxX() - size.x
                                       : aStart.Center().x - size.x / 2;
  double y = aDock.v == VEdge::Bottom ? aStart.MinY()
             : aDock.v == VEdge::Top  ? aStart.MaxY() - size.y
                                      : aStart.Center().y - size.y / 2;
  return Box::FromOriginSize(ClampOrigin({x, y}, size, aArea), size);
}

// Damped harmonic oscillator solved analytically, so the motion is exact and
// independent of the display refresh rate. `response` is the undamped period
// in seconds; `dampingRatio` 1 is critical damping, < 1 allows overshoot.
struct SpringParams {
  double response = 0.42;
  double dampingRatio = 0.86;
};

struct Spring1D {
  // Displacement from the target and velocity at t = 0.
  double x0 = 0;
  double v0 = 0;

  void Evaluate(double aT, const SpringParams& aParams, double* aX,
                double* aV) const {
    double omega = 2 * M_PI / std::max(aParams.response, 0.01);
    double zeta = std::clamp(aParams.dampingRatio, 0.05, 2.0);
    if (zeta < 1) {
      double wd = omega * std::sqrt(1 - zeta * zeta);
      double decay = std::exp(-zeta * omega * aT);
      double a = x0;
      double b = (v0 + zeta * omega * x0) / wd;
      double c = std::cos(wd * aT);
      double s = std::sin(wd * aT);
      *aX = decay * (a * c + b * s);
      *aV = decay *
            ((b * wd - zeta * omega * a) * c - (a * wd + zeta * omega * b) * s);
    } else if (zeta == 1) {
      double decay = std::exp(-omega * aT);
      double b = v0 + omega * x0;
      *aX = decay * (x0 + b * aT);
      *aV = decay * (b - omega * (x0 + b * aT));
    } else {
      double root = omega * std::sqrt(zeta * zeta - 1);
      double r1 = -zeta * omega + root;
      double r2 = -zeta * omega - root;
      double c2 = (v0 - r1 * x0) / (r2 - r1);
      double c1 = x0 - c2;
      *aX = c1 * std::exp(r1 * aT) + c2 * std::exp(r2 * aT);
      *aV = c1 * r1 * std::exp(r1 * aT) + c2 * r2 * std::exp(r2 * aT);
    }
  }
};

// Two-axis spring from a position and velocity toward a target.
class Spring2D {
 public:
  void Start(Vec2 aFrom, Vec2 aVelocity, Vec2 aTarget,
             const SpringParams& aParams) {
    mTarget = aTarget;
    mParams = aParams;
    mX.x0 = aFrom.x - aTarget.x;
    mX.v0 = aVelocity.x;
    mY.x0 = aFrom.y - aTarget.y;
    mY.v0 = aVelocity.y;
  }

  void Sample(double aT, Vec2* aPosition, Vec2* aVelocity) const {
    double x, vx, y, vy;
    mX.Evaluate(aT, mParams, &x, &vx);
    mY.Evaluate(aT, mParams, &y, &vy);
    *aPosition = {mTarget.x + x, mTarget.y + y};
    *aVelocity = {vx, vy};
  }

  bool IsSettled(double aT, double aDistanceEpsilon = 0.35,
                 double aSpeedEpsilon = 6) const {
    Vec2 position, velocity;
    Sample(aT, &position, &velocity);
    return (position - mTarget).Length() < aDistanceEpsilon &&
           velocity.Length() < aSpeedEpsilon;
  }

  Vec2 Target() const { return mTarget; }

 private:
  Spring1D mX;
  Spring1D mY;
  Vec2 mTarget;
  SpringParams mParams;
};

// Release velocity from recent pointer samples (points/second). Samples older
// than `aWindow` before the release are ignored, and a pointer that stopped
// before release yields zero velocity.
struct PointerSample {
  double time = 0;  // seconds
  Vec2 position;
};

inline Vec2 ReleaseVelocity(const std::vector<PointerSample>& aSamples,
                            double aReleaseTime, double aWindow = 0.08,
                            double aStaleAfter = 0.06) {
  if (aSamples.size() < 2) {
    return {};
  }
  const PointerSample& last = aSamples.back();
  if (aReleaseTime - last.time > aStaleAfter) {
    return {};
  }
  size_t first = aSamples.size() - 1;
  while (first > 0 && last.time - aSamples[first - 1].time <= aWindow) {
    first--;
  }
  double dt = last.time - aSamples[first].time;
  if (dt <= 1e-4) {
    return {};
  }
  return (last.position - aSamples[first].position) * (1.0 / dt);
}

}  // namespace zen::pip

#endif  // mozilla_ZenPipGeometry_h_
