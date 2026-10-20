# Hermes Quick roadmap

Gaps found in a review on 2026-10-20, most important first. Tick items off as they land, and add notes on what was decided.
The bar for every item: it should feel native, polished and intuitive (system idioms, keyboard-first, no dead ends), and be checked in the running app.

## High impact

- [x] **1. Past conversations.** ⌘K list of stored chats (`session.list`/`session.resume`), search, archive/delete, rename via the header title, "Open Recent" in the menu bar, richer restored history. Built 2026-10-20. Still to check by hand: typing in search and arrow keys, rename, archive, delete, the menu-bar submenu.
- [x] **2. Answer other gateway prompts.** Built 2026-10-20. `GatewayPrompt` queue in `ChatStore`, cards in `UI/PromptCards.swift`: `clarify` (one question at a time, ⌘1–⌘4 picks, multi-select ticks + Continue, Skip, × dismisses all, or type your own answer in the composer; each answer goes up with `clarify.lock`), and a masked field card for `sudo`, `secret`, `vault.unlock_prompt`, `vault.code` and `vault.save_login`. Approvals use the same queue (⌘1… on its buttons). `request.cancel` removes a card, and `open_requests` from `session.resume` brings back questions that were waiting. Desktop-only bridges (`preview.*`, `terminal.read`, `window.read`, `tour`) answer 4404 so the agent moves on at once; `theme.*`, `setup_beat` get -32601. The message list shrinks (min 160pt) to make room for a card: the panel is a fixed 720pt and content taller than that crashed AppKit in a constraints loop. Checked in the app: single choice, multi-select, typed answer, Skip, sudo card + Skip. Still to check by hand: × dismiss, a vault/secret card, and a reconnect while a question is open.
- [ ] **3. Notify when a reply finishes.** Agent turns can take minutes, and nothing tells you when one is done or an approval is waiting while the panel is hidden. Add user notifications, and maybe a badge on the menu bar icon.
- [ ] **4. Retry, regenerate and edit.** No retry after an error, no "regenerate last reply", no "edit and resend", no ↑ to recall the last prompt. The gateway has `session.undo` and `session.branch*`, which may help.
- [x] **5. Better restored history.** Done as part of 1: tool steps and attachments are kept and the cap is 200 messages. Possible later: load older messages when scrolling to the top.

## Medium impact

- [ ] **6. Send content in from other apps.** A hotkey that sends the selected text, a Services menu entry ("Ask Hermes"), App Intents for Shortcuts and Spotlight, a `hermesquick://` URL scheme, or "attach a screenshot of the current window".
- [ ] **7. Fuller Markdown.** `MarkdownView` only splits text from code blocks. It has no tables, blockquotes or syntax highlighting.
- [ ] **8. Queue messages typed while offline.** A send during a reconnect errors. Queue it and send it once the connection is back.
- [ ] **9. Usage display.** Show tokens, cost and context-window fill (`session.usage`, `session.context_breakdown`).

## Polish

- [ ] 10. A custom hotkey recorder (today there's only the `HotKeyPreset` list).
- [ ] 11. Remember the panel's size, and a "pin on top / don't hide when focus is lost" option.
- [ ] 12. Search inside a chat, and export a chat as Markdown.
- [ ] 13. Tests, and auto-update (updates currently only come from rerunning `install.sh`).
- [ ] 14. The slash menu scrolls itself when hovering near its edge (selection follows hover, and the list scrolls to the selection). Fix it the way `HistoryView` does with `historyScrollRequest`.
