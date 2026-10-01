# Drafty

A menu bar app that checks Slack and Gmail every 3 minutes for messages waiting on you. When one needs an answer, it notifies you and has Claude Opus 5.5 draft a reply. You edit the draft and send it from the popover, ask Claude to redraft it (optionally with a comment like "decline politely"), or dismiss it.

## Build

```sh
./build.sh
open build/Drafty.app   # or move it to /Applications first if you want "Open at login"
```

Drafts are written by your installed Claude Code (`claude -p`), so they use your Claude subscription. You need to have run `claude` once to log in. The first launch opens Settings, where you connect Slack, Gmail or both.

## Slack

1. Go to https://api.slack.com/apps and choose **Create New App**, then **From a manifest**. Pick your workspace and paste:
   ```yaml
   display_information:
     name: Drafty
   oauth_config:
     scopes:
       user: [search:read, channels:history, groups:history, im:history, mpim:history, users:read, chat:write]
   settings:
     org_deploy_enabled: false
     socket_mode_enabled: false
     token_rotation_enabled: false
   ```
2. Click **Install to Workspace**. Then copy the **User OAuth Token** (`xoxp-…`) from *OAuth & Permissions* into the app.

Replies are posted as you. Channel mentions get their reply in a thread.

## Gmail

1. In the [Google Cloud console](https://console.cloud.google.com), create a project and enable the **Gmail API**.
2. Under **Google Auth Platform → Audience**, choose **Internal**. That limits it to your Workspace, so it needs no app verification and the refresh token doesn't expire after 7 days.
3. Under **Clients**, create an OAuth client of type **Desktop app**.
4. Paste the client ID and secret into the app and click **Connect**. Sign-in happens in your browser.

The app requests the `gmail.modify` scope so it can read mail, send replies, and mark a thread read after you answer it.

## How it decides

- **Slack:** It looks at DMs to you (`to:me`) and @mentions from the last 2 days. A conversation counts as answered when your latest message in it (`from:me`) is newer than theirs.
- **Gmail:** It looks at inbox threads from the last 2 days, skipping Promotions, Social, Updates and Forums, and keeps the ones where the last message isn't yours.
- **Claude:** Each new message goes to Opus 5.5 once, with the surrounding thread, through `claude -p`. Claude decides whether it needs a reply and drafts one in the same call. Claude Code runs with no tools, settings, hooks or MCP servers (`--tools "" --restricted --strict-mcp-config`), since the input is mail from strangers. Write who you are and how you like to sound in **About you**.

In Settings, **Write from my messages** has Claude describe how you write, from your last 500 Slack messages and 40 sent emails, and puts it in About you so drafts sound like you.

An item drops off the list when you reply anywhere (in the app, Slack or Gmail), when a newer message replaces it, or when you dismiss it. Nothing is sent without you clicking **Send**.

The queries and the lookback window are constants at the top of `Slack.swift` and `Gmail.swift`. Settings and tokens are stored in plain text in `~/Library/Application Support/Drafty/state.json`, readable only by your user (0600).
