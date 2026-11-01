# Security

## Reporting a vulnerability

Please report security issues privately through a [GitHub security advisory](https://github.com/OWCramer/shiori/security/advisories/new) (or by email to me@ocramer.com) rather than in a public issue: anything that could expose a Steam sign-in token, a password, or a user's files.

## What Shiori protects

Shiori keeps the Steam sign-in token in iCloud Keychain and never stores passwords. It has no account server of its own; compatibility reports, when turned on, go to compat.ocramer.com.

## Games and patches

Games and patches run with the app's privileges. A Ren'Py game is Python, an Artemis game runs Lua, and other engines run their games' scripts, all inside Shiori's process with access to what Shiori can reach, including the Keychain. iOS keeps that to Shiori's own container, but within it a game or patch is trusted like the app. Install patches you trust.

Patches from the patch list are checked against the list's SHA-256 when it has one; Shiori asks before installing one that has none.
