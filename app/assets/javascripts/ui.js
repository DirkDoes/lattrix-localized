document.addEventListener("select", (event) => {
  if (!event.target.matches("se-profile[data-profile-menu]")) return;
  if (event.detail.id === "account") window.location.assign(event.target.dataset.accountUrl);
  if (event.detail.id === "logout") document.getElementById("logout-form").requestSubmit();
});

const systemColorMode = matchMedia("(prefers-color-scheme: dark)");
function applyColorMode(preference) {
  const root = document.documentElement;
  root.dataset.themePreference = preference;
  const mode = preference === "system" ? (systemColorMode.matches ? "dark" : "light") : preference;
  root.dataset.theme = mode;
  root.dataset.seTheme = mode === "dark" ? "flat" : "clean";
}
systemColorMode.addEventListener("change", () => {
  if (document.documentElement.dataset.themePreference === "system") applyColorMode("system");
});
document.addEventListener("change", (event) => {
  if (!event.target.matches("se-theme-switch")) return;
  applyColorMode(event.detail.value);
});

document.addEventListener("click", (event) => {
  if (event.target.closest("[data-open-password-modal]")) document.getElementById("password-modal").open();
  if (event.target.closest("[data-open-email-modal]")) document.getElementById("email-modal").open();
  if (event.target.closest("[data-open-delete-modal]")) document.getElementById("delete-account-warning").open();
});

document.addEventListener("confirm", (event) => {
  if (["password-modal", "email-modal", "delete-account-warning", "delete-account-confirmation", "connect-provider-modal"].includes(event.target.id)) event.target.querySelector("form").requestSubmit();
});

for (const type of ["copy", "cut", "paste", "drop"]) {
  document.addEventListener(type, (event) => {
    if (event.target.closest("[data-no-copy], [data-deletion-confirmation]")) event.preventDefault();
  });
}

applyColorMode(document.documentElement.dataset.themePreference || "system");

// Bridge autocomplete until se-input forwards it to its native control.
customElements.whenDefined("se-input").then(() => {
  document.querySelectorAll("se-input[autocomplete]").forEach((field) => {
    field.querySelector("input, textarea")?.setAttribute("autocomplete", field.getAttribute("autocomplete"));
  });
});
