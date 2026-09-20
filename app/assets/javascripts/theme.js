// Blocking head script: resolve system preference before CSS or components can paint.
(() => {
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
applyColorMode(document.documentElement.dataset.themePreference || "system");
})();
