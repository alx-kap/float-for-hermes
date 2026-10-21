# Installing Float for Hermes (instructions for AI agents)

Float is a native macOS menu bar app: a global-hotkey quick-chat panel for a Hermes agent. If a user asks you to install it, do this.

## Requirements
- macOS 26 (Tahoe) or later. Check with `sw_vers -productVersion`. Stop and tell the user if it's older.
- A reachable Hermes gateway (the user signs in inside the app; you don't need credentials).

## Fastest: install the prebuilt app
```bash
curl -L -o /tmp/Float.zip https://github.com/<your-username>/float-for-hermes/releases/latest/download/Float.zip
unzip -q -o /tmp/Float.zip -d ~/Applications
xattr -dr com.apple.quarantine ~/Applications/Float.app
open ~/Applications/Float.app
```
The app is ad-hoc signed, not notarized. Removing the quarantine flag as above avoids the Gatekeeper prompt.

## Or build from source
Requires Xcode 26+ (`xcodebuild -version`). The script installs XcodeGen via Homebrew if needed.
```bash
git clone https://github.com/<your-username>/float-for-hermes.git
cd float-for-hermes
./install.sh
```

## After installing
- Float lives in the menu bar (no Dock icon). The default hotkey is Option+Space.
- It finds the gateway from the Hermes desktop app's connection settings, or the user can set it in Settings › Connection.
- The user must complete sign-in in their browser and may need to grant microphone and notification permissions. Tell them to do this; don't try to automate it.

## Developing
- `Float/project.yml` is the XcodeGen spec; the `.xcodeproj` is generated and git-ignored.
- `./release.sh` builds `dist/Float.zip` for a GitHub release.
- No third-party dependencies. See README.md for the source layout.
