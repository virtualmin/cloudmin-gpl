use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use Test::More;
use File::Temp qw(tempdir);
our ($module_root_directory, $root_directory, %text, %config);
$module_root_directory = "$Bin/..";
$root_directory = $CloudminTest::webmin_root;
require "$Bin/../cloudmin-pages.pl";
require "$Bin/../cloudmin-presets-lib.pl";
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if /^([^=]+)=(.*)$/; }
close($lang);
# Keep persistence, permissions and lock accounting inside an isolated store.
my $dir = tempdir(CLEANUP => 1);
my ($readonly, $delegated, $locks, $unlocks) = ( 0, 0, 0, 0 );
my @audit;
my $store = Cloudmin::Presets->new(directory => $dir,
				   access =>
					   sub { die "read-only\n" if ($_[0] && $readonly); die "denied\n"
			if ($delegated); },
				   lock => sub { $locks++; 1 },
				   unlock => sub { $unlocks++ },
				   template_users => sub { { } },
				   log => sub { push(@audit, [ @_ ]); });

# A read-only first visitor creates no configuration or lock files.
$readonly = 1;
is(scalar(@{$store->list('template')->{'entries'}}), 5,
   'base and four Virtualmin variants on a fresh host');
for my $entry (@{$store->list('template')->{'entries'}}) {
	next if ($entry->{'id'} eq Cloudmin::Presets::default_id());
	my $settings = $entry->{'settings'};
	like($entry->{'name'},
	     qr/\AVirtualmin (?:GPL|Pro) with (?:Apache|Nginx)\z/,
	     'variant name contains only the edition and web server');
	like($entry->{'name'}, $settings->{'virtualmin_bundle'} eq 'LAMP'
		? qr/Apache/
		: qr/Nginx/,
	     'variant web server matches its name');
	is($settings->{'virtualmin_type'}, 'full',
	   'every bundled variant defaults to full installation');
	is($settings->{'require_fqdn'}, 1,
	   'every bundled Virtualmin variant requires a qualified hostname');
	}
is($store->list('template')->{'default'}, '0' x 31 . '1',
   'Default Template is initially selected');
my $builtin = $store->get('template', '0' x 31 . '3');
is($builtin->{'settings'}->{'software'}, 'virtualmin-pro',
   'Pro template selects the Pro installer');
my $base_plan = $store->list('plan');
is($base_plan->{'default'}, Cloudmin::Presets::default_id(),
   'built-in plan is selected on fresh hosts');
is_deeply($base_plan->{'entries'}->[0]->{'settings'},
	  { cpus => 2, memory_mib => 2048, disk_gib => 20 },
	  'default plan has usable resources');
{
	local $store->{'host_cpus'} = sub { 1 };
	is($store->resolve({ plan => Cloudmin::Presets::default_id() })->{'cpus'},
	   1,
	   'factory plan fits a one-CPU host through API resolution');
	}
is_deeply([ glob("$dir/*") ], [ ], 'reads create nothing');
is($store->resolve({ template => Cloudmin::Presets::default_id() })->{'image'},
   'catalogue:rocky-linux-10',
   'fresh creation defaults to a catalogue release before download');
# Template references accept the catalogue's full 96-character ID limit.
my $long_image = 'catalogue:custom-'.('a' x 89);
is($store->validate('template',
		    { name => 'Long ID', settings => { image => $long_image } })
   ->{'settings'}->{'image'}, $long_image,
   'valid long catalogue IDs can be selected');
ok(!eval { $store->validate('template',
			    { name => 'Too long',
			      settings => { image => $long_image.'a' } }); 1 },
   'catalogue IDs over the shared limit are rejected');
# Denied mutations must fail before acquiring a configuration lock.
my $plan = { name => 'Small', description => 'Test',
	     settings => { cpus => 2, memory_mib => 2048, disk_gib => 30 } };
for my $action ( sub { $store->save('plan', $plan) },
		 sub { $store->update('plan', 'default', [ ]) } ) {
	ok(!eval { $action->(); 1 }, 'read-only mutation denied');
	like($@, qr/read-only/, 'read-only error precedes locks');
	}
is($locks, 0, 'no locks on refused mutations');
$readonly = 0;
$delegated = 1;
ok(!eval { $store->save('plan', $plan); 1 },
   'delegated user cannot create plan');
ok(!eval { $store->list('plan'); 1 },
   'delegated user cannot inspect host presets');
$delegated = 0;

# Persist records, enforce unique names, and allow saves from earlier forms.
my $saved = $store->save('plan', $plan);
{
	local $store->{'host_cpus'} = sub { 1 };
	is($store->get('plan',
		       Cloudmin::Presets::default_id())->{'settings'}->{'cpus'},
	   1,
	   'persisted but unedited factory plan still fits a one-CPU host');
	is($store->resolve({ plan => $saved->{'id'} })->{'cpus'}, 2,
	   'explicit custom allocations remain unchanged');
	is($store->resolve({ plan => Cloudmin::Presets::default_id(), cpus =>
									      3 })->{'cpus'}, 3,
	   'explicit CPU input remains subject to normal host validation');
	}
my $id = $saved->{'id'};
like($id, qr/\A[a-f0-9]{32}\z/, 'generated ID');
is((stat("$dir/plans.json"))[2] & 0777, 0600, 'configuration is private');
my $edit = $store->get('plan', $id);
is_deeply($edit->{'settings'}, $plan->{'settings'}, 'allocation round trip');
ok(!eval { $store->save('plan', { %$plan, name => 'SMALL' }); 1 },
   'case-insensitive duplicate name refused');
$store->save('plan', { %$edit, name => 'Updated' });
$store->save('plan',
	     { %$edit, name => 'Resaved', revision => 'previous-revision' });
is($store->get('plan', $id)->{'name'}, 'Resaved',
   'earlier plan form can be saved again');
is($store->get('plan', $id)->{'created'}, $edit->{'created'},
   'resaving retains the original creation date');
ok(!exists($store->get('plan', $id)->{'revision'}),
   'presets no longer expose form revisions');
$edit = $store->get('plan', $id);
$store->update('plan', 'default', [ $id ]);
is($store->list('plan')->{'default'}, $id, 'default plan saved');
my $before = read_file_contents("$dir/plans.json");
ok(!eval { $store->update('plan', 'delete', [ $id, 'x' ]); 1 },
   'invalid bulk member prevents every deletion');
is(read_file_contents("$dir/plans.json"), $before,
   'failed batch leaves file unchanged');

# Templates must reject credentials, guest identity and unsupported fields.
my $template =
	{ name => 'Debian', settings =>
				    { image => 'a' x 32,
				      install_source => 'cloud',
				      username => 'cloudmin', start => 0,
				      autostart => 1,
				      address_mode => 'static',
				      gateway4 => '192.0.2.1',
				      dns => '192.0.2.53' } };
for my $field (
	qw(password password_hash hostname mac ipv4 ipv6 cpus arbitrary virtualmin_serial virtualmin_key)) {
	ok(!eval { $store->save('template', { %$template,
					      settings => { %{$template->{'settings'}},
							    $field => 'secret' } }); 1 },
	   "$field cannot be saved in a template");
	}
for my $case ( [ { cpus => 0 }, qr/CPU.*1 to 1024/ ],
	       [ { memory_mib => 255 }, qr/Memory.*256 to 1073741824 MiB/ ],
	       [ { disk_gib => 0.5 }, qr/Disk size.*1 to 1048576 GiB/ ],
	       [ { memory_mib => [ ] }, qr/Invalid Memory/ ] ) {
	ok(!eval { $store->save('plan',
				{ %$plan,
				  settings => { %{$plan->{'settings'}},
						%{$case->[0]} } }); 1 },
	   'invalid plan allocation refused');
	like($@, $case->[1],
	     'plan validation uses a visible label and allocation units');
	}
# Form parsing uses translated labels for invalid values and unit selections.
for my $case ( [ memory_mib => 'bad', qr/positive number for Memory/ ],
	       [ disk_gib => 'bad', qr/positive number for Disk size/ ],
	       [ memory_mib_units => 'bad', qr/valid units for Memory/ ],
	       [ disk_gib_units => 'bad', qr/valid units for Disk size/ ] ) {
	ok(!eval { preset_form_record('plan',
				      { %{$plan->{'settings'}},
					$case->[0] => $case->[1] }); 1 },
	   'invalid plan form value refused');
	like($@, $case->[2], 'form error names the displayed resource');
	}
# Resolve selected presets while preserving explicit empty and zero overrides.
my $tmpl = $store->save('template', $template);
my $tid = $tmpl->{'id'};
is_deeply($store->resolve({ template => $tid, plan => $id, name => 'guest',
			    cpus => 3, username => '', start => 0 }),
	  { %{$store->get('template',
			  Cloudmin::Presets::default_id())->{'settings'}},
	    %{$template->{'settings'}}, %{$plan->{'settings'}}, template =>
									$tid,
	    plan => $id,
	    name => 'guest', cpus => 3, username => '', start => 0 },
	  'explicit overrides win, including empty and zero');
is($store->resolve({ plan => $id, memory_mib_units =>
					  1024**3 })->{'memory_mib_units'},
   undef,
   'inherited memory cannot acquire a stray multiplier');
is_deeply($store->resolve({ name => 'manual' }), { name => 'manual' },
	  'API does not silently apply global defaults');
my $clone = $store->resolve({ template => $tid, plan => $id }, 'clone');
ok(!exists($clone->{'image'}) && !exists($clone->{'install_source'}),
   'clone defaults omit installation media');
is($clone->{'require_fqdn'}, 0,
   'clone defaults retain the template hostname rule');
is($store->resolve({ template => Cloudmin::Presets::default_id(),
		     require_fqdn =>
			     1 },
		   'clone')->{'require_fqdn'}, 1,
   'explicit clone hostname requirement survives');
is($clone->{'cpus'}, 2, 'clone can reuse plan allocations');
ok(!eval { $store->get('template', '../plans.json'); 1 },
   'paths cannot act as IDs');

# Bundled records retain administrator-written descriptions.
my $builtin_edit = $store->get('template', '0' x 31 . '2');
$store->save('template', { %$builtin_edit, description => 'Local override' });
is($store->get('template', $builtin_edit->{'id'})->{'description'},
   'Local override', 'built-in overrides persist');

# Protected defaults survive delete requests and replace cleared selections.
my $base_id = Cloudmin::Presets::default_id();
ok(!eval { $store->update('plan', 'delete', [ $base_id ]); 1 },
   'Default Plan cannot be deleted');
ok(!eval { $store->update('template', 'delete', [ $base_id ]); 1 },
   'Default Template cannot be deleted');
like($@, qr/Default Template cannot be deleted/,
     'protected template is identified');
ok(!eval { $store->update('template', 'clear_default', [ ]); 1 },
   'separate module default action is gone');
# ISO selection suppresses inherited software, not explicit conflicting input.
my $iso =
	$store->resolve({ template => '0' x 31 . '3',
			  install_source => 'iso' });
ok(!Cloudmin::Software::enabled($iso),
   'ISO override does not inherit guest software');
is($store->resolve({ template => '0' x 31 . '3', install_source => 'iso',
		     software => 'virtualmin-pro' })->{'software'},
   'virtualmin-pro',
   'explicit incompatible software still reaches normal validation');
# Virtualmin templates inherit the current Default Template settings.
my $base_template = $store->get('template', $base_id);
unlike(show_preset_form('template', $base_template, { }, 'token', 'access'),
       qr/<option value=""/,
       'Default Template has a concrete authentication choice');
$store->save('template',
	     { %$base_template, settings =>
					{ %{$base_template->{'settings'}},
					  username => 'alice' } });
is($store->resolve({ template => '0' x 31 . '3' })->{'username'}, 'alice',
   'Virtualmin templates inherit edited Default Template');
$base_template = $store->get('template', $base_id);
$store->save('template',
	     { %$base_template, settings =>
					{ %{$base_template->{'settings'}},
					  username => 'cloudmin' } });

# Native forms retain Virtualmin page names, byteboxes, defaults and copy links.
my $list = show_preset_list('plan', $store->list('plan'), 'token');
like($list, qr/delete_plans\.cgi/,
     'list posts to Virtualmin-style bulk endpoint');
like($list, qr/edit_plan\.cgi/, 'list opens the plan editor');
like($list, qr/Make Default/, 'default action provided');
my $view = show_preset_list('plan', $store->list('plan'));
unlike($view, qr/type="checkbox"|name="token"|Make Default/,
       'read-only list has no action controls');
my $form = show_preset_form('plan', $edit, { }, 'token');
like($form, qr/name="memory_mib_units"/, 'memory uses a bytebox');
like($form, qr/name="disk_gib_units"/, 'disk uses a bytebox');
like($form, qr/name="clone"/, 'copy joins the standard form actions');
my $parsed = preset_form_record('plan', { name => 'Fraction', cpus => 2,
					  memory_mib => 1.5,
					  memory_mib_units => 1024**3,
					  disk_gib => 0.5,
					  disk_gib_units => 1024**4 });
is_deeply($store->validate('plan', $parsed)->{'settings'},
	  { cpus => 2, memory_mib => 1536, disk_gib => 512 },
	  'byteboxes convert before whole-unit validation');
# Plans round fractional MiB from decimal GiB just as creation requests do.
my $rounded_plan = preset_form_record('plan', { name => 'Rounded', cpus => 2,
						memory_mib => 1.2,
						memory_mib_units => 1024**3,
						disk_gib =>
							20 });
is($rounded_plan->{'settings'}->{'memory_mib'}, 1229,
   'plan memory uses the same GiB rounding as creation');
# Creation applies named presets without hiding manual field overrides.
my $options =
	{ capabilities => { cpus => 8 },
	  form_defaults => get_vm_form_defaults({ }),
	  images => [ { id => 'a' x 32, name => 'Debian',
			pool_name => 'default' } ],
	  pools => [ { id => 'pool', name => 'default' } ], networks =>
								    [ { key => 'network:default', name => 'default',
									type => 'network' } ],
	  presets =>
		  { template => $store->list('template'), plan =>
								  $store->list('plan') } };
my $create = show_vm_form($options, { template => $tid }, 'token');
like($create, qr/name="plan"/, 'creation has a plan selector');
unlike($create, qr/>Custom<|Use module defaults/,
       'creation has only named presets');
like($create, qr/name="cpus"[^>]*value="2"/,
     'selected default plan fills resources');
like($create, qr/name="username"[^>]*value="cloudmin"/,
     'template fills access defaults');
like($create, qr/data-vm-presets=/, 'browser receives preset choices');
# The initial value and browser preset data agree on small hosts.
{
	local $store->{'host_cpus'} = sub { 1 };
	my $small = show_vm_form({ %$options, capabilities => { cpus => 1 },
				   presets =>
					   { template => $store->list('template'),
					     plan =>
						     $store->list('plan') } },
				 { plan => Cloudmin::Presets::default_id() },
				 'token');
	like($small, qr/name="cpus"[^>]*value="1"/,
	     'creation form uses one CPU on a one-CPU host');
	my ($json) =
		$small =~ m{<script\b[^>]*data-vm-presets[^>]*>(.*?)</script>}s;
	my ($plan) = grep { $_->{'id'} eq Cloudmin::Presets::default_id() }
		     @{convert_from_json($json)->{'plan'}->{'entries'}};
	is($plan->{'settings'}->{'cpus'}, 1,
	   'switching back to Default Plan keeps the valid CPU count');
	}
# Template scripts must survive Webmin rendering and cannot end the JSON tag.
my $script =
	"cat <<'YAML'\nitems:\n    - 'a  b'\nYAML\nprintf '</script><script>alert(1)</script>'\n";
my $script_form =
	show_vm_form({ %$options, presets =>
					  { template => { default => $tid,
							  entries => [
								  { id => $tid,
								    name => 'Script',
								    settings => { before_script => $script } } ] } } }, { },
		     'token');
my ($preset_json) =
	$script_form =~ m{<script\b[^>]*data-vm-presets[^>]*>(.*?)</script>}s;
ok(defined($preset_json), 'preset data uses a JSON script element');
unlike($preset_json, qr/</, 'script contents cannot close the JSON element');
is(
	WebminCore::convert_from_json(
		$preset_json)->{'template'}->{'entries'}->[0]->{'settings'}->{'before_script'},
	$script,
	'script indentation and repeated spaces survive actual Webmin rendering');
my $custom = show_vm_form($options, { plan => $id, cpus => 7 }, 'token');
like($custom, qr/name="cpus"[^>]*value="7"/,
     'manual selection overrides default plan');

# Section forms and saves must leave unrelated settings intact.
my $existing = $store->get('template', $tid);
my $network_edit = preset_form_record('template', { id => $tid,
						    editmode => 'network',
						    address_mode => 'dhcp',
						    start => 1,
						    name => 'Ignored' },
				      $existing);
is($network_edit->{'name'}, 'Debian',
   'network section cannot rename the template');
is($network_edit->{'settings'}->{'start'}, 0,
   'other section keeps explicit No');
is($network_edit->{'settings'}->{'image'}, 'a' x 32,
   'network edit preserves installation media');
$store->save('template', $network_edit);
my $after_network = $store->get('template', $tid);
is($after_network->{'settings'}->{'address_mode'}, 'dhcp',
   'network section updated');
ok(!exists($after_network->{'settings'}->{'gateway4'}),
   'cleared network field returns to defaults');
my $basic = preset_form_record('template', { id => $tid,
					     editmode => 'basic',
					     name => 'Renamed', description =>
									'Basic edit', require_fqdn => 1 }, $after_network);
is_deeply($basic->{'settings'},
	  { %{$after_network->{'settings'}}, require_fqdn => 1 },
	  'basic edit changes the hostname rule and preserves other sections');
# Browser Back resubmits the earlier section, using the latest saved base.
my $access_input =
	{ id => $tid, editmode => 'access', username => 'alice', auth_type =>
									 'password',
	  revision => 'previous-revision' };
$store->save('template',
	     preset_form_record('template', $access_input, $after_network));
$store->save('template',
	     preset_form_record('template', { id => $tid, editmode => 'network',
					      address_mode => 'static',
					      gateway4 => '192.0.2.254' },
				$store->get('template', $tid)));
$access_input->{'username'} = 'bob';
$store->save('template',
	     preset_form_record('template', $access_input,
				$store->get('template', $tid)));
my $resaved = $store->get('template', $tid)->{'settings'};
is($resaved->{'username'}, 'bob',
   'earlier access form can be edited and saved again');
is($resaved->{'gateway4'}, '192.0.2.254',
   'resaving access preserves the latest network settings');
ok(!eval { template_section('unknown'); 1 }, 'unknown sections refused');
is(template_section('basic', -1)->[0], 'boot',
   'previous wraps to final section');
is(template_section('boot', 1)->[0], 'basic', 'next wraps to first section');
# Section editors expose only their fields and omit read-only mutation controls.
my $section_form = show_preset_form('template', $after_network,
				    { default_auth_type => 'keys' }, 'token',
				    'access');
like($section_form, qr/name="editmode"/,
     'existing template has section navigation');
like($section_form, qr/name="next"/, 'template offers Save and Next');
like($section_form, qr/name="username"/, 'access section has guest account');
unlike($section_form, qr/name="revision"/, 'editor has no stale-form check');
like($section_form, qr/data-vm-template-access="1" data-default-auth="keys"/,
     'access visibility uses Default Template authentication');
like($section_form, qr/id="vm_keys_row"/,
     'SSH key row can be hidden with its label');
like($section_form, qr/machine_template\.js\?\d+/,
     'access editor loads its visibility handler');
unlike($section_form, qr/name="gateway4"|name="image"|<fieldset/,
       'only selected fields and standard tables rendered');
my $readonly_form =
	show_preset_form('template', $after_network, { }, undef, 'access');
unlike($readonly_form, qr/name="token"|name="next"|name="clone"/,
       'read-only editor has no mutation controls');
like($readonly_form, qr/name="username"[^>]*disabled/,
     'read-only controls are disabled individually');
like($readonly_form, qr/<tr[^>]* id="vm_keys_row" data-vm-readonly="1"/,
     'visibility handler preserves read-only controls');
# Default Template selects an image explicitly; other templates can inherit it.
my $choices =
	get_vm_image_choices([ { id => 'catalogue:rocky-linux-10',
				 catalogue_id =>
					 'rocky-linux-10',
				 name => 'Rocky Linux 10', os => 'Rocky Linux',
				 release => '10' } ]);
my $base_images =
	preset_select('image', 'catalogue:rocky-linux-10', $choices, 0, 1);
unlike($base_images, qr/value=""|>Automatic<|>Use Default Template</,
       'base image selector has no automatic or inherited choice');
like($base_images, qr/required/,
     'base image selector requires an explicit choice');
like($base_images, qr/<optgroup\b[^>]*label="Rocky Linux"[^>]*>/,
     'template selector has distribution headings');
like(preset_select('image', '', $choices, 0, 0),
     qr/value="" selected>Use Default Template<\/option>/,
     'other templates retain their inheritance choice');
like(preset_select('pool', '', [ [ 'pool', 'default' ] ], 0, 1),
     qr/>Automatic<\/option>/,
     'storage pool retains automatic selection');
like(preset_select('image', 'removed', $choices, 0, 0),
     qr/value="removed" selected/,
     'missing saved image remains selected for repair');
my $without_image = $store->get('template', $base_id);
delete($without_image->{'settings'}->{'image'});
ok(!eval { $store->save('template', $without_image); 1 },
   'saving the base template without an image is refused');
like($@, qr/Select an image for Default Template/,
     'missing base image reports the required choice');
like(show_preset_list('template', $store->list('template'), 'token'), qr/cp=1/,
     'list offers creation from defaults');
unlike(show_preset_list('template', $store->list('template'), 'token'),
       qr/name="revision_/,
       'list actions do not require displayed revisions');

# Deleting a default removes only its reusable settings, with balanced locks.
$store->save('plan',
	     { %$edit, description => 'Changed since the list was opened' });
$store->update('plan', 'delete', [ $id ]);
is_deeply($store->list('plan'), $base_plan,
	  'deleting custom default restores Default Plan');
ok(!eval { $store->save('plan', $edit); 1 },
   'saving a deleted plan does not recreate it');
like($@, qr/no longer exists/, 'missing plan error identifies deletion');
is($locks, $unlocks, 'every acquired lock is released on success and failure');
is($audit[0]->[1], 'plan', 'audit records preset type');
is_deeply($audit[0]->[3], { name => 'Small' },
	  'audit records names without account data');
# Template round trips preserve shell contents, including
# indentation and newlines.
my $script_record = { name => 'Guest setup', settings => {
	packages => "jq\n curl jq", before_script =>
					    "  printf 'before'\n",
	after_script => "cat <<'END'\n</script>\nEND\n" } };
my $script_template;
# Pro validates and stores a new script template normally.
if (Cloudmin::Software::has_scripts()) {
	$script_template = $store->save('template', $script_record);
	}
else {
	# Simulate a template saved before the Pro package was removed.
	ok(!eval { $store->save('template', $script_record); 1 },
	   'GPL cannot create a script template');
	$script_template = { %$script_record, id => 'a' x 32 };
	my $saved = $store->read('template');
	push(@{$saved->{'entries'}}, $script_template);
	write_file_contents("$dir/templates.json", convert_to_json($saved));
	$script_template =
		$store->save('template',
			     { %$script_template, description => 'Preserved' });
	is($script_template->{'settings'}->{'before_script'},
	   $script_record->{'settings'}->{'before_script'},
	   'GPL preserves existing scripts when editing other settings');
	ok(!eval { $store->save('template',
				{ %$script_template,
				  settings => { before_script => 'changed' } }); 1 },
	   'GPL cannot replace saved scripts');
	}
my $script_settings =
	$store->get('template', $script_template->{'id'})->{'settings'};
is($script_settings->{'packages'}, 'jq curl',
   'template stores normalized package names');
is($script_settings->{'before_script'}, "  printf 'before'\n",
   'template preserves script whitespace');
my $resolved =
	$store->resolve({ template => $script_template->{'id'}, packages => '',
			  after_script => '' });
is($resolved->{'packages'}, '', 'creation can clear a template package list');
is($resolved->{'after_script'}, '', 'creation can clear a template script');
# An explicitly empty package list must also survive saving a template.
my $package_base = $store->get('template', $base_id);
$store->save('template', { %$package_base,
			   settings =>
				   { %{$package_base->{'settings'}},
				     packages => 'jq' } });
my $no_packages =
	$store->save('template',
		     { name => 'No packages', settings => { packages => '' } });
is($store->resolve({ template => $no_packages->{'id'} })->{'packages'}, '',
   'an empty saved package list overrides Default Template');
my $inherit_packages =
	$store->save('template', { name => 'Inherited packages',
				   settings => { } });
is($store->resolve({ template => $inherit_packages->{'id'} })->{'packages'},
   'jq',
   'an unset package list still inherits Default Template');
$store->save('template', { %{$store->get('template', $base_id)},
			   settings => $package_base->{'settings'} });
my $cloned = $store->resolve({ template => $script_template->{'id'} }, 'clone');
ok(!exists($cloned->{'before_script'}) && !exists($cloned->{'packages'}),
   'cloning omits guest provisioning');

# Software saves distinguish inherited, disabled and explicitly listed packages.
{
	my $fresh =
		Cloudmin::Presets->new(%$store,
				       directory => tempdir(CLEANUP => 1));
	my $base = $fresh->get('template', $base_id);
	$fresh->save('template',
		     { %$base,
		       settings => { %{$base->{'settings'}},
				     packages => 'jq' } });
	my $gpl = $fresh->get('template', '0' x 31 . '2');
	my $input =
		{ id => $gpl->{'id'}, editmode => 'software',
		  %{$gpl->{'settings'}},
		  virtualmin_bundle => 'LEMP',
		  packages_mode => 'inherit' };
	$gpl =
		$fresh->save('template',
			     preset_form_record('template', $input, $gpl));
	ok(!exists($gpl->{'settings'}->{'packages'}),
	   'web server edit preserves package inheritance');
	ok(!exists($gpl->{'settings'}->{'packages_mode'}),
	   'package selector is not stored as a software option');
	is($fresh->resolve({ template => $gpl->{'id'} })->{'packages'}, 'jq',
	   'inherited packages still reach creation');
	my $inherited = show_software_settings($gpl->{'settings'});
	like($inherited,
	     qr/name="packages_mode"[^>]*value="inherit"[^>]*checked/,
	     'inherited package source is selected on reopening');
	like($inherited,
	     qr/<div\b(?=[^>]*data-vm-package-list="1")(?=[^>]*\bhidden\b)[^>]*>/,
	     'inherited packages hide the custom list');
	like($inherited, qr/<textarea[^>]*name="packages"[^>]*disabled/,
	     'hidden list is excluded from submission');
	# Switching to None ignores stale textarea contents, even
	# after defaults change.
	$gpl = $fresh->save('template', preset_form_record('template',
							   { %$input,
							     packages_mode => 'none', packages => 'curl' }, $gpl));
	$base = $fresh->get('template', $base_id);
	$fresh->save('template',
		     { %$base,
		       settings => { %{$base->{'settings'}},
				     packages => 'git' } });
	is($fresh->resolve({ template => $gpl->{'id'} })->{'packages'}, '',
	   'None overrides the current default packages');
	# A listed override is normalized; selecting inheritance
	# removes it entirely.
	$gpl = $fresh->save('template', preset_form_record('template',
							   { %$input,
							     packages_mode => 'list', packages => "curl\n curl jq" }, $gpl));
	is($fresh->resolve({ template => $gpl->{'id'} })->{'packages'},
	   'curl jq',
	   'listed packages replace the default list');
	$gpl =
		$fresh->save('template',
			     preset_form_record('template',
						{ %$input, packages => 'curl' },
						$gpl));
	is($fresh->resolve({ template => $gpl->{'id'} })->{'packages'}, 'git',
	   'restoring inheritance uses updated defaults');
	# Default Template defines the list and cannot inherit from itself.
	for my $mode (qw(none list)) {
		$base =
			$fresh->save('template',
				     preset_form_record('template',
							{ id => $base_id,
							  editmode => 'software',
							  packages_mode => $mode,
							  packages => 'jq' },
							$base));
		is($base->{'settings'}->{'packages'}, $mode eq 'list'
			? 'jq'
			: '', 'base template saves its package choice');
		}
	my $base_form = show_software_settings($base->{'settings'}, 0, 0, 1);
	unlike($base_form, qr/value="inherit"/,
	       'base template does not offer package inheritance');
	like($base_form, qr/name="packages_mode"[^>]*value="list"[^>]*checked/,
	     'base template reopens its saved list');
	unlike(show_software_settings($gpl->{'settings'}, 0, 1),
	       qr/name="packages_mode"/,
	       'creation keeps its resolved package textarea');
	for my $bad ( { packages_mode => 'unknown' }, { packages_mode => '' },
		      { id => $base_id },
		      { packages_mode => 'list', packages => " \n" } ) {
		ok(!eval { preset_form_record('template',
					      { %$input, %$bad },
					      $gpl); 1 },
		   'invalid package choices are refused without changing the template');
		}
	}

# Paths are reusable references; saving and listing templates never reads them.
if (Cloudmin::Software::has_scripts()) {
	my $file_template =
		$store->save('template', { name => 'Host script', settings => {
			before_script_mode => 'file',
			before_script_path => '/missing/setup.sh' } });
	is($file_template->{'settings'}->{'before_script_path'},
	   '/missing/setup.sh', 'template saves an unread host path');
	my $file_override =
		$store->resolve({ template => $file_template->{'id'},
				  before_script => 'echo override' });
	is(Cloudmin::Software::settings($file_override)->{'before_script_mode'},
	   'inline', 'pasted override replaces a template file');
	my $file_none =
		$store->resolve({ template => $file_template->{'id'},
				  before_script_mode => 'none' });
	ok(
		!Cloudmin::Software::enabled(
			Cloudmin::Software::settings($file_none)),
		'None clears a template file selection');
	my $file_clone =
		$store->resolve({ template => $file_template->{'id'} },
				'clone');
	ok(!exists($file_clone->{'before_script_path'}),
	   'cloning cannot reapply a host script');
	}
else {
	# GPL can clear saved scripts, but a stale form cannot
	# restore them afterward.
	my $cleared =
		preset_form_record('template',
				   { id => $script_template->{'id'},
				     editmode => 'software',
				     packages_mode => 'list', packages => 'jq',
				     clear_setup_scripts => 1 },
				   $script_template);
	my $saved = $store->save('template', $cleared);
	ok(!Cloudmin::Software::uses_scripts($saved->{'settings'}),
	   'explicit checkbox clears both saved scripts');
	my $preserved =
		preset_form_record('template',
				   { id => $script_template->{'id'},
				     editmode => 'software',
				     packages_mode => 'list',
				     packages => 'curl' },
				   $script_template);
	ok(!eval { $store->save('template', $preserved); 1 },
	   'stale form cannot put cleared scripts back');
	}

# Explicit edits to the bundled plan retain normal capacity validation.
{
	my $small =
		Cloudmin::Presets->new(%$store,
				       directory => tempdir(CLEANUP => 1),
				       host_cpus => sub { 1 });
	my $plan = $small->get('plan', Cloudmin::Presets::default_id());
	$plan->{'settings'}->{'cpus'} = 2;
	$small->save('plan', $plan);
	is($small->resolve({ plan => $plan->{'id'} })->{'cpus'}, 2,
	   'an edited Default Plan is never silently reduced');
	local $small->{'host_cpus'} = sub { die "Host unavailable\n"; };
	is($small->get('plan', $plan->{'id'})->{'settings'}->{'cpus'}, 2,
	   'saved plans remain readable without libvirt');
	}

# Optional bundled templates can be removed, but never while referenced.
{
	my ($gpl, $pro) = map { '0' x 31 . $_ } ( 2, 3 );
	my $users = { $pro => [ 'mail.example.test' ] };
	local $store->{'template_users'} = sub { $users };
	my $before = read_file_contents("$dir/templates.json");
	ok(!eval { $store->update('template', 'delete', [ $gpl, $pro,
							  $tid ]); 1 },
	   'one used template prevents the entire deletion batch');
	like($@, qr/Virtualmin Pro.*mail\.example\.test/,
	     'refusal identifies the template and guest');
	is(read_file_contents("$dir/templates.json"), $before,
	   'refused deletion changes no records');
	{
		local $store->{'template_users'} =
			sub { die "Inventory unavailable\n"; };
		ok(!eval { $store->update('template', 'delete', [ $gpl ]); 1 },
		   'inventory failure blocks deletion');
		is(read_file_contents("$dir/templates.json"), $before,
		   'failed usage lookup leaves settings intact');
		}
	$users = { };
	# Deletions must survive both unrelated saves and reopening the store.
	$store->update('template', 'delete', [ $gpl ]);
	ok(!eval { $store->get('template', $gpl); 1 },
	   'deleted GPL template stays absent on reads');
	$store->update('template', 'default', [ $pro ]);
	$store->update('template', 'delete', [ $pro ]);
	is($store->list('template')->{'default'}, $base_id,
	   'deleting optional default selects Default Template');
	$store->save('template', $store->get('template', $tid));
	my $reopened = Cloudmin::Presets->new(%$store);
	ok(!grep({ $_->{'id'} eq $gpl ||
		$_->{'id'} eq $pro } @{$reopened->list(
			'template')->{'entries'}}),
	   'unrelated saves and new store instances do not restore deleted bundled templates');
	$store->update('template', 'delete', [ $tid ]);
	ok(!eval { $store->get('template', $tid); 1 },
	   'unused custom templates remain deletable');
	$store->update('template', 'delete',
		       [ map { sprintf('%032x', $_) } 4 .. 5 ]);
	ok(!grep({ Cloudmin::Presets::builtin('template', $_->{'id'}) &&
		$_->{'id'} ne $base_id }
		 @{$store->list('template')->{'entries'}}),
	   'every optional Virtualmin variant can stay deleted');
	}

# Supplied titles follow Virtualmin options; manual names and copies stay fixed.
{
	my $fresh =
		Cloudmin::Presets->new(%$store,
				       directory => tempdir(CLEANUP => 1));
	my ($gpl, $pro, $nginx) = map { '0' x 31 . $_ } ( 2, 3, 4 );
	my $entry = $fresh->get('template', $gpl);
	$entry =
		$fresh->save('template',
			     { %$entry, settings =>
						{ %{$entry->{'settings'}},
						  virtualmin_bundle => 'LEMP' } });
	is($entry->{'name'}, 'Virtualmin GPL with Nginx 2',
	   'server edit updates the title without colliding with another template');
	is($fresh->get('template', $nginx)->{'name'},
	   'Virtualmin GPL with Nginx', 'existing title is unchanged');
	is($fresh->get('template', $gpl)->{'name'}, $entry->{'name'},
	   'automatic title survives a fresh read');
	$entry =
		$fresh->save('template',
			     { %$entry, settings =>
						{ %{$entry->{'settings'}},
						  virtualmin_postgres => 1 } });
	is($entry->{'name'}, 'Virtualmin GPL with Nginx and PostgreSQL',
	   'PostgreSQL is included when enabled');
	$entry =
		$fresh->save('template',
			     { %$entry, settings =>
						{ %{$entry->{'settings'}},
						  software => 'virtualmin-pro' } });
	is($entry->{'name'}, 'Virtualmin Pro with Nginx and PostgreSQL',
	   'edition edits keep the automatic name current');
	# Installation size and disabling setup must not leave
	# stale title details.
	$entry =
		$fresh->save('template',
			     { %$entry, settings =>
						{ %{$entry->{'settings'}},
						  virtualmin_type => 'mini' } });
	is($entry->{'name'}, 'Virtualmin Pro with Nginx and PostgreSQL',
	   'installation size never enters the title');
	is($entry->{'settings'}->{'virtualmin_type'}, 'mini',
	   'an explicit minimal installation remains available');
	$entry =
		$fresh->save('template',
			     { %$entry, settings =>
						{ %{$entry->{'settings'}},
						  software => 'none' } });
	is($entry->{'name'}, 'Machine Template',
	   'disabling Virtualmin removes it from the automatic name');
	$entry =
		$fresh->save('template',
			     { %$entry, settings =>
						{ %{$entry->{'settings'}},
						  software => 'virtualmin-gpl',
						  virtualmin_postgres => 0 } });
	is($entry->{'name'}, 'Virtualmin GPL with Nginx 2',
	   'automatic naming continues after Virtualmin is re-enabled');
	$fresh->update('template', 'delete', [ $nginx ]);
	$entry =
		$fresh->save('template',
			     { %$entry, settings =>
						{ %{$entry->{'settings'}},
						  username => 'alice' } });
	is($entry->{'name'}, 'Virtualmin GPL with Nginx 2',
	   'editing access settings does not reset the title');
	# A manually chosen title stays custom even if it
	# matches a supplied title.
	$entry =
		$fresh->save('template', { %$entry,
					   name => 'My hosting template' });
	ok(!$entry->{'name_default'}, 'renaming turns off automatic naming');
	$entry =
		$fresh->save('template',
			     { %$entry, settings =>
						{ %{$entry->{'settings'}},
						  virtualmin_bundle => 'LAMP' } });
	is($entry->{'name'}, 'My hosting template',
	   'software edits preserve a custom title');
	$entry =
		$fresh->save('template',
			     { %$entry, name => 'Virtualmin GPL with Apache' });
	$entry =
		$fresh->save('template',
			     { %$entry, settings =>
						{ %{$entry->{'settings'}},
						  software => 'virtualmin-pro' } });
	is($entry->{'name'}, 'Virtualmin GPL with Apache',
	   'a custom name matching a supplied title stays custom');
	# Copies and Default Template retain their names through software edits.
	my $copy =
		$fresh->save('template',
			     { %{$fresh->get('template', $pro)}, id => undef,
			       name =>
				       'Copy for staging' });
	$copy =
		$fresh->save('template',
			     { %$copy, settings =>
					       { %{$copy->{'settings'}},
						 virtualmin_bundle => 'LEMP' } });
	is($copy->{'name'}, 'Copy for staging',
	   'copies keep their chosen name');
	my $base = $fresh->get('template', $base_id);
	$base =
		$fresh->save('template',
			     { %$base, settings =>
					       { %{$base->{'settings'}},
						 software => 'virtualmin-gpl' } });
	is($base->{'name'}, 'Default Template',
	   'software edits never rename Default Template');
	}

# Supplied descriptions explain defaults; manual descriptions survive edits.
{
	my $fresh =
		Cloudmin::Presets->new(%$store,
				       directory => tempdir(CLEANUP => 1));
	my $data = $fresh->read('template');
	my %entries = map { $_->{'id'} => $_ } @{$data->{'entries'}};
	like($entries{$base_id}->{'description'},
	     qr/Rocky Linux 10.*password.*cloudmin.*DHCP/,
	     'base description names the image and access defaults');
	is($entries{'0' x 31 . '3'}->{'description'},
	   'Virtualmin Pro with Apache',
	   'Virtualmin description names only the edition and web server');
	$fresh->save('template',
		     { %{$entries{'0' x 31 . '3'}}, description =>
							    'Administrator description' });
	is($fresh->get('template', '0' x 31 . '3')->{'description'},
	   'Administrator description',
	   'custom description is never overwritten');
	my $base = $fresh->get('template', $base_id);
	{
		# Saving translated stock text must retain its
		# automatic-description flag.
		local $text{'presets_description_template'} =
			'Translated template description';
		is(preset_description($base),
		   'Translated template description',
		   'shipped description uses a full translation string');
		my $parsed =
			preset_form_record('template',
					   { id => $base_id,
					     editmode => 'basic',
					     name => $base->{'name'},
					     description => preset_description($base),
					     require_fqdn => $base->{'settings'}->{'require_fqdn'} }, $base);
		$fresh->save('template', $parsed);
		ok($fresh->get('template',
			       $base_id)->{'description_default'},
		   'unchanged translated form retains shipped text');
		}
	# Only supplied descriptions are cleared when their settings change.
	$fresh->save('template',
		     { %$base, settings =>
				       { %{$base->{'settings'}},
					 auth_type => 'keys' } });
	is($fresh->get('template', $base_id)->{'description'}, '',
	   'changing settings clears the supplied description');
	my $custom = $fresh->get('template', '0' x 31 . '3');
	$fresh->save('template',
		     { %$custom, settings =>
					 { %{$custom->{'settings'}},
					   virtualmin_bundle => 'LEMP' } });
	is($fresh->get('template', $custom->{'id'})->{'description'},
	   'Administrator description',
	   'changing settings preserves a manually written description');
	my $gpl = $fresh->get('template', '0' x 31 . '2');
	$fresh->save('template', { %$gpl, description => 'My web server',
				   settings =>
					   { %{$gpl->{'settings'}},
					     virtualmin_type =>
						     'mini' } });
	is($fresh->get('template', $gpl->{'id'})->{'description'},
	   'My web server',
	   'a description submitted with changed settings is kept');
	}

# Usage comes from strict live inventory and all pending
# jobs, not recent history.
{
	package TemplateUsageJobs;

	# list_pending(self) includes creations waiting for
	# their first allocation.

	sub list_pending
	{
	return $_[0]->{'pending'};
	}
	package TemplateUsageInventory;

	# list_domains(self, strict) requires reliable metadata,
	# including stopped guests.

	sub list_domains
	{
	die "Strict inventory required\n"
		if (!$_[1]); return $_[0]->{'domains'};
	}
	package main;
	my ($gpl, $pro) = map { '0' x 31 . $_ } ( 2, 3 );
	my $jobs = bless({ pending => [
		{ request => { template => $gpl, name => 'queued' } },
		{ request => { template => $pro, name => 'not-creation',
			       operation => 'edit' } } ] },
			 'TemplateUsageJobs');
	my $inventory = bless({ domains => [
		{ uuid => 'stopped-uuid', name => 'stopped', active => 0,
		  cloudmin => { template => $gpl } },
		{ uuid => 'running-uuid', name => 'running', active => 1,
		  cloudmin => { template => $pro } },
		{ uuid => 'other-uuid', name => 'unmanaged' } ] },
			      'TemplateUsageInventory');
	no warnings qw(redefine once);
	local *main::get_vm_jobs = sub { $jobs };
	local *main::get_libvirt = sub { $inventory };
	is_deeply(
		get_template_users(),
		{ $gpl => [ 'queued', 'stopped' ], $pro => [ 'running' ] },
		'pending creations and guest metadata count; edits and unmanaged guests do not');
	}

# Hostname requirements are independent of template names and software setup.
{
	# Webmin supplies these global labels outside the module language file.
	local @text{qw(yes no)} = ( 'Yes', 'No' );
	my $fresh =
		Cloudmin::Presets->new(%$store,
				       directory => tempdir(CLEANUP => 1));
	my $base = $fresh->get('template', $base_id);
	is($base->{'settings'}->{'require_fqdn'}, 0,
	   'Default Template allows short hostnames');
	my $required = $fresh->save('template', { name => 'Company servers',
						  settings => { require_fqdn => 1,
								software => 'none' } });
	is($fresh->resolve({ template => $required->{'id'} })->{'require_fqdn'},
	   1,
	   'custom requirement survives saving and resolution without Virtualmin');
	is($fresh->resolve({ template => $required->{'id'}, require_fqdn =>
								    0 })->{'require_fqdn'}, 1,
	   'creation input cannot disable the selected template requirement');
	ok(!eval { $fresh->save('template',
				{ name => 'Invalid rule',
				  settings => { require_fqdn => 'yes' } }); 1 },
	   'template settings reject malformed hostname rules');
	my $inherit =
		$fresh->save('template',
			     { name => 'Inherited rule', settings => { } });
	$fresh->save('template',
		     { %$base,
		       settings => { %{$base->{'settings'}},
				     require_fqdn => 1 } });
	is($fresh->resolve({ template => $inherit->{'id'} })->{'require_fqdn'},
	   1,
	   'unset requirement inherits Default Template');
	$fresh->save('template', { %$inherit,
				   settings => { require_fqdn => 0 } });
	is($fresh->resolve({ template => $inherit->{'id'} })->{'require_fqdn'},
	   0,
	   'explicit No in a template overrides Default Template');
	$fresh->save('template',
		     preset_form_record('template', { id => $inherit->{'id'},
						      editmode => 'basic',
						      name => $inherit->{'name'},
						      require_fqdn => '' },
					$fresh->get('template',
						    $inherit->{'id'})));
	is($fresh->resolve({ template => $inherit->{'id'} })->{'require_fqdn'},
	   1,
	   'saving Use Default Template restores inheritance');
	my $form =
		show_preset_form('template', $required, { }, 'token', 'basic');
	like($form, qr/Require fully qualified hostname/,
	     'Basic settings expose the hostname rule');
	like($form, qr/tmpl_require_fqdn/, 'hostname rule has field help');
	like($form, qr/<option value="1" selected>Yes</,
	     'custom requirement is selected on reopen');
	like($form, qr/>Use Default Template</,
	     'custom templates can inherit the hostname rule');
	unlike(show_preset_form('template', $base, { }, 'token', 'basic'),
	       qr/>Use Default Template</,
	       'Default Template has a concrete hostname rule');
	for my $case ( [ $fresh->get('template', '0' x 31 . '2'), { } ],
		       [ $inherit,
			 { default_software => 'virtualmin-pro' } ] ) {
		my $virtualmin =
			show_preset_form('template', $case->[0], $case->[1],
					 'token', 'basic');
		like($virtualmin,
		     qr/<select\b[^>]*name="require_fqdn"[^>]*disabled/,
		     'Virtualmin locks its hostname prerequisite including inherited software');
		like($virtualmin, qr/<option value="1" selected>Yes</,
		     'Virtualmin displays Yes');
		like($virtualmin,
		     qr/<input\b(?=[^>]*type="hidden")(?=[^>]*name="require_fqdn")(?=[^>]*value="1")/,
		     'editable Virtualmin form submits its disabled requirement');
		}
	my $readonly =
		show_preset_form('template', $required, { }, undef, 'basic');
	like($readonly, qr/<select\b[^>]*name="require_fqdn"[^>]*disabled/,
	     'read-only hostname rule is disabled');
	unlike($readonly,
	       qr/<input\b(?=[^>]*type="hidden")(?=[^>]*name="require_fqdn")/,
	       'read-only form has no writable hostname rule');
	}

# Form parsing preserves hidden installer settings; save validates policy later.
{
	local $config{'virtualmin_enabled'} = 0;
	my $original = { settings => { software => 'virtualmin-pro',
				       virtualmin_type => 'mini',
				       webmin_register => 1,
				       packages => 'curl' } };
	my $record = preset_form_record('template', { editmode => 'software',
						      packages_mode => 'list',
						      packages => 'jq',
						      software =>
							      'none' },
					$original);
	is($record->{'settings'}->{'software'}, 'virtualmin-pro',
	   'hidden installer choice is preserved');
	is($record->{'settings'}->{'virtualmin_type'}, 'mini',
	   'hidden installer options are preserved');
	is($record->{'settings'}->{'packages'}, 'jq',
	   'form parsing retains package edits');
	}

# Installer policy applies to bundled, renamed and inherited template settings.
{
	my $policy =
		Cloudmin::Presets->new(%$store,
				       directory => tempdir(CLEANUP => 1));
	my $virtualmin =
		$policy->save('template',
			      { name => 'Custom installer', settings =>
								    { software => 'virtualmin-gpl' } });
	my $inherited =
		$policy->save('template',
			      { name => 'Inherited installer',
				settings => { } });
	my $plain =
		$policy->save('template',
			      { name => 'Plain guest',
				settings => { software => 'none' } });
	$policy->update('template', 'default', [ $virtualmin->{'id'} ]);
	my $saved = read_file_contents($policy->path('template'));
	{
		local $policy->{'virtualmin_enabled'} = 0;
		# Hide unavailable entries and choose a usable
		# default for display only.
		my $list = $policy->list('template');
		is($list->{'default'}, Cloudmin::Presets::default_id(),
		   'disabled default falls back without rewriting configuration');
		is(scalar(grep { $_->{'disabled'} } @{$list->{'entries'}}), 5,
		   'bundled and renamed installer templates are disabled');
		my $html = show_preset_list('template', $list, 'token');
		unlike($html,
		       qr/Custom installer|Virtualmin (?:GPL|Pro) with/,
		       'disabled templates are absent from the management table');
		like($html, qr/Plain guest/,
		     'ordinary templates remain visible');
		# An explicit opt-out cannot make a disabled template usable.
		foreach my $id ( $virtualmin->{'id'}, '0' x 31 . '3' ) {
			foreach my $mode ( '', 'clone' ) {
				ok(!eval { $policy->resolve({ template => $id,
							      software => 'none' },
							    $mode); 1 },
				   'old ID cannot select a disabled template');
				like($@,
				     qr/Virtualmin installation is disabled in Module Configuration/, 'template error explains the global setting');
				}
			}
		# Refused writes preserve installer records
		# and the saved default.
		ok(!eval { $policy->update('template', 'default',
					   [ $virtualmin->{'id'} ]); 1 },
		   'disabled template cannot become the default');
		ok(!eval { $policy->save('template',
					 { name => 'Stale form', settings =>
									 { software => 'virtualmin-pro' } }); 1 },
		   'stale forms cannot save installer templates');
		is(read_file_contents($policy->path('template')), $saved,
		   'disabled templates and saved default remain intact');
		}
	# A custom template can opt out even when Default Template
	# installs Virtualmin.
	my $base = $policy->get('template', Cloudmin::Presets::default_id());
	$base->{'settings'}->{'software'} = 'virtualmin-pro';
	$policy->save('template', $base);
	{
		local $policy->{'virtualmin_enabled'} = 0;
		ok(!eval { $policy->get('template', $inherited->{'id'}); 1 },
		   'inherited Virtualmin also disables a template');
		is($policy->resolve({
			template => $plain->{'id'} })->{'software'},
		   'none',
		   'explicit opt-out still inherits other base settings');
		is($policy->list('template')->{'default'}, $plain->{'id'},
		   'available custom template replaces a disabled base for display');
		}
	# With every template blocked, the display must leave the default empty.
	$plain->{'settings'}->{'software'} = 'virtualmin-gpl';
	$policy->save('template', $plain);
	{
		local $policy->{'virtualmin_enabled'} = 0;
		is($policy->list('template')->{'default'}, '',
		   'no available templates leaves no selected default');
		}
	# Lifting policy restores the stored default and its original installer.
	is($policy->list('template')->{'default'}, $virtualmin->{'id'},
	   're-enabling restores the saved default');
	is($policy->get('template',
			$virtualmin->{'id'})->{'settings'}->{'software'},
	   'virtualmin-gpl',
	   're-enabling restores the template');
	}

done_testing();
