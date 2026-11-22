# zen-pip

**The ultimate Picture-in-Picture for Zen Browser.** Flick the video into a corner, slide it around with two fingers, and it stays neatly out of your way, the way Arc's Picture-in-Picture did.

zen-pip is built and tested on **Zen** (macOS). It should also work with:

| Browser | Status |
| --- | --- |
| Zen | ✅ Tested |
| Firefox (and LibreWolf, Firefox Developer Edition, Nightly) | 🟡 Should work: same PiP window as Zen, not yet tested |
| Chrome, Brave, Edge, Helium, Vivaldi, Chromium | 🟡 Might work for video PiP (English-language browsers only), not yet tested |
| Safari, Arc | ❌ Not supported (they have their own PiP) |

If you try it in a browser marked 🟡, please open an issue to say how it went.

> zen-pip is an unofficial community project. It isn't made by or affiliated with the Zen team, Mozilla or The Browser Company. It was inspired by the Picture-in-Picture in Arc.

## What you get

| Do this | The PiP window |
| --- | --- |
| Two-finger swipe on the video | Follows your fingers, and the pointer moves with it |
| Lift your fingers slowly | Stays where you left it, snapping onto an edge if it's close, and the pointer centres on it |
| Flick towards a side or corner | Flies all the way there, springs slightly past the edge and settles, and the pointer goes back to where it was |
| Click and drag it, letting go while still moving (mouse or trackpad click) | Is thrown to that side or corner in the same way |
| Click and drag it slowly | Stays where you put it, snapping onto a nearby edge |
| Push or drag it past an edge | Resists, then slides back on screen |
| Push it well past the left or right edge, or flick it again towards the side it's resting on | Tucks away off-screen and keeps playing, leaving a slim glass tab with an arrow at the edge (with Stage Manager on, at the right edge only) |
| Drag the tab, or swipe on it with two fingers, up or down | Moves it along the edge |
| Click the tab, or drag or swipe it inwards | Slides the video back out |
| Swipe on it while it's flying | Catches it |
| Switch between a full-screen app and a normal desktop | Follows the bottom edge: the very bottom in full screen, just above the Dock on a desktop |

With the recommended Zen settings you also get:

- **Automatic PiP:** a playing video pops out when you switch tabs, swipe to another desktop or minimise Zen, and pops back in when you return.
- **Glass buttons:** the close, minimise and back-to-tab buttons in the PiP window become translucent, macOS-style glass circles.
- **No floating PiP button on videos:** it only gets in the way once PiP opens by itself. ⌥⌘⇧] still toggles PiP.
- **Optional fade-in:** turn on Zen's see-through mode and a new PiP fades in once its video has had a moment to get going, instead of showing a frozen frame while it catches up (as it does after swiping to another desktop). It appears about half a second later.

Everything else stays as it was. Normal scrolling and clicking anywhere else, mouse wheels, and ⌘-dragging the PiP (Zen's own snap-to-corner, which comes from Firefox) all work as before.

## Why

Arc's PiP was one of its nicest details: you could push the video aside with a flick and it would land in a corner and stay on screen. Zen's PiP is a good video player, but the window only moves by click-dragging and happily disappears off the edge of the screen. zen-pip brings the Arc feel to Zen without modifying Zen itself.

## Requirements

- macOS 13 or later (it's built for 13 and up). Tested on macOS 27 with Zen 1.24, which is based on Firefox 160.
- The Xcode Command Line Tools, to build it (`xcode-select --install`). The full Xcode app isn't needed.
- A trackpad for the swipes. The click-and-drag throws also work with a mouse.

## Install

1. **Get the code.** On GitHub, click **Code → Download ZIP** and unzip it, or clone the repository with git.
2. **Build and install it.** In Terminal, go to the folder you downloaded and run the install script. For example:

   ```bash
   cd ~/Downloads/zen-pip-main
   ./scripts/install.sh
   ```

   This builds the app, puts it in `~/Applications/ZenPiP.app`, and sets it to start at login. It has no window or Dock icon; it just runs in the background.

3. **Give it Accessibility permission.** macOS may show a prompt; click **Open System Settings**. In **Privacy & Security → Accessibility**, switch **ZenPiP** on. If it isn't in the list, click **+** and choose `~/Applications/ZenPiP.app` (press ⌘⇧G and type `~/Applications`). ZenPiP starts working within a couple of seconds.

### Set up Zen

These steps change Zen's own settings and add the stylesheet for the glass buttons (and the optional fade-in).

1. In Zen, open `about:support` and, next to **Profile Folder**, click **Show in Finder**.
2. Copy [`zen/user.js`](zen/user.js) into that folder. If there's already a `user.js`, add the lines from ours to it.
3. Copy [`zen/userChrome.css`](zen/userChrome.css) into the `chrome` folder inside it (create the folder if it doesn't exist). If there's already a `userChrome.css`, add ours to the end of it.
4. Quit and reopen Zen.

<details>
<summary>Prefer to change the settings by hand? Set these in <code>about:config</code> instead of using user.js.</summary>

| Setting | Value | What it does |
| --- | --- | --- |
| `media.videocontrols.picture-in-picture.enable-when-switching-tabs.enabled` | `true` | PiP when you switch tabs |
| `media.videocontrols.picture-in-picture.enable-when-occluded.enabled` | `true` | PiP when Zen's window is hidden (another desktop, minimised) |
| `media.videocontrols.picture-in-picture.video-toggle.enabled` | `false` | Hides the PiP button drawn on videos (optional) |
| `media.videocontrols.picture-in-picture.seethrough-mode.enabled` | `true` | Lets a new PiP fade in, with the zen-pip stylesheet (optional) |
| `toolkit.legacyUserProfileCustomizations.stylesheets` | `true` | Lets Zen load `chrome/userChrome.css` (restart Zen after changing it) |

</details>

Why hide the on-video PiP button instead of moving it lower? Zen (like Firefox) fixes its position partway down the video, and nothing outside Zen's own code can change that.

## Settings

ZenPiP reads its settings whenever a gesture lands on a PiP window, so changes apply straight away, with no restart or rebuild.

```bash
defaults write local.zenpip edgeMargin -float 12       # gap kept from the screen edges, in points
defaults write local.zenpip followPointer -bool false  # leave the pointer alone
defaults write local.zenpip stash -bool false          # never tuck the window away at a side
defaults write local.zenpip invert -bool true          # if the window moves against your fingers
defaults write local.zenpip debug -bool true           # log every gesture (for troubleshooting)
```

The feel of the movement can be tuned the same way:

```bash
defaults write local.zenpip flingSpeed -float 0.45     # how fast a swipe must be to count as a flick (points per ms)
defaults write local.zenpip cornerShare -float 0.38    # how diagonal a flick must be to go to a corner (lower = more corners)
defaults write local.zenpip throwCarryMs -float 250    # how far a flick carries along a side it isn't aimed at
defaults write local.zenpip magnet -float 28           # how close to an edge a set-down window snaps onto it
defaults write local.zenpip springSpeed -float 0.015   # how quickly a thrown window gets there
defaults write local.zenpip springDamping -float 0.7   # bounce past the edge: lower = bouncier, 1 = none
defaults write local.zenpip throwSpeed -float 4        # top starting speed of a throw (limits the bounce)
```

`defaults delete local.zenpip <name>` goes back to the default. Out-of-range values are clamped, and a throw always comes to rest within a few seconds.

## How it works

ZenPiP is a small background app: about 1,400 lines of Swift, including its self-test, with no dependencies.

1. **It watches scrolls and clicks.** With Accessibility permission, macOS lets ZenPiP see trackpad scroll and mouse button events before they reach any app. Keyboard events are never watched.
2. **It checks whether you're on a PiP window.** When a two-finger swipe starts, ZenPiP looks at the window under the pointer. If it's an always-on-top browser window titled "Picture-in-Picture", the swipe is ZenPiP's; anything else passes straight through, untouched. It looks past invisible full-screen overlays (screenshot tools such as CleanShot X, or the Dock during a space swipe) that would otherwise hide the PiP.
3. **It moves the window.** While your fingers move, ZenPiP moves the PiP window the same distance through the Accessibility interface, the same way window managers like Rectangle do, and moves the pointer with it.
4. **It throws.** When you let go, it measures how fast you were moving. Fast enough means a throw: it works out which side or corner you were aiming at and carries the window there with a spring, which overshoots a little before settling. Click-and-drag works the same way: the browser does the drag, and ZenPiP measures your speed when you let go.
5. **It knows where the Dock is.** It asks macOS whether the current space is a full-screen app, where the Dock is hidden, or a normal desktop, and keeps the PiP in the right area when you switch.
6. **It tucks the window away.** macOS never lets an app move another app's window fully off-screen, so a tucked-away PiP shrinks and parks with a sliver left on screen, and ZenPiP covers the sliver with a glass tab of its own. If macOS moves the window back on screen (it sometimes does when you switch spaces), ZenPiP waits until macOS has finished moving it and tucks it away again.

The Zen side is just Zen's own settings and a stylesheet. For the details, including the physics, edge cases and performance, see [docs/how-it-works.md](docs/how-it-works.md).

### Why not a Zen mod?

Zen's official mods can only change how Zen looks (they're CSS), and moving a window needs code. Code mods, such as those run by the community mod manager Sine, need a loader placed inside `Zen.app`. macOS then reports Zen as "damaged" unless the app is re-signed. Re-signing removes Zen's passkey permission (so iCloud Keychain passkeys stop working), makes macOS ask for camera and microphone access again, and has to be redone after every Zen update. A separate helper app avoids all of that: Zen stays exactly as shipped and updates normally.

## Privacy and permissions

- **Accessibility permission** is used only to see trackpad scroll and mouse button events, to read the title of always-on-top browser windows (to recognise PiP windows), and to move PiP windows and the pointer.
- **Core Audio** is asked, while a PiP is tucked away, whether the browser is playing sound, so the tab can turn grey when the video is paused (macOS 14.2 or later; on earlier versions the tab always shows the video). This needs no permission.
- **No network access** and **no data collection.** Nothing is stored except the settings you set and a log at `~/Library/Logs/ZenPiP.log`, which only records gestures when `debug` is on.
- **A few undocumented macOS functions** are used, the same ones most window managers use. They're listed in [Sources/ZenPiP/PrivateAPI.swift](Sources/ZenPiP/PrivateAPI.swift). If a future macOS removes one, ZenPiP loses that feature instead of breaking.
- The whole app is in [`Sources/ZenPiP`](Sources/ZenPiP). Please read it before giving it Accessibility permission, as you should with any app that asks for it.

## Updating

```bash
git pull            # or download the new ZIP
./scripts/install.sh
```

Then, in **Privacy & Security → Accessibility**, select ZenPiP, click **minus (−)**, and add it again with **plus (+)**. The app is signed locally ("ad hoc") rather than with a paid Apple developer certificate, so macOS ties the permission to each exact build. Switching the old entry off and on isn't enough.

## Troubleshooting

- **Nothing happens.** Run `tail ~/Library/Logs/ZenPiP.log`. If the last line says it's waiting for Accessibility permission, remove ZenPiP from the Accessibility list and add it again.
- **Swipes on the PiP aren't picked up.** Turn on `debug` (see [Settings](#settings)), swipe on the PiP, and check the log. It says when a PiP is under the pointer but another window is covering it.
- **It moves the opposite way to your fingers.** `defaults write local.zenpip invert -bool true`.
- **The glass buttons don't show.** Check that `toolkit.legacyUserProfileCustomizations.stylesheets` is `true` in `about:config` and that `userChrome.css` is in the profile's `chrome` folder, then restart Zen.
- **The PiP disappears for a moment when you switch desktops.** macOS hides windows that show on every desktop while it animates the switch, and shows them again when it's done. ZenPiP can't change that (Safari's PiP is macOS's own, which is why it stays put).
- **"Back to tab" leaves the video in PiP.** That happens in Zen when another tab is selected: Zen closes the PiP before it has switched tabs, and its PiP-when-switching-tabs setting opens a new one. Selecting the video's tab first works.
- **It won't tuck away at the left edge.** Stage Manager keeps the left edge for its strip of recent apps and pushes small windows straight back out from there, so with Stage Manager on, a push to the left just lands at the edge. The right edge works as usual.
- **PiP doesn't open when switching tabs or desktops.** Check the two `enable-when-…` settings. Zen also skips this for muted tabs and for videos you closed the PiP of yourself.

## Uninstall

```bash
./scripts/uninstall.sh
```

Then remove ZenPiP from the Accessibility list. To undo the Zen side too, remove the zen-pip lines from your profile's `user.js` and `chrome/userChrome.css`, then reset the four settings listed under [Set up Zen](#set-up-zen) in `about:config` (removing them from `user.js` alone leaves them set).

## Project layout

```
Sources/ZenPiP/      the app (Swift)
  main.swift           start-up
  Engine*.swift        gestures, throws, stashing, spaces and animation
  Stash.swift          stashing rules and the edge tab
  Physics.swift        movement maths: rubber band, throws, spring
  Windows.swift        finding PiP windows; Accessibility helpers
  Screens.swift        displays, the Dock, full-screen spaces and Stage Manager
  Audio.swift          whether the browser is playing sound (for the stash tab's look)
  WindowMover.swift    moving the PiP window
  Pointer.swift        moving the mouse pointer
  Settings.swift       settings
  Log.swift            the log
  PrivateAPI.swift     the undocumented macOS functions, looked up safely
  SelfTest.swift       checks run by scripts/test.sh
Resources/           Info.plist and the login item
scripts/             build, test, install, uninstall
zen/                 Zen settings (user.js) and the glass PiP buttons (userChrome.css)
docs/                how it works, in detail
```

`./scripts/test.sh` builds the app and runs its self-test, which checks the movement maths and window rules without touching any windows. The scripts work from any folder.

## Credits

Inspired by Arc's Picture-in-Picture, by The Browser Company. Built for [Zen Browser](https://zen-browser.app), on top of Firefox's Picture-in-Picture.

## Licence

[MIT](LICENSE)
