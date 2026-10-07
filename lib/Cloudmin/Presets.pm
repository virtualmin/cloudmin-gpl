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

1;
