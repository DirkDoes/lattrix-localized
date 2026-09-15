import { Application, Controller } from "@hotwired/stimulus";

Application.start().register("auth-form", class extends Controller {
  static targets = ["panel"];

  switch(event) {
    if (!event.detail?.value) return;
    this.panelTargets.forEach(panel => {
      panel.hidden = panel.dataset.method !== event.detail.value;
    });
  }
});
