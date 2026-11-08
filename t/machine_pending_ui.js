/* Check live pending summaries without a browser or DOM dependencies. */
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
// closest(selector) models the wrapper around an initially hidden form.
const cluster = {hidden: false};
const action = {hidden: true, closest: () => cluster},
    title = {};
// Model only the summary rows and action touched by incoming status messages.
const values = {};
const rows = ['cpu_limit', 'memory_mib', 'boot', 'bootmenu', 'networks'].map(
    field => ({
        dataset: {pendingField: field},
        querySelector: () => (values[field] ||= {})
    })
);
const banner = {
    dataset: {
        pendingConfig: JSON.stringify({
            one: 'Saved. 1 change',
            many: 'Saved. $1 changes',
            values: 'Running: $1, next start: $2',
            yes: 'Yes',
            no: 'No',
            none: 'None',
            boot_labels: {
                roles: {
                    system: 'System disk',
                    seed: 'Cloud-init configuration',
                    disk: 'Disk'
                },
                disks: {vda: 'system', vdb: 'seed'},
                kinds: {
                    hd: 'Disks',
                    interface: 'Network interface',
                    network: 'Network',
                    bridge: 'Bridge'
                }
            }
        })
    },
    querySelector: selector =>
        ({'#vm-power-cycle-form': action, '[data-pending-title]': title})[
            selector
        ],
    querySelectorAll: () => rows
};
const context = {
    window: {},
    document: {
        querySelector: selector =>
            ({
                '[data-vm-pending-banner]': banner,
                '#vm-power-cycle-form': action
            })[selector]
    }
};
vm.runInNewContext(fs.readFileSync('machine_pending.js', 'utf8'), context);
const update = context.window.cloudminPendingUpdate;
// A running guest with one saved difference shows a
// singular actionable summary.
update({state: 'running', pending: {cpu_limit: {running: 2, saved: 3}}});
assert.equal(banner.hidden, false);
assert.equal(title.textContent, 'Saved. 1 change');
assert.equal(values.cpu_limit.textContent, 'Running: 2, next start: 3');
assert.equal(action.hidden, false);
assert.equal(
    cluster.hidden,
    false,
    'pending changes reveal the editor cluster'
);
// Lost status and paused execution prevent power
// cycling while retaining values.
update(null);
assert.equal(
    cluster.hidden,
    true,
    'a lost status channel hides the whole editor cluster'
);
assert.equal(
    banner.hidden,
    false,
    'unknown state retains the saved-change warning'
);
update({
    state: 'paused',
    pending: {
        cpu_limit: {running: 2, saved: 3},
        memory_mib: {running: 512, saved: 2048}
    }
});
assert.equal(title.textContent, 'Saved. 2 changes');
assert.equal(
    values.memory_mib.textContent,
    'Running: 512 MiB, next start: 2 GiB'
);
assert.equal(
    cluster.hidden,
    true,
    'paused guest cannot accidentally be power cycled'
);
// Boot labels must stay readable after polling, including external
// device changes.
update({
    state: 'running',
    pending: {
        boot: {
            running: [{device: 'hd'}],
            saved: [{device: 'disk', target: 'vdb'}]
        }
    }
});
assert.equal(
    values.boot.textContent,
    'Running: Disks, next start: Cloud-init configuration (vdb)'
);
update({
    state: 'running',
    disk_roles: {vdb: 'system'},
    pending: {
        boot: {
            running: [{device: 'disk', target: 'vdb'}],
            saved: [{device: 'disk', target: 'vdz'}]
        }
    }
});
assert.equal(
    values.boot.textContent,
    'Running: System disk (vdb), next start: Disk (vdz)'
);
// Network changes name the MAC and both attachments, with empty
// lists supported.
update({
    state: 'running',
    pending: {
        networks: {
            running: [
                {mac: '52:54:00:11:22:33', type: 'network', source: 'default'}
            ],
            saved: [
                {mac: '52:54:00:11:22:33', type: 'bridge', source: 'br-lan'}
            ]
        }
    }
});
assert.equal(
    values.networks.textContent,
    'Running: 52:54:00:11:22:33: Network default, next start: 52:54:00:11:22:33: Bridge br-lan'
);
assert.equal(cluster.hidden, false);
update({state: 'running', pending: {networks: {running: [], saved: []}}});
assert.equal(values.networks.textContent, 'Running: None, next start: None');
// A successful empty comparison clears the warning after settings take effect.
update({state: 'running', pending: {}});
assert.equal(
    banner.hidden,
    true,
    'matching running and saved settings clear the banner'
);
assert.equal(
    cluster.hidden,
    true,
    'cleared changes leave no empty button cluster'
);
// Details have no grouped wrapper, so their form still owns visibility.
// closest(selector) returns no match on this page.
action.closest = () => null;
update({state: 'running', pending: {}});
assert.equal(action.hidden, true, 'details hide the standalone form');
update({state: 'running', pending: {cpu_limit: {running: 2, saved: 3}}});
assert.equal(action.hidden, false, 'details restore the standalone form');
console.log(
    'Pending summary updates, unknown state and cleared settings passed'
);
