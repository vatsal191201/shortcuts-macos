# Why this app exists, and what the audit found

This project is a clean-room alternative to a closed-source macOS shortcut viewer.
Before writing a line of code we audited the original binary and recorded the
results below. The audit is the reason several features are deliberately absent.

The short version: **we found nothing malicious and nothing remotely exploitable.**
The original is a legitimate, signed app. The differences below are design choices,
not accusations.

## What was audited

KeyClu 0.33 (`com.0804Team.KeyClu`), a universal Mach-O signed with a Developer ID,
hardened runtime enabled, shipped as a ZIP. Two independent static passes:

1. Mach-O and code-signature parsing, string and symbol extraction, framework
   inventory, SQL schema recovery and a public-advisory review.
2. Ghidra decompilation of the arm64 slices of the app and its XPC helper, tracing
   call sites of the Accessibility write APIs, the URL handler, the XPC listener and
   every `dlsym` / `openURL:` site.

No binaries were executed (the audit host was Linux).

## Findings that shaped this design

| Finding | Consequence here |
| --- | --- |
| The original can activate shortcuts: it sets `AXFrontmost` on the app you picked and, ~0.3 s later, sends `AXPress` to the menu item you picked. The call graph shows this runs only from a click in its own panel; neither its URL handler nor its IPC can reach it. | This app never activates anything. It uses only attribute-copy APIs; the shipped binary has no `AXUIElementPerformAction` or `AXUIElementSetAttributeValue` symbol. |
| Its XPC helper accepts every connection (no audit-token or code-signing check), and relays commands to the app over a session-wide distributed notification that any same-user process can post. The reachable commands only show/toggle its panel and add/remove ignored apps. Low impact, but unauthenticated. | There is no helper, no XPC and no notification channel here. No inter-process control surface at all. |
| Its SQLite store keeps app names, menu titles, bookmark/hidden flags and usage counters, and exports Markdown to Documents. | State here is a small JSON file with `0600` permissions, holding only IDs you bookmark or hide. Menu contents stay in memory. |
| No telemetry or analytics was found. Automatic network traffic is limited to the Sparkle updater (HTTPS appcast, Ed25519-signed updates); other links are static help pages opened in your browser when clicked. | This app has no updater and no network code. Updates are `git pull` and rebuild. |
| The `keyclu://` scheme has exactly one route, which opens its Settings window. | No URL scheme, no CLI. |

## What was not verified

Code-signature trust and notarisation could not be validated on Linux; the audit
records certificate metadata only. Runtime behaviour, TCC prompts, live XPC
reachability and packet capture were not exercised. Findings are static evidence,
not a proof of safety in either direction.
