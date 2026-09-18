# AGENTS.md
The role of this file is to describe common mistakes and confusion points that agents might encounter as they work in this project. If you ever encounter something in the project that surprises you, please alert the developer working with you and indicate that this is the case in the AgentMD file to help prevent future agents from having the same issue.

## Developer Notes

- The authoritative checkout is `D:\codeProjects\apps\lattrix-localized`. Verify the working directory before editing; an earlier session incorrectly used a separate C: checkout, which has now been migrated and removed.

- Use Simple Elements components wherever available, including form controls, buttons, titles, badges, empty states, and workspace cards for workspaces. Read the Simple Elements wiki and verify APIs against the installed package; sibling component-library checkouts may contain unreleased changes.

- Capture and show screenshots of affected screens or states after every app change.


## Agent Notes (Surprises Encountered)

- Simple Elements v0.13.0's wide layout-brand sizing targets `.se-layout-brand[data-wide-icon]`, but the element does not receive that class. The app stylesheet sizes the expanded sidebar wordmark explicitly; keep compact sizing provided by the library.

- SE file-upload emits dropped files without updating its native input. The profile-photo upload handler bridges this event to the form input so drag-and-drop submits correctly.

- Historical note: Simple Elements v0.7.0 had fewer icons than the current wiki (e.g. no plus, globe, or arrow-left); check src/icon-names.js. Its se-input does not forward required/maxlength, so retain server-side validation.

- The current UI uses Simple Elements; app styles are in `app/assets/stylesheets/application.css`. The older `logged_in.css` and `public_pages.css` paths below no longer exist.

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

- Simple Elements v0.13.2 modal serializes child content with innerHTML. Already-initialized se-select children retain data-ready but lose listeners and selected state. Fix by preserving/moving child nodes in the library; do not patch its internals from the app.
