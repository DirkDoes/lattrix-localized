# AGENTS.md
The role of this file is to describe common mistakes and confusion points that agents might encounter as they work in this project. If you ever encounter something in the project that surprises you, please alert the developer working with you and indicate that this is the case in the AgentMD file to help prevent future agents from having the same issue.

## Developer Notes

- The authoritative checkout is `D:\codeProjects\apps\lattrix-localized`. Verify the working directory before editing; an earlier session incorrectly used a separate C: checkout, which has now been migrated and removed.

- Use Simple Elements components wherever available, including form controls, buttons, titles, badges, empty states, and project cards for projects. Read the Simple Elements wiki and verify APIs against the installed package; sibling component-library checkouts may contain unreleased changes.

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

- Project/sheet visibility controls are mounted from inert templates by `modal-fields` after se-modal composition, so its current serialization cannot discard their listeners. Remove this deferred mounting when the library preserves child nodes.

- Simple Elements v0.13.2 se-select renders an absolutely positioned menu inside the modal's scrollable body. It has no documented portal/popover option, so menus expand/clip that body. This needs a library-level top-layer menu implementation; do not add app CSS overrides of select/modal internals.

- Sidebar groups and chapters do not emit the sidebar's collapsechange event. navigation_state.js restores their public collapsed attributes before library initialization and observes subsequent changes. Put a stable unique id on new collapsible sidebar elements. Load this deferred script before simple-elements; restoring attributes after initialization would leave chapter aria-expanded stale.

- Authorization uses Pundit policies in app/policies. Follow docs/authorization.md: controllers must authorize resources and policy_scope collections before search/pagination; views must use those same policies. New resource controllers need verify_authorized and verify_policy_scoped hooks. Keep authentication/challenge flows separate, and preserve model-level last-owner and capacity protections.

- Simple Elements v0.13.2 se-menu has no icon-only trigger API (it always adds More). Its absolute menu is clipped by table cells with overflow:hidden and the collection overflow boundary. Use pencil edit links until the library supports top-layer menus inside tables; do not override internal table/menu CSS.

- v0.13.3 supersedes the v0.13.2 modal/select notes above: modals preserve child nodes and select menus use the top layer. The app's modal-fields workaround has been removed.

- Simple Elements v0.14.0 tree collapse operates on direct child rows of one collection. Keep lazy-loaded translation rows in that collection via Turbo append; separate collections break collapse across pages.
- v0.14.0 se-list-row builds its toggle's accessible name from the entire first cell, including hidden menu option text. The library should accept a row label or exclude action content. Do not patch generated internal markup in this app.
- v0.14.2 adds native se-menu heading options and variant="mini", replacing the disabled pluralization label. It also allows interactive table cells to overflow for focus rings.

- v0.14.2 se-select exposes local searchable options but no remote-query event or API to update options without rebuilding the search field. The key editor composes se-popover, se-input and result buttons for server-side parent lookup instead of modifying select internals.

- v0.14.3 supersedes the async-select workaround: the parent picker uses searchable remote se-select with Stimulus debounce and bounded Rails results. Theme resolution must run synchronously before styles/components; a deferred theme script flashes light mode for system-dark users.

- v0.14.4 preserves tooltip children, fixing duplicated initialized icons. Use an explicit mini info button as the tooltip trigger. se-input errors are initialization-only; recreate the field through its public attributes while preserving focus, rather than patching library markup.

- v0.14.4 tooltips only accept escaped plain-text content and close when leaving the trigger; clickable reference links inside the bubble need a library API for rich, interactive content. Do not inject HTML into generated tooltip markup.

- v0.14.5 supports rich tooltip content, but its hover dismissal still makes the bubble non-interactive. The plural badge itself links to Unicode; use a popover if interactive content inside the floating panel is needed.

- Non-user entity primary keys are bigint after migration 20260921000000. Only users and their foreign keys use UUIDs. Compare request/DOM ID strings explicitly with numeric model IDs; never assume UUID-shaped identifiers outside users.

- Before changing translation architecture, read `docs/translation-architecture.md` for the recording/recordable rationale and the explicitly deferred reflection/history ideas.
