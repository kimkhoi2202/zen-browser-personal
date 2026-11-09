/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef mozilla_nsZenPipNativePlayer_h_
#define mozilla_nsZenPipNativePlayer_h_

#include "nsIZenPipNativePlayer.h"

namespace zen {

/**
 * @brief Service that attaches the native (AppKit Liquid Glass) chrome to
 * Picture-in-Picture player windows. Registered on macOS only; elsewhere the
 * player keeps its stock HTML controls.
 */
class nsZenPipNativePlayer final : public nsIZenPipNativePlayer {
 public:
  NS_DECL_ISUPPORTS
  NS_DECL_NSIZENPIPNATIVEPLAYER

  nsZenPipNativePlayer() = default;

 private:
  ~nsZenPipNativePlayer() = default;
};

}  // namespace zen

#endif
