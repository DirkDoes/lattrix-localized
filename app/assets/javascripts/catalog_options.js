function refresh(form) {
  const mode = form.querySelector('se-segmented-control').value;
  form.querySelector('[data-validation-options]').hidden = !form.querySelector('[data-pr-validation]').checked;
  form.querySelectorAll('[data-plural-check]').forEach(row => row.hidden = mode === 'off');
  form.querySelectorAll('[data-plural-description]').forEach(text => text.hidden = text.dataset.pluralDescription !== mode);
}
document.addEventListener('change', event => {
  const form = event.target.closest('[data-catalog-options]');
  if (form) refresh(form);
});
