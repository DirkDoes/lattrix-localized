# Design language

## Components first

Start with Simple Elements components and documented patterns. Use Tailwind or application CSS when necessary to compose, arrange, or enhance what the library does not provide. Application styles may position component hosts, but must not target or override component internals; fix or refine the component in Simple Elements instead.

## Backend-owned validation

Every form must remain submittable in every field state. Components do not expose `required`; forms use `novalidate`; and browser constraints must not replace backend validation. The backend validates, returns `422 Unprocessable Entity`, preserves submitted values, and supplies each message through its field's `error` attribute.

```html
<se-input type="email" name="email" error="Enter a complete email address."></se-input>
```

## Composition and responsive layout

- Workspace pages use `se-nav-tabs` for Dashboard, Projects, Members, and Settings above page content. Sending invitations belongs on Members; received Invitations have their own sidebar page.
- Use one sidebar below the full-width top bar. Project pages show project navigation on desktop; mobile navigation includes project, workspace, and administration as adjacent `se-sidebar-chapter` elements so the library supplies dividers.
- Mobile navigation uses the responsive sidebar's top-down dropdown. Project breadcrumbs appear at the top of that dropdown on mobile and in the top bar on desktop, using `layout-mode`.
- Use `se-title level="page"` consistently for page headings. Keep workspace visibility beside its name; membership roles belong in the members list.
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

- Every account, including Guests, has Dashboard, Workspaces, and Invitations navigation. Project pages swap to project navigation on desktop and retain global navigation in the mobile dropdown.
- The overview uses `se-empty-illustration variant="translation-2"`. Guests cannot create workspaces; their empty workspace state explains invitations. Members and higher get a Create new workspace action inside the empty state, or in the header when the list is nonempty.
- The regular workspace index lists memberships only. Public workspaces are accessible by shared URL, not through a public directory. Owners and admins may open the separate administration workspace table and manage all workspaces, including private ones without membership.
- For guests and members, public workspace access does not expose its membership list or private projects. A private workspace also hides its public-marked projects from nonmembers.
- The Banned users tab filters by `banned_at`, without redundant banned badges. Empty lists render an illustration instead of an empty table.

- All empty illustrations share `--se-illustration-width: 32rem`, capped by the library at the available width. Include a useful title and description; do not set per-page illustration sizes.
- Show email verification separately from bans: non-banned users remain in Active users, with Verified/Unverified badges.

- Global roles are Guest (default, stored value 0), Member (3), Admin (1), and Owner (2). Workspace Viewer roles remain unchanged. Admins may manage nonowner users but cannot grant ownership, modify owner accounts, or delete other users. Owners may manage everyone, subject to preserving one active owner.
- Use a segmented control beside the Users heading for Active/Banned filtering. Empty illustrations share responsive top spacing as well as their artwork size.

- Users, administration Workspaces, and workspace Members tables use backend search and fixed 20-row pages. Show `se-pagination` with a nonempty table, including one-page results; hide both for empty results. Preserve search and status across pagination; reset the page when searching or switching status.

- Table searches have no visible label or submit button; retain accessible names and debounce backend filtering by 350 ms without replacing the header or focused input.
- Project creation mirrors the name to a snake_case slug until the slug is edited. Existing hyphenated project URLs remain valid.

- Workspace Settings are visible and writable to workspace admins/owners and global admins/owners. Editing the name preserves its slug and existing links.
- Workspace and project create forms share `slug-mirror`, with source/destination targets and underscores by default. Manual hyphens remain valid; editing the slug stops mirroring.

- Members can create a workspace only while they own fewer than three; existing workspaces survive a downgrade. Global admins/owners have no workspace cap. Every workspace has a maximum of twelve projects. Creation checks run under row locks to serialize simultaneous requests.

- Sidebar collapse preferences use the shared navigation_state script and per-account browser storage, restored before Simple Elements initializes. Give every collapsible sidebar element a stable, unique id; its public collapsed attribute is persisted automatically. Administration is collapsible and defaults to collapsed. Full-page navigation keeps permissions, scope, breadcrumbs, and profile content server-rendered and current; no permanent stale sidebar or coordinated Turbo frames are needed.
- A workspace allows at most 200 members (including owners). The membership model locks the workspace during creation/moves; a rejected acceptance keeps the invitation pending. Existing member role changes remain available at capacity.

- Empty pages and empty lists use se-empty-illustration with a relevant variant, title, and helpful text. Do not use se-empty-state or wrap an empty illustration in a card. Workspace invitations use the inbox illustration; navigation already in the sidebar must not be repeated in the page header.
