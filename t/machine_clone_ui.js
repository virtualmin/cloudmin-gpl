// Check clone form transitions, including theme reinitialization.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const fields = {}, rows = {}, handlers = {};
// Model only the form controls and DOM hooks used by the real initializer.
for (const name of ['clone_mode','auth_type','hostname_set','start','autostart','template','plan',
    'username','ssh_keys','network','pool','address_mode','gateway4','gateway6','dns','host_ssh_key',
    'cpus','memory_mib','memory_mib_units','disk_gib','disk_gib_units','shutdown','nvram_mode']) {
    fields[name] = {value:'',checked:false,dispatchEvent(){}};
}
Object.assign(fields.clone_mode,{value:'prepared'});
Object.assign(fields.auth_type,{value:'password'});
for (const kind of ['hostname','password','keys','unchanged']) rows['[data-clone-'+kind+']']={style:{}};
const data={defaults:{cpus:2,memory_mib:2048,disk_gib:20,network:'source-net',pool:'source-pool'},
    presets:{template:{default:'base',entries:[{id:'base',settings:{auth_type:'password'}},
        {id:'virtualmin',settings:{software:'virtualmin-pro',require_fqdn:1,auth_type:'keys',pool:'',network:''}}]},
        plan:{default:'base',entries:[{id:'base',settings:{cpus:2,memory_mib:2048,disk_gib:20}},
            {id:'large',settings:{cpus:4,memory_mib:4096,disk_gib:40}}]}}};
const form={dataset:{},elements:{namedItem:name=>fields[name]},
    querySelector:()=>({textContent:JSON.stringify(data)}),querySelectorAll:selector=>[rows[selector]],
    addEventListener:(event,handler)=>handlers[event]=handler};
const context={window:{},Event,document:{getElementById:()=>form}};
vm.runInNewContext(fs.readFileSync('machine_clone.js','utf8'),context);
// Initial access uses a password, while firmware follows source consistency.
assert.equal(rows['[data-clone-password]'].hidden,false);
assert.equal(rows['[data-clone-keys]'].hidden,true);
fields.shutdown.value='1';
handlers.change({target:{name:'shutdown'}});
assert.equal(fields.nvram_mode.value,'copy','clean shutdown permits copying firmware');
fields.shutdown.value='0';
handlers.change({target:{name:'shutdown'}});
assert.equal(fields.nvram_mode.value,'fresh','live cloning uses fresh firmware');
fields.nvram_mode.value='copy';
handlers.change({target:{name:'nvram_mode'}});
assert.equal(fields.nvram_mode.value,'copy','explicit firmware choices reach server validation');
fields.template.value='virtualmin';
// Templates change access defaults without enabling a separate hostname.
handlers.change({target:{name:'template'}});
assert.equal(fields.hostname_set.checked,false,'FQDN requirement never opens a separate hostname');
assert.equal(rows['[data-clone-password]'].hidden,true);
assert.equal(rows['[data-clone-keys]'].hidden,false);
assert.equal(fields.network.value,'source-net','empty preset retains source attachment');
assert.equal(fields.pool.value,'source-pool','empty preset retains source pool');
fields.plan.value='large';
// Selecting and clearing a plan keeps the displayed byte units consistent.
handlers.change({target:{name:'plan'}});
assert.equal(fields.memory_mib.value,'4');
assert.equal(fields.memory_mib_units.value,String(1024**3));
fields.plan.value='';
handlers.change({target:{name:'plan'}});
assert.equal(fields.memory_mib.value,'2','clearing plan restores source resources');
fields.clone_mode.value='unchanged';
// Unchanged copies submit explicit stopped values and survive reinitialization.
handlers.change({target:{name:'clone_mode'}});
assert.equal(rows['[data-clone-unchanged]'].hidden,false);
assert.equal(fields.start.value,'0');
assert.equal(fields.autostart.value,'0');
assert.equal(fields.start.disabled,true);
handlers.submit();
assert.equal(fields.start.disabled,false,'explicit stopped value is submitted');
context.window.cloudminVmCloneInit();
assert.equal(fields.clone_mode.value,'unchanged','theme reinitialization keeps the user selection');
console.log('PASS: clone credentials, presets, units, unchanged mode and theme initialization');
