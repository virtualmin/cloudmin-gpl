package Cloudmin::Software;

# Guest provisioning uses pinned SSH. Scripts run only inside the guest;
# license inputs stay out of templates and the seed disk.
use strict;
use warnings;
use WebminCore qw(convert_to_json read_file_contents check_ipaddress check_ip6address);
use File::Basename qw(dirname);
use Time::HiRes ();

# script_fields() names reusable script settings, including inactive sources.
sub script_fields { return qw(before_script before_script_mode before_script_path
	after_script after_script_mode after_script_path); }

# has_scripts() checks both Pro helpers on disk, without caching availability.
sub has_scripts
{
my $pro = dirname(__FILE__).'/../../pro';
return -r "$pro/SetupScripts.pm" && -r "$pro/guest-scripts.pl";
}

# require_scripts() refuses script work when its Pro implementation is absent.
sub require_scripts
{
die "Custom setup scripts require Cloudmin Pro. Set both scripts to None or install Cloudmin Pro.\n"
	if (!has_scripts());
require(dirname(__FILE__).'/../../pro/SetupScripts.pm');
}

# uses_scripts(settings) detects selected sources, even when their text is empty.
# Explicit None overrides stale text or paths; older records infer the source.
sub uses_scripts
{
my ($settings) = @_;
return scalar grep {
	my $mode = $settings->{$_.'_mode'};
	defined($mode) && length($mode) ? $mode ne 'none'
		: length($settings->{$_} // '') || length($settings->{$_.'_path'} // '')
} qw(before_script after_script);
}

# script_settings(input) returns normalized script fields for supplied options.
# GPL can clear fields; active sources require Pro validation. Omitted fields
# remain absent so callers can preserve template inheritance.
sub script_settings
{
my ($input) = @_;
if (uses_scripts($input)) {
	# This gate also protects direct API requests and recovered creation data.
	require_scripts();
	return Cloudmin::Pro::SetupScripts::settings($input);
}
my %values;
foreach my $field (qw(before_script after_script)) {
	# Omitted fields still inherit; explicit None discards either old source.
	next if (!grep { exists($input->{$_}) } ($field, $field.'_mode', $field.'_path'));
	@values{$field.'_mode', $field, $field.'_path'} = ('none', '', '');
}
return \%values;
}

# fields() lists reusable software options, excluding license and login secrets.
sub fields { return qw(packages before_script before_script_mode before_script_path
	after_script after_script_mode after_script_path software virtualmin_bundle
	virtualmin_type virtualmin_postgres virtualmin_ssl webmin_register); }

# enabled(settings) checks for packages, scripts or a Virtualmin installation.
sub enabled
{
my ($settings) = @_;
return (($settings->{'software'} || 'none') ne 'none' ||
	length($settings->{'packages'} || '') || grep {
		($settings->{$_.'_mode'} || '') ne 'none' &&
		(length($settings->{$_} || '') || length($settings->{$_.'_path'} || ''))
	} qw(before_script after_script)) ? 1 : 0;
}

# settings(input) validates supplied options without adding template defaults.
sub settings
{
my ($input) = @_;
my %patterns = (software => qr/(?:none|virtualmin-gpl|virtualmin-pro)/,
	virtualmin_bundle => qr/(?:LAMP|LEMP)/, virtualmin_type => qr/(?:full|mini)/,
	virtualmin_postgres => qr/[01]/, virtualmin_ssl => qr/[01]/,
	webmin_register => qr/[01]/);
my %values;
# Validate only supplied installer choices; defaults are applied at creation.
foreach my $field (keys %patterns) {
	next if (!exists($input->{$field}) || defined($input->{$field}) && $input->{$field} eq '');
	die "Invalid software installation option\n" if (!defined($input->{$field}) ||
		ref($input->{$field}) || $input->{$field} !~ /\A$patterns{$field}\z/);
	$values{$field} = $input->{$field};
}
# Packages are names, not command options, paths, URLs or shell expressions.
if (exists($input->{'packages'})) {
	my $value = $input->{'packages'};
	die "Enter package names separated by spaces or newlines\n"
		if (!defined($value) || ref($value) || length($value) > 8192);
	my @packages = grep { length } split(/\s+/, $value);
	die "Enter at most 200 package names, without versions or wildcards\n"
		if (@packages > 200 || grep { !/\A[a-zA-Z0-9][a-zA-Z0-9.+_:-]{0,127}\z/ || /-\z/ } @packages);
	my %seen;
	$values{'packages'} = join(' ', grep { !$seen{$_}++ } @packages);
}
# The Pro package owns script validation and file access. GPL accepts explicit
# clearing, but rejects active scripts from forms, presets and API requests.
my $scripts = script_settings($input);
@values{keys %$scripts} = values %$scripts;
return \%values;
}

# prepare(input, request) validates guest setup before allocation.
sub prepare
{
my ($input, $request) = @_;
my $values = settings($input);
# Generic scripts and packages must not inherit a Virtualmin login request.
delete($values->{'webmin_register'}) if (($values->{'software'} || 'none') eq 'none');
# Template hostname rules also apply when no software installation is requested.
die "The selected template requires a fully qualified hostname, such as host.example.com. ".
	"Use it as the virtual machine name, or set the guest hostname separately.\n"
	if ($request->{'install_source'} eq 'cloud' &&
		($request->{'require_fqdn'} || ($values->{'software'} || '') =~ /\Avirtualmin-/) &&
		$request->{'hostname'} !~ /\./);
# Ordinary creation requests need no software prerequisites.
return if (!enabled($values));
die "Guest software setup requires a cloud image and Start after creation\n"
	if ($request->{'install_source'} ne 'cloud' || !$request->{'start'});
# Copy file contents before submission; workers never reopen the host paths.
foreach my $field (qw(before_script after_script)) {
	next if (($values->{$field.'_mode'} || '') ne 'file');
	$values->{$field} = Cloudmin::Pro::SetupScripts::script_file($values->{$field.'_path'});
	$values->{$field.'_mode'} = 'inline';
	$values->{$field.'_path'} = '';
}
@{$request}{keys %$values} = values %$values;
# Package-only and script-only setups need no Virtualmin-specific resources.
return if (($values->{'software'} || 'none') eq 'none');
my %options = (virtualmin_bundle => 'LAMP', virtualmin_type => 'full',
	virtualmin_postgres => '0', virtualmin_ssl => '1', webmin_register => '1', %$values);
my $minimum = $options{'virtualmin_type'} eq 'mini' ? 1024 : 2048;
die "Virtualmin needs at least $minimum MiB of memory and 20 GiB of disk space\n"
	if ($request->{'memory_mib'} < $minimum || $request->{'disk_gib'} < 20);
@{$request}{keys %options} = values %options;
}

# seed(data, request, uuid) adds guest helpers and configuration to cloud-init.
# Virtualmin license credentials are delivered later over authenticated SSH.
sub seed
{
my ($data, $request, $uuid) = @_;
# Do not install the helper or its dependencies when setup is disabled.
return if (!enabled($request));
# Recheck the installed executor before turning a saved request into a seed.
require_scripts() if (uses_scripts($request));
my $root = dirname(__FILE__).'/../..';
my %config = (uuid => $uuid, map { $_ => $request->{$_} }
	grep { defined($request->{$_}) } fields(), qw(username hostname));
# The seed installs a dormant service; authenticated SSH starts it after setup.
push(@{$data->{'write_files'}},
	{ path => '/usr/local/lib/cloudmin/guest-software.pl', owner => 'root:root',
	  permissions => '0700', content => read_file_contents("$root/guest-software.pl") },
	{ path => '/usr/local/lib/cloudmin/guest-software-bootstrap.sh', owner => 'root:root',
	  permissions => '0700', content => read_file_contents("$root/guest-software-bootstrap.sh") },
	{ path => '/etc/cloudmin-install.json', owner => 'root:root', permissions => '0600',
	  content => convert_to_json(\%config, 0, 1) },
	{ path => '/etc/systemd/system/cloudmin-software.service', owner => 'root:root',
	  permissions => '0644', content => "[Unit]\nDescription=Set up guest software\n".
	  "After=network-online.target cloud-final.service\nWants=network-online.target\n".
	  "[Service]\nType=oneshot\nUMask=0077\n".
	  "ExecStart=/usr/bin/perl /usr/local/lib/cloudmin/guest-software.pl run\n".
	  "ExecStopPost=/bin/rm -f /var/lib/cloudmin-install/request.json /var/lib/cloudmin-install/installer.sh /var/lib/cloudmin-install/before_script.sh /var/lib/cloudmin-install/after_script.sh\n".
	  "TimeoutStartSec=7200\nTimeoutStopSec=30\nKillMode=control-group\nStandardOutput=null\nStandardError=null\n" });
# Include the Pro executor only when this request selects custom scripts.
if (uses_scripts($request)) {
	push(@{$data->{'write_files'}}, {
		path => '/usr/local/lib/cloudmin/guest-scripts.pl', owner => 'root:root',
		permissions => '0700', content => read_file_contents("$root/pro/guest-scripts.pl") });
}
# Install distro-specific Perl modules before software starts. The agent also
# supplies bridged DHCP addresses that host leases cannot discover.
push(@{$data->{'packages'}}, 'qemu-guest-agent');
push(@{$data->{'runcmd'}},
	['/bin/sh', '/usr/local/lib/cloudmin/guest-software-bootstrap.sh'],
	['systemctl', 'daemon-reload'],
	['/usr/bin/perl', '/usr/local/lib/cloudmin/guest-software.pl', 'prepare']);
# Cloud-init generates the normal guest host keys. Only the public identity
# is read through libvirt; no host private key is ever written to this seed.
}

1;
