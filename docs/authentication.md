# Authentication

This template uses Devise sessions/password hashes, verified email codes, and linked Google/GitHub/Discord identities.

## Configuration

AUTH_METHODS is a comma-separated list of password,email_code,google,github,discord (default: password,email_code). Recreate the web container after environment changes. These settings are enforced server-side.

Enabled providers require NAME_CLIENT_ID and NAME_CLIENT_SECRET (GOOGLE, GITHUB, DISCORD). Register OAuth applications at each provider and configure exact production HTTPS callback URLs:

- /users/auth/google_oauth2/callback
- /users/auth/github/callback
- /users/auth/discord/callback

For local testing use http://localhost:3021 plus the path. Request only basic identity/email scopes, not repository access or Discord bot permissions. Missing provider credentials prevent startup. Keep secrets out of Git. Configure APP_HOST/APP_PROTOCOL and SMTP for email delivery.

## Accounts

Users have UUID primary keys and case-insensitively unique normalized emails. All five methods have auth_identities records with unique provider/ID and user/provider constraints. Password hashes stay on User for Devise compatibility; save callbacks synchronize password and verified-email identities. Every verified email receives an email-code identity, including provider registration. Existing verified users are backfilled by an additive migration. Stored identities may remain while a method is disabled; AUTH_METHODS gates their use and visibility in settings.

Email registration creates no User until verification. OAuth registration, login and linking require an email verified by the provider. A new identity matching an existing email requires signing in through an existing method and explicitly linking it. An explicitly linked provider may use a different email; it never changes the account's primary email. There is no legacy sign-in verification flow for pre-existing unverified accounts.

Personal settings show enabled methods and the account email. Completing an email code (including signup/login) grants 10 minutes to change passwords or link/unlink identities. The card-header verification button renews this window; it is separate from the email's verification status. This also works when email-code login is disabled, but requires an authenticated session. Users can disable passwords or disconnect external providers, but cannot disconnect email-code login or remove their final enabled method. Password recovery only works for a connected password and disabling it invalidates reset tokens. A duplicate password signup sends the same challenge response but does not sign in or change the existing account after proof. Provider display names/usernames are stored on successful sign-in or linking; existing connections acquire these labels on their next provider sign-in. Provider access tokens are not retained.

Provider-verified email makes email-code login available when globally enabled, but provider login alone does not grant recent security proof. Reusing a current security check never extends its ten-minute deadline without another code. Changing the primary email requires a recent security check and a single-use code sent to the new address. The original email remains active until verification succeeds; uniqueness is enforced at that point. Successful changes preserve linked identities and invalidate old-email challenges, password-reset tokens, and security proof in other sessions.

Edit email is enabled after card-level verification and opens the new-address modal directly. The server independently enforces recent verification. Self-service deletion has two confirmation dialogs, recent email proof, and an exact server-checked confirmation phrase. The UI prevents copying/pasting the phrase as an accidental-deletion precaution, not a security boundary. Deletion removes linked identities and pending email challenges, signs the user out, and cannot remove the last active owner.

Admins manage viewer names, permitted roles and bans/deletion. Owners also manage admins/owners. Other users' authentication credentials and appearance are read-only. Active and inactive users have separate list views. Bans do not prevent authentication: a verified user receives an access-denied screen on every application request, with sign-out still available. No ban status is disclosed before authentication. The final active owner cannot be banned, deleted, or demoted. UUIDs do not replace authorization checks.

## Registration and access

Every verified new account receives application access. The first account becomes owner under a database lock; later accounts are viewers. Invitation policy and its environment flag have been removed. Historical invitation/access-grant database data is retained but unused, so this change does not delete existing data. Bans and role permissions remain separate application concerns. Deletion permits re-registration; banning preserves the account while denying access.

## Abuse protection

New passwords require 12–72 characters and at most 72 UTF-8 bytes, avoiding bcrypt's silent truncation. Existing passwords remain valid for sign-in. Password resets also enforce the globally enabled password method.

Codes expire in 10 minutes, allow five attempts, and are consumed under a row lock. Resending invalidates the old challenge. Only secret-keyed digests and pending Devise password hashes are stored. No plaintext passwords are persisted. Expired challenges and throttle records are pruned during requests; run authentication:cleanup periodically on quiet deployments.

Database-backed limits work across processes: mail requests have a 1,000/hour global cap, 30/IP/hour, 5/email/hour and one/email per 30-second window. Rejections report the remaining wait for the limiting window in the message and Retry-After header. Failed cooldown requests roll back all mail counters, preserving the hourly allowance. Password verification has global, IP and email limits. Code verification has global/IP limits and the per-code attempt budget. Global admission bounds temporary database growth. Set upstream request-size and traffic limits for production, and configure trusted proxies correctly for IP-based limits.

Development sends all mail to [MailCatcher](https://mailcatcher.me/), started by Docker Compose. Open http://localhost:1080 for the inbox (override MAILCATCHER_WEB_PORT if needed). The inbox is bound to localhost and is temporary; recreating its container clears messages. Rails uses mailcatcher:1025 without SMTP credentials or TLS. Codes are never displayed in the app or stored in browser sessions. APP_PORT follows WEB_HOST_PORT so password-reset links point back to the running app. Production still uses its existing SMTP configuration. Delivery errors are surfaced.

Before disabling methods, run `AUTH_METHODS=<proposed methods> bin/rails authentication:audit` to list affected accounts and migrate them first. Unlinking an identity does not end an already authenticated session; banning denies its application access on the next request.

## Tests

The explicit test URL overrides Docker's development DATABASE_URL. TEST_DATABASE_URL can supply another database, but its name must end in _test. The test helper refuses other database names. Never bypass this guard.

OAuth integration tests run with all providers enabled and placeholder test credentials, using OmniAuth simulated callbacks. They test admission and linking rules; live provider login still requires actual credentials and browser consent.

## Known deployment follow-up

Development and production Dockerfiles use Ruby 3.4.10. The Brakeman scan flags role assignment; the controller restricts role changes by actor and target, and integration tests exercise those restrictions. Passing the automated suite is not a guarantee against every vulnerability.
