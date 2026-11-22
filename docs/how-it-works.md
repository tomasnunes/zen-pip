# How zen-pip works

This is the detailed version of the [README's overview](../README.md#how-it-works), for anyone curious or wanting to change the code. ZenPiP has two parts:

- **ZenPiP.app**, a background helper that adds the gestures. It's covered below.
- **Zen's own settings and a stylesheet** (`zen/user.js`, `zen/userChrome.css`), which turn on automatic PiP and restyle the PiP window's buttons. Nothing in Zen is modified.

## The big picture

```
trackpad / mouse ──▶ macOS ──▶ ZenPiP's event tap ──▶ is this on a PiP window?
                                     │                      │ no ─▶ passes through untouched
                                     │                      │ yes
                                     │                      ▼
                                     │        follow the fingers (rubber band at edges)
                                     │                      │ fingers lift
                                     │                      ▼
                                     │     slow ─▶ set down (snap to a near edge)
                                     │     fast ─▶ throw to a side or corner (spring)
                                     │                      │
                                     ▼                      ▼
                              space switches ──▶ window moves, through Accessibility
```

ZenPiP runs as a login item with no Dock icon (`LSUIElement`). Everything happens on the main thread except the actual window moves.

## Seeing the gestures

`Engine.installTap()` installs a `CGEventTap` at the session level, listening only to **scroll** events and the **left mouse button** (down, dragged, up). This is why it needs Accessibility permission. It never listens to the keyboard.

The tap sees every scroll and click on the system before any app does, so the callback has to be cheap:

- **A mouse-wheel scroll** has no scroll phase, so it's recognised from two integer fields and passed straight on.
- **A trackpad scroll** in the middle of a swipe costs a couple of field reads and a clock read, unless the swipe is on a PiP.
- **The start of a swipe** (`mayBegin` or `began`) is the only time ZenPiP looks at which window is under the pointer (see the next section). That takes under a millisecond.
- **Clicks** are only noted in the callback; the window lookup runs just afterwards, so clicks are never delayed.

Returning `nil` from the callback swallows an event. ZenPiP does that only for swipes that started on a PiP window, so the browser doesn't also try to scroll. It also swallows macOS's "momentum" scroll events after such a swipe, because ZenPiP animates the window itself.

If macOS ever pauses the tap (it does this when a callback is too slow), ZenPiP turns it back on and finishes any swipe in progress cleanly.

## Recognising a PiP window

`Engine.findPip(at:)` runs in three steps, cheapest first:

1. **What's under the pointer?** `WindowList.topmost(at:)` walks the on-screen window list front to back. It skips windows you see and click straight through: the pointer itself, invisible windows, and always-on-top windows that cover a whole display. That last group includes screenshot and screen-recording tools such as CleanShot X, which keep an invisible full-screen layer above everything, and the Dock's full-screen container during space swipes. Without this, those layers would hide the PiP. A real window or menu on top of the PiP still counts.
2. **Could it be a PiP?** `isCandidate` checks for an always-on-top window (a window level between normal windows and the Dock) owned by a known browser and at least video-sized.
3. **Is it a PiP?** `verify` asks the browser for the window's title through Accessibility and compares it with "Picture-in-Picture" in every language Zen ships. This stops ZenPiP from ever moving some other small always-on-top browser window. The answer is remembered: confirmed PiP windows for good, other windows for a few seconds. A browser that's too busy to answer within 0.15 s is asked again shortly after, rather than holding up your scrolling.

Matching the window list to an Accessibility window uses `_AXUIElementGetWindow` (see [Undocumented functions](#undocumented-functions)). If that function ever disappears, windows are matched by position and size instead.

## Moving the window

Windows are moved by setting their Accessibility position, as window managers such as Rectangle do. `WindowMover` does this on a background queue and only ever sends the newest position. If the browser is slow to respond, positions in between are skipped rather than queued, so the window keeps up with your fingers instead of lagging behind. If the window has gone (you closed the PiP, or Zen closed it after you returned to the tab), the mover reports it and the engine stops.

While your fingers move, the pointer is moved by the same amount with a posted "mouse moved" event (`Pointer`). Moving it this way rather than warping it keeps it responsive, and the PiP notices the hover and shows its controls. The pointer is never moved while a button is held, and it's kept a few points inside the display so it can't set off a hot corner or reveal the Dock.

## The physics

All the movement maths is in [`Physics.swift`](../Sources/ZenPiP/Physics.swift). It works in points and milliseconds and touches nothing on the system, so the self-test covers it.

- **Bounds.** A window's top-left corner may go anywhere on the display's usable area (see [Spaces and the Dock](#spaces-and-the-dock)), keeping `edgeMargin` (12 pt) from each edge.
- **Following and the rubber band.** Finger movement is applied one to one inside the bounds. Past an edge it's scaled down, more the further out it already is (`resist`), so the window can be pushed out at most about 70 pt.
- **Release speed.** ZenPiP keeps the last 40 finger movements with their timestamps. On release, the speed is the distance covered in the last 80 ms divided by the time taken (`releaseVelocity`). If the fingers rested for more than 50 ms before lifting, the speed is zero, so it's a placement, not a throw.
- **Throw or set down.** At 0.45 pt/ms or faster (`flingSpeed`) it's a throw.
  - **A throw** goes to every side it is "aimed at": a side counts if the speed in its direction is at least 38% of the total (`cornerShare`). A flick straight right lands on the right side, keeping its height plus a little carry (`throwCarryMs`); a diagonal flick lands in the corner.
  - **A set-down** stays where it is, snapped onto any edge within 28 pt (`magnet`).
- **The spring.** The window travels to its destination as an under-damped spring (stiffness ω = 0.015 rad/ms, damping ratio 0.7), starting at the release speed, capped at 4 pt/ms. That carries it slightly past the edge and back, and it settles in about 0.6 s. The spring is stepped in fixed 4 ms increments for stability and drawn 120 times a second.
- **Soft overshoot.** While animating, any position past an edge is squeezed with an exponential curve (`soften`), so even a hard throw only shows a short bounce. When a spring starts outside the bounds (after being pushed, dragged off-screen, or left under the Dock after a space switch), the squeezing is measured from where it starts, so it slides in smoothly instead of jumping.
- **Catching.** A swipe that starts on a flying window stops it where it's drawn and carries on from there. A plain click on a flying window (to pause, say) lets it finish its trip.

## Stashing at a side

Like macOS's own Picture-in-Picture, the window can be tucked away at the left or right edge
(`Stash.swift`, `Engine+Stash.swift`). It's stashed when:

- **A swipe pushes it well past a side:** the window is let go more than 35 pt past the side bound, which takes a firm push against the rubber band.
- **A flick sends it towards the side it was already resting on:** the flick must be clearly sideways (within about 35° of straight across), so a diagonal flick still goes to the corner; a flick from the middle of the screen only reaches the edge.
- **A mouse drag leaves it well off a side:** about a third of the window off-screen, or a quick throw from the edge.

macOS never lets an app move another app's window completely off-screen. Asked to, it pulls the
window back to about 40 points showing, although it accepts a position with about 20 points showing
when that's what's asked for. So stashing has three steps:

1. **Away:** the window flies off the side. The moment it's nearly gone, ZenPiP covers what's left
   with a glass tab of its own, just above the PiP's window level and on every space. Behind the
   tab, the window shrinks to Zen's smallest height and parks with 21 points left on screen (the
   resize and move are applied in order, after any move still on its way). Once the window has stayed
   put there for a moment, the tab contracts into a slim handle with an arrow, a point wider than
   the sliver, so its rounded corners never show the window.
2. **Parked:** the video keeps playing, so you still hear it. While it plays, the handle's glass
   blurs the sliver of video behind it, so it shimmers with the video's colours; while it's paused,
   the handle turns plain dark grey. (ZenPiP asks Core Audio whether the browser is playing sound,
   which needs no permission; macOS can only say from version 14.2, so before that the handle always
   shows the video. So a muted video looks paused, and sound from another tab looks like
   playing.) Dragging the handle, or swiping on it
   with two fingers, moves it and the hidden window along the edge. A drag decides its direction
   once, so a vertical drag never pops the window out. Two-finger swipes on the handle are handled in
   the event tap, so none of the swipe or its coasting reaches the page underneath.
3. **Back:** clicking the handle, or dragging or swiping it inwards, fades the handle and slides the
   small window out to the edge, where it grows back to its full size over 0.2 s. (Growing it
   behind the tab isn't possible on the left side, because macOS resizes windows from the top-left
   corner, which would briefly show the video.) Zen adjusts each size it's given a moment later,
   so after the many sizes of the grow an older one can land last; ZenPiP checks the size once
   things have settled and puts it right. It also comes back to exactly the size it was asked for
   last time, so Zen's rounding doesn't shrink it a point with every stash.

### Keeping it parked

ZenPiP checks the parked window 20 times a second (asking where one window is costs next to nothing),
because macOS can put it back on screen at any moment: after space switches, and sometimes just when
you switch tabs in the browser. Checking that often tucks it away again before it's more than a
glimpse. If it was closed, the handle goes. If it was moved or resized, what happens depends on where
it is (`Stash.check`):

- **Off every display:** when you switch spaces, macOS slides windows with the space and reports
  them far off-screen for a moment. ZenPiP waits.
- **Still moving:** the same slide passes across the screen. ZenPiP waits until the window has stayed
  put for 0.2 s.
- **Left somewhere else:** after some switches between a full-screen app and a desktop, macOS puts a
  mostly off-screen window fully back on screen. ZenPiP parks it again; the handle stays as it is.
  When macOS puts it back in one go, flush against the edge at the same height, that's clear
  straight away, so it's parked again without waiting for it to stay put.

Twice a second ZenPiP also makes sure the handle itself is on screen and in front of the window.
The handle's window is set to show on every space and with every app's windows, but after a while
macOS can keep it to one space (Stage Manager seems to tie it to a stage), and then it can't be shown
anywhere else. So every stash gets a new handle window, and if a handle ever goes missing, a new one
takes its place; if the PiP ends up above it, it's brought back to the front.

A park only counts once macOS has left the window as a sliver at the edge, at the right height, for
at least two looks in a row; a window put back on screen is never taken for a parked one. macOS
putting it back flush against the edge is normal and never counts against it. But if something else
keeps putting the window back within 3 s of it being parked, in the same place each time and
with no space switch to explain it (another window manager, say), ZenPiP stops after the third time:
it brings the window back properly and doesn't stash at that side for 10 minutes. Any of this waits
while a space switch is under way, which ZenPiP can tell because macOS then reports even its own tab
somewhere else.

If a PiP is ever found as a sliver at a side with no tab (Zen reopening a PiP where the last one
was, say, or a PiP leaving full screen going back to where it was), ZenPiP tucks it away properly,
with its tab. (If another PiP is already tucked away, or that side is blocked, it's put back on
screen at that edge instead.) It looks for that every 2 s and after space switches, and only acts
once the window has been there for a moment, so one sliding past with a space switch is left alone.

### Stage Manager

Stage Manager keeps the left edge of each display for its strip of recent apps. A small window
moved there, or left mostly off the left edge, is pushed straight back out to the right of the strip.
Big windows can rest against the edge, so a normal-sized PiP at the left edge is fine, but a parked
one can't stay. So while Stage Manager is on, a push or flick to the left just lands the window at
the edge, and only the right edge stashes.

It won't stash towards a side where another display sits, since the window would just appear
there. If a PiP is closed while stashed, Zen usually sees its last position is off-screen and opens
the next PiP in its usual default spot; if it reopens one as a sliver where the stashed one was,
ZenPiP tucks that away (see [Keeping it parked](#keeping-it-parked)).

## Click-and-drag throws

When you click and drag the PiP with the mouse or a trackpad click, the browser moves the window itself. ZenPiP records the pointer positions while the button is down and, when it comes up, checks whether the PiP actually moved:

- **It didn't move** (a click on play, pause and so on): nothing to do, unless it interrupted a flight.
- **It moved, fast:** a throw, with the same rules as a flick. If macOS ever withholds the drag's pointer positions, the speed is worked out from how far the window moved and how quickly.
- **It moved, slowly:** a set-down, which also brings it back on screen if it was left over an edge.

⌘-drag is left to the browser's own snap-to-corner (a Firefox feature Zen inherits), and the pointer is never moved, since your hand is on it.

## Spaces and the Dock

On a normal desktop the PiP keeps clear of the Dock. In a full-screen app or Split View the Dock is hidden, so it can go all the way to the bottom. ZenPiP asks macOS which kind of space is showing on each display with `CGSManagedDisplayGetCurrentSpace` and `CGSSpaceGetType`.

After a space switch (and after waking, unlocking, or a display change), ZenPiP looks twice: once when the switch has settled (0.3 s) and once more in case the first look was mid-animation (1.2 s). For each PiP window, `ScreenArea.destinationAfterSpaceChange` decides where it goes:

- **Resting on the bottom edge of the old kind of space:** it follows the bottom edge of the new one. This includes a PiP still where Zen first opened it, flush in the corner.
- **Anywhere else:** it stays put, unless it would now sit under the Dock, in which case it moves up just enough.

Windows are moved one at a time, and the check waits while you're swiping or dragging. It also waits
until each window has stopped moving, and leaves alone a window that's mostly off the display: a PiP
leaving full screen, or sliding with the switch (especially while you hold a swipe halfway), is still
being moved by macOS, and moving it then would send it somewhere odd or leave it at an in-between size.

## Staying out of the way

- **App Nap:** macOS slows background apps down to save energy, which makes animations choppy. ZenPiP opts out of this without stopping the Mac from sleeping, and asks for precise timers only while a window is animating.
- **Idle cost:** when nothing is happening it uses next to no CPU. Its only timer is a check every 2 s that it still has permission and that no PiP is stranded at an edge (see [Keeping it parked](#keeping-it-parked)), and that check can drift by a second. While a PiP is tucked away, the check on it 20 times a second costs about 0.03 ms each time. It uses about 9 MB of memory.
- **Busy browsers:** every Accessibility request gives up after 0.15 s, so a browser busy with a hundred tabs can't stall scrolling elsewhere.
- **Permission removed:** if Accessibility permission is taken away while ZenPiP is running, it exits (an event tap left behind can stall input), and launchd restarts it to wait for permission again.
- **Zen's accessibility engine:** Firefox-based browsers start a heavy accessibility engine when an assistive app explores their web content. ZenPiP only asks for window titles and positions, which the system answers without starting that engine. You can confirm it in Zen at `about:support` → Accessibility → Activated: false.
- **One copy only:** a second ZenPiP exits straight away, so two can't fight over the window.

## Undocumented functions

These are looked up when ZenPiP starts (`PrivateAPI.swift`), so a macOS without them still runs ZenPiP, with reduced features:

| Function | Used for | Without it |
| --- | --- | --- |
| `_AXUIElementGetWindow` | Matching a window in the window list to its Accessibility element | Windows are matched by position and size |
| `CGSMainConnectionID`, `CGSGetActiveSpace`, `CGSManagedDisplayGetCurrentSpace`, `CGSSpaceGetType` | Telling full-screen spaces from normal desktops | Every space is treated as a normal desktop |

## Why the permission resets after a rebuild

macOS ties Accessibility permission to the app's code signature. ZenPiP is signed "ad hoc" (`codesign --sign -`), which needs no Apple developer account but gives every build a different signature. So after rebuilding, the old permission entry no longer matches the new app: remove it and add the app again. A build signed with an Apple Developer ID would keep its permission across updates.

## Known limitations

- **The on-video PiP button can't be moved.** Its position is part of Firefox's video controls, so the recommended setting hides it instead.
- **One window animates at a time.** With two PiP windows, a throw on one finishes any animation on the other first.
- **The PiP disappears for a moment during a desktop switch.** Zen's PiP shows on every desktop, and macOS hides such windows while it animates a switch, showing them again at the end. Nothing outside Zen can change that; Safari's PiP stays put because it's macOS's own Picture-in-Picture, not an ordinary window.
- **A stashed PiP can be glimpsed now and then.** macOS sometimes puts the parked window back on screen (after space switches, and sometimes when you switch tabs). ZenPiP checks 20 times a second and tucks it away again at once, but it can't stop macOS doing it.
- **Only one PiP is stashed at a time.** Stashing a second one puts the first back at its edge, and a second PiP found as a sliver while one is stashed is put back on screen.
- **Stashing doesn't know about a Dock at the side.** With the Dock on the left or right, a tab at that side can sit over it.
- **Throws stay on the display they started on.** A throw doesn't cross to another display; drag the window there instead.
- **If the browser resizes the PiP** (for example, when the video changes shape), ZenPiP doesn't notice until the next gesture or space switch.
- **Chrome-family browsers are untested.** Their video PiP windows should be recognised by title. Document Picture-in-Picture windows, such as Google Meet's, have a different title and are deliberately left alone.
