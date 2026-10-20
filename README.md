# Hermes Quick

A native macOS quick-chat for your Hermes agent: a global hotkey brings up a Liquid Glass panel that talks to your remote Hermes gateway over Tailscale.

## Install / update

```bash
./install.sh
```

This builds a Release copy into `~/Applications/Hermes Quick.app` and launches it. The app lives in the menu bar (⚡). It needs Xcode 26+ and `xcodegen` (`brew install xcodegen`).

## Use

| Action | Shortcut |
|---|---|
| Show / hide panel | ⌥Space (change it in Settings) |
| Send | ↩ |
| Slash commands | Type `/` for suggestions: ↑↓ choose, ↩ run, ⇥ insert to add arguments, esc close |
| Stop the current turn | ⌘. |
| New chat | ⌘N |
| Past chats | ⌘K, or the clock button: type to search, ↑↓ choose, ↩ open, esc back. Right-click a chat to archive or delete it; double-click the title in the header to rename. Recent chats are also in the menu bar |
| Dictate one message | ⌘D |
| Hands-free voice mode | ⇧⌘D |
| Attach files or images | ⌘O, drag and drop (Finder, Safari, Photos, screenshots), or ⌘V a copied file or image |
| Move the panel | Drag the header, the grabber at the top, or the empty space around the input |
| Dismiss | Esc |

- **Gateway:** the app reads your Hermes desktop app's remote URL from `~/Library/Application Support/Hermes/connection.json` (currently `your gateway URL`).
- **Sign-in:** the same RFC 8252 browser + PKCE flow the Hermes desktop app uses. Your password only goes into the gateway's own login page. Tokens are stored in the Keychain and refresh automatically.
- **Bots and models:** the header pills switch between Hermes profiles (`profiles.list`) and models (`model.options` / `config.set model`).
- **Voice:** Apple's on-device `SpeechAnalyzer`/`SpeechTranscriber` for listening, and the macOS system voice for spoken replies. In voice mode it listens, sends when you pause, speaks the reply, then listens again. Tap the orb to interrupt. For a more natural voice, set System Settings › Accessibility › Read & Speak › System voice to a Siri voice. macOS hides Siri voices from third-party speech APIs, so replies are spoken through the system voice (`/usr/bin/say`).
- **Images and files from Hermes:** when a reply mentions a file on the gateway (a path, `MEDIA:` line or Markdown image) or an image URL, it is downloaded with your sign-in and shown inline. Hover or right-click to save or open in Preview; other files appear as chips that download and open.
- **Approvals:** when Hermes asks to run a risky command, an inline card lets you allow or deny it.

## Layout

```
HermesQuick/
  project.yml            XcodeGen spec (generates the .xcodeproj)
  Sources/App            App entry, menu bar, floating panel, hotkey, preferences
  Sources/Gateway        PKCE sign-in, Keychain, JSON-RPC WebSocket client (/api/ws)
  Sources/Chat           Session and stream state, attachments, approvals
  Sources/Voice          SpeechAnalyzer listening and speech output
  Sources/UI             SwiftUI views (glass card, messages, markdown, composer, voice orb, settings)
```
