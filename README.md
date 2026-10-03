# Drafty

A menu bar app that checks Slack and Gmail every 3 minutes for messages waiting on you. When one needs an answer, it notifies you and has Claude Opus 5.5 draft a reply. You edit the draft and send it from the popover, ask Claude to redraft it (optionally with a comment like "decline politely"), or dismiss it. The chat button next to ↻ opens a side chat with Claude about the message, to ask about it or add context; ↻ then redrafts using what you told it. The terminal button in the header opens Claude Code in a new Ghostty window (Terminal if you don't have Ghostty), asked to read the channel or email thread for context, with your draft, so you can dig in with your own skills and MCP servers. macOS asks once to let Drafty control the terminal.

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

- **Slack:** It looks at DMs to you (`to:me`), @mentions, and replies in channel threads you've posted in, from the last 2 days. Slack's own system messages are skipped. A conversation counts as answered when your latest message in it (`from:me`) is newer than theirs.
- **Gmail:** It looks at inbox threads from the last 2 days, skipping Promotions, Social, Updates and Forums, and keeps the ones where the last message isn't yours. Automated mail, bulk mail from outside your domain and noreply senders are skipped before Claude sees them.
- **Claude:** Each new message goes to Opus 5.5 once, with the surrounding thread, through `claude -p`. Claude decides whether it needs a reply and drafts one in the same call. Claude Code runs with no tools, settings, hooks or MCP servers (`--tools "" --restricted --strict-mcp-config`), since the input is mail from strangers. Write who you are and how you like to sound in **About you**.

In Settings, **Auto-generate** (under About you) has Claude describe how you write, from your last 500 Slack messages and 40 sent emails, and puts it in About you so drafts sound like you.

**Chat and redraft with tools** (Settings, off by default) lets Claude look things up in the chat, and adds a wrench next to ↻ for redrafting with tools: **Read files** gives read-only access to your home folder (no shell, writing or network), **Full access** runs Claude Code with `--dangerously-skip-permissions`. Both read messages other people wrote, so a crafted message could steer them; Settings explains the risk before either is turned on. Automatic checks never use tools.

## Auto-reply

Off by default. In Settings, a slider sets what Drafty may send on its own: **Acknowledgements** (replies that say nothing new, like "tack" or 👍), **Quick answers** (short answers fully covered by the conversation) or **Routine** (low-stakes replies to colleagues that commit you to nothing new), for Slack, email or both.

Claude writes the reply; [Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev) (TypeSafe, needs an API key) decides what kind of reply it is, with a calibrated confidence, and whether the message came from a bot or agent. A reply only goes out on its own when, in addition:

- it's a DM with a colleague (no channels, no Slack Connect) or an email from your own domain addressed to you,
- it isn't high priority and the draft has no `[placeholder]`,
- Jev is at least 90% sure of the kind and the sender isn't a bot or agent,
- nothing was auto-sent in that conversation in the last hour.

**Dry run** (under the slider) checks the messages in your list right now and shows what would be sent, word for word, or why each one stays with you, without sending anything. The results follow the slider and the Slack / Email setting as you change them.

Each auto-reply waits 60 seconds first, with a countdown on the item and a notification you can cancel from; editing the draft cancels it too. Everything you send from Drafty is listed under the clock icon, with the thread and a link to open it in Slack or Gmail; the ones it sent on its own are marked Auto.

An item drops off the list when you reply anywhere (in the app, Slack or Gmail), when a newer message replaces it, or when you dismiss it. Nothing is sent without you clicking **Send**.

The queries and the lookback window are constants at the top of `Slack.swift` and `Gmail.swift`. Settings and tokens are stored in plain text in `~/Library/Application Support/Drafty/state.json`, readable only by your user (0600).
