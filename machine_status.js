/* initStatus() installs one channel across full-page and AJAX navigation. */
(() => {
    // createChannel() owns the transport independently of replaceable page markup.
    function createChannel() {
        let container, config, socket, request, retry, detach;
        let attempt = 0, lastMessage = 0, healthy = false;
        const records = new Map();

        // statusWarning(visible) explains why overview actions are unavailable.
        function statusWarning(visible) {
            const warning = container?.querySelector('[data-vm-status-warning]');
            // Detail pages have no overview warning to toggle.
            if (warning) warning.hidden = !visible;
        }

        // fieldsRoot() includes detail tables moved into separate theme panels.
        function fieldsRoot() {
            return container.dataset.vmDetails ? document : container;
        }

        // setField(field, value, [checking]) hides guidance during pending checks.
        // field is a status node with optional data-vm-message guidance.
        // value is status text; checking defaults to false.
        function setField(field, value, checking = false) {
            const message = !checking && field.dataset.vmMessage;
            field.textContent = message
                ? value + (/[.!?…]\s*$/.test(value) ? ' ' : '. ') + message
                : value;
        }

        // sshCard(state) uses native card accents without duplicating the message.
        function sshCard(state) {
            const card = container.querySelector('#cloudmin-ssh-status');
            // Only the SSH page uses the standalone service card.
            if (!card) return;
            card.classList.remove('ui_card_success', 'ui_card_warning', 'ui_card_danger');
            card.classList.add('ui_card_' + state);
        }

        // headerStatus(vm) also updates console pages without a pending alert.
        function headerStatus(vm) {
            const state = document.querySelector('.vm-pending-state');
            if (state) {
                // Console headers omit this badge;
                // editor/details headers share it.
                state.querySelector('span').textContent = label('index_state_' + (vm?.state || 'unknown'));
                state.classList.toggle('ui_badge_success', vm?.state === 'running');
                state.classList.toggle('ui_badge_neutral', vm?.state !== 'running');
            }
            const pending = document.querySelector('[data-vm-header-pending]');
            // An unavailable comparison must not clear a saved-change warning.
            if (pending && vm?.pending != null) pending.hidden = !Object.keys(vm.pending).length;
        }

        // actionNotice(vm) retires accepted power requests once status confirms them.
        function actionNotice(vm) {
            const notice = document.querySelector('[data-vm-action-notice]');
            if (!notice || !vm || notice.dataset.vmActionId !== vm.uuid) return;
            const action = notice.dataset.vmActionNotice;
            const complete = ['start', 'resume'].includes(action)
                ? vm.active && ['running', 'blocked'].includes(vm.state)
                : ['shutdown', 'force_off'].includes(action)
                    ? !vm.active && vm.state === 'shutoff'
                    : action === 'suspend' && vm.state === 'paused';
            // Reboot/reset cannot be confirmed from Running alone.
            if (complete) notice.hidden = true;
        }

        // powerControls(vm) updates all actions; null hides power controls.
        // Hidden entries are disabled so keyboard navigation skips them too.
        function powerControls(vm) {
            if (vm && !vm.active) delete container.dataset.vmShutdownRequested;
            const running = !!(vm?.active && ['running', 'blocked'].includes(vm.state)) && !container.dataset.vmShutdownRequested;
            const visible = {
                start: vm?.state === 'shutoff' && !vm.active,
                running, paused: vm?.state === 'paused', active: !!vm?.active,
                cycle: running && !!Object.keys(vm.pending || {}).length
            };
            const more = container.querySelector('[data-vm-more]');
            const menu = more?.querySelector('details');
            for (const [state, show] of Object.entries(visible)) {
                for (const control of container.querySelectorAll(`[data-vm-${state}]`)) {
                    // Close an open menu when a status change alters its actions.
                    if (control.hidden === show && menu) {
                        if (control.contains(document.activeElement)) menu.querySelector('summary').focus();
                        menu.open = false;
                    }
                    control.hidden = !show;
                    if (control.matches('.ui_dropdown_item')) {
                        // Keep menu keyboard navigation in sync with visibility.
                        control.setAttribute('aria-disabled', String(!show));
                        if (control.tagName === 'BUTTON') control.disabled = !show;
                    }
                }
            }
            // A delegated operator may have no available secondary actions.
            if (more) {
                more.hidden = ![...more.querySelectorAll('.ui_dropdown_item')].some(item => !item.hidden);
                // An empty menu must also close when guest status disappears.
                if (more.hidden) menu.open = false;
            }
        }

        // unavailable() clears stale health and prevents stale overview actions.
        function unavailable() {
            healthy = false;
            // A removed view has no stale fields left to clear.
            if (!container?.isConnected) return;
            container.dataset.statusConnected = '0';
            headerStatus(null);
            window.cloudminPendingUpdate?.(null);
            const root = fieldsRoot();
            for (const field of root.querySelectorAll('[data-vm-field]')) setField(field, config.unavailable);
            for (const field of root.querySelectorAll('[data-vm-resource], [data-vm-guest], [data-vm-disk]')) field.textContent = config.usage.unavailable;
            filesystems(root);
            sshCard('warning');
            // Hide details actions while the guest's power state is unknown.
            powerControls(null);
            // Block power actions until fresh inventory arrives after
            // reconnect.
            if (config.id === 'overview') {
                statusWarning(true);
                for (const badge of container.querySelectorAll('#cloudmin-machines .ui_badge > span')) badge.textContent = config.unavailable;
                for (const link of container.querySelectorAll('[data-vm-id]')) delete link.closest('tr').dataset.power;
                for (const input of container.querySelectorAll('#cloudmin-machines input[type="checkbox"]')) input.disabled = true;
            }
        }

        // label(key) uses the current viewer's translations, never the collector's.
        function label(key) { return config.labels[key] || config.unavailable; }

        // size(bytes) formats capacities and rates consistently in both views.
        function size(bytes) {
            // Missing or invalid measurements must not look like zero usage.
            if (bytes == null || !Number.isFinite(bytes) || bytes < 0) return config.usage.unavailable;
            let unit = 0;
            while (bytes >= 1024 && unit < config.units.length - 1) { bytes /= 1024; unit++; }
            return (Math.round(bytes * 100) / 100) + ' ' + config.units[unit];
        }

        // resourceValues(record) never substitutes host allocation for guest use.
        function resourceValues(record) {
            const vm = record?.vm, r = record?.resources || {}, guest = record?.guest || {};
            // usage(percent, total) keeps known capacity when usage is unknown.
            const usage = (percent, total) => total == null ? config.usage.unavailable :
                (percent == null ? config.usage.missing.replace('$1', total) :
                    config.usage.format.replace('$1', percent).replace('$2', total));
            const capacity = r.disk_capacity_bytes;
            const memory = r.memory_bytes ?? (vm?.memory_kib == null ? null : vm.memory_kib * 1024);
            const used = guest.filesystem_used_bytes;
            // Agent totals may not match attached capacity; do not invent a
            // ratio.
            const diskPercent = vm?.active && capacity > 0 && used != null && used <= capacity
                ? Math.round(used / capacity * 1000) / 10 : null;
            const values = {
                cpu: usage(r.cpu_percent, r.vcpus ?? vm?.vcpus),
                memory: usage(r.memory_percent, memory == null ? null : size(memory)),
                disk: usage(diskPercent, capacity == null ? null : size(capacity)),
                memory_used: size(r.memory_used_bytes), disk_used: size(used)
            };
            for (const [name, key] of Object.entries({ disk_read: 'disk_read_bytes_sec', disk_write: 'disk_write_bytes_sec',
                network_rx: 'network_rx_bytes_sec', network_tx: 'network_tx_bytes_sec' })) {
                values[name] = r[key] == null ? config.usage.unavailable : config.usage.rate.replace('$1', size(r[key]));
            }
            return values;
        }

        // resources(root, record) fills only text nodes, including guest-supplied names.
        function resources(root, record) {
            const values = resourceValues(record);
            for (const field of root.querySelectorAll('[data-vm-resource]')) field.textContent = values[field.dataset.vmResource];
            for (const field of root.querySelectorAll('[data-vm-guest]')) {
                const value = record?.guest?.[field.dataset.vmGuest];
                // Keep OS names and versions without a trailing release codename.
                field.textContent = (field.dataset.vmGuest === 'os' && value
                    ? value.replace(/\s+\([^()]*\)$/, '') : value) || config.usage.unavailable;
            }
            for (const field of root.querySelectorAll('[data-vm-disk]')) {
                field.textContent = size(record?.resources?.disks?.[field.dataset.vmDisk]?.[field.dataset.diskField]);
            }
            filesystems(root, record);
        }

        // filesystems(root, [record]) replaces empty or stale tables with an explanation.
        function filesystems(root, record) {
            const content = root.querySelector('[data-vm-filesystems]');
            // Only details pages contain the filesystem accordion.
            if (!content) return;
            // Themes may wrap the data table in a layout table. Find the
            // table that owns the column headings instead of the wrapper.
            const heading = content.querySelector('thead, tr.ui_columns_heads');
            const table = heading?.closest('table');
            if (!table) return;
            const vm = record?.vm, guest = record?.guest, health = record?.health;
            const rows = vm?.active && !guest?.error ? guest?.filesystems || [] : [];
            // Some themes put headings in tbody; retain them in a separate section.
            let body = table.querySelector('tbody[data-vm-filesystem-rows]');
            if (!body) { body = table.createTBody(); body.dataset.vmFilesystemRows = '1'; }
            body.replaceChildren();
            for (const fs of rows) {
                const row = document.createElement('tr');
                for (const value of [fs.name, fs.mountpoint, fs.fstype, size(fs['total-bytes']), size(fs['used-bytes'])]) {
                    const cell = document.createElement('td'); cell.textContent = value || config.usage.unavailable; row.append(cell);
                }
                body.append(row);
            }
            // Keep the hint and headings hidden whenever there are no current rows.
            content.hidden = !rows.length;
            root.querySelector('[data-vm-filesystems-warning]').hidden = !!rows.length;
            const state = !vm ? 'unavailable' : !vm.active ? 'stopped'
                : guest?.filesystems && !guest.error ? 'empty'
                : guest?.error || health?.error || health?.agent === 'unavailable'
                    || !['running', 'blocked'].includes(vm.state) ? 'unavailable' : 'checking';
            root.querySelector('[data-vm-filesystems-message]').textContent = config.filesystems[state];
        }

        // details(record) distinguishes power, agent and SSH evidence.
        function details(record) {
            const vm = record?.vm, health = record?.health;
            headerStatus(vm);
            window.cloudminPendingUpdate?.(vm);
            const root = fieldsRoot();
            const values = {
                name: vm?.name || config.unavailable,
                persistent: !vm ? config.unavailable : vm.persistent ? config.yes : config.no,
                autostart: vm?.autostart == null ? config.unavailable : vm.autostart ? config.yes : config.no,
                power: vm ? label('index_state_' + vm.state) : config.unavailable,
                addresses: vm?.addresses?.map(item => item.address).join(', ') || config.no_ips || '-',
                agent: !vm ? config.unavailable : !health ? config.checking : health.error ? config.unavailable : label('vm_agent_' + health.agent),
                ssh: !vm ? config.unavailable : !health ? config.checking : health.error ? config.unavailable : health.ssh_address
                    ? label('vm_ssh_responding').replace(/\$1/g, health.ssh_address).replace(/\$2/g, health.ssh_port || 22)
                    : label('vm_ssh_' + health.ssh).replace(/\$1/g, health.ssh_port || 22)
            };
            // Keep login guidance hidden while the SSH check is pending.
            for (const field of root.querySelectorAll('[data-vm-field]')) {
                const checking = field.dataset.vmField === 'ssh' && !!vm && !health;
                setField(field, values[field.dataset.vmField] || config.unavailable, checking);
            }
            container.dataset.power = vm?.state || 'unknown';
            container.dataset.ssh = health?.ssh || 'unknown';
            actionNotice(vm);
            powerControls(vm);
            resources(root, record);
            // Only a confirmed SSH response is green; every other state is orange.
            sshCard(vm && health && !health.error && health.ssh === 'responding' && health.ssh_address
                ? 'success' : 'warning');
            // Reopen an editor waiting for shutdown only when the VM has stopped.
            // Health probes and paused guests cannot complete that wait.
            const ready = config.reopen === 'edit_machine'
                ? vm?.state === 'shutoff' && !vm.active
                : health?.[config.reopen + '_available'];
            // Reopen the requested page only when its live readiness check succeeds.
            if (!config.readonly && config.reopen && ready) {
                config.reopen = ''; // Further deltas must not repeat navigation.
                // Let the page's navigation handlers process the link.
                // Other themes follow the link in the current document or frame.
                const link = document.createElement('a');
                link.href = config.url;
                link.hidden = true;
                container.append(link);
                link.click();
                link.remove();
            }
        }

        // overview(id, [record]) updates or adds a row; no record removes it.
        function overview(id, record) {
            const table = container.querySelector('#cloudmin-machines table');
            // A replaced or non-inventory view has no rows to update.
            if (!table) return;
            let link = table.querySelector('[data-vm-id="' + id + '"]');
            let row = link?.closest('tr');
            // Removal deltas delete only the corresponding guest row.
            if (!record) { row?.remove(); return; }
            const vm = record.vm;
            const cells = (config.rows[vm.state] || config.rows.unknown).map(html => String(html).replaceAll('00000000-0000-0000-0000-000000000000', id));
            // Build new rows from server-generated templates; names stay text.
            if (!row) {
                row = document.createElement('tr');
                for (const html of cells) { const cell = document.createElement('td'); cell.innerHTML = html; row.append(cell); }
                (table.tBodies[0] || table).append(row);
                link = row.querySelector('[data-vm-id]');
            }
            link.textContent = vm.name;
            // Column IDs keep live updates aligned with the configured table.
            // Older page markup without IDs uses the original full column order.
            const columns = config.columns || ['name', 'state', 'ips', 'cpu', 'memory', 'disk', 'macs', 'persistent', 'autostart', 'controls'];
            // cell(name) finds the visible cell, or returns undefined if hidden.
            const cell = name => row.cells[columns.indexOf(name)];
            // template(name) finds matching HTML in the current power-state row.
            const template = name => cells[columns.indexOf(name)];
            // Replace only fields whose meaning changed; keep toggle focus and forms.
            if (row.dataset.power !== vm.state) {
                // Keep state and controls independent when optional columns are absent.
                if (cell('state')) cell('state').innerHTML = template('state');
                // A hidden controls column must not be recreated by live status.
                if (cell('controls')) cell('controls').innerHTML = template('controls');
                row.dataset.power = vm.state;
            }
            // Keep pending badges until a fresh XML comparison confirms the change.
            const pending = row.querySelector('[data-vm-pending-badge]');
            if (pending && vm.pending != null) pending.hidden = !Object.keys(vm.pending).length;
            const ips = cell('ips');
            if (ips) {
                // Optional address columns do not affect health or SSH discovery.
                ips.replaceChildren();
                for (const [index, address] of (vm.addresses || []).entries()) {
                    // Separate multiple addresses without adding a leading blank line.
                    if (index) ips.append(document.createElement('br'));
                    const text = document.createElement('tt'); text.textContent = address.address; ips.append(text);
                }
                // An empty address list still needs the translated placeholder.
                if (!vm.addresses?.length) ips.textContent = config.no_ips;
            }
            resources(row, record);
            // Guest identifiers update only when their columns are visible.
            if (cell('macs')) cell('macs').textContent = vm.macs?.join(', ') || '-';
            // Persistence is optional too, and uses the page's translated labels.
            if (cell('persistent')) cell('persistent').textContent = vm.persistent ? config.yes : config.no;
            const boot = cell('autostart');
            // The remaining updates concern only the optional host-boot control.
            if (!boot) return;
            const policy = vm.persistent && vm.autostart != null;
            // Transient guests and unknown policies cannot have a boot toggle.
            if (row.dataset.policy !== String(policy)) {
                boot.innerHTML = policy ? template('autostart') : '';
                row.dataset.policy = String(policy);
            }
            const toggle = boot.querySelector('input[type="checkbox"]');
            // The saved policy updates the visible toggle and its POST payload.
            if (toggle) {
                toggle.checked = !!vm.autostart; toggle.disabled = false;
                toggle.setAttribute('aria-label', config.boot_label + ': ' + vm.name);
                toggle.form.elements.enabled.value = vm.autostart ? '1' : '0';
            // Read-only or unsupported controls show the policy as plain text.
            } else boot.textContent = vm.autostart == null ? config.unavailable : vm.autostart ? config.yes : config.no;
        }

        // render(message) applies status updates or reloads after an ACL change.
        function render(message) {
            // Rebuild controls after ACL changes, including on hidden pages.
            if (message.type === 'access_changed') { window.location.reload(); return; }
            // Hidden pages request a fresh snapshot when they become visible.
            if (!container?.isConnected || document.hidden) return;
            // Collector errors invalidate the displayed measurements and
            // controls.
            if (message.type === 'error') { unavailable(); return; }
            // Heartbeats keep transport liveness without changing rendered
            // data.
            if (message.type !== 'status') return;
            healthy = true; attempt = 0; container.dataset.statusConnected = '1';
            statusWarning(false);
            // A snapshot replaces the cache; deltas below change individual
            // guests.
            if (message.full) {
                const incoming = new Set(Object.keys(message.changed));
                for (const id of records.keys()) if (!incoming.has(id)) { if (config.id === 'overview') overview(id); }
                // Initial HTML may contain guests deleted before the socket opened.
                if (config.id === 'overview') for (const link of container.querySelectorAll('[data-vm-id]')) {
                    if (!incoming.has(link.dataset.vmId)) link.closest('tr').remove();
                }
                records.clear();
            }
            for (const id of message.removed || []) { records.delete(id); if (config.id === 'overview') overview(id); }
            for (const [id, record] of Object.entries(message.changed || {})) {
                records.set(id, record); if (config.id === 'overview') overview(id, record);
            }
            // A detail view renders only its target, including target removal.
            if (config.id !== 'overview') { details(records.get(config.id)); return; }
            // Overview counts describe the full retained snapshot, not this
            // delta.
            const counts = { vms: records.size, running: [...records.values()].filter(record => record.vm.active).length };
            if ('jobs' in message) counts.jobs = message.jobs ?? config.unavailable;
            for (const [name, count] of Object.entries(counts)) {
                const value = container.querySelector('[data-vm-count="' + name + '"]');
                if (value) value.textContent = count;
            }
            const empty = container.querySelector('[data-vm-empty]');
            if (empty) empty.hidden = !!records.size;
            const table = container.querySelector('[data-vm-table]');
            if (table) table.hidden = !records.size;
            const discoveryError = container.querySelector('[data-vm-discovery-error]');
            if (discoveryError) discoveryError.hidden = true;
            // Themes can reapply action styling without replacing rows or sorting.
            container.dispatchEvent(new CustomEvent('cloudmin-status-updated', { bubbles: true }));
            const jq = window.jQuery;
            if (jq) jq(container).find('#cloudmin-machines table').trigger('update', [false]);
        }

        // subscribe() changes the visible VM without creating another connection.
        function subscribe() {
            // Reuse an open channel; visibility pauses collection for this
            // viewer.
            if (socket?.readyState === 1 && config) socket.send(JSON.stringify({ id: config.id,
                paused: document.hidden || !container?.isConnected, snapshot: !document.hidden }));
        }

        // connect() uses HTTP only for socket setup; reconnects back off after failure.
        async function connect() {
            // Avoid duplicate setup requests and work for hidden or removed
            // views.
            if (!container?.isConnected || document.hidden || request || socket) return;
            const controller = request = new AbortController();
            const timeout = setTimeout(() => controller.abort(), 10000);
            try {
                const response = await fetch(config.endpoint, { credentials: 'same-origin', cache: 'no-store', signal: controller.signal });
                if (!response.ok) throw new Error('Status setup failed');
                const result = await response.json();
                // A setup failure cannot produce a usable WebSocket endpoint.
                if (!result.socket_url) throw new Error('Status unavailable');
                // Navigation may have aborted or replaced this setup request.
                if (request !== controller || !container?.isConnected) return;
                const ws = socket = new WebSocket(result.socket_url);
                lastMessage = Date.now();
                ws.addEventListener('open', subscribe);
                // message(event) accepts frames only from the current
                // transport.
                ws.addEventListener('message', event => {
                    if (socket !== ws) return;
                    lastMessage = Date.now();
                    try { render(JSON.parse(event.data)); } catch (_) { ws.close(); }
                });
                // error(event) enters the shared close-and-retry path.
                ws.addEventListener('error', () => ws.close());
                // close(event) clears stale status and schedules a reconnect.
                ws.addEventListener('close', () => {
                    if (socket !== ws) return;
                    socket = undefined; unavailable(); reconnect();
                });
            } catch (_) { if (request === controller) { unavailable(); reconnect(); } }
            finally { clearTimeout(timeout); if (request === controller) request = undefined; }
        }

        // reconnect() retries transport setup, never falls back to status polling.
        function reconnect() {
            clearTimeout(retry);
            // Backoff applies only while a visible page still needs the
            // channel.
            if (container?.isConnected && !document.hidden) retry = setTimeout(connect, Math.min(30000, 1000 * 2 ** Math.min(attempt++, 5)));
        }

        // close() releases only status resources; SSH and console sessions are separate.
        function close() {
            clearTimeout(retry); clearTimeout(detach);
            request?.abort(); request = undefined;
            const ws = socket; socket = undefined; ws?.close();
            container = undefined; config = undefined; records.clear();
        }

        // bind() reuses the channel when navigation evaluates this script again.
        function bind() {
            const next = document.getElementById('cloudmin-vm-status');
            // Unrelated pages and repeated initialization need no new binding.
            if (!next || next === container) return;
            clearTimeout(detach); detach = undefined;
            container = next; config = JSON.parse(next.dataset.config); records.clear();
            healthy = false;
            if (socket?.readyState === 1) {
                // Force a snapshot even when returning to the same VM's new markup.
                socket.send(JSON.stringify({ id: config.id, paused: document.hidden, snapshot: true }));
            // A new or closed transport needs setup before subscribing.
            } else connect();
        }
        // navigation(records) rebinds replacement markup before idle cleanup.
        const observer = new MutationObserver(() => {
            bind();
            // Give AJAX navigation a brief gap to insert its replacement view.
            if (container && !container.isConnected && !detach) {
                subscribe();
                // detachExpired() closes only if no replacement was bound.
                detach = setTimeout(() => { detach = undefined; if (!container?.isConnected) close(); }, 1000);
            }
        });
        observer.observe(document.body, { childList: true, subtree: true });
        // visibilitychange(event) resumes with a snapshot and checks liveness.
        document.addEventListener('visibilitychange', () => {
            // Navigation away from Cloudmin leaves no subscription to resume.
            if (!config) return;
            // Background throttling may have hidden a dead transport.
            if (!document.hidden && socket && Date.now() - lastMessage > 60000) { socket.close(); return; }
            subscribe();
            if (!socket && !document.hidden) { clearTimeout(retry); connect(); }
        });
        // submit(event) prevents stale overview actions before theme handlers
        // run.
        document.addEventListener('submit', event => {
            // Block inventory actions while the displayed state cannot be trusted.
            if (config?.id === 'overview' && container?.contains(event.target) && !healthy) {
                event.preventDefault();
                // Theme AJAX handlers must not submit an action we just blocked.
                event.stopImmediatePropagation();
                statusWarning(true);
                const toggle = event.target.querySelector('input[type="checkbox"]');
                // Restore a blocked toggle to the last confirmed server value.
                if (toggle) {
                    const vm = records.get(event.target.elements.id.value)?.vm;
                    toggle.checked = vm ? !!vm.autostart : toggle.defaultChecked;
                    event.target.elements.enabled.value = toggle.checked ? '1' : '0';
                }
            }
        }, true);
        // heartbeatCheck() detects dead transports without VM or SSH probes.
        setInterval(() => {
            if (!document.hidden && socket && Date.now() - lastMessage > 60000) socket.close();
        }, 15000);
        // Back/forward cache restores the same document and its event listeners.
        window.addEventListener('pagehide', close);
        window.addEventListener('pageshow', bind);
        return { bind };
    }
    // cloudminStatusInit() binds current markup using the document's shared
    // channel.
    window.cloudminStatusInit = () => {
        // The script can be evaluated during navigation to an unrelated page.
        if (!document.getElementById('cloudmin-vm-status')) return;
        window.cloudminStatusChannel ||= createChannel();
        window.cloudminStatusChannel.bind();
    };
    // Initial document parsing must finish before looking for the page
    // container.
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', window.cloudminStatusInit, { once: true });
    // Theme navigation can evaluate this script after DOMContentLoaded.
    else window.cloudminStatusInit();
})();
