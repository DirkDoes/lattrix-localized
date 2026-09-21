document.addEventListener("select", (event) => {

  if (!event.target.matches("se-profile[data-profile-menu]")) return;

  if (event.detail.id === "account") window.location.assign(event.target.dataset.accountUrl);

  if (event.detail.id === "logout") document.getElementById("logout-form").requestSubmit();

});







function openExportModal(eventId, eventDate) {
  const modal = document.getElementById("export-modal");
  const form = modal.querySelector("form");
  form.setAttribute("action", `${form.action.split("?")[0]}${eventId ? `?recording_event_id=${eventId}` : ""}`);
  const replacement = document.createElement("se-modal");
  for (const {name, value} of modal.attributes) if (name !== "data-ready" && name !== "title") replacement.setAttribute(name, value);
  replacement.setAttribute("title", eventDate ? `Export translations · ${eventDate}` : "Export translations");
  replacement.append(form);
  modal.replaceWith(replacement);
  queueMicrotask(() => replacement.open());
}

document.addEventListener("click", (event) => {

  const modalTrigger = event.target.closest("[data-open-modal]");

  if (modalTrigger) {
    if (modalTrigger.hasAttribute("data-export-current")) openExportModal();
    else document.getElementById(modalTrigger.dataset.openModal).open();
  }

  if (event.target.closest("[data-open-password-modal]")) document.getElementById("password-modal").open();

  if (event.target.closest("[data-open-email-modal]")) document.getElementById("email-modal").open();

  if (event.target.closest("[data-open-delete-modal]")) document.getElementById("delete-account-warning").open();

});



document.addEventListener("confirm", (event) => {

  if (event.target.id === "profile-photo-modal") event.target.querySelector("form").requestSubmit();

  if (["key-create", "language-create", "sheet-create-modal", "password-modal", "email-modal", "delete-account-warning", "delete-account-confirmation", "connect-provider-modal", "project-create-modal", "project-invite-modal"].includes(event.target.id)) event.target.querySelector("form").requestSubmit();

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

document.addEventListener("dragstart", (event) => {
  if (event.target.closest("se-layout-brand")) event.preventDefault();
});

document.addEventListener("confirm", (event) => {
  if (event.target.matches("se-modal[data-submit-form]")) event.target.querySelector("form").requestSubmit();
  if (event.target.matches("se-modal[data-confirm-next]")) document.getElementById(event.target.dataset.confirmNext).open();
});

document.addEventListener("select", (event) => {
  if (!event.target.matches("se-menu[data-row-actions]")) return;
  if (event.detail.id === "edit") window.location.assign(event.target.dataset.editUrl);
  if (event.detail.id === "action") event.target.parentElement.querySelector("form[data-row-action-form]").requestSubmit();
});

document.addEventListener("select", (event) => {
  if (!event.target.matches("se-menu[data-members-menu]")) return;
  if (event.detail.id === "invite") document.getElementById("project-invite-modal").open();
  if (event.detail.id === "invites") window.location.assign(event.target.dataset.invitesUrl);
});

document.addEventListener("select", (event) => {
  if (!event.target.matches("se-menu[data-history-actions]")) return;
  if (event.detail.id === "restore") document.getElementById(`restore-event-${event.target.dataset.eventId}`).open();
  if (event.detail.id === "export") {
    openExportModal(event.target.dataset.eventId, event.target.dataset.eventDate);
  }
});

document.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-history-more]");
  if (!button || button.hasAttribute("disabled")) return;
  button.setAttribute("disabled", "");
  const response = await fetch(button.dataset.url, {headers: {Accept: "text/vnd.turbo-stream.html"}});
  if (response.ok) Turbo.renderStreamMessage(await response.text());
  else button.removeAttribute("disabled");
});
