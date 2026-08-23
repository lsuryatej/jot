# Security Policy

Jot is a small, solo-maintained macOS app. It's ad-hoc signed (no paid Apple
Developer account behind it), makes zero network requests by default, and
you can read every line of what it does — see [README.md](README.md#privacy)
for exactly what the two opt-in network features send and when.

## Reporting a vulnerability

If you find a security issue (something worse than a bug — data leaking
somewhere it shouldn't, a way to run arbitrary code via a note, anything
along those lines), please report it privately rather than opening a public
issue:

- Email **lsuryatej@gmail.com** with a description and, if you can,
  reproduction steps.
- You should get a response within a few days. This is a one-person
  project, not a company with an on-call rotation, so please be patient.

Once a fix is out, I'll credit you in the release notes unless you'd rather
stay anonymous.

## Supported versions

Only the latest release is supported. There's no long-term support branch;
given the size and pace of this project, everyone should just be on the
newest tagged release (`brew upgrade jot`, or Jot's own **Check for
Updates**).

## Scope

Things that are already known, documented trade-offs rather than
vulnerabilities to report:

- **Ad-hoc code signing, not notarized.** There's no paid Apple Developer
  Program membership behind this project. Both documented install paths
  (`brew install`, `install.sh`) strip the quarantine flag themselves, so
  neither triggers a Gatekeeper prompt; see the README's Install section.
- **Apple Notes sync, when enabled, talks to Notes.app locally via
  AppleScript.** It never touches the network. It's one-way and off by
  default.
- **The two opt-in network features** (live currency rates, update checks)
  are documented in full under [Privacy](README.md#privacy), including
  exactly what leaves your machine and when.
