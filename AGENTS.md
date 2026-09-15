# AGENTS.md
The role of this file is to describe common mistakes and confusion points that agents might encounter as they work in this project. If you ever encounter something in the project that surprises you, please alert the developer working with you and indicate that this is the case in the AgentMD file to help prevent future agents from having the same issue.

## Developer Notes


## Agent Notes (Surprises Encountered)

### Test runtime compatibility
- Docker sets DATABASE_URL to development. The explicit test URL in database.yml must point to a dedicated database ending in _test; never override this safeguard or run fixtures against development.
- Rails 8.1.1's test runner is incompatible with Minitest 6; keep the test dependency on Minitest 5 until Rails supports the newer runner API.
- Keep executable files under bin/ LF-terminated; CRLF shebangs fail inside Linux Docker containers.
- Ruby 3.4 needs libyaml-dev in the development image to compile the locked psych gem. Reinstall native gems in the bundle volume when upgrading Ruby.

### Authentication versus application access
- New verified users receive access by default. Banned users can authenticate; ApplicationController enforces application access separately. Keep sign-out available.
- Do not read current_user in a prepended sign-in callback before the rate limiter: Warden may authenticate directly from the submitted password parameters.

### View, Style, And Vector Asset Separation
- Views should stay focused on markup and Rails helpers. Avoid embedding large `<style>` blocks or inline SVG markup in `.erb` templates.
- Page and layout styling belongs in Rails asset stylesheets under `app/assets/stylesheets/`. The logged-in shell/sidebar styles currently live in `app/assets/stylesheets/logged_in.css`; public landing/auth styles live in `app/assets/stylesheets/public_pages.css`.
- Public static vector assets belong under `public/icons/`. The sidebar icons are stored there as separate SVG files and loaded by the layout instead of being written directly into the view.
- Keep custom interactive behavior in JavaScript assets instead of inline scripts when possible. The split verification-code input behavior lives in `app/assets/javascripts/verification_code.js`.
- The authenticated layout keeps navigation structure in `app/views/layouts/settings.html.erb`, but styling and SVG source are separated into their own asset files.

- Passwords stay in Devise; auth_identities records explicit connections. Verified email now automatically gets an email-code identity, including provider registration; AUTH_METHODS still gates actual access. Do not allow password reset to add a disconnected or globally disabled password.
- Account email verification and a recent security check are different. Reuse completed email-code proof for the security window; rejected mail cooldown checks must roll back hourly counters.
- Email verification grants email-code eligibility, not recent security proof. Security proof is bound to the user and current primary email and expires without sliding renewal. Provider login does not grant it.
