/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Bridges the toolkit Picture-in-Picture player (player.js) and Zen's native
// macOS chrome (nsIZenPipNativePlayer): Liquid Glass controls, physical window
// motion and display containment. Every native control maps onto the same
// player/actor paths the stock controls use, so playback commands always act
// on the original <video> in the source tab (the player only shows a visual
// clone that shares the original decoder).

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
XPCOMUtils.defineLazyPreferenceGetter(lazy, "EDGE_GAP", "zen.pip.edge-gap", 10);
XPCOMUtils.defineLazyPreferenceGetter(
  lazy,
  "IDLE_HIDE_MS",
  "zen.pip.controls.idle-hide-ms",
  2400
);
XPCOMUtils.defineLazyPreferenceGetter(
  lazy,
  "TWO_FINGER_CARRY",
  "zen.pip.motion.two-finger-carry",
  true
);

const PLACEMENT_PREF = "zen.pip.last-placement";
const TEXT_TRACK_FONT_SIZE_PREF =
  "media.videocontrols.picture-in-picture.display-text-tracks.size";
const SEEK_SECONDS = 15;

// macOS virtual key codes, as the native chrome reports them.
const MAC_KEY = {
  RETURN: 36,
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
// The same keys by DOM key code, for keys that reach the player document.
const DOM_VK_TAB = 9;
const MAC_KEY_BY_DOM_KEY = new Map([
  [13, MAC_KEY.RETURN],
  [27, MAC_KEY.ESCAPE],
  [32, MAC_KEY.SPACE],
  [35, MAC_KEY.END],
  [36, MAC_KEY.HOME],
  [37, MAC_KEY.LEFT],
  [38, MAC_KEY.UP],
  [39, MAC_KEY.RIGHT],
  [40, MAC_KEY.DOWN],
]);

// Closes the user asked for fade the player out; going back to the tab
// shrinks it into the video in its page.
const FADE_OUT_REASONS = [
  "CloseButton",
  "ClosePlayerShortcut",
  "Shortcut",
  "ContextMenu",
];
const SHRINK_REASONS = ["Unpip", "Foregrounded"];
// A transition never holds a close up for longer than this.
const EXIT_TIMEOUT_MS = 600;

function nativeService() {
  return (
    Cc["@mozilla.org/zen/pip-native-player;1"]?.getService(
      Ci.nsIZenPipNativePlayer
    ) ?? null
  );
}

// A screen rect in device pixels to desktop pixels; all zero when unknown.
function desktopRect(rect, desktopToDeviceScale) {
  if (!rect || !(desktopToDeviceScale > 0)) {
    return { left: 0, top: 0, width: 0, height: 0 };
  }
  return {
    left: rect.left / desktopToDeviceScale,
    top: rect.top / desktopToDeviceScale,
    width: rect.width / desktopToDeviceScale,
    height: rect.height / desktopToDeviceScale,
  };
}

function configuration() {
  return {
    edgeGap: lazy.EDGE_GAP,
    idleHideDelay: lazy.IDLE_HIDE_MS / 1000,
    carryWithTwoFingers: lazy.TWO_FINGER_CARRY ? 1 : 0,
    rightToLeft: Services.locale.isAppLocaleRTL ? 1 : 0,
  };
}

// Localized labels: stock Picture-in-Picture strings where they exist, Zen
// strings for the additions (the stock tooltips need their $shortcut).
// "timePosition" and "behindLive" come back as templates that the native side
// fills in (%1$@, %2$@).
const LABELS = [
  ["close", "pictureinpicture-close-btn", { shortcut: "⌘W" }],
  ["minimize", "pictureinpicture-minimize-btn"],
  ["play", "pictureinpicture-play-btn"],
  ["pause", "pictureinpicture-pause-btn"],
  ["replay", "zen-pip-replay"],
  ["mute", "pictureinpicture-mute-btn", { shortcut: "M" }],
  ["unmute", "pictureinpicture-unmute-btn", { shortcut: "M" }],
  ["returnToTab", "pictureinpicture-unpip-btn"],
  ["speed", "pictureinpicture-playback-rate-btn"],
  ["subtitlesMenu", "pictureinpicture-subtitles-label"],
  ["captionsSize", "pictureinpicture-font-size-label"],
  ["captionSize-small", "pictureinpicture-font-size-small"],
  ["captionSize-medium", "pictureinpicture-font-size-medium"],
  ["captionSize-large", "pictureinpicture-font-size-large"],
  ["back15", "zen-pip-back-15"],
  ["forward15", "zen-pip-forward-15"],
  ["subtitlesOn", "zen-pip-subtitles-show"],
  ["subtitlesOff", "zen-pip-subtitles-hide"],
  ["subtitlesUnavailable", "zen-pip-subtitles-unavailable"],
  ["timeline", "zen-pip-timeline"],
  [
    "timePosition",
    "zen-pip-time-position",
    { elapsed: "%1$@", duration: "%2$@" },
  ],
  ["live", "zen-pip-live"],
  ["goLive", "zen-pip-go-live"],
  ["behindLive", "zen-pip-behind-live", { duration: "%1$@" }],
  ["restore", "zen-pip-restore"],
];

async function localizedLabels(document) {
  const messages = await document.l10n.formatMessages(
    LABELS.map(([, id, args]) => ({ id, args }))
  );
  const strings = {};
  messages.forEach((message, index) => {
    const attribute = message?.attributes?.find(a => a.name == "aria-label");
    const text = attribute?.value ?? message?.value;
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
  #sourceWindow = null;
  #wasPlayingBeforeScrub = false;
  #captionsAvailable = false;
  #captionStyle = null;
  #live = false;
  #seekable = false;
  #atLiveEdge = true;
  #exit = null;

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

  // For tests and diagnostics.
  get controls() {
    return this.#controls;
  }

  // The system caption style last handed to the player page (for tests).
  get captionStyle() {
    return this.#captionStyle;
  }

  // State mirrored from the original video.

  setPlaying(playing) {
    this.#controls?.setPlaying(playing);
  }

  setMuted(muted) {
    this.#controls?.setMuted(muted);
  }

  setVolume(volume) {
    this.#controls?.setVolume(volume);
  }

  setPlaybackRate(rate) {
    this.#controls?.setPlaybackRate(rate);
  }

  setPlaybackState({ buffering, ended, loaded }) {
    this.#controls?.setPlaybackState(!!buffering, !!ended, loaded ?? -1);
  }

  setTimeline({ currentTime, duration, isLive, liveWindow }) {
    if (typeof currentTime != "number") {
      return;
    }
    this.#live = !!isLive;
    if (isLive && liveWindow) {
      // A live stream that can be scrubbed: the timeline spans its seekable
      // window, and the Live button returns to the live edge.
      this.#seekable = true;
      this.#atLiveEdge = !!liveWindow.atLiveEdge;
      this.#controls?.setTimeline(
        currentTime - liveWindow.start,
        liveWindow.end - liveWindow.start,
        true,
        true
      );
      this.#controls?.setLiveEdge(this.#atLiveEdge);
      return;
    }
    this.#seekable = Number.isFinite(duration) && duration > 0 && !isLive;
    this.#controls?.setTimeline(
      currentTime,
      duration,
      this.#seekable,
      this.#live
    );
  }

  setCaptions(available, enabled) {
    this.#captionsAvailable = available;
    this.#controls?.setCaptions(available, enabled);
  }

  setVideoSize(width, height) {
    if (width > 0 && height > 0) {
      this.#controls?.setVideoSize(width, height);
    }
  }

  setSourceWindow(sourceWindow) {
    this.#sourceWindow = sourceWindow ?? null;
    this.#controls?.setSourceWindow(this.#sourceWindow);
  }

  // Transitions.

  /**
   * The player grows out of the video in its page: `rect` in device pixels
   * of the source window's display, or null to fade in.
   */
  playEntrance(rect, desktopToDeviceScale) {
    const { left, top, width, height } = desktopRect(
      rect,
      desktopToDeviceScale
    );
    this.#controls?.playEntrance(left, top, width, height);
  }

  /**
   * Called before the player closes for `reason` (a Glean close method):
   * back to the tab it shrinks into the video, closed by the user it fades.
   */
  async beforeClose(reason) {
    if (!this.#controls) {
      return;
    }
    if (SHRINK_REASONS.includes(reason)) {
      const rect = await this.#player.actor
        .sendQuery("PictureInPicture:ZenVideoRect")
        .catch(() => null);
      await this.#playExit(rect, this.#sourceWindow?.desktopToDeviceScale);
    } else if (FADE_OUT_REASONS.includes(reason)) {
      await this.#playExit(null);
    }
  }

  #playExit(rect, desktopToDeviceScale) {
    if (!this.#exit) {
      this.#exit = Promise.withResolvers();
      const { left, top, width, height } = desktopRect(
        rect,
        desktopToDeviceScale
      );
      this.#controls?.playExit(left, top, width, height);
      this.#window.setTimeout(this.#exit.resolve, EXIT_TIMEOUT_MS);
    }
    return this.#exit.promise;
  }

  // Intents from the native controls.

  onAction(action, value, detail) {
    if (action == "exit-done") {
      this.#exit?.resolve();
      return;
    }
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
      case "scrub-end":
        actor.sendAsyncMessage("PictureInPicture:SetVideoTime", {
          scrubberPosition: value,
          wasPlaying: this.#wasPlayingBeforeScrub,
        });
        if (action == "scrub-end" && this.#wasPlayingBeforeScrub) {
          actor.sendAsyncMessage("PictureInPicture:Play");
        }
        break;
      case "toggle-mute":
        player.toggleMute();
        break;
      case "go-live":
        actor.sendAsyncMessage("PictureInPicture:ZenGoLive");
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
        this.#onKey({ code: value, ...JSON.parse(detail) });
        break;
      case "controls":
        this.#positionCaptions(value == 1, JSON.parse(detail).timelineTop);
        break;
      case "caption-style":
        // The system caption style (Accessibility > Captions), on open and
        // whenever it changes; the player page renders captions with it.
        this.#captionStyle = JSON.parse(detail);
        actor.sendAsyncMessage(
          "PictureInPicture:ZenCaptionStyle",
          this.#captionStyle
        );
        break;
      case "placement":
        Services.prefs.setStringPref(PLACEMENT_PREF, detail);
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

  #positionCaptions(showing, timelineTop) {
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

  // Speeds above normal can't do anything at a live stream's live edge.
  #canSpeedUp() {
    return (
      !this.#live ||
      (this.#seekable && !this.#atLiveEdge) ||
      this.#player._playbackRate < 1
    );
  }

  /**
   * The player's keys (Yab's where they don't clash with Firefox's): Space
   * play/pause, ←/→ ±15 s, ↑/↓ volume, M mute, C subtitles, < > speed, Return
   * back to the tab (keeps playing), Esc pause and close, ⌘W close, ⌘⌥⇧P
   * toggle Picture-in-Picture. Returns whether the key is one of them.
   */
  #onKey({ code, key = "", shift, alt, ctrl, meta }) {
    const player = this.#player;
    const KeyEvent = this.#window.KeyEvent;
    const plain = !meta && !ctrl && !alt;
    const sendKey = keyCode =>
      player.actor.sendAsyncMessage("PictureInPicture:KeyDown", {
        altKey: !!alt,
        shiftKey: !!shift,
        metaKey: !!meta,
        ctrlKey: !!ctrl,
        keyCode,
      });
    // A live stream that can't be scrubbed has nowhere to seek to.
    const canSeek = !this.#live || this.#seekable;

    switch (code) {
      case MAC_KEY.SPACE:
        sendKey(KeyEvent.DOM_VK_SPACE);
        return true;
      case MAC_KEY.ESCAPE:
        player.onClose(!!shift);
        return true;
      case MAC_KEY.RETURN:
      case MAC_KEY.ENTER:
        lazy.PictureInPicture.focusTabAndClosePip(this.#window, player.actor);
        return true;
      case MAC_KEY.LEFT:
      case MAC_KEY.RIGHT:
        if (canSeek && plain) {
          this.onAction(
            "seek-relative",
            code == MAC_KEY.LEFT ? -SEEK_SECONDS : SEEK_SECONDS,
            ""
          );
        } else if (canSeek) {
          sendKey(
            code == MAC_KEY.LEFT ? KeyEvent.DOM_VK_LEFT : KeyEvent.DOM_VK_RIGHT
          );
        }
        return true;
      case MAC_KEY.UP:
        sendKey(KeyEvent.DOM_VK_UP);
        return true;
      case MAC_KEY.DOWN:
        sendKey(KeyEvent.DOM_VK_DOWN);
        return true;
      case MAC_KEY.HOME:
      case MAC_KEY.END:
        if (canSeek) {
          sendKey(
            code == MAC_KEY.HOME ? KeyEvent.DOM_VK_HOME : KeyEvent.DOM_VK_END
          );
        }
        return true;
    }

    const char = key.toLowerCase();
    if (meta && char == "w") {
      sendKey(KeyEvent.DOM_VK_W);
    } else if (meta && alt && shift && char == "p") {
      player.closePipWindow({ reason: "Shortcut" });
    } else if (plain && char == "m") {
      player.toggleMute();
    } else if (plain && char == "c") {
      this.#toggleCaptions();
    } else if (!meta && (key == "<" || (shift && key == ","))) {
      player.cyclePlaybackRate(-1);
    } else if (!meta && (key == ">" || (shift && key == "."))) {
      if (this.#canSpeedUp()) {
        player.cyclePlaybackRate(1);
      }
    } else {
      return false;
    }
    return true;
  }

  /**
   * Keys that reach the player document (when Gecko holds keyboard focus)
   * take the same shortcuts; the others go on to Gecko and the menu bar.
   * Returns whether the key was handled.
   */
  handleKeyDown(event) {
    let handled = true;
    if (event.keyCode == DOM_VK_TAB) {
      this.#controls?.focusControls();
    } else {
      handled = this.#onKey({
        code: MAC_KEY_BY_DOM_KEY.get(event.keyCode) ?? -1,
        key: event.key,
        shift: event.shiftKey,
        alt: event.altKey,
        ctrl: event.ctrlKey,
        meta: event.metaKey,
      });
    }
    if (handled) {
      event.preventDefault();
    }
    return handled;
  }

  destroy() {
    this.#exit?.resolve();
    this.#controls?.destroy();
    this.#controls = null;
    this.#player = null;
  }
}

export const ZenPipNativeControls = {
  /** Whether player windows get the native chrome (registered on macOS). */
  get isEnabled() {
    return lazy.NATIVE_ENABLED && !!nativeService();
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
      // No display information: Firefox places the player itself.
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
