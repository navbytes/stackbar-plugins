# Slack

Slack in the menu bar and the palette. The number in the menu bar is how many
unread messages wait in the conversations you watch (it turns orange when one
is a direct message, and shows a moon while notifications are snoozed); the
panel lists them, newest first, with Open, Mark as Read and Reply.

- **Needs:** `slack.com` and the secret `SLACK_TOKEN`, a Slack user token
  (`xoxp-…`) from a Slack app you create in your workspace (below). It opens
  `slack:` links to jump into the Slack app.
- **Surfaces:** menu bar, panel, settings.
- **Commands:** Search Slack Messages (alias `sl`; Slack's own search syntax
  such as `in:#channel` and `from:@person` works), Open Slack Channel
  (channels, group messages and people; ⌘W watches one), Slack Unread
  Messages, Send Slack Message, Set Slack Status (presets or your own text,
  emoji and when to clear it), Clear Slack Status, Snooze Slack
  Notifications (20 minutes to tomorrow morning, or off), Set Slack Presence
  (away or automatic) and Search Slack Emoji (your workspace's custom emoji).
- **Watched conversations:** pick up to 30 channels and people, in Settings or
  with ⌘W in Open Slack Channel. Each is checked every two minutes, two
  requests apiece, so the plugin stays well inside Slack's limits.
- **Settings:** watched conversations, open links in the Slack app or the
  browser, notifications for new messages in watched conversations (off by
  default), and the server: slack.com, or another address such as
  `slack-gov.com` for GovSlack or a company gateway (`SLACK_API_URL`).

## Setting up your token

Slack tokens belong to a Slack app, so you create a small private one in your
own workspace. It takes about three minutes, and nothing leaves your Mac
except requests to Slack.

1. Open [api.slack.com/apps](https://api.slack.com/apps), choose **Create New
   App**, then **From a manifest**, and pick your workspace.
2. Paste the manifest below, then **Create**.
3. Choose **Install to Workspace** and allow it. If your workspace needs an
   admin to approve apps, Slack sends them the request.
4. Under **OAuth & Permissions**, copy the **User OAuth Token** (it starts
   with `xoxp-`) and paste it when Stackbar asks for `SLACK_TOKEN`.

```yaml
display_information:
  name: Stackbar
  description: Slack in your Mac's menu bar and command palette.
oauth_config:
  scopes:
    user:
      # Your channels, group messages and direct messages, and people's names
      - channels:read
      - groups:read
      - im:read
      - mpim:read
      - users:read
      # Unread messages in watched conversations
      - channels:history
      - groups:history
      - im:history
      - mpim:history
      # Mark as Read, and starting a direct message
      - channels:write
      - groups:write
      - im:write
      - mpim:write
      # Search Slack Messages
      - search:read
      # Send Slack Message
      - chat:write
      # Set and Clear Slack Status
      - users.profile:read
      - users.profile:write
      # Set Slack Presence
      - users:write
      # Snooze Slack Notifications
      - dnd:read
      - dnd:write
      # Search Slack Emoji
      - emoji:read
settings:
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
```

You can leave out the groups of scopes for commands you won't use; that
command then says which scope it is missing.

## What's new in 1.0.1

- Slack Unread Messages opens at once with the messages already fetched, and checks Slack again behind them when they are more than 15 seconds old. Before, every open and every keystroke waited for Slack to answer.

## What's new in 1.0.0

- First release: unread messages from the conversations you watch in the menu bar and panel, message search, a channel and people switcher, sending messages, status, snooze, presence and custom emoji from the palette.
