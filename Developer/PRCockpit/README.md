# PR Cockpit

Your pull requests and the ones waiting on your review, with CI, review state
and merge conflicts, in the menu bar; the issues assigned to you; and your
repositories and new issues from the palette. It tells you when someone asks
for your review, when an issue is assigned to you, and when one of your own
pull requests is approved, gets changes requested, or fails its checks.

The separate GitHub plugin is now part of PR Cockpit. If you had it, you can
uninstall it: its repositories, assigned issues and Create GitHub Issue are
all here, with the same sign-in.

- **Needs:** network access to `api.github.com` only, and one of two ways to
  sign in, chosen on the Settings page: a `GITHUB_TOKEN` secret kept in the
  Keychain (the default), or, with **Sign in with gh** on, the gh
  command-line tool (`gh auth login`; the plugin reads its token itself,
  nothing to paste). Only the chosen one is read. A classic token needs the `repo` and
  `read:org` scopes (`read:org` finds review requests to your teams); gh's
  usual scopes cover all of it. A fine-grained token sees one owner's
  repositories only, so for an organization's pull requests make it with the
  organization as the resource owner, with read access to pull requests,
  issues and metadata (creating issues needs write access to issues). Approving, merging, auto-merge
  and Mark Ready for Review need write access to pull requests (merging also
  needs contents write). Mark as done in the inbox needs the notifications
  scope (`gh auth refresh -s notifications`, or a classic token). Running
  gh lets PR Cockpit do anything gh can, including `gh api` to any
  endpoint, gists and extensions; Stackbar shows that grant on the install
  sheet, and the plugin only ever runs `gh auth token`. On GitHub
  Enterprise Server, turn it on in Settings and enter the server as
  `GITHUB_ENTERPRISE_URL` (always needed); for the token, paste that
  server's token as `GITHUB_TOKEN`, or with Sign in with gh, sign in to that
  server with gh (`gh auth login --hostname <server>`). Requests go to that server and no
  other.
- **Checks on click:** click a pull request to see each check under it:
  failures first with the step that failed and its first errors, which
  checks are required, how long each took, and the commit's deployments
  with their preview links. While checks run they refresh every 20
  seconds. Re-run failed jobs (or all of them) from there, open a job's
  log, or copy a summary of what failed. Settings can make a click open the
  browser as before; ⌘↩ always does. Re-running needs a token with Actions
  write access. In the palette, a selected pull request shows its checks
  beside the list, fetched in the background for the ones whose checks
  changed (a setting turns this off); ⌘I opens them in full.
- **Your own pull requests:** merge one that is approved with green checks
  the way its repository's merge button does (squash, rebase or a merge
  commit), turn on auto-merge for one still waiting on reviews or checks so
  GitHub merges it by itself, or take a draft out of draft. Stackbar asks for
  a second press first, naming the pull request.
- **View Diff:** ⌘D on any pull request lists the files it changes, with each
  file's diff beside the list.
- **Surfaces:** menu bar, panel (To review, Mine, Issues and an optional
  Inbox), window, widget, settings.
- **Missing pull requests:** GitHub's search leaves out, without a word,
  pull requests your sign-in isn't let see: an organization with single
  sign-on the token isn't authorized for, or one that hasn't approved the
  GitHub CLI app gh signs in with. PR Cockpit checks what GitHub says it left
  out and names the organization and the fix above the lists. Add a
  repository under Settings › Missing pull requests? (or Always Check Its
  Pull Requests on it in Search GitHub Repositories) and its open pull
  requests are read directly on every refresh, so yours and the ones asking
  you or your teams to review show up even when search misses them, and a
  repository GitHub refuses says why.
- **Settings:** include team review requests, include drafts, how recently a
  pull request or issue must have changed to show (any age, or the last week
  to three months), notifications, repositories (include archived, copy clone
  URLs as SSH or HTTPS, reload), repositories to hide, and the inbox view.
- **Commands:** Search Pull Requests (each row also copies a `gh pr checkout`
  command), Review Queue, Open Next Review, Search
  GitHub Repositories (yours first, recently opened on top, then GitHub
  search; each row opens the repository, its pull requests, issues or
  Actions, copies the clone URL, or starts a new issue), My GitHub Issues,
  GitHub Inbox (Mark as read, Mark as done, Mark All as Read), Create GitHub Issue, Refresh Pull
  Requests.
- **Agent tools:** `review_queue`, `my_pull_requests` and `my_issues`.

## Highlights

### Why it failed, without opening the browser
Click a pull request to see its checks, the step that failed and the error,
and its preview deploy. Re-run the failed jobs right there.
<!-- preview: checks -->

### Everything waiting on your review
Every pull request waiting on you, with its CI, review state and conflicts.
Open the next one with a single command, or snooze one until it changes.

### Your own pull requests at a glance
See which of yours passed their checks, got approved or need changes, and get
a notification the moment that changes.
<!-- preview: mine -->

### All of GitHub from the palette
Search your repositories (recently opened first), jump to their pull
requests, issues or Actions, copy a clone URL, or start a new issue.

### Everything in one window
Both lists side by side, what merged or closed in the last two days, and
how long reviews have waited.
<!-- preview: dashboard -->

### On your desktop too
A widget keeps the review queue in view.
<!-- preview: widget -->

## What's new in 1.18.1

- Switching tabs in the panel works every time. A click made while PR Cockpit was refreshing used to be ignored when the refresh changed a tab's count, so nothing happened. The tabs no longer show counts; the To review and Mine numbers stay at the top of the panel.

## What's new in 1.18.0

- Missing pull requests from your organization? PR Cockpit now says why: an organization whose single sign-on your token or gh isn't authorized for, a missing read:org scope for your teams' review requests, or a fine-grained token that can't see the organization, with the fix.
- Repositories to always check: add one in Settings (or from Search GitHub Repositories) and its open pull requests are read directly on every refresh, beside the search, so yours and the reviews asked of you or your teams show even when search misses them. A repository GitHub refuses says why.
- Search Pull Requests shows the matching pull requests already in your lists at once as you type, then GitHub's, which now include review requests to your teams.

## What's new in 1.17.0

- The palette's preview shows a pull request's checks in color: each check with its state, failures first, then deployments. Stackbar 0.38 and older still show the text.

## What's new in 1.16.0

- Sign in with gh: turn it on in Settings and PR Cockpit uses the gh command-line tool's sign-in (`gh auth login`), with nothing to paste. It reads the token itself with `gh auth token`, kept for five minutes, not once per request. A pasted `GITHUB_TOKEN` stays the default.
- Stackbar now asks to let PR Cockpit run gh. It only ever runs `gh auth token`.
- On GitHub Enterprise Server, gh's token is read for that server's host (`gh auth login --hostname <server>`).
- Try Again and Refresh Pull Requests ask gh again at once, so signing in takes effect without waiting.
- Hints about token access now cover both a pasted fine-grained token and gh's scopes.

## What's new in 1.15.0

- Type `pr`, a space and text in the palette to search pull requests straight away. Change or clear the alias in Settings › Commands.

## What's new in 1.14.0

- When your organization uses SAML single sign-on, PR Cockpit says to authorize the token for it (Configure SSO on github.com), instead of a bare 403.
- Signed in to the gh command-line tool? The empty state tells you how to reuse its token: `gh auth token | pbcopy`.

## What's new in 1.13.0

- Merge your own pull request from the panel or the palette once it is approved with green checks, the way its repository merges (squash, rebase or a merge commit).
- Enable Auto-Merge on one still waiting on reviews or checks, and GitHub merges it by itself; the row says Auto-merge while it is on.
- Mark Ready for Review takes one of your drafts out of draft.
- View Diff (⌘D) lists the files a pull request changes, with each diff beside the list.
- Copy checkout command copies `gh pr checkout` for the pull request.
- Mark as done (⌘E) in the inbox takes a notification out of GitHub's inbox, as Done does on github.com.

## What's new in 1.12.0

- Approve, Mark All as Read and the re-run actions ask through Stackbar, naming what they do.
- Stackbar 0.35.0 now asks for the second press itself, the same way in the panel, the palette and every window, and VoiceOver reads the question.

## What's new in 1.11.0

- The palette shows a pull request's checks beside the list as soon as you select it. Your listed pull requests' checks are fetched in the background, in one request and only for those whose checks changed. A setting turns this off.

## What's new in 1.10.0

- Click a pull request to see its checks and deployments under it: what failed and why (the failing step and its first errors), which checks are required, how long each took, and preview links. Running checks refresh every 20 seconds while you look.
- Re-run failed jobs, or all of them, from the checks (press twice). Needs a token with Actions write access.
- Copy a summary of what failed, to paste into a chat or an issue.
- In the palette, ⌘I on a pull request opens its checks, and a selected pull request shows them beside the list once loaded.
- A setting keeps the old click, which opens the browser. ⌘↩ opens it either way.
- Needs Stackbar 0.35.0 or later.

## What's new in 1.9.0

- GitHub Inbox in the palette, and Mark All as Read there and in the panel's Inbox tab (press twice to confirm).
- Approve a pull request straight from your review queue.
- Approve asks for a second press within 10 seconds, so a stray click doesn't approve anything.
- Switching to another GitHub token no longer announces everything on the new account as new, and its repositories replace the old ones at once.
- Many merges or mentions at once arrive as one notification instead of a burst.
- The window shows how to connect GitHub instead of empty lists, and a failed Mark as Read says so.
- The review and Mine lists say when they show only the 40 most recent.
- Agent tools report a missing token instead of "nothing waiting", and pull request search gives up on a slow GitHub sooner.

## What's new in 1.8.1

- Mentions in your inbox are announced even when the inbox was empty before.
- Clicks wait less behind a slow GitHub: refresh requests give up after 10 seconds.
- Assigned issues load past the first page (up to 300), and a failed repository search says so instead of showing nothing.
- The repository and issue lists, and pull request search, no longer ask GitHub again on every keystroke.
- Mark all as seen saves once instead of once per pull request.
- Slow GitHub responses get 20 seconds before they count as a failure, repository searches are remembered for five minutes, a failed issue list waits 30 seconds before trying again instead of retrying per keystroke, and changing your token retries the repository list at once.

## What's new in 1.8.0

- GitHub Enterprise Server: turn it on in Settings and enter your server's address. Pull requests, issues, the inbox and search all come from it.
- Updating asks once more for approval, because the plugin can now reach an Enterprise server you enter.

## What's new in 1.7.0

- Type owner/repo or repo#123 in the palette to jump straight to the repository or pull request.

## What's new in 1.6.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.5.0

- Switching tabs is quicker: a refresh now fetches pull requests, issues and
  the inbox side by side instead of one after another, and a click no longer
  waits as long behind it.
- A new **Updated within** setting shows only pull requests and issues
  changed in the last week, two weeks, month or three months, and fetches
  only those pull requests.
