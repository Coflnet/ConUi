document.addEventListener('DOMContentLoaded', () => {
  const form = document.getElementById('kc-register-form');
  const email = form?.querySelector('#email');
  const group = input => input.closest('.pf-v5-c-form__group, .form-group');
  if (!email || !group(email)) return;

  const fields = ['firstName', 'lastName', 'username']
    .map(id => form.querySelector(`#${id}`))
    .filter(input => input && group(input))
    .map(input => ({input, group: group(input), edited: input.value !== ''}));
  if (!fields.length) return;
  const hasErrors = fields.some(({input}) => input.getAttribute('aria-invalid') === 'true');
  const submittedWithErrors = form.querySelector('[aria-invalid="true"]') !== null;
  const profile = document.createElement('details');
  const summary = document.createElement('summary');
  summary.textContent = document.documentElement.lang.toLowerCase().startsWith('de')
    ? 'Profil bearbeiten' : 'Edit profile';
  profile.append(summary, ...fields.map(field => field.group));
  email.type = 'email';
  form.prepend(group(email), profile);

  fields.forEach(field => {
    if (submittedWithErrors) field.edited = true;
    field.input.addEventListener('input', () => { field.edited = true; });
    // Required username validation must never target a collapsed field.
    field.input.addEventListener('invalid', () => { profile.open = true; });
  });

  function update() {
    const ready = email.value.trim() !== '' && email.validity.valid;
    if (ready) {
      const parts = email.value.trim().split('@')[0].split('+')[0]
        .replace(/\p{Nd}/gu, '').toLocaleLowerCase().split(/[._]+/).filter(Boolean);
      const names = parts.every(part => /^[\p{L}][\p{L}'’-]*$/u.test(part)) ? parts : [];
      const capitalize = name => name.replace(/(^|[-'’])\p{L}/gu, letter => letter.toLocaleUpperCase());
      const suggestions = {
        username: names.join('.'),
        firstName: capitalize(names[0] || ''),
        lastName: names.slice(1).map(capitalize).join(' '),
      };
      fields.forEach(field => {
        if (!field.edited) field.input.value = suggestions[field.input.id];
      });
    }
    const username = fields.find(({input}) => input.id === 'username')?.input;
    if (hasErrors || (ready && username && !username.value)) profile.open = true;
  }
  email.addEventListener('input', update);
  email.addEventListener('change', update);
  window.addEventListener('pageshow', update);
  update();
});
