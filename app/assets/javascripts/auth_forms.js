import { Application, Controller } from "@hotwired/stimulus";

const application = Application.start();

// se-button attributes are initialization-only in v0.16. Recreate through its public API.
function updateButton(button, text, disabled) {
  if (button.getAttribute("text") === text && button.hasAttribute("disabled") === disabled) return;
  const replacement = button.cloneNode(false);
  replacement.removeAttribute("data-ready");
  replacement.setAttribute("text", text);
  replacement.toggleAttribute("disabled", disabled);
  button.replaceWith(replacement);
}

application.register("auth-form", class extends Controller {
  static targets = ["panel"];

  switch(event) {
    if (!event.detail?.value) return;
    this.panelTargets.forEach(panel => {
      panel.hidden = panel.dataset.method !== event.detail.value;
    });
  }
});

application.register("email-code-request", class extends Controller {
  submit(event) {
    if (this.pending) { event.preventDefault(); return; }
    this.pending = true;
    const button = this.element.querySelector('se-button[type="submit"]');
    if (button) updateButton(button, "Sending…", true);
  }
});

application.register("email-code-resend", class extends Controller {
  static targets = ["button"];
  static values = { readyAt: Number };

  connect() { this.timer = setInterval(() => this.tick(), 1000); this.tick(); }
  disconnect() { clearInterval(this.timer); }

  tick() {
    const seconds = Math.max(0, Math.ceil(this.readyAtValue - Date.now() / 1000));
    updateButton(this.element.querySelector('[data-email-code-resend-target="button"]'), seconds > 0 ? `Resend in ${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}` : "Resend code", seconds > 0);
    if (!seconds) clearInterval(this.timer);
  }

  submit(event) {
    if (this.pending || Date.now() / 1000 < this.readyAtValue) { event.preventDefault(); return; }
    this.pending = true;
    clearInterval(this.timer);
    updateButton(this.element.querySelector('[data-email-code-resend-target="button"]'), "Sending…", true);
  }
});
