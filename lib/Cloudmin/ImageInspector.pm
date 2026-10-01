package Cloudmin::ImageInspector;

# Read-only inspection of custom disk images inside a libguestfs appliance.
use strict;
use warnings;

# check_cloud_config(guestfs)
# Rejects explicit datasource or network settings that ignore Cloudmin's seed
# disk.
sub check_cloud_config
{
my ($g) = @_;
eval { require YAML::XS; YAML::XS->VERSION(0.69); 1 }
	|| die "Install YAML::XS to check custom cloud-init configuration\n";
my @files = ('/etc/cloud/cloud.cfg',
	sort $g->glob_expand('/etc/cloud/cloud.cfg.d/*.cfg'));
# Bound both fragment count and total bytes before parsing guest-controlled
# YAML.
die "Too many cloud-init configuration files to inspect\n" if (@files > 128);
my ($sources, $sources_set, $network, $bytes);
foreach my $file (@files) {
	# Limit input and disable Perl object/code construction in
	# guest-supplied YAML.
	$bytes += $g->filesize($file);
	die "Cloud-init configuration is too large to inspect\n"
		if ($bytes > 1024*1024);
	my $config = eval {
		no warnings 'once';
		local $YAML::XS::LoadBlessed = 0;
		local $YAML::XS::LoadCode = 0;
		local $YAML::XS::UseCode = 0;
		my @documents = YAML::XS::Load($g->read_file($file));
		# A fragment may be empty but cannot contain several YAML
		# documents.
		die "Multiple documents\n" if (@documents > 1);
		$documents[0] || {};
		};
	# Require a parsed mapping before reading datasource and network
	# settings.
	die "Cannot read cloud-init configuration in $file\n"
		if ($@ || ref($config) ne 'HASH');
	# Later config fragments override explicit datasource and network
	# choices.
	if (exists($config->{'datasource_list'})) {
		$sources = $config->{'datasource_list'};
		$sources_set = 1;
		}
	if (ref($config->{'network'}) eq 'HASH' &&
		exists($config->{'network'}->{'config'})) {
		# Preserve the last explicit network switch in cloud-init's load
		# order.
		$network = $config->{'network'}->{'config'};
		}
	}
# Explicit datasource lists must allow the seed format Cloudmin writes.
die "This image disables the NoCloud datasource required by Cloudmin\n"
	if ($sources_set &&
	(ref($sources) ne 'ARRAY' ||
	!grep { defined($_) && !ref($_) && $_ eq 'NoCloud' } @$sources));
# A disabled network stage would ignore the addresses chosen during creation.
die "Cloud-init network configuration is disabled in this image\n"
	if (defined($network) && $network eq 'disabled');
}

1;
