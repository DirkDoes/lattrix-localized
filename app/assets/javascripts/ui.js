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

  const modalTrigger = event.target.closest("[data-open-modal]");

  if (modalTrigger) document.getElementById(modalTrigger.dataset.openModal).open();

  if (event.target.closest("[data-open-password-modal]")) document.getElementById("password-modal").open();

  if (event.target.closest("[data-open-email-modal]")) document.getElementById("email-modal").open();

  if (event.target.closest("[data-open-delete-modal]")) document.getElementById("delete-account-warning").open();

});



document.addEventListener("confirm", (event) => {

  if (event.target.id === "profile-photo-modal") event.target.querySelector("form").requestSubmit();

  if (["project-create-modal", "password-modal", "email-modal", "delete-account-warning", "delete-account-confirmation", "connect-provider-modal", "workspace-create-modal", "workspace-invite-modal"].includes(event.target.id)) event.target.querySelector("form").requestSubmit();

});



document.addEventListener("collapsechange", (event) => {

  if (event.target.id !== "app-sidebar") return;

  document.cookie = `sidebar_collapsed=${event.detail.collapsed}; Path=/; Max-Age=31536000; SameSite=Lax`;

});



document.addEventListener("files", (event) => {

  const upload = event.target;

  if (!upload.matches("[data-profile-photo-upload]")) return;

  const form = upload.closest("form");

  const preview = form.querySelector("[data-photo-preview]");

  const image = preview.querySelector("img");

  const message = form.querySelector("[data-photo-filename]");

  const file = event.detail.files[0];

  if (image.dataset.objectUrl) URL.revokeObjectURL(image.dataset.objectUrl);

  image.removeAttribute("src");

  delete image.dataset.objectUrl;

  preview.hidden = true;

  upload.hidden = false;

  const transfer = new DataTransfer();

  if (file && file.size <= 5 * 1024 * 1024) transfer.items.add(file);

  upload.querySelector("input[type=file]").files = transfer.files;

  if (!file) { message.textContent = ""; return; }

  if (!transfer.files.length) { message.textContent = "Choose an image up to 5 MB."; return; }

  message.textContent = file.name;

  image.onload = () => { upload.hidden = true; preview.hidden = false; };

  image.onerror = () => { message.textContent = `${file.name} - This browser cannot preview this format. You can still save it or choose another image.`; };

  image.dataset.objectUrl = URL.createObjectURL(file);

  image.src = image.dataset.objectUrl;

});

document.addEventListener("click", (event) => {

  const change = event.target.closest("[data-change-photo]");

  if (change) change.closest("form").querySelector("input[type=file]").click();

});



for (const type of ["copy", "cut", "paste", "drop"]) {

  document.addEventListener(type, (event) => {

    if (event.target.closest("[data-no-copy], [data-deletion-confirmation]")) event.preventDefault();

  });

}



applyColorMode(document.documentElement.dataset.themePreference || "system");



// The library renders the final breadcrumb as text; project scope needs a link.

customElements.whenDefined("se-breadcrumbs").then(() => {

  document.querySelectorAll("se-breadcrumbs[data-current-href]").forEach((trail) => {

    const current = trail.querySelector('[aria-current="page"]');

    if (!current) return;

    const link = document.createElement("a");

    link.href = trail.dataset.currentHref;

    link.textContent = current.textContent;

    link.setAttribute("aria-current", "page");

    current.replaceWith(link);

  });

});

// Bridge autocomplete until se-input forwards it to its native control.

customElements.whenDefined("se-input").then(() => {

  document.querySelectorAll("se-input[autocomplete]").forEach((field) => {

    field.querySelector("input, textarea")?.setAttribute("autocomplete", field.getAttribute("autocomplete"));

  });

});



// Use the logo gradient's middle blue; the library derives accessible theme roles.

customElements.whenDefined("se-theme-switch").then(() => {

  SimpleElements.setBrandTheme({ primary: "#3B82F6" });

});


document.addEventListener("change", (event) => {
  if (!event.target.matches("se-segmented-control")) return;
  event.target.closest("form[data-segmented-navigation]")?.requestSubmit();
});

document.addEventListener("change", (event) => {
  if (!event.target.matches("se-pagination[data-pagination-url]")) return;
  const url = new URL(event.target.dataset.paginationUrl, window.location.origin);
  url.searchParams.set("page", event.detail.page);
  window.location.assign(url);
});
