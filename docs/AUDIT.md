# Why this app exists, and what the audit found

This project is a clean-room replacement for a closed-source macOS shortcut viewer.
Before writing a line of code we audited the original binary and recorded the
results below. The audit is the reason several features are deliberately absent.

## What was audited

KeyClu 0.33 (`com.0804Team.KeyClu`), a universal Mach-O signed with a Developer ID
and shipped as a ZIP. Method: Mach-O parsing, code-signature inspection, string and
symbol extraction, framework inventory, SQL schema recovery, and a public-advisory
review. No binaries were executed (the audit host was Linux).

## Findings that shaped this design

| Finding | Consequence here |
| --- | --- |
| The original imports `AXUIElementPerformAction` and `AXUIElementSetAttributeValue`, so its Accessibility grant allows pressing menu items and changing attributes in other apps. | This app is read-only. It uses only attribute-copy APIs. |
| It is unsandboxed with only two XPC mach-lookup exceptions, and its bundled XPC service exposes panel and ignore-list operations with no visible client validation. | There is no XPC service and no helper here. No inter-process control surface. |
| Its SQLite store keeps app names, menu titles, bookmark/hidden flags and usage counters, and exports Markdown to Documents. | State here is a small JSON file with `0600` permissions, holding only IDs you bookmark or hide. Menu contents stay in memory. |
| The only network egress is the Sparkle updater (HTTPS appcast with Ed25519). Sparkle 2.9.6 carries a November 2026 package-replay advisory fixed in 2.11. | This app has no updater and no network code. Updates are `git pull` and rebuild. |
| The `keyclu://` scheme opens settings; CLI flags drive panels and ignore lists. | No URL scheme, no CLI. |

## What was not verified

Code signature trust and notarisation could not be validated on Linux; the audit
records certificate metadata only. Runtime behaviour, TCC prompts and packet
capture were not exercised. Findings are static evidence, not a proof of safety.

Full report: `~/oss/briefs/keyclu/reports/audit-codex.md` (not part of this repo).
