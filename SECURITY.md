# Security Policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting: open the repository's
**Security** tab and choose **Report a vulnerability**. Do not open a
public issue for security problems.

## Scope

Hush's core promise is that nothing leaves your Mac. Issues that break the
privacy invariants are the highest priority, for example:

- unexpected network traffic (anything other than model download)
- reading or watching secure text fields (`AXSecureTextField`, Secure Event
  Input contexts)
- transcript or audio content written to logs
- user data written outside `~/Library/Application Support/Hush/`

Issues in hotkey capture, accessibility access, or model handling that
could affect other apps or leak data are also in scope.

## Supported versions

Only the `main` branch is supported. There are no versioned releases yet.
