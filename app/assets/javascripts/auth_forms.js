import { Application, Controller } from "@hotwired/stimulus";

const application = Application.start();

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
  submit() {
    const button = this.element.querySelector('se-button[type="submit"]');
    button?.setAttribute("disabled", "");
    button?.setAttribute("text", "Sending…");
  }
});

application.register("email-code-resend", class extends Controller {
  static targets = ["button"];
  static values = { readyAt: Number };

  connect() { this.tick(); this.timer = setInterval(() => this.tick(), 1000); }
  disconnect() { clearInterval(this.timer); }

  tick() {
    const seconds = Math.max(0, Math.ceil(this.readyAtValue - Date.now() / 1000));
    this.buttonTarget.toggleAttribute("disabled", seconds > 0);
    this.buttonTarget.setAttribute("text", seconds > 0 ? `Resend in 0:${String(seconds).padStart(2, "0")}` : "Resend code");
    if (!seconds) clearInterval(this.timer);
  }

  submit(event) {
    if (this.buttonTarget.hasAttribute("disabled")) { event.preventDefault(); return; }
    this.buttonTarget.setAttribute("disabled", "");
    this.buttonTarget.setAttribute("text", "Sending…");
  }
});
