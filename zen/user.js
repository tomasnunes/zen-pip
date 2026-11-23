// zen-pip: recommended Zen settings for the best Picture-in-Picture experience.
//
// Copy this file into your Zen profile folder (about:support > Profile Folder > Show in Finder)
// as user.js, or add these lines to an existing user.js, then restart Zen.
// Zen applies user.js at every start, so to change one of these later, edit or remove the line
// here rather than in about:config.

// A playing video pops into Picture-in-Picture when you switch to another tab…
user_pref("media.videocontrols.picture-in-picture.enable-when-switching-tabs.enabled", true);

// …and when Zen's window is hidden: you swipe to another desktop or minimise it.
// When you come back, the PiP closes and the video carries on in the page.
user_pref("media.videocontrols.picture-in-picture.enable-when-occluded.enabled", true);

// Hide the PiP button drawn on top of videos. Zen fixes its position partway down the video, and
// with the two settings above you rarely need it. ⌥⌘⇧] still toggles PiP on the current video.
// Leave this line out to keep the button.
user_pref("media.videocontrols.picture-in-picture.video-toggle.enabled", false);

// Let Zen load chrome/userChrome.css from your profile (the glass PiP buttons in zen/userChrome.css).
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);

// Optional: see-through mode lets the PiP window be transparent, which zen/userChrome.css uses to fade
// a new PiP in once its video has had a moment to get going, instead of showing a frozen frame while
// it catches up. A new PiP then appears about half a second later. Remove the // to turn it on.
// user_pref("media.videocontrols.picture-in-picture.seethrough-mode.enabled", true);
