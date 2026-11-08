// The initializer installs key insertion for creation, clone and template
// forms. It takes no arguments and can run again after SPA navigation.
(() => {
    // One delegated listener survives form replacement and cached
    // SPA navigation.
    if (window.cloudminSSHKeysClick) return;
    // cloudminSSHKeysClick(event) inserts into the clicked menu's current form.
    window.cloudminSSHKeysClick = event => {
        const entry =
            event.target.closest &&
            event.target.closest('[data-ssh-key-insert]');
        const box = entry && entry.closest('[data-ssh-key-input]');
        const input = box && box.querySelector('textarea[name="ssh_keys"]');
        // Ignore unrelated clicks, automatic entries and locked
        // template fields.
        if (
            !input ||
            input.matches(':disabled') ||
            entry.matches(':disabled, [aria-disabled="true"]')
        )
            return;
        const keys = input.value.trim().split(/\r?\n/).filter(Boolean);
        // identity(key) compares type and bytes, ignoring comment labels.
        const identity = key => key.trim().split(/\s+/).slice(0, 2).join(' ');
        const saved = entry.getAttribute('data-ssh-key-insert');
        // Append new identities without disturbing existing key comments.
        if (!keys.some(key => identity(key) === identity(saved))) {
            keys.push(saved);
            input.value = keys.join('\n');
            // Notify form validation and previews after changing the value.
            input.dispatchEvent(new Event('change', {bubbles: true}));
        }
    };
    document.addEventListener('click', window.cloudminSSHKeysClick);
})();
