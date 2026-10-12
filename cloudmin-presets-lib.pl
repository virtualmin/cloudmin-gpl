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

1;
