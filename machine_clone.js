(function () {
    'use strict';
    // init() runs after full loads and theme navigation, once per form.
    function init() {
        var form = document.getElementById('vm-clone-form');
        if (!form || form.dataset.cloneReady) return;
        form.dataset.cloneReady = '1';
        var data = JSON.parse(
            form.querySelector('[data-clone-presets]').textContent
        );

        // field(name) finds one named form control.
        function field(name) {
            return form.elements.namedItem(name);
        }

        // set(name, value) updates existing controls without creating
        // hidden inputs.
        function set(name, value) {
            var node = field(name);
            if (node) node.value = value == null ? '' : String(value);
        }

        // show(selector, visible) keeps theme table cells and
        // headings together.
        function show(selector, visible) {
            form.querySelectorAll(selector).forEach(function (node) {
                node.hidden = !visible;
                node.style.display = visible ? '' : 'none';
            });
        }

        // refresh() matches credential visibility and startup to the
        // clone mode.
        function refresh() {
            var prepared = field('clone_mode').value === 'prepared';
            var auth = field('auth_type').value;
            show(
                '[data-clone-hostname]',
                prepared && field('hostname_set').checked
            );
            show('[data-clone-password]', prepared && auth !== 'keys');
            show('[data-clone-keys]', prepared && auth !== 'password');
            show('[data-clone-unchanged]', !prepared);
            if (!prepared) {
                // Copies retaining source identity must remain stopped
                // for review.
                set('start', 0);
                set('autostart', 0);
            }
            field('start').disabled = !prepared;
            field('autostart').disabled = !prepared;
        }

        // preset(kind) applies only clone-relevant template or plan settings.
        function preset(kind) {
            var group = data.presets[kind];
            var selected = group.entries.find(function (entry) {
                return entry.id === field(kind).value;
            });
            var base = group.entries.find(function (entry) {
                return entry.id === group.default;
            });
            var values = Object.assign(
                {},
                data.defaults,
                selected && base ? base.settings : {},
                selected ? selected.settings : {}
            );
            // Limit preset fields so installation settings cannot enter
            // a clone.
            var names =
                kind === 'plan'
                    ? ['cpus', 'memory_mib', 'disk_gib']
                    : [
                          'username',
                          'auth_type',
                          'ssh_keys',
                          'pool',
                          'network',
                          'address_mode',
                          'gateway4',
                          'gateway6',
                          'dns',
                          'host_ssh_key',
                          'start',
                          'autostart'
                      ];
            names.forEach(function (name) {
                if (values[name] == null) return;
                // Convert stored resource units to the form's MiB/GiB controls.
                if (name === 'memory_mib' || name === 'disk_gib') {
                    var bytes =
                        values[name] *
                        Math.pow(1024, name === 'memory_mib' ? 2 : 3);
                    var unit =
                        bytes >= Math.pow(1024, 3)
                            ? Math.pow(1024, 3)
                            : Math.pow(1024, 2);
                    set(name, bytes / unit);
                    set(name + '_units', unit);
                } else {
                    // Empty pool or network defaults keep the
                    // source attachment.
                    set(
                        name,
                        values[name] ||
                            (name === 'pool' || name === 'network'
                                ? data.defaults[name]
                                : values[name])
                    );
                }
            });
            var address = field('address_mode');
            // Refresh static field visibility after changing the select
            // in code.
            if (address)
                address.dispatchEvent(new Event('change', {bubbles: true}));
            refresh();
        }
        form.addEventListener('change', function (event) {
            // Copy firmware only when the source will be stopped for the copy.
            if (event.target.name === 'shutdown') {
                set(
                    'nvram_mode',
                    field('shutdown').value === '1' ? 'copy' : 'fresh'
                );
            }
            // Preset changes fill controls; other edits only
            // refresh visibility.
            if (
                event.target.name === 'template' ||
                event.target.name === 'plan'
            )
                preset(event.target.name);
            // Ordinary field edits keep the current preset values.
            else refresh();
        });
        // Disabled controls are omitted; submit explicit zeroes for
        // unchanged copies.
        form.addEventListener('submit', function () {
            field('start').disabled = false;
            field('autostart').disabled = false;
        });
        refresh();
    }
    window.cloudminVmCloneInit = init;
    init();
})();
