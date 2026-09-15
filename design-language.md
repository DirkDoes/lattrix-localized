# Design language

## Components first

Start with Simple Elements components and documented patterns. Use Tailwind or application CSS when necessary to compose, arrange, or enhance what the library does not provide. Application styles may position component hosts, but must not target or override component internals; fix or refine the component in Simple Elements instead.

## Backend-owned validation

Every form must remain submittable in every field state. Components do not expose `required`; forms use `novalidate`; and browser constraints must not replace backend validation. The backend validates, returns `422 Unprocessable Entity`, preserves submitted values, and supplies each message through its field's `error` attribute.

```html
<se-input type="email" name="email" error="Enter a complete email address."></se-input>
```

## Composition and responsive layout

- Begin with the closest documented pattern and preserve its component hierarchy.
- Use native regions where a component defines them: `header`, `section`, and `footer` in `se-sidebar`; `data-start`, `data-center`, and `data-end` sections in `se-topbar`.
- `layout-mode` defaults to `always`. Use `mobile-only` or `desktop-only` for viewport-specific content, and `responsive` on a sidebar that becomes mobile navigation.
- When equivalent content exists in desktop and mobile regions, use `layout-mode` to show only the appropriate instance.
- Compose page shells with `se-page-layout`, `se-page-layout__row`, and `se-page-layout__content` before adding custom layout CSS.
- When no saved user preference exists, initialize the theme from the system `prefers-color-scheme` preference.
- On narrow screens, consider combining closely related table values before accepting horizontal scrolling—for example, a bold name with its email as supporting text in the same cell. Choose this per table; it is not a mandatory transformation.

## Actions

- Use `se-button` for actions and action-like navigation. Use `variant="ghost"` for lower-priority actions and `variant="link"` for low-emphasis navigation or help.
- Give each action group one clear primary call to action; render the remaining actions as ghost or secondary variants according to their hierarchy.
- Put form actions at the bottom right. Place Cancel immediately left of the primary submit action.
- In compact authentication-card forms, stretch the primary action across the available width. When the card presents multiple peer actions, divide that width equally between them.
