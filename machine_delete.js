/* Explain the power action implied by the selected disks. */
// cloudminVmDeleteInit() binds the deletion preview once per rendered form.
window.cloudminVmDeleteInit = () => {
    const form = document.getElementById('vm-delete-confirm-form');
    const note = form?.querySelector('[data-delete-stop]');
    // Stopped guests need no stop preview; revisits must not bind it twice.
    if (!note || form.dataset.deleteReady) return;
    form.dataset.deleteReady = '1';
    // update() keeps the preview in sync; the worker checks actual storage again.
    const update = () => {
        // A retained writable row or live-only
        // dependency requires a clean stop.
        const retained = note.dataset.forceBlocked === '1' ||
            Array.from(form.querySelectorAll('[data-delete-writable="1"]'))
                .some(row => !row.querySelector('input[name="disks"]')?.checked);
        note.querySelector('[data-delete-stop-text]').textContent =
            retained ? note.dataset.clean : note.dataset.force;
    };
    form.addEventListener('change', update);
    update();
};
// Wait for the form when the script loads before the document is ready.
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', window.cloudminVmDeleteInit, { once: true });
// Deferred theme loading may run the script after parsing has already finished.
else window.cloudminVmDeleteInit();
