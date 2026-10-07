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

1;
