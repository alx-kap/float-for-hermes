# Float for Hermes

**A native macOS quick-chat for your Hermes agent.** Press a hotkey, ask something, get an answer, and get back to what you were doing.

Float is a small floating panel that lives in your menu bar and talks to your own Hermes gateway. Think Spotlight or Raycast, but the thing answering is your agent, with your tools, your memory and your models.

It is not a replacement for the Hermes desktop app. When you want the full workspace, use that. Float is for the other 90% of the time: the quick question, the one-off task, the "hey, can you just…" that shouldn't require switching apps and finding the right window.

## Why it exists

Most of the time you don't want to open an app to talk to your agent. You want to be in the middle of something else, hit a key, type a line, and see the answer without losing your place. Float is built around that moment, and it tries to feel like it shipped with the Mac:

- **One hotkey.** `⌥Space` by default, changeable in Settings. Esc puts it away.
- **Liquid Glass.** A translucent panel that floats over whatever you're working on and follows your light or dark appearance.
- **Keyboard first.** Send, stop, new chat, search past chats, dictate and attach files without touching the mouse.
- **Lives in the menu bar.** No Dock icon, no window to hunt for. It quietly notifies you when a reply is ready.

## What it does

- Chat with your Hermes agent, with streaming replies, tool steps shown inline, and Markdown that renders properly (tables, callouts, syntax-highlighted code).
- Switch between Hermes **profiles** and **models** from the header.
- Search, rename, archive and resume **past conversations** with ⌘K.
- **Voice**: dictate a message (⌘D) or go hands-free (⇧⌘D). It listens, sends when you pause, speaks the reply, then listens again. Speech recognition runs on-device with Apple's `SpeechAnalyzer`.
- **Attach** files and images by dragging them in, pasting, or ⌘O. Images and files that Hermes sends back show up inline, with save, open in Preview and copy.
- Answer the agent when it **asks you something**: approvals for risky commands, clarifying questions, password and secret prompts.
- **Retry, regenerate and edit** the latest message. Messages typed while you're offline wait and send when the connection returns.
- A **context ring** in the header shows how full the context window is, with a token breakdown one click away.
- Slash commands with autocomplete, just type `/`.

## Requirements

- A Mac running **macOS 26 (Tahoe)** or later
- **Xcode 26+** only if you build from source. The prebuilt download doesn't need it
- A running **Hermes gateway** you can reach, such as the one the Hermes desktop app connects to. Over [Tailscale](https://tailscale.com) works great for reaching your agent from anywhere.

## Install

### Option 1: Download the app (no Xcode needed)

1. Download `Float.zip` from the [latest release](../../releases/latest) and unzip it.
2. Drag **Float.app** into your Applications folder.
3. Open it. The first time, macOS will say it can't verify the app, because Float isn't notarized by Apple (that needs a paid developer account, and this is a free open-source project). To allow it, **right-click Float.app › Open › Open**, or go to **System Settings › Privacy & Security** and click **Open Anyway**.

Or do it all in Terminal:

```bash
curl -L -o /tmp/Float.zip https://github.com/<your-username>/float-for-hermes/releases/latest/download/Float.zip
unzip -q -o /tmp/Float.zip -d ~/Applications
xattr -dr com.apple.quarantine ~/Applications/Float.app
open ~/Applications/Float.app
```

### Option 2: Build it yourself

```bash
git clone https://github.com/<your-username>/float-for-hermes.git
cd float-for-hermes
./install.sh
```

That builds a Release copy into `~/Applications/Float.app` and launches it. It checks for Xcode 26+ and installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) through Homebrew if it's missing. Run it again any time to update. Because you built it yourself, macOS doesn't show the security warning.

### Using an AI agent?

Point it at this repo and say "install Float". [AGENTS.md](AGENTS.md) has exact, copy-pasteable steps.

## Getting started

1. Launch Float. You'll see its icon in the menu bar.
2. Float finds your gateway from the Hermes desktop app's connection settings. If you don't use the desktop app, or want a different gateway, set the URL in **Settings › Connection**.
3. Sign in. Float uses the same browser and PKCE flow as the Hermes desktop app (RFC 8252), so your password only ever goes into your gateway's own login page. Tokens are stored in the macOS Keychain and refresh on their own.
4. Hit `⌥Space` and start typing.

## Shortcuts

| Action | Shortcut |
|---|---|
| Show / hide Float | `⌥Space` (change it in Settings) |
| Send | `↩` |
| Slash commands | Type `/`, then ↑↓ to choose, `↩` to run, `⇥` to add arguments |
| Stop the current reply | `⌘.` |
| New chat | `⌘N` |
| Past chats | `⌘K` |
| Regenerate the last reply | `⌘R` |
| Dictate one message | `⌘D` |
| Hands-free voice mode | `⇧⌘D` |
| Attach files or images | `⌘O`, drag and drop, or paste |
| Dismiss | `Esc` |

## How it's built

Float is a plain SwiftUI and AppKit app with no third-party dependencies. It speaks JSON-RPC over a WebSocket to the Hermes gateway.

```
Float/
  project.yml          XcodeGen spec (generates the Xcode project)
  Sources/App          App entry, menu bar, floating panel, hotkey, preferences
  Sources/Gateway      PKCE sign-in, Keychain, JSON-RPC WebSocket client
  Sources/Chat         Session and stream state, attachments, approvals
  Sources/Voice        SpeechAnalyzer listening and speech output
  Sources/UI           SwiftUI views: glass panel, messages, Markdown, composer, settings
```

See [ROADMAP.md](ROADMAP.md) for what's done and what's next.

## FAQ

**Is this an official Hermes app?**
No. Float is an independent, community-made client. It's not affiliated with or endorsed by Nous Research.

**Does it work without a Hermes gateway?**
No. Float is only a front end, so it needs a Hermes agent to talk to.

**Why not just use the Hermes desktop app?**
You should, for the full experience. Float is the lightweight companion for quick questions from anywhere on your Mac.

**Does my data go anywhere other than my gateway?**
No. Float only connects to the gateway you point it at. Voice transcription happens on your Mac.

## Contributing

Issues and pull requests are welcome. If you're changing the UI, the bar is simple: it should feel like it belongs on a Mac.

## License

[MIT](LICENSE)

---

<sub>Keywords: Hermes Agent client for macOS, Hermes quick chat, menu bar AI assistant, global hotkey AI chat, native SwiftUI macOS app, Liquid Glass, Tailscale, self-hosted AI agent, Nous Research Hermes.</sub>
