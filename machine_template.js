// cloudminTemplateAccessInit() binds access controls after page navigation.
window.cloudminTemplateAccessInit = () => {
    for (const form of document.querySelectorAll('[data-vm-template-access]')) {
        // Theme navigation may initialize the same form more than once.
        if (form.dataset.accessReady) continue;
        form.dataset.accessReady = '1';
        const row = form.querySelector('#vm_keys_row');
        // update() resolves inheritance and hides keys for
        // password-only access.
        const update = () => {
            const auth =
                form.elements.auth_type.value || form.dataset.defaultAuth;
            row.hidden = auth === 'password';
            form.elements.ssh_keys.disabled =
                row.hidden || row.hasAttribute('data-vm-readonly');
        };
        form.addEventListener('change', update);
        // Enhanced selectors also send synthetic jQuery events.
        if (window.jQuery)
            window.jQuery(form).on('change.cloudminTemplateAccess', update);
        update();
    }
};
// Full page loads may execute this asset before its controls are ready.
if (document.readyState === 'loading')
    document.addEventListener(
        'DOMContentLoaded',
        window.cloudminTemplateAccessInit,
        {once: true}
    );
// Theme navigation inserts the form before evaluating its scripts.
else window.cloudminTemplateAccessInit();
