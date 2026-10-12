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

1;
