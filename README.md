# QuotaDesk

A small macOS desktop widget that shows how much of your **Codex** (ChatGPT) and **Claude** subscription quota you have used, with reset countdowns and exact reset times.

วิดเจ็ตบนเดสก์ท็อป macOS แสดงโควตาที่ใช้ไปของ Codex และ Claude พร้อมเวลารีเซ็ต รองรับภาษาไทยและอังกฤษ

## Requirements

- macOS 14 or later, with the Xcode command-line tools installed (`xcode-select --install`)
- A Codex and/or Claude **subscription** (an API key won't work)
- The official CLIs used to sign in: [Codex CLI](https://github.com/openai/codex) and [Claude Code](https://docs.anthropic.com/en/docs/claude-code/setup)

## Build and run

```sh
zsh build.sh                                  # installs to ~/Applications/QuotaDesk.app
BUNDLE_ID=com.yourname.quotadesk zsh build.sh   # optional: your own bundle identifier
open ~/Applications/"QuotaDesk.app"
```

Diagnostics, which print only percentages and sanitized errors:

```sh
~/Applications/"QuotaDesk.app"/Contents/MacOS/QuotaDesk --self-test   # offline unit checks
~/Applications/"QuotaDesk.app"/Contents/MacOS/QuotaDesk --check       # live usage read
```

The app is ad-hoc signed by `build.sh`. If you share a prebuilt `.app`, recipients have to right-click → Open the first time (Gatekeeper). Sharing the source and having each person run `build.sh` avoids that.

## Use

- Open **Settings & accounts…** from the widget's `⋯` menu or the menu-bar icon (⌘,):
  - **Language:** System, ไทย or English
  - **Show:** both cards, Codex only or Claude only. A hidden provider isn't read or contacted at all, and with one card the widget becomes narrower.
  - **Time zone:** used for the exact reset times and the "last updated" clock (defaults to the Mac's zone)
  - **Refresh every:** 1, 2, 5 (default), 10, 15, 30 or 60 minutes. The 5-minute default keeps requests well under the providers' rate limits.
  - **Open at login**
  - **Accounts:** connection status, **Sign in** for each provider, and **Check now**
- Under each bar, the widget shows a countdown ("Resets in 4h 32m") and the exact time, e.g. `Tomorrow · Thu 1 Oct 2026 · 02:49` or `พรุ่งนี้ · พฤหัส 1 ต.ค. 2569 · 13:49 น.`.
- Drag the background to move the widget. Use `⋯` → *Float above windows* to keep it on top.
- Percentages are the share of quota **used**.

## Sign-in and privacy

- **Sign in** opens Terminal and runs the provider's own command (`codex login` / `claude auth login`). You enter your password only on the provider's website. QuotaDesk never sees or stores passwords.
- The app reads credentials the CLIs already saved: `~/.codex/auth.json` (or `$CODEX_HOME`), and Claude Code's `~/.claude/.credentials.json` or the `Claude Code-credentials` Keychain item. For the Keychain item it uses `/usr/bin/security`, which Claude Code itself uses to write that item, so reading it doesn't trigger password prompts after each token refresh.
- Each access token is sent only to its own provider's HTTPS usage endpoint. A Claude token may be kept **in memory** for up to 10 minutes. Tokens are never written to disk, logged or copied to another Keychain item, and the app never rotates or rewrites the CLIs' tokens.
- After sign-in, the app checks every 5 seconds (locally, for up to 5 minutes) whether the CLI has written new credentials, then refreshes once.
- Settings (`language`, `timeZone`, `refreshMinutes`, `providers`, `floating` and window position) are stored in the app's standard UserDefaults and contain no secrets.
- The repository contains no API keys, client secrets or personal data. `build-cache/` and built `.app` bundles are git-ignored.

## Rate limits

Automatic refreshes follow the chosen interval. Manual and wake refreshes are at least 55 seconds apart. An HTTP 429 pauses only that provider, following `Retry-After` (minimum 1 minute, default 5 minutes). The usage endpoints are provider-internal and may change without notice.

## References

- Codex usage endpoint: https://github.com/steipete/CodexBar/blob/main/docs/codex.md
- Claude OAuth usage endpoint: https://github.com/steipete/CodexBar/blob/main/docs/claude.md

This code was written independently; no CodexBar source is copied or bundled.

## Disclaimer

QuotaDesk is an independent, unofficial project. It is not affiliated with, endorsed by or sponsored by OpenAI or Anthropic. "Codex", "ChatGPT" and "Claude" are trademarks of their respective owners and are used here only to describe compatibility. The usage endpoints it reads are undocumented and may change or stop working at any time. Use at your own risk.

## License

[MIT](LICENSE)
