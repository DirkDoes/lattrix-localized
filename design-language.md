# Design language

## Components first

Start with Simple Elements components and documented patterns. Use Tailwind or application CSS when necessary to compose, arrange, or enhance what the library does not provide. Application styles may position component hosts, but must not target or override component internals; fix or refine the component in Simple Elements instead.

## Backend-owned validation

Every form must remain submittable in every field state. Components do not expose `required`; forms use `novalidate`; and browser constraints must not replace backend validation. The backend validates, returns `422 Unprocessable Entity`, preserves submitted values, and supplies each message through its field's `error` attribute.

```html
<se-input type="email" name="email" error="Enter a complete email address."></se-input>
```

## Composition and responsive layout

- Project pages use `se-nav-tabs` for Dashboard, Sheets, Members, and Settings above page content. Sending invitations belongs on Members; received Invitations have their own sidebar page.
- Keep the global sidebar throughout signed-in navigation, including sheets. On desktop it contains the brand in its header and the profile in its footer; the top bar is mobile-only. Use `se-nav-tabs` for sheet Dashboard, Translations and Settings. Place one Export button in the project or sheet tabs’ `[data-actions]` slot; it opens a format chooser and, at project level, a sheet chooser.
- Mobile navigation uses the responsive sidebar's top-down dropdown. Do not render breadcrumbs. Mobile keeps the brand and profile in the top bar.
- Use `se-title level="page"` consistently for page headings. Keep project visibility beside its name; membership roles belong in the members list.
- Do not duplicate navigation already available in the sidebar with extra back-to-index buttons.

- Begin with the closest documented pattern and preserve its component hierarchy.
- Use native regions where a component defines them: `header`, `section`, and `footer` in `se-sidebar`; `data-start`, `data-center`, and `data-end` sections in `se-topbar`.
- `layout-mode` defaults to `always`. Use `mobile-only` or `desktop-only` for viewport-specific content, and `responsive` on a sidebar that becomes mobile navigation.
- When equivalent content exists in desktop and mobile regions, use `layout-mode` to show only the appropriate instance.
- Compose page shells with `se-page-layout`, `se-page-layout__row`, and `se-page-layout__content` before adding custom layout CSS.
- When no saved user preference exists, initialize the theme from the system `prefers-color-scheme` preference.
- On narrow screens, consider combining closely related table values before accepting horizontal scrolling—for example, a bold name with its email as supporting text in the same cell. Choose this per table; it is not a mandatory transformation.

## Actions

- Index pages focus on viewing data. Place record actions, including the primary Create action, at the top right of the page header; do not embed creation forms in the list.
- Use a medium `se-modal` for short create/invite forms (usually three fields or fewer). Use a dedicated new-record page for larger or more involved forms.
- Keep failed forms open with submitted values and inline backend validation messages. Use the modal's Cancel and confirmation actions.
- Use `se-sidebar-group variant="page"` when a destination also contains child pages: its label navigates to the index and its separate disclosure control expands the child links. Use `se-sidebar-button` for each child and keep the list scoped to the current user's memberships.

- Use `se-button` for actions and action-like navigation. Use `variant="ghost"` for lower-priority actions and `variant="link"` for low-emphasis navigation or help.
- Give each action group one clear primary call to action; render the remaining actions as ghost or secondary variants according to their hierarchy.
- Put form actions at the bottom right. Place Cancel immediately left of the primary submit action.
- In compact authentication-card forms, stretch the primary action across the available width. When the card presents multiple peer actions, divide that width equally between them.

## Account roles and navigation

- Every account, including Guests, has Dashboard, Projects, and Invitations navigation. Sheet pages retain the global sidebar and use sheet navigation tabs.
- The overview uses `se-empty-illustration variant="translation-2"`. Guests cannot create projects; their empty project state explains invitations. Members and higher get a Create new project action inside the empty state, or in the header when the list is nonempty.
- The regular project index lists memberships only. Public projects are accessible by shared URL, not through a public directory. Owners and admins may open the separate administration project table and manage all projects, including private ones without membership.
- For guests and members, public project access does not expose its membership list or private sheets. A private project also hides its public-marked sheets from nonmembers.
- The Banned users tab filters by `banned_at`, without redundant banned badges. Empty lists render an illustration instead of an empty table.

- All empty illustrations share `--se-illustration-width: 32rem`, capped by the library at the available width. Include a useful title and description; do not set per-page illustration sizes.
- Show email verification separately from bans: non-banned users remain in Active users, with Verified/Unverified badges.

- Global roles are Guest (default, stored value 0), Member (3), Admin (1), and Owner (2). Project Viewer roles remain unchanged. Admins may manage nonowner users but cannot grant ownership, modify owner accounts, or delete other users. Owners may manage everyone, subject to preserving one active owner.
- Use a segmented control beside the Users heading for Active/Banned filtering. Empty illustrations share responsive top spacing as well as their artwork size.

- Users, administration Projects, and project Members tables use backend search and fixed 20-row pages. Show `se-pagination` with a nonempty table, including one-page results; hide both for empty results. Preserve search and status across pagination; reset the page when searching or switching status.

- Table searches have no visible label or submit button; retain accessible names and debounce backend filtering by 350 ms without replacing the header or focused input.
- Sheet creation mirrors the name to a snake_case slug until the slug is edited. Existing hyphenated sheet URLs remain valid.

- Project Settings are visible and writable to project admins/owners and global admins/owners. Editing the name preserves its slug and existing links.
- Project and sheet create forms share `slug-mirror`, with source/destination targets and underscores by default. Manual hyphens remain valid; editing the slug stops mirroring.

- Members can create a project only while they own fewer than three; existing projects survive a downgrade. Global admins/owners have no project cap. Every project has a maximum of 90 sheets. Creation checks run under row locks to serialize simultaneous requests.

- Sidebar collapse preferences use the shared navigation_state script and per-account browser storage, restored before Simple Elements initializes. Give every collapsible sidebar element a stable, unique id; its public collapsed attribute is persisted automatically. Administration is collapsible and defaults to collapsed. Full-page navigation keeps permissions, scope, breadcrumbs, and profile content server-rendered and current; no permanent stale sidebar or coordinated Turbo frames are needed.
- A project allows at most 200 members (including owners). The membership model locks the project during creation/moves; a rejected acceptance keeps the invitation pending. Existing member role changes remain available at capacity.

- Empty pages and empty lists use se-empty-illustration with a relevant variant, title, and helpful text. Do not use se-empty-state or wrap an empty illustration in a card. Project invitations use the inbox illustration; navigation already in the sidebar must not be repeated in the page header.

- Translation tree rows use `se-list-row level` and `guides`. Key actions use a single right-aligned `se-menu icon-only`. Use native `collapsible` on parent rows, `sticky` on the header, and `dividers="1,2"` on the collection. Append lazy-loaded rows to the same collection so collapse and guides span every loaded page. Plural forms are child rows in both views; their creation actions belong in the key menu. Language selectors use `size="small"` inside the table header. The page heading groups its title and Add key action on the left, with search and the view/sort filter popover on the right. Table menus use `variant="mini"` and native `heading` options; inline translation inputs use `size="small"`.

- The sidebar's brand owns its collapse button (`se-layout-brand collapsible`); do not add the sidebar edge control. Plural category child rows use `variant="secondary"`. Empty editable translations show their textarea immediately. Reserve an inline status slot for the library spinner and brand-colored saved check; success messages must not expand rows. Keep the search input at its default size.

- Key mutations refresh only the translation results frame and preserve view, sort, selected languages, and search. Read-mode translation text matches the small textarea's typography and box dimensions to avoid a height jump when editing.

- Mobile translations use two equal language columns with their selectors and no key/tree column. The table reaches both content edges; tree collapse is disabled on mobile without discarding the desktop collapse state. Desktop remains the three-column tree/key editor.
