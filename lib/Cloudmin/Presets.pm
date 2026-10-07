package Cloudmin::Presets;

# Saved creation defaults. These records do not own or modify existing VMs.
use strict;
use warnings;
use WebminCore qw(read_file_contents write_file_contents convert_to_json convert_from_json);
use File::Basename qw(dirname);
require(dirname(__FILE__).'/VMs.pm');

# new(class, directory => path, access => callback, lock => callback,
#     unlock => callback, log => callback, [host_cpus => callback],
#     [template_users => callback], [virtualmin_enabled => boolean])
# access(writing) must refuse unauthorized callers before any file access.
# lock(path) and unlock(path) protect writes; log(action, kind, id, details)
# records successful changes without copying template settings into the log.
# host_cpus() sizes the unedited bundled plan for this compute host.
# template_users() maps template IDs to guest names and is required for deletion.
# virtualmin_enabled defaults to true. When false, it blocks templates that
# select Virtualmin.
sub new
{
my ($class, %args) = @_;
return bless(\%args, $class);
}

# path(self, kind) limits storage to the two supported configuration files.
sub path
{
my ($self, $kind) = @_;
die "Unknown preset type\n" if ($kind !~ /\A(?:template|plan)\z/);
return "$self->{directory}/${kind}s.json";
}

# read(self, kind) combines saved and bundled presets without writing files.
sub read
{
my ($self, $kind) = @_;
$self->{'access'}->(0);
my $path = $self->path($kind);
my $data = -e $path ? convert_from_json(read_file_contents($path))
	: { version => 1, default => default_id(), entries => [] };
die "Invalid $kind configuration\n" if (ref($data) ne 'HASH' ||
 ($data->{'version'} || 0) != 1 || ref($data->{'entries'}) ne 'ARRAY');
# Bundled records exist on fresh hosts without writing configuration on reads.
my %saved = map { ref($_) eq 'HASH' ? ($_->{'id'} => 1) : () } @{$data->{'entries'}};
# Presets remain editable while libvirt is unavailable; creation still validates
# the host's current capacity before allocating resources.
my $cpus = $kind eq 'plan' && $self->{'host_cpus'} ? eval { $self->{'host_cpus'}->() } : undef;
my %bundled = map { $_->{'id'} => $_ } builtin_presets($kind, $cpus);
my $deleted = $data->{'deleted'} || [];
# Reject deletion markers that conflict with saved or protected presets.
die "Invalid deleted $kind list\n" if (ref($deleted) ne 'ARRAY' || grep {
	ref($_) || !builtin($kind, $_) || $_ eq default_id() || $saved{$_}
} @$deleted);
my %deleted = map { $_ => 1 } @$deleted;
# Remember removed optional templates so reads and upgrades do not restore them.
push(@{$data->{'entries'}}, grep { !$saved{$_->{'id'}} && !$deleted{$_->{'id'}} }
 values %bundled);
# A cleared selection or deleted custom default returns to the built-in preset.
$data->{'default'} ||= default_id();
my %ids;
foreach my $entry (@{$data->{'entries'}}) {
	# Reject damaged configuration before a save can discard records.
	die "Invalid $kind record\n" if (ref($entry) ne 'HASH' ||
		($entry->{'id'} || '') !~ /\A[a-f0-9]{32}\z/ || $ids{$entry->{'id'}}++);
	# Saved script sources remain readable when their Pro package is absent.
	$self->validate($kind, $entry, 1);
	# Missing built-in settings retain their shipped values.
	$entry->{'settings'} = { %{$bundled{$entry->{'id'}}->{'settings'}}, %{$entry->{'settings'}} }
		if ($bundled{$entry->{'id'}});
	# Saving another plan can persist the bundled record without editing it.
	$entry->{'settings'}->{'cpus'} = 1 if ($kind eq 'plan' && ($cpus || 0) == 1 &&
		$entry->{'id'} eq default_id() && !$entry->{'updated'} && $entry->{'settings'}->{'cpus'} == 2);
}
# The selected default must survive validation and optional-template deletion.
die "Invalid default $kind\n" if ($data->{'default'} && !$ids{$data->{'default'}});
return $data;
}

# default_id() identifies the protected base preset in each list.
sub default_id { return '0'x31 . '1'; }

# builtin_presets(kind, [host_cpus]) supplies bundled templates or plans.
# host_cpus caps the unedited plan's CPU allocation when the host has one CPU.
sub builtin_presets
{
my ($kind, $cpus) = @_;
# Plans define allocations; templates define source and guest setup defaults.
return ({ id => default_id(), name => 'Default Plan',
	description => 'Default resources for new virtual machines', created => 0, updated => 0,
	settings => { cpus => ($cpus || 0) == 1 ? 1 : 2, memory_mib => 2048, disk_gib => 20 } }) if ($kind eq 'plan');
my @templates = (
	{ id => default_id(), name => 'Default Template',
	  description => 'Rocky Linux 10, password login as cloudmin, DHCP and automatic startup',
	  description_default => 'template',
	  created => 0, updated => 0, settings => { image => 'catalogue:rocky-linux-10', install_source => 'cloud',
		username => 'cloudmin', auth_type => 'password', require_fqdn => 0,
		address_mode => 'dhcp', firmware => 'auto', start => 1, autostart => 1, software => 'none' } });
my $id = 2;
# Supply GPL and Pro with each web server, using full installation.
foreach my $server (['LAMP', 'Apache'], ['LEMP', 'Nginx']) {
	foreach my $edition ('GPL', 'Pro') {
		push(@templates, { id => sprintf('%032x', $id++),
			name => "Virtualmin $edition with $server->[1]", name_default => 1,
			description => "Virtualmin $edition with $server->[1]",
			description_default => join('_', 'virtualmin', lc($edition), lc($server->[1]), 'full'),
			created => 0, updated => 0,
			settings => { install_source => 'cloud', start => 1, require_fqdn => 1,
				software => 'virtualmin-'.lc($edition),
				virtualmin_bundle => $server->[0], virtualmin_type => 'full',
				virtualmin_postgres => '0', virtualmin_ssl => '1', webmin_register => '1' } });
	}
}
return @templates;
}

# template_name(settings, names) describes Virtualmin without installation size.
# names contains lowercase names already in use; a suffix keeps names unique.
sub template_name
{
my ($settings, $names) = @_;
my $name = 'Machine Template';
if (($settings->{'software'} || '') =~ /\Avirtualmin-(gpl|pro)\z/) {
	# Include PostgreSQL only when requested; disabling Virtualmin drops its name.
	my $edition = $1 eq 'gpl' ? 'GPL' : 'Pro';
	my $server = ($settings->{'virtualmin_bundle'} || 'LAMP') eq 'LEMP' ? 'Nginx' : 'Apache';
	$name = "Virtualmin $edition with $server";
	$name .= ' and PostgreSQL' if ($settings->{'virtualmin_postgres'});
}
my ($candidate, $suffix) = ($name, 2);
# Keep generated names distinct from both custom titles and other variants.
$candidate = $name.' '.$suffix++ while ($names->{lc($candidate)});
return $candidate;
}

# builtin(kind, id) identifies bundled presets, including saved overrides.
sub builtin
{
my ($kind, $id) = @_;
return defined($id) && ($id eq default_id() ||
	$kind eq 'template' && $id =~ /\A0{31}[2-5]\z/);
}

# template_error(self, settings, [base])
# Returns a policy error or an empty string when the template is allowed.
# base supplies inherited settings. With no installer in either hash, use none.
sub template_error
{
my ($self, $settings, $base) = @_;
my $software = $settings->{'software'} // ($base || {})->{'software'} // 'none';
return defined($self->{'virtualmin_enabled'}) && !$self->{'virtualmin_enabled'} &&
	$software =~ /\Avirtualmin-/
	? "Virtualmin installation is disabled in Module Configuration. Re-enable it to use this template.\n" : '';
}

# base_settings(self, kind) reads inheritance defaults for templates or plans.
# Bypass selection policy so a template that opts out of Virtualmin can still
# inherit other settings from a disabled Default Template.
sub base_settings
{
my ($self, $kind) = @_;
my ($base) = grep { $_->{'id'} eq default_id() } @{$self->read($kind)->{'entries'}};
return $base->{'settings'};
}

# list(self, kind) returns sorted records and an available default for the UI/API.
# Disabled records retain their ID/name so old CLI references get a clear error.
sub list
{
my ($self, $kind) = @_;
my $data = $self->read($kind);
my @entries = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @{$data->{'entries'}};
if ($kind eq 'template') {
	# Check inherited software as well as explicit installer selections.
	my ($base) = grep { $_->{'id'} eq default_id() } @entries;
	foreach my $entry (@entries) {
		my $error = $self->template_error($entry->{'settings'}, $base->{'settings'});
		# Retain the rejection reason for callers resolving old IDs or names.
		$entry->{'disabled'} = $error if ($error);
	}
}
# Restrict default selection to usable entries without removing error metadata.
my %available = map { $_->{'id'} => 1 } grep { !$_->{'disabled'} } @entries;
my ($first) = grep { !$_->{'disabled'} } @entries;
# Prefer the saved default, then the base, then the first available entry.
# An empty ID means none are usable. This fallback never changes saved settings.
my $default = $available{$data->{'default'}} ? $data->{'default'} :
	$available{default_id()} ? default_id() : ($first || {})->{'id'} || '';
return { default => $default, entries => \@entries };
}

# get(self, kind, id) returns a usable template or plan by its exact record ID.
sub get
{
my ($self, $kind, $id) = @_;
# Names and paths must not be treated as stored record IDs.
die "Invalid $kind ID\n" if (!defined($id) || ref($id) || $id !~ /\A[a-f0-9]{32}\z/);
my ($record) = grep { $_->{'id'} eq $id } @{$self->list($kind)->{'entries'}};
# Distinguish deleted presets from ones blocked by the current host policy.
die "The selected $kind no longer exists\n" if (!$record);
die $record->{'disabled'} if ($record->{'disabled'});
return $record;
}

# fields(kind) lists reusable settings, excluding passwords and VM identities.
sub fields
{
return $_[0] eq 'plan' ? qw(cpus memory_mib disk_gib) :
	(qw(image install_source pool network username auth_type ssh_keys require_fqdn address_mode
		gateway4 gateway6 dns firmware start autostart), Cloudmin::Software::fields());
}

# validate(self, kind, record, [stored_scripts]) checks and normalizes a preset.
# stored_scripts defaults to false. True retains saved script fields without
# Pro source validation, for reads or saves whose script fields are unchanged.
# Host capacity and image availability are checked again during VM creation.
sub validate
{
my ($self, $kind, $record, $stored_scripts) = @_;
$self->path($kind);
# Bound display text before storing it or including names in the action log.
my %clean;
foreach my $field (qw(name description)) {
	my $value = $record->{$field} // '';
	die "Invalid $field\n" if (ref($value) || $value =~ /[\x00-\x1f]/ ||
		length($value) > ($field eq 'name' ? 100 : 1000));
	$value =~ s/^\s+|\s+$//g;
	$clean{$field} = $value;
}
die "Enter a name\n" if (!length($clean{'name'}));
my $settings = $record->{'settings'};
die "Invalid settings\n" if (ref($settings) ne 'HASH');
my %allowed = map { $_ => 1 } fields($kind);
die "Unsupported $kind setting\n" if (grep { !$allowed{$_} } keys %$settings);
# Plan errors use visible labels and the units stored by the API.
my %plan_fields = (cpus => ['CPU', 1, 1024, ''],
	memory_mib => ['Memory', 256, 1073741824, ' MiB'],
	disk_gib => ['Disk size', 1, 1048576, ' GiB']);
# Preserve script whitespace while normalizing ordinary form values.
my %values;
foreach my $field (keys %$settings) {
	my $value = $settings->{$field};
	my $label = $kind eq 'plan' ? $plan_fields{$field}->[0] : $field;
	die "Invalid $label\n" if (!defined($value) || ref($value) ||
		length($value) > 16384 || $value =~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/);
	$value =~ s/^\s+|\s+$//g if ($field !~ /\A(?:before|after)_script\z/);
	$values{$field} = $value;
}
if ($kind eq 'plan') {
	# Plans use whole MiB and GiB, independently of the current host's capacity.
	foreach my $field (fields($kind)) {
		my ($label, $min, $max, $units) = @{$plan_fields{$field}};
		die "$label must be a whole number from $min to $max$units\n"
			if (!defined($values{$field}) || $values{$field} !~ /\A\d{1,10}\z/ ||
			$values{$field} < $min || $values{$field} > $max);
		$values{$field} = 0 + $values{$field};
	}
}
else {
	# Empty fields inherit defaults, except a cleared package list, which
	# explicitly skips package installation.
	delete($values{$_}) for grep { $values{$_} eq '' && $_ ne 'packages' } keys %values;
	my $uuid = qr/[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}/i;
	my %patterns = (image => qr/(?:[a-f0-9]{32}|catalogue:[a-z0-9][a-z0-9._-]{0,95})/, pool => $uuid,
		network => qr/(?:network:$uuid|bridge:[a-zA-Z0-9_.:-]{1,15})/,
		install_source => qr/(?:cloud|iso)/, firmware => qr/(?:auto|efi|bios)/,
		username => qr/[a-z_][a-z0-9_-]{0,31}/, auth_type => qr/(?:keys|password|both)/,
		address_mode => qr/(?:dhcp|static)/, start => qr/[01]/, autostart => qr/[01]/,
		require_fqdn => qr/[01]/);
	# Check identifiers and enumerated values before resolving host resources.
	foreach my $field (keys %patterns) {
		die "Invalid $field\n" if (exists($values{$field}) &&
			$values{$field} !~ /\A$patterns{$field}\z/);
	}
	# Service accounts cannot be reused as the initial administrator login.
	die "Choose a guest login account; daemon, bin, sys, nobody and sshd are reserved\n" if (($values{'username'} || '') =~
		/\A(?:daemon|bin|sys|nobody|sshd)\z/);
	# Gateways must match their IP family and cannot contain a network prefix.
	foreach my $family (4, 6) {
		$values{'gateway'.$family} = Cloudmin::VMs::address($values{'gateway'.$family}, $family, 0)
			if ($values{'gateway'.$family});
	}
	if ($values{'dns'}) {
		# Store a bounded list of validated addresses in a consistent format.
		my @dns = split(/[\s,]+/, $values{'dns'});
		die "Enter at most three DNS servers\n" if (@dns > 3);
		$values{'dns'} = join(' ', map { Cloudmin::VMs::address($_, /:/ ? 6 : 4, 0) } @dns);
	}
	# Validate script sources and installer options without reading host files.
	my %software_input = %values;
	# Preserve stored sources while still validating the other software options.
	delete(@software_input{Cloudmin::Software::script_fields()}) if ($stored_scripts);
	my $software = Cloudmin::Software::settings(\%software_input);
	@values{keys %$software} = values %$software;
	# Save public keys only; credentials belong to individual creation requests.
	$values{'ssh_keys'} = join("\n", Cloudmin::VMs::public_keys($values{'ssh_keys'}))
		if ($values{'ssh_keys'});
}
$clean{'settings'} = \%values;
return \%clean;
}

# change(self, kind, action, callback) locks configuration edits and logs them.
# callback(data) edits one complete file and returns the changed record or IDs.
sub change
{
my ($self, $kind, $action, $callback) = @_;
$self->{'access'}->(1);
my $path = $self->path($kind);
$self->{'lock'}->($path) || die "Cannot lock $kind settings\n";
my ($result, @names);
my $ok = eval {
	my $data = $self->read($kind);
	my %names = map { $_->{'id'} => $_->{'name'} } @{$data->{'entries'}};
	$result = $callback->($data);
	@names = map { $names{$_} || $_ } split(/,/, $result) if (!ref($result));
	# Restore the caller's umask even if the private atomic write fails.
	local $main::error_must_die = 1;
	my $mask = umask(0077);
	my $written = eval { write_file_contents($path, convert_to_json($data, 0, 1)); 1 };
	my $error = $@;
	umask($mask);
	die $error if (!$written);
	1;
};
my $error = $@;
# Release the configuration lock before reporting a write failure.
$self->{'unlock'}->($path);
die $error if (!$ok);
# Audit names and IDs only; reusable public keys need not enter the action log.
$self->{'log'}->($action, $kind, ref($result) eq 'HASH' ? $result->{'id'} : $result,
	ref($result) eq 'HASH' ? { name => $result->{'name'} } : { names => join("\0", @names) });
return $result;
}

1;
