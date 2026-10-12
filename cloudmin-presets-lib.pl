# Templates and plans share storage and controllers, with separate Webmin pages.
use strict;
use warnings;
our (%text, %config, %in, $module_root_directory, $module_config_directory, $remote_user);
require "$module_root_directory/lib/Cloudmin/Presets.pm";

# get_presets() uses Webmin access, locking and audit helpers for preset storage.
sub get_presets
{
return Cloudmin::Presets->new(directory => $module_config_directory,
	virtualmin_enabled => virtualmin_enabled(),
	access => sub {
		# access(writing) denies writes before locking or opening configuration.
		die "Template and plan changes are disabled in read-only mode\n"
			if ($_[0] && is_readonly_mode());
		require_access($_[0] ? 'manage' : 'host');
	}, lock => \&lock_data_file, unlock => \&unlock_data_file,
	# host_cpus() reads capacity without opening a writable connection.
	host_cpus => sub { get_libvirt(0)->connect()->get_node_info()->{'cpus'} },
	template_users => \&get_template_users,
	# log(action, type, id, details) uses Webmin's normal audit trail.
	log => sub { webmin_log(@_); });
}

# get_template_users() maps template IDs to existing or pending guest names.
# Deletion holds create-host until the configuration write finishes.
sub get_template_users
{
my $jobs = get_vm_jobs();
my %users;
# Read pending jobs first, so a creation finishing during inventory is still seen.
foreach my $job (@{$jobs->list_pending()}) {
	my $request = $job->{'request'};
	$users{$request->{'template'}}->{$request->{'name'}} = 1
		if (!$request->{'operation'} && $request->{'template'});
}
# Strict inventory includes stopped guests and propagates lookup failures.
foreach my $guest (@{get_libvirt()->list_domains(1)}) {
	my $template = ($guest->{'cloudmin'} || {})->{'template'};
	$users{$template}->{$guest->{'name'}} = 1 if ($template);
}
return {map { $_ => [sort keys %{$users{$_}}] } keys %users};
}

# preset_pages(kind) returns the list, editor and action URLs for a preset type.
sub preset_pages
{
return $_[0] eq 'template'
	? qw(edit_newtmpl.cgi edit_tmpl.cgi save_tmpl.cgi delete_tmpls.cgi)
	: qw(edit_newplan.cgi edit_plan.cgi save_plan.cgi delete_plans.cgi);
}

# template_sections() defines the editor order and fields saved by each section.
sub template_sections
{
return (
	['basic', 'presets_basic', ['require_fqdn']],
	['image', 'presets_image', [qw(image install_source pool)]],
	['access', 'vm_step_access', [qw(username auth_type ssh_keys)]],
	['network', 'vm_network', [qw(network address_mode gateway4 gateway6 dns)]],
	['software', 'vm_software', [Cloudmin::Software::fields()]],
	['boot', 'vm_boot_options', [qw(firmware start autostart)]],
);
}

# template_section(name, [step]) validates and wraps section navigation.
# Empty names select Basic; step defaults to zero and may be negative.
sub template_section
{
my ($name, $step) = @_;
my @sections = template_sections();
my ($index) = grep { $sections[$_]->[0] eq ($name || 'basic') } 0..$#sections;
die "Unknown template section\n" if (!defined($index));
return $sections[($index + ($step || 0)) % @sections];
}

# preset_form_record(kind, input, [base]) parses the displayed settings only.
# base supplies saved or copied template sections that this form does not edit.
sub preset_form_record
{
my ($kind, $input, $base) = @_;
$base ||= {settings => {}};
my %settings = %{$base->{'settings'} || {}};
my %record = %$base;
if ($kind eq 'plan') {
	# Normalize all plan allocations from their displayed units.
	%settings = map { $_ => $input->{$_} // '' } Cloudmin::Presets::fields($kind);
	foreach my $size (['memory_mib', 1024**2], ['disk_gib', 1024**3]) {
		$settings{$size->[0]} = Cloudmin::VMs::size_bytes($input, @$size,
			$text{'vm_'.$size->[0]}) / $size->[1];
	}
}
else {
	# Preserve other sections, including explicit No values and public keys.
	my $section = template_section($input->{'editmode'});
	foreach my $field (@{$section->[2]}) {
		# Keep hidden installer defaults for re-enabling; ignore posted edits.
		next if (!virtualmin_enabled() &&
			($field eq 'software' || $field eq 'webmin_register' || $field =~ /\Avirtualmin_/));
		# Disabled Pro fields are omitted; retain saved data until explicitly cleared.
		next if (!Cloudmin::Software::has_scripts() && $field =~ /\A(?:before|after)_script(?:_mode|_path)?\z/ &&
			!exists($input->{$field}));
		$settings{$field} = $input->{$field} // '';
	}
	if ($input->{'clear_setup_scripts'}) {
		# Clearing is available in either edition, but cannot enable execution.
		delete(@settings{Cloudmin::Software::script_fields()});
		@settings{qw(before_script_mode after_script_mode)} = ('none', 'none');
	}
	if ($section->[0] eq 'software') {
		# Keep inheritance distinct from an explicitly empty package list.
		my $mode = $input->{'packages_mode'} || '';
		die "$text{'vm_packages_emode'}\n" if ($mode !~ /\A(?:inherit|none|list)\z/ ||
			$mode eq 'inherit' && ($input->{'id'} || '') eq Cloudmin::Presets::default_id());
		if ($mode eq 'inherit') {
			# Resolve packages from Default Template at creation time.
			delete($settings{'packages'});
		}
		elsif ($mode eq 'none') {
			# Ignore any list left in the hidden textarea.
			$settings{'packages'} = '';
		}
		else {
			# An empty custom list must not silently disable inherited packages.
			die "$text{'vm_packages_elist'}\n" if (ref($settings{'packages'}) ||
				$settings{'packages'} !~ /\S/);
		}
	}
}
if ($kind eq 'plan' || ($input->{'editmode'} || 'basic') eq 'basic') {
	# Other template sections retain their existing name and description.
	@record{qw(name description)} = @{$input}{qw(name description)};
	# An unchanged translated description retains its canonical stored text.
	$record{'description'} = $base->{'description'} if ($input->{'id'} &&
		$base->{'description_default'} && ($input->{'description'} || '') eq preset_description($base));
}
$record{'id'} = $input->{'id'};
$record{'settings'} = \%settings;
return \%record;
}

# preset_select(name, value, choices, [disabled], [base])
# Retains missing references so administrators can repair them explicitly.
# base identifies Default Template; both flags default to false.
sub preset_select
{
my ($name, $value, $choices, $disabled, $base) = @_;
my @choices = @$choices;
# The base template has concrete settings; only host resources are automatic.
unshift(@choices, ['', $text{$base ? 'vm_auto' : 'presets_inherit'}])
	if (!$base || $name =~ /\A(?:pool|network)\z/);
# A removed resource must remain visible instead of silently choosing another.
push(@choices, [$value, text('presets_unavailable', $value)])
	if (length($value || '') && !grep { $_->[0] eq $value } @choices);
# Image choices carry distribution headings; other resources are flat lists.
return show_image_select('image', $value, \@choices, $disabled, $base) if ($name eq 'image');
return ui_select($name, $value, \@choices, 1, 0, 0, $disabled);
}

# show_preset_list(kind, data, [token]) renders Virtualmin-style list actions.
sub show_preset_list
{
my ($kind, $data, $token) = @_;
my ($list, $edit, $save, $delete) = preset_pages($kind);
# Use Virtualmin's compact label markup so it follows the active palette.
my $default_badge = ui_tag('span', ui_tag('span', html_escape(uc($text{'presets_default'})),
	{style => 'font-size:10px;font-weight:bold;background-color:#bdbdbd;'.
		'border-radius:50px;color:#fff;line-height:inherit;margin:0 5px 0 10px;'.
		'padding:1px 5px;vertical-align:inherit;'}),
	{class => 'vui_inline_label', style => 'display:contents;'});
# Enable deletion only when the table includes a selectable non-base preset.
my $deletable = grep { !$_->{'disabled'} && $_->{'id'} ne Cloudmin::Presets::default_id() }
	@{$data->{'entries'}};
my @rows;
# Each selection identifies the preset used by the list actions.
foreach my $entry (@{$data->{'entries'}}) {
	# Keep disabled installer templates out of the management table.
	next if ($entry->{'disabled'});
	my @cells = ($token ? {type => 'checkbox', name => 'd', value => $entry->{'id'}} : '',
		ui_link("$edit?id=$entry->{id}", html_escape($entry->{'name'})).
		($data->{'default'} eq $entry->{'id'} ? $default_badge : ''),
		html_escape(preset_description($entry)));
	# Plans expose allocations alongside their editable description.
	push(@cells, $entry->{'settings'}->{'cpus'},
		nice_size_text($entry->{'settings'}->{'memory_mib'} * 1024**2),
		nice_size_text($entry->{'settings'}->{'disk_gib'} * 1024**3)) if ($kind eq 'plan');
	push(@cells, $entry->{'created'} ? make_date($entry->{'created'}, 1) : $text{'presets_builtin'});
	push(@rows, \@cells);
}
my @create = $kind eq 'template'
	? (["$edit?new=1&cp=1", $text{'presets_from_defaults'}],
	   ["$edit?new=1", $text{'presets_empty'}])
	: (["$edit?new=1", $text{'presets_add_plan_button'}]);
# A missing token leaves a browsable list without mutation controls.
return ui_form_columns_table($delete, $token ? [
		($deletable ? (['delete', $text{'presets_delete'}]) : ()),
		['default', $text{'presets_set_default'}] ] : [], !!$token,
		$token ? \@create : [],
		$token ? [['token', $token]] : [],
		['', $text{'presets_name'}, $text{'presets_description'},
			($kind eq 'plan' ? @text{qw(vm_cpus vm_memory_mib vm_disk_gib)} : ()),
			$text{'presets_created'}],
		100, \@rows, undef, 0, undef, $text{'presets_none_'.$kind});
}

# show_preset_form(kind, record, options, [token], [editmode]) uses Virtualmin's
# section navigation for templates and collapsible details for resource plans.
# Without a token the form is read-only; editmode defaults to Basic.
sub show_preset_form
{
my ($kind, $record, $options, $token, $editmode) = @_;
my (undef, $edit, $save) = preset_pages($kind);
my $values = $record->{'settings'} || {};
my $section = template_section($editmode);
my $disabled = !$token;
my $base = ($record->{'id'} || '') eq Cloudmin::Presets::default_id();
my $page = '';
if ($kind eq 'template' && $record->{'id'}) {
	# Navigation alone does not save; Save and Next commits before moving.
	$page .= ui_form_start($edit).ui_hidden('id', $record->{'id'}).
		$text{'presets_edit_section'}.' '.ui_select('editmode', $section->[0],
		[map { [$_->[0], $text{$_->[1]}] } template_sections()],
		1, 0, 0, 0, 'onchange="form.submit()"').' '.
		ui_submit($text{'tmpl_switch'}, undef, undef, undef, 'fa fa-fw fa-search').' '.
		ui_submit($text{'tmpl_nprev'}, 'nprev').' '.
		ui_submit($text{'tmpl_nnext'}, 'nnext').ui_form_end();
}
my $access = $kind eq 'template' && $section->[0] eq 'access';
# Inherited authentication must show the same controls as Default Template.
my $access_attrs = $access ? 'data-vm-template-access="1" data-default-auth="'.
	html_escape($options->{'default_auth_type'} || 'password').'"' : '';
$page .= ui_form_start($save, 'post', undef, $access_attrs).ui_hidden('id', $record->{'id'} || '');
$page .= ui_hidden('token', $token) if ($token);
$page .= ui_hidden('editmode', $section->[0]) if ($kind eq 'template');
# Copy forms retain the source ID for sections not shown in the form.
$page .= ui_hidden('cloneof', $record->{'cloneof'}) if ($record->{'cloneof'});
# Keep tables directly inside the form so standard column and label styling
# applies without a fieldset wrapper.
$page .= $kind eq 'plan'
	? ui_hidden_table_start($text{'presets_plan_details'}, 'width=100%', 2, 'main', 1, ['width=30%'])
	: ui_table_start($text{$section->[1]}, 'width=100%', 2, ['width=30%']);
if ($kind eq 'plan' || $section->[0] eq 'basic') {
	# Names belong to basic settings, not each independently saved section.
	$page .= ui_table_row($text{'presets_'.$kind.'_name'},
		ui_textbox('name', $record->{'name'}, 40, $disabled)).
		ui_table_row($text{'presets_description'},
		ui_textbox('description', preset_description($record), 60, $disabled));
}
if ($kind eq 'plan') {
	# Plans set initial resources without limiting later edits.
	$page .= ui_table_row($text{'vm_cpus'}, ui_tag('input', '', {type => 'number', name => 'cpus',
		value => $values->{'cpus'}, min => 1, max => 1024, step => 1, required => undef,
		class => 'ui_textbox', style => 'width:8em', inputmode => 'numeric',
		$disabled ? (disabled => undef) : ()}));
	foreach my $size (['memory_mib', 1024**2], ['disk_gib', 1024**3]) {
		$page .= ui_table_row($text{'vm_'.$size->[0]},
			ui_bytesbox($size->[0], ($values->{$size->[0]} || 0) * $size->[1], 5, $disabled, '', $size->[1]));
	}
}
elsif ($section->[0] eq 'basic') {
	# Enforce Virtualmin's hostname rule only while installation is allowed,
	# including when the installer choice is inherited from Default Template.
	my $virtualmin = virtualmin_enabled() &&
		($values->{'software'} // $options->{'default_software'} // 'none') =~ /\Avirtualmin-/;
	my $hostname = preset_select('require_fqdn', $virtualmin ? 1 : $values->{'require_fqdn'},
		[[1, $text{'yes'}], [0, $text{'no'}]], $disabled || $virtualmin, $base);
	# Disabled selects are not submitted; keep their value without a second ID.
	$hostname .= ui_tag('input', '', {type => 'hidden', name => 'require_fqdn', value => 1})
		if ($virtualmin && !$disabled);
	$page .= ui_table_row(hlink($text{'presets_require_fqdn'}, 'tmpl_require_fqdn'), $hostname);
}
elsif ($section->[0] eq 'image') {
	# Empty fields use Default Template or available host resources.
	$page .= ui_table_row($text{'vm_image'}, preset_select('image', $values->{'image'},
		get_vm_image_choices(get_vm_form_images($options, $values->{'image'})), $disabled, $base)).
		ui_table_row($text{'images_storage'}, preset_select('pool', $values->{'pool'},
		[map { [$_->{'id'}, $_->{'name'}] } @{$options->{'pools'} || []}], $disabled, $base));
}
elsif ($section->[0] eq 'access') {
	# Store login choices and public keys; passwords belong to each creation.
	$page .= ui_table_row($text{'vm_username'}, ui_textbox('username', $values->{'username'}, 30, $disabled)).
		ui_table_row($text{'vm_auth_type'}, preset_select('auth_type', $values->{'auth_type'},
		[map { [$_, $text{'vm_auth_'.$_}] } qw(keys password both)], $disabled, $base)).
		ui_table_row($text{'vm_ssh_keys'}, ui_textarea('ssh_keys', $values->{'ssh_keys'}, 4, 75, undef, $disabled),
		undef, undef, ['id="vm_keys_row"'.($disabled ? ' data-vm-readonly="1"' : '')]);
}
elsif ($section->[0] eq 'network') {
	# Save network defaults; each new guest needs its own address.
	$page .= ui_table_row($text{'vm_network'}, preset_select('network', $values->{'network'},
		[map { [$_->{'key'}, $_->{'name'}.' ('.($_->{'forward'} || $_->{'type'}).')'] }
			@{$options->{'networks'} || []}], $disabled, $base)).
		ui_table_row($text{'vm_address_mode'}, preset_select('address_mode', $values->{'address_mode'},
		[['dhcp', $text{'vm_dhcp'}], ['static', $text{'vm_static'}]], $disabled, $base));
	foreach my $field (qw(gateway4 gateway6 dns)) {
		$page .= ui_table_row($text{'vm_'.$field}, ui_textbox($field, $values->{$field}, 45, $disabled));
	}
}
elsif ($section->[0] eq 'software') {
	# Reuse creation controls with license credential inputs omitted.
	$page .= show_software_settings($values, $disabled, 0, $base);
}
elsif ($section->[0] eq 'boot') {
	# Firmware and startup choices can inherit the base template's settings.
	$page .= ui_table_row($text{'catalogue_firmware'}, preset_select('firmware', $values->{'firmware'},
		[['auto', $text{'vm_auto'}], ['efi', 'UEFI'], ['bios', 'BIOS']], $disabled, $base));
	foreach my $field (qw(start autostart)) {
		$page .= ui_table_row($text{'vm_'.$field}, preset_select($field, $values->{$field},
			[[1, $text{'yes'}], [0, $text{'no'}]], $disabled, $base));
	}
}
$page .= $kind eq 'plan' ? ui_hidden_table_end('main') : ui_table_end();
# Templates can save and open the next section; saved records also offer Copy.
my @buttons = (['save', $text{$record->{'id'} ? 'presets_save' : 'presets_create'}]);
push(@buttons, ['next', $text{$record->{'id'} ? 'tmpl_snext' : 'tmpl_cnext'}])
	if ($kind eq 'template');
push(@buttons, ['clone', $text{'presets_clone'}]) if ($record->{'id'});
$page .= ui_form_end($token ? \@buttons : []);
if ($access) {
	# Initialize authentication controls on full loads and theme navigation.
	$page .= ui_tag('script', '', {src => get_webprefix().'/server-manager/machine_template.js?'.
		(stat("$module_root_directory/machine_template.js"))[9]}).
		ui_tag('script', 'window.cloudminTemplateAccessInit?.();');
}
return $page;
}

# preset_page(kind, mode) serves the separate list, editor, save and bulk CGIs.
sub preset_page
{
my ($kind, $mode) = @_;
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'presets_error'});
my $write = $mode eq 'save' || $mode eq 'update';
# Check permissions and request size before parsing changes.
error($text{'presets_readonly'}) if ($write && is_readonly_mode());
error($text{'catalogue_epost'}) if ($write && ($ENV{'REQUEST_METHOD'} || '') ne 'POST');
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 131072);
ReadParse();
my ($list, $edit, $save, $delete) = preset_pages($kind);
my $store = get_presets();
my ($page, $title, $subtitle);
my $ok = eval {
	if ($write) {
		# Store methods check access again; the token grants no permissions.
		get_image_jobs()->check_token($remote_user, $in{'token'});
		if ($mode eq 'save') {
			# Handle one editor submission, including its Copy action.
			if ($in{'clone'}) {
				# Copy opens the saved source in a new editor.
				my $source = $store->get($kind, $in{'id'});
				redirect("$edit?new=1&clone=$source->{id}");
				return 1;
			}
			my $base = {settings => {}};
			if ($in{'id'}) {
				# Merge the edited section into the existing record.
				$base = $store->get($kind, $in{'id'});
			}
			elsif ($in{'cloneof'}) {
				# Copy the source's current settings, including other sections.
				$base = $store->get($kind, $in{'cloneof'});
			}
			my $record = preset_form_record($kind, \%in, $base);
			if ($kind eq 'template' && ($in{'editmode'} || '') eq 'image' &&
				$record->{'settings'}->{'image'}) {
				# Keep other sections editable if their image is removed.
				my $selection = $record->{'settings'}->{'image'};
				my $image;
				if ($selection =~ /\Acatalogue:(.+)\z/) {
					# Save the release ID; creation will download it if needed.
					$image = get_available_server_image($1);
				}
				else {
					# Only ready imports can be saved as image choices.
					$image = get_image_jobs()->get($selection);
					$image = undef if ($image && $image->{'state'} ne 'ready');
				}
				die "Select an available image\n" if (!$image);
				$record->{'settings'}->{'install_source'} = $image->{'format'} eq 'iso' ? 'iso' : 'cloud';
			}
			my $saved = $store->save($kind, $record);
			# Advance only after saving the validated settings.
			redirect($kind eq 'template' && $in{'next'}
				? "$edit?id=$saved->{id}&editmode=".template_section($in{'editmode'}, 1)->[0] : $list);
			return 1;
		}
		# Bulk actions use the selected preset IDs.
		my @actions = grep { $in{$_} } qw(delete default);
		die "Select one action\n" if (@actions != 1);
		my $action = $actions[0];
		my @ids = unique(grep { length } split(/\0/, $in{'d'} || ''));
		my @records = map { $store->get($kind, $_) } @ids;
		die "Select at least one $kind\n" if (!@ids);
		if ($action eq 'delete' && !$in{'confirm'}) {
			# Confirm the selected names before deleting presets.
			$title = $text{'presets_delete'};
			$page = sub { ui_confirmation_form($delete, $text{'presets_confirm'},
				[['token', $in{'token'}], ['delete', 1], map { ['d', $_] } @ids],
				[['confirm', $text{'presets_delete'}]],
				join(', ', map { '<tt>'.html_escape($_->{'name'}).'</tt>' } @records)) };
		}
		else {
			# Apply confirmed deletion or default selection to the current records.
			# apply() runs under the creation lock only for template deletion.
			my $apply = sub { $store->update($kind, $action, \@ids); };
			# Serialize usage checks and deletion with new creation submissions.
			if ($kind eq 'template' && $action eq 'delete') {
				get_vm_jobs()->lock('create-host', $apply);
			}
			else {
				# Plan deletion and default selection need only the preset file lock.
				$apply->();
			}
			redirect($list);
			return 1;
		}
	}
	elsif ($mode eq 'list') {
		# Read-only mode omits tokens for preset actions.
		$title = $text{'presets_'.$kind.'s'};
		my $token = is_readonly_mode() ? '' : get_image_jobs()->form_token($remote_user);
		my $data = $store->list($kind);
		$page = sub { show_preset_list($kind, $data, $token) };
	}
	else {
		# Read-only users can still view records in the editor.
		error($text{'presets_readonly'}) if ($in{'new'} && is_readonly_mode());
		my $record = $in{'new'} ? { settings => {} } : $store->get($kind, $in{'id'});
		if ($in{'new'} && $in{'clone'}) {
			# Keep the source ID to copy settings from the other sections.
			$record = $store->get($kind, $in{'clone'});
			$record->{'cloneof'} = delete($record->{'id'});
			$record->{'name'} = text('presets_copy_name', $record->{'name'});
		}
		elsif ($in{'new'} && $kind eq 'template' && $in{'cp'}) {
			# Copy the selected default, including a custom template.
			my $default = $store->list('template')->{'default'};
			$record = $store->get('template', $default);
			$record->{'cloneof'} = delete($record->{'id'});
			$record->{'name'} = text('presets_copy_name', $record->{'name'});
		}
		elsif ($in{'new'} && $kind eq 'plan') {
			# Start new plans with the default plan's resources.
			$record->{'settings'} = $store->get('plan', $store->list('plan')->{'default'})->{'settings'};
		}
		my $section = $in{'new'} ? template_section('basic') :
			template_section($in{'editmode'}, $in{'nprev'} ? -1 : $in{'nnext'} ? 1 : 0);
		# Basic, access and boot settings need no libvirt inventory.
		my $options = $kind eq 'template' && $section->[0] =~ /\A(?:image|network)\z/
			? call_vm_api(1, 'options', {}) : {};
		if ($kind eq 'template' && $section->[0] eq 'access') {
			# Inherit access even when the base installer is disabled.
			$options->{'default_auth_type'} = $store->base_settings('template')->{'auth_type'};
		}
		if ($kind eq 'template' && $section->[0] eq 'basic') {
			# Read base software without selecting a disabled template.
			$options->{'default_software'} = $store->base_settings('template')->{'software'};
		}
		$subtitle = html_escape($record->{'name'}) if ($kind eq 'template' && $record->{'id'});
		$title = $text{'presets_'.($in{'new'} ? 'add_' : 'edit_').$kind};
		my $token = is_readonly_mode() ? '' : get_image_jobs()->form_token($remote_user);
		$page = sub { show_preset_form($kind, $record, $options, $token, $section->[0]) };
	}
	1;
};
error(error_html(error_message($@))) if (!$ok);
return if (!defined($page));
# The header loads the theme's widget overrides; render forms only afterward.
ui_print_header($subtitle, $title, '', $kind eq 'template' ? 'tmpls' : 'plans');
print $page->();
print software_script() if ($kind eq 'template' && $mode eq 'edit');
ui_print_footer($mode eq 'list' ? ('index.cgi', $text{'vm_return'}) :
	($list, $text{'presets_return_'.$kind.'s'}));
}

1;
