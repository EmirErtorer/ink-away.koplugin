# Security

## Supported versions

Only the latest release gets fixes. If you are on an older one, update first
(Settings, Updates) and check the problem is still there.

| Version | Supported |
|---|---|
| Latest release | Yes |
| Latest prerelease, while it is newer than the latest release | Yes |
| Anything older | No |

## Reporting a problem

Please do not open a public issue for a security problem. Report it privately
through GitHub instead: the Security tab of this repository, then Report a
vulnerability. Only I can see it there until a fix is out.

Tell me what it is, the steps to reproduce it, the Ink Away and KOReader
versions and the device. A file that shows it (a drawing, a notebook or a book's
.sdr folder) helps a lot.

I will answer within a week. Once it is fixed I will put out a release, say
what was fixed in the changelog and credit you unless you would rather not be
named.

## What counts

Ink Away runs inside KOReader with the same rights KOReader has on your device,
so these matter most:

- **The updater.** It only talks to GitHub, only installs a release whose zip
  matches the SHA-256 digest GitHub lists for it and only unpacks files inside
  the plugin's own folder. A way around any of that is a security problem.
- **Files it opens.** Drawings, notebooks, ink saved with a book, imported
  pictures and PDFs. A file that makes Ink Away write outside its own folders,
  run code or lose other data is a security problem.
- **Files it writes.** Exports and backups ending up somewhere they should not.

A crash or a slowdown from a file you made yourself is a normal bug; please
report that as an issue. Problems in KOReader itself belong to the
[KOReader project](https://github.com/koreader/koreader/security).
