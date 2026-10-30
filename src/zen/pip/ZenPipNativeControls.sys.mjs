/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Bridges the toolkit Picture-in-Picture player (player.js) and Zen's native
// macOS chrome (nsIZenPipNativePlayer): Liquid Glass controls, physical window
// motion and display containment. Every native control maps onto the same
// player/actor paths the stock controls use, so playback commands always act
// on the original <video> in the source tab (the player only shows a visual
// clone that shares the original decoder).

import { AppConstants } from "resource://gre/modules/AppConstants.sys.mjs";
import { XPCOMUtils } from "resource://gre/modules/XPCOMUtils.sys.mjs";

const lazy = {};

ChromeUtils.defineESModuleGetters(lazy, {
  PictureInPicture:
    "moz-src:///toolkit/components/pictureinpicture/PictureInPicture.sys.mjs",
});

XPCOMUtils.defineLazyPreferenceGetter(
  lazy,
  "NATIVE_ENABLED",
  "zen.pip.native-controls.enabled",
  true
);
XPCOMUtils.defineLazyPreferenceGetter(lazy, "EDGE_GAP", "zen.pip.edge-gap", 14);

const PLACEMENT_PREF = "zen.pip.last-placement";
const TEXT_TRACK_FONT_SIZE_PREF =
  "media.videocontrols.picture-in-picture.display-text-tracks.size";
const SEEK_SECONDS = 15;

// macOS virtual key codes delivered by the native chrome.
const MAC_KEY = {
  RETURN: 36,
  TAB: 48,
  SPACE: 49,
  ESCAPE: 53,
  ENTER: 76,
  HOME: 115,
  END: 119,
  LEFT: 123,
  RIGHT: 124,
  DOWN: 125,
  UP: 126,
};

function nativeService() {
  try {
    return (
      Cc["@mozilla.org/zen/pip-native-player;1"]?.getService(
        Ci.nsIZenPipNativePlayer
      ) ?? null
    );
  } catch {
    return null;
  }
}

function intPref(name, fallback) {
  return Services.prefs.getIntPref(name, fallback);
}

function configuration() {
  return {
    edgeGap: lazy.EDGE_GAP,
    springResponse: intPref("zen.pip.motion.response-ms", 420) / 1000,
    springDamping: intPref("zen.pip.motion.damping-percent", 86) / 100,
    decelerationRate:
      intPref("zen.pip.motion.deceleration-per-mille", 998) / 1000,
    flickSpeed: intPref("zen.pip.motion.flick-speed", 320),
    magnetDistance: intPref("zen.pip.motion.magnet-distance", 36),
    idleHideDelay: intPref("zen.pip.controls.idle-hide-ms", 2400) / 1000,
    carryWithTwoFingers: Services.prefs.getBoolPref(
      "zen.pip.motion.two-finger-carry",
      true
    )
      ? 1
      : 0,
  };
}

// Localized labels: stock Picture-in-Picture strings where they exist, Zen
// strings for the additions.
const LABELS = [
  ["close", "pictureinpicture-close-btn", { shortcut: "⌘W" }],
  ["minimize", "pictureinpicture-minimize-btn"],
  ["play", "pictureinpicture-play-btn"],
  ["pause", "pictureinpicture-pause-btn"],
  ["mute", "pictureinpicture-mute-btn", { shortcut: "M" }],
  ["unmute", "pictureinpicture-unmute-btn", { shortcut: "M" }],
  ["returnToTab", "pictureinpicture-unpip-btn"],
  ["speed", "pictureinpicture-playback-rate-btn"],
  ["captionsSize", "pictureinpicture-font-size-label"],
  ["captionSize-small", "pictureinpicture-font-size-small"],
  ["captionSize-medium", "pictureinpicture-font-size-medium"],
  ["captionSize-large", "pictureinpicture-font-size-large"],
  ["back15", "zen-pip-back-15"],
  ["forward15", "zen-pip-forward-15"],
  ["captionsOn", "zen-pip-captions-show"],
  ["captionsOff", "zen-pip-captions-hide"],
  ["captionsMenuShow", "zen-pip-captions-show"],
  ["captionsUnavailable", "zen-pip-captions-unavailable"],
  ["timeline", "zen-pip-timeline"],
  ["timeOf", "zen-pip-time-of"],
  ["live", "zen-pip-live"],
  ["restore", "zen-pip-restore"],
];

async function localizedLabels(document) {
  const messages = await document.l10n.formatMessages(
    LABELS.map(([, id, args]) => ({ id, args }))
  );
  const strings = {};
  messages.forEach((message, index) => {
    if (!message) {
      return;
    }
    const attribute = message.attributes?.find(a => a.name == "aria-label");
    const text = attribute?.value ?? message.value;
    if (text) {
      strings[LABELS[index][0]] = text;
    }
  });
  return strings;
}

/**
 * One native chrome session, owned by a player window's Player object.
 */
class ZenPipNativeSession {
  #controls = null;
  #player = null;
  #window = null;
  #wasPlayingBeforeScrub = false;
  #captionsAvailable = false;

  constructor(window, player, controls) {
    this.#window = window;
    this.#player = player;
    this.#controls = controls;
    controls.setConfiguration(JSON.stringify(configuration()));
    controls.setCaptionSize(
      Services.prefs.getCharPref(TEXT_TRACK_FONT_SIZE_PREF, "medium")
    );
    localizedLabels(window.document).then(
      strings => this.#controls?.setStrings(JSON.stringify(strings)),
      console.error
    );
  }

  get controls() {
    return this.#controls;
  }

  // State mirrored from the original video.

  setPlaying(playing) {
    this.#controls?.setPlaying(playing);
  }

  setMuted(muted) {
    this.#controls?.setMuted(muted);
  }

  setPlaybackRate(rate) {
    this.#controls?.setPlaybackRate(rate);
  }

  setTimeline({ currentTime, duration, isLive }) {
    if (typeof currentTime != "number") {
      return;
    }
    const seekable = Number.isFinite(duration) && duration > 0 && !isLive;
    this.#controls?.setTimeline(currentTime, duration, seekable, !!isLive);
  }

  setCaptions(available, enabled) {
    this.#captionsAvailable = available;
    this.#controls?.setCaptions(available, enabled);
  }

  setVideoSize(width, height) {
    if (!this.#controls || !(width > 0) || !(height > 0)) {
      return false;
    }
    this.#controls.setVideoSize(width, height);
    return true;
  }

  setSourceWindow(sourceWindow) {
    this.#controls?.setSourceWindow(sourceWindow ?? null);
  }

  // Intents from the native controls.

  onAction(action, value, detail) {
    const player = this.#player;
    const actor = player.actor;
    if (!actor || this.#window.closed) {
      return;
    }
    switch (action) {
      case "toggle-play":
        actor.sendAsyncMessage(
          player.isPlaying ? "PictureInPicture:Pause" : "PictureInPicture:Play"
        );
        break;
      case "seek-relative":
        actor.sendAsyncMessage(
          value < 0
            ? "PictureInPicture:SeekBackward"
            : "PictureInPicture:SeekForward",
          { seconds: Math.abs(value) }
        );
        break;
      case "scrub-start":
        this.#wasPlayingBeforeScrub = player.isPlaying;
        if (player.isPlaying) {
          actor.sendAsyncMessage("PictureInPicture:Pause");
        }
        break;
      case "scrub":
        actor.sendAsyncMessage("PictureInPicture:SetVideoTime", {
          scrubberPosition: value,
          wasPlaying: this.#wasPlayingBeforeScrub,
        });
        break;
      case "scrub-end":
        actor.sendAsyncMessage("PictureInPicture:SetVideoTime", {
          scrubberPosition: value,
          wasPlaying: this.#wasPlayingBeforeScrub,
        });
        if (this.#wasPlayingBeforeScrub) {
          actor.sendAsyncMessage("PictureInPicture:Play");
        }
        break;
      case "toggle-mute":
        player.toggleMute();
        break;
      case "set-rate":
        player.requestPlaybackRate(value);
        break;
      case "toggle-captions":
        this.#toggleCaptions();
        break;
      case "caption-size":
        this.#setCaptionSize(detail);
        break;
      case "close":
        player.onClose();
        break;
      case "return":
        lazy.PictureInPicture.focusTabAndClosePip(this.#window, actor);
        break;
      case "key":
        this.#onKey(value, detail);
        break;
      case "controls":
        this.#positionCaptions(value == 1, detail);
        break;
      case "placement":
        if (detail) {
          Services.prefs.setStringPref(PLACEMENT_PREF, detail);
        }
        break;
    }
  }

  #toggleCaptions() {
    if (!this.#captionsAvailable) {
      return;
    }
    // Same path as the stock subtitles switch (sends ToggleTextTracks and
    // persists the preference).
    this.#window.document.getElementById("subtitles-toggle")?.click();
  }

  #setCaptionSize(size) {
    if (!["small", "medium", "large"].includes(size)) {
      return;
    }
    const radio = this.#window.document.getElementById(size);
    if (radio) {
      radio.checked = true;
    }
    this.#player.onSubtitleChange(size);
    this.#controls?.setCaptionSize(size);
  }

  #positionCaptions(showing, detail) {
    let timelineTop = null;
    try {
      timelineTop = JSON.parse(detail || "{}").timelineTop ?? null;
    } catch {}
    this.#player.actor.sendAsyncMessage(
      showing
        ? "PictureInPicture:ShowVideoControls"
        : "PictureInPicture:HideVideoControls",
      {
        isFullscreen: false,
        isVideoControlsShowing: showing,
        playerBottomControlsDOMRect:
          showing && timelineTop != null ? { top: timelineTop } : null,
        isScrubberShowing: showing,
      }
    );
  }

  /**
   * Keyboard map (Yab's where it does not clash with Firefox's): Space
   * play/pause, ←/→ ±15 s, ↑/↓ volume, M mute, C captions, < > speed,
   * Return back to the tab (keeps playing), Esc pause and close, ⌘W close,
   * Tab focuses the native controls.
   */
  #onKey(macKeyCode, detail) {
    let key = {};
    try {
      key = JSON.parse(detail || "{}");
    } catch {}
    const player = this.#player;
    const plain = !key.meta && !key.ctrl && !key.alt;
    const KeyEvent = this.#window.KeyEvent;
    const sendKey = keyCode =>
      player.actor.sendAsyncMessage("PictureInPicture:KeyDown", {
        altKey: !!key.alt,
        shiftKey: !!key.shift,
        metaKey: !!key.meta,
        ctrlKey: !!key.ctrl,
        keyCode,
      });
    const char = (key.key || "").toLowerCase();

    switch (macKeyCode) {
      case MAC_KEY.SPACE:
        sendKey(KeyEvent.DOM_VK_SPACE);
        return;
      case MAC_KEY.ESCAPE:
        player.onClose(!!key.shift);
        return;
      case MAC_KEY.RETURN:
      case MAC_KEY.ENTER:
        lazy.PictureInPicture.focusTabAndClosePip(this.#window, player.actor);
        return;
      case MAC_KEY.LEFT:
      case MAC_KEY.RIGHT:
        if (plain) {
          this.onAction(
            "seek-relative",
            macKeyCode == MAC_KEY.LEFT ? -SEEK_SECONDS : SEEK_SECONDS,
            ""
          );
        } else {
          sendKey(
            macKeyCode == MAC_KEY.LEFT
              ? KeyEvent.DOM_VK_LEFT
              : KeyEvent.DOM_VK_RIGHT
          );
        }
        return;
      case MAC_KEY.UP:
        sendKey(KeyEvent.DOM_VK_UP);
        return;
      case MAC_KEY.DOWN:
        sendKey(KeyEvent.DOM_VK_DOWN);
        return;
      case MAC_KEY.HOME:
        sendKey(KeyEvent.DOM_VK_HOME);
        return;
      case MAC_KEY.END:
        sendKey(KeyEvent.DOM_VK_END);
        return;
    }

    if (key.meta && char == "w") {
      sendKey(KeyEvent.DOM_VK_W);
    } else if (key.meta && key.alt && key.shift && char == "p") {
      player.closePipWindow({ reason: "Shortcut" });
    } else if (plain && char == "m") {
      player.toggleMute();
    } else if (plain && char == "c") {
      this.#toggleCaptions();
    } else if (!key.meta && (char == "<" || char == ",")) {
      if (char == "<" || key.shift) {
        player.cyclePlaybackRate(-1);
      }
    } else if (!key.meta && (char == ">" || char == ".")) {
      if (char == ">" || key.shift) {
        player.cyclePlaybackRate(1);
      }
    }
  }

  /**
   * Keys that still reach the player document (when Gecko holds keyboard
   * focus) take the same native-mode shortcuts. Returns true if handled.
   */
  handleKeyDown(event) {
    if (event.keyCode == this.#window.KeyEvent.DOM_VK_TAB) {
      this.#controls?.focusControls();
      event.preventDefault();
      return true;
    }
    const macCodes = {
      [this.#window.KeyEvent.DOM_VK_SPACE]: MAC_KEY.SPACE,
      [this.#window.KeyEvent.DOM_VK_ESCAPE]: MAC_KEY.ESCAPE,
      [this.#window.KeyEvent.DOM_VK_RETURN]: MAC_KEY.RETURN,
      [this.#window.KeyEvent.DOM_VK_LEFT]: MAC_KEY.LEFT,
      [this.#window.KeyEvent.DOM_VK_RIGHT]: MAC_KEY.RIGHT,
      [this.#window.KeyEvent.DOM_VK_UP]: MAC_KEY.UP,
      [this.#window.KeyEvent.DOM_VK_DOWN]: MAC_KEY.DOWN,
      [this.#window.KeyEvent.DOM_VK_HOME]: MAC_KEY.HOME,
      [this.#window.KeyEvent.DOM_VK_END]: MAC_KEY.END,
    };
    this.#onKey(
      macCodes[event.keyCode] ?? -1,
      JSON.stringify({
        key: event.key,
        shift: event.shiftKey,
        alt: event.altKey,
        ctrl: event.ctrlKey,
        meta: event.metaKey,
      })
    );
    event.preventDefault();
    return true;
  }

  destroy() {
    this.#controls?.destroy();
    this.#controls = null;
    this.#player = null;
  }
}

export const ZenPipNativeControls = {
  /** Whether player windows get the native chrome. */
  get isEnabled() {
    return (
      AppConstants.platform == "macosx" &&
      lazy.NATIVE_ENABLED &&
      !!nativeService()?.isSupported
    );
  },

  get hasLiquidGlass() {
    return !!nativeService()?.hasLiquidGlass;
  },

  /**
   * Where a new player for a video from `sourceWindow` should open, in that
   * window's CSS pixels: fully inside the usable area of the display holding
   * the source window, in the last used corner/size.
   *
   * @returns {{left, top, width, height}|null}
   */
  initialFrame(sourceWindow, videoWidth, videoHeight) {
    if (!this.isEnabled) {
      return null;
    }
    try {
      const [left, top, width, height] = nativeService().initialFrame(
        sourceWindow,
        videoWidth,
        videoHeight,
        Services.prefs.getStringPref(PLACEMENT_PREF, ""),
        lazy.EDGE_GAP
      );
      const cssToDesktop =
        sourceWindow.devicePixelRatio / sourceWindow.desktopToDeviceScale;
      return {
        left: left / cssToDesktop,
        top: top / cssToDesktop,
        width: width / cssToDesktop,
        height: height / cssToDesktop,
      };
    } catch (e) {
      console.error(e);
      return null;
    }
  },

  /**
   * Attaches the native chrome to a player window.
   *
   * @param {Window} window The player window (player.xhtml).
   * @param {object} player The player's `Player` object.
   * @returns {ZenPipNativeSession|null} null to keep the stock controls.
   */
  attach(window, player) {
    if (!this.isEnabled) {
      return null;
    }
    let session = null;
    try {
      const controls = nativeService().attach(window, {
        onAction: (action, value, detail) =>
          session?.onAction(action, value, detail),
      });
      session = new ZenPipNativeSession(window, player, controls);
    } catch (e) {
      console.error("Zen PiP: native controls unavailable", e);
      return null;
    }
    return session;
  },
};
