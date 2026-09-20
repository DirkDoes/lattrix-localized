# Authorization

The app uses [Pundit](https://github.com/varvet/pundit), a common Rails policy pattern.
Authentication (Devise, email challenges and connected sign-in methods) remains separate.

## Resource access

- Policies live in `app/policies` and inherit from `ApplicationPolicy`. Its action defaults deny access; its base Scope requires an explicit implementation.
- Controllers call `authorize record` (or an explicit query such as `authorize Project, :administration_index?`) before exposing or changing data.
- Resolve records through `policy_scope(Model)`. Keep nested resources nested: `policy_scope(@project.sheets).find_by!(slug: params[:id])`.
- Apply search, ordering and pagination after the authorized scope. The regular project list additionally filters to the current user's memberships; public visibility never becomes a discovery directory.
- Views use the same policies, for example `policy(@sheet).create?`. Hiding a button is not authorization.
- UserPolicy owns user-management permissions, allowed role choices and permitted profile attributes. Global admins cannot edit or ban owners, grant ownership, or delete other users.
- Invitation scope is always the recipient's verified account email, including for global owners. Sending invitations requires project administration.
- Protected resource controllers verify authorization after each action, and verify scoping on index/list actions. Settings controllers inherit those hooks from Settings::BaseController. Add these hooks to every new resource controller:
  ```ruby
  after_action :verify_authorized
  after_action :verify_policy_scoped, only: :index
  ```
  These are development safeguards; actual access is enforced by authorize and scoped queries.

## Authentication and data invariants

- Devise login/registration/OAuth and email-code verification establish identity and retain their existing authentication controls rather than requiring a signed-in resource policy.
- Authenticated account-security operations and self-deletion also use UserPolicy#manage_account?, in addition to recent-verification and confirmation checks.
- Public photo retrieval first validates a signed token, then uses UserPolicy#public_photo?. Invalid tokens return 404 without exposing a record.
- Missing or inaccessible records remain 404 where previously hidden. Policy-denied resource operations return 403; administration pages retain their permission-denied redirects.
- Application access still rejects unverified/banned accounts before resource actions.
- Last-active-owner protection and sheet/member capacity checks remain model invariants. ProjectPolicy#new? includes the member project cap; the create action rechecks it while holding the user row lock. The role-level create? check runs first so guests are forbidden and capacity failures retain their helpful form error.

## Checks

Run `PARALLEL_WORKERS=1 bundle exec rails test`. Policy tests cover role and tenant scopes; integration tests exercise requests, forbidden mutations, concurrent capacity limits and missing-policy guards.

## Project roles and privacy

- Personal project lists and sidebar groups contain memberships only. An empty list uses a plain sidebar link. Public projects and public sheets inside them can be opened by URL without signing in or joining. Anonymous private-resource requests redirect to login; signed-in access still requires membership or global administration. Anonymous pages have no global sidebar; sheet navigation is available through tabs. All mutations remain authenticated.
- Project Viewers can read the project. Translators also see the Members tab, with names and roles only. Their search matches names only.
- Project Admins can edit ordinary settings, create sheets/invitations, and manage Viewer/Translator memberships. They cannot edit/remove Admins or Owners or promote anyone to those roles.
- Project Owners can change visibility and slug, delete the project, and manage membership roles. Owner memberships cannot be removed: demote them first, retaining at least one Owner. Global application Owners retain an override; global Admins require project Owner membership for these sensitive actions.
- Invitations accept only Viewer or Translator. Their stored role is applied on acceptance; accepting an invitation never changes an existing membership.
- Visibility and slug changes have separate forms and require confirmation before saving. Slug availability is rechecked at confirmation; old URLs have no redirects or aliases. Project deletion requires the exact phrase `DELETE PROJECT` after a warning.
- Membership mutations lock the project row and cannot demote/remove its final Owner. Deleting the project itself can remove its dependent memberships.
- Email addresses appear in the application Users administration and in project Members for authorized admins/owners. Authorized user settings pages also display the email (self, or an administrator/owner permitted to edit that user). The header and invitation list do not display email addresses.

## Invitation previews and account removal

- A pending invitation grants its verified recipient read-only access to the project and its sheets, including private ones. It does not create membership or allow member administration, editing, or sheet creation. Acceptance grants the stored role; decline/revocation removes the preview access.
- Project admins/owners use the separate invitation management scope to list and revoke pending invitations. The recipient's invitation scope remains email-bound. New invitations record invited_by; historical invitations have no invented sender. Deleting a sender nullifies this reference.
- Global Owners cannot delete another global Owner until that account is demoted. Administrative deletion transfers otherwise ownerless projects to the acting Owner, preserving sheets and member capacity; projects with other owners keep those owners. Transfers and account deletion share one transaction.
- User tables use passive profiles. Email subtitles remain limited to application administration and authorized project managers.
- Ban/Restore actions from the users table return to that same status/query/page. The table-action Stimulus controller replaces results and displays response toasts without replacing the page shell.
- Identifier is the UI name for the existing slug field; database column names and URL behavior remain unchanged.

## Translation editing

SheetPolicy authorizes key management and settings for project/global admins and owners. Translators may edit only their assigned active project languages. Viewer memberships and invitation previews are read-only. Visible language choices do not grant editing permission; every write is checked on the server. The export modal and export endpoints share the policy-scoped sheet collection.
