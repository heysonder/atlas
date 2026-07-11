# Security Policy

Thank you for helping keep Atlas and its users safe.

## Supported versions

Atlas is currently distributed as a pre-release project. Security fixes are
made on the latest `main` branch and current beta. Older commits, archived
builds, and forks are not maintained as separate supported releases.

| Version | Supported |
| --- | --- |
| Latest `main` and current beta | Yes |
| Older builds and commits | No |

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability.

Use [GitHub private vulnerability reporting](https://github.com/heysonder/atlas/security/advisories/new)
when possible. If that is unavailable, email
[contact@cmf.sh](mailto:contact@cmf.sh) with the subject `Atlas Security`.

Include enough information to reproduce and assess the issue:

- The affected commit, build, or app version.
- The affected device and iOS version.
- A concise description of the impact and expected security boundary.
- Reproduction steps or a minimal proof of concept.
- Relevant logs or screenshots with credentials, private URLs, tokens, and
  personal data removed.

We aim to acknowledge a complete report within five business days. We will
coordinate validation, remediation, and disclosure with the reporter. Please
allow a reasonable remediation window before publishing details.

## Scope

Security problems in the Atlas app, PipedKit, repository automation, local data
handling, downloads, backups, playback networking, and destination-policy
enforcement are in scope.

Atlas does not operate Piped, YouTube, media hosts, or Apple platform services.
Vulnerabilities solely within those services should be reported to their
operators. An Atlas bug that handles one of those services unsafely is still in
scope here.

General bugs, feature requests, and performance issues that do not cross a
security or privacy boundary can use the public issue tracker.
