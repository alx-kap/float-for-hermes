# Hermes Quick roadmap

Gaps found in a review on 2026-10-20, most important first. Tick items off as they land, and add notes on what was decided.
The bar for every item: it should feel native, polished and intuitive (system idioms, keyboard-first, no dead ends), and be checked in the running app.

## High impact

- [x] **1. Past conversations.** ⌘K list of stored chats (`session.list`/`session.resume`), search, archive/delete, rename via the header title, "Open Recent" in the menu bar, richer restored history. Built 2026-10-20. Still to check by hand: typing in search and arrow keys, rename, archive, delete, the menu-bar submenu.
- [ ] **2. Answer other gateway prompts.** `ChatStore.handleServerRequest` only handles `approval`. Every other server request (clarifying questions, sudo/secret prompts, choice pickers) is refused with "use the Hermes app", so the turn stalls or fails. Add inline cards for them, like `ApprovalCard`. Check `tui_gateway` (`~/.hermes/hermes-agent/tui_gateway`) for the method names and payloads.
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
