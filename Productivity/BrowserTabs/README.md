# Browser Tabs

Your open browser tabs and your bookmarks in the palette. Search Browser
Tabs lists every tab in Safari, Chrome, Arc, Brave and Edge while they run;
type part of a title or address and Return switches to it (⌘W closes it,
⌘⇧C copies the link). Search Bookmarks finds the bookmarks Chrome, Brave,
Edge and Vivaldi keep in every profile, and opens one in its browser.

- **Needs:** running `osascript` to read and switch tabs (macOS asks once to
  let Stackbar control each browser), `cat` to read each Chromium browser's
  `Local State` and each profile's `Bookmarks` file in its folder, and the list of running apps, so a
  browser that isn't open is never started. Stackbar 0.36.0 or later.
- **Surfaces:** panel (the open tabs).
- **Commands:** Search Browser Tabs, Search Bookmarks.
- **Leaves out:** Safari's bookmarks, which macOS keeps behind Full Disk
  Access, and Arc's sidebar.

## What's new in 1.4.0

- Search Browser Tabs opens at once. It shows the tabs it already knows and reads them again in the background, and the list updates when that read finishes. Before, every open waited for every browser to answer.
- Reading tabs is faster. Each browser is asked for all its titles and addresses at once, instead of twice for every tab.
- Switching to a tab no longer reads every tab first. The switch checks that the page is still in that spot, and reads again only if it moved.
- Tabs are read again in the background when you leave a browser, so the next search starts from a fresh list.

## What's new in 1.3.0

- Search Bookmarks reads every browser profile, not just the first one. If you use Chrome, Brave, Edge or Vivaldi with a second profile (a work sign-in, say), its bookmarks show up too, with the profile's name beside each one. Stackbar asks you to approve the plugin again, because it now reads the browser's whole folder instead of one profile.
- A very large bookmark set no longer loses bookmarks quietly. Up to 20,000 are kept (it was 5,000 per browser), and past that the panel says how many were left out.

## What's new in 1.2.1

- Search Browser Tabs lists your tabs again. It said "No tabs open" for every browser, because the script that reads them wrote the word "tab" where it meant a tab character.

## What's new in 1.2.0

- Close Tab says outright that it closes at once, so Stackbar doesn't ask.
- Stackbar 0.35.0 now asks for the second press itself, the same way in the panel, the palette and every window, and VoiceOver reads the question.

## What's new in 1.1.0

- Switching to or closing a tab checks that it's still the same page first. After you rearrange tabs, Close no longer closes a different tab, and a tab that has gone says so.
- Copy as Markdown Link on every tab and bookmark.
- When a browser doesn't answer, or its bookmarks can't be read, the panel says which one instead of showing nothing.
- Tabs from the panel no longer show up in the palette's results with out-of-date titles.
- A page title with a tab in it no longer breaks that tab's address.

## What's new in 1.0.1

- Tabs are read from every running browser at the same time, so one slow browser no longer holds up the rest.
- Bookmark search is lighter on big bookmark sets.
- A bookmarks file too large to read now says so instead of showing no bookmarks.

## What's new in 1.0.0

- First release.
