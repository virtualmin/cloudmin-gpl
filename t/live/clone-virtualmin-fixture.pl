#!/usr/bin/perl
# clone-virtualmin-fixture.pl setup|check
# Run only inside the disposable nested Virtualmin guest, never its controller.
package virtual_server;
use strict;
use warnings;
use JSON::PP qw(encode_json);
use Cwd qw(abs_path);
my $fixture_path = abs_path($0);
# Restrict application setup and probes to the nested fixture's hostnames.
my $hostname = `/bin/hostname`;
chomp($hostname);
die "Not a clone fixture guest\n" unless $hostname eq 'source.example.test' ||
	$hostname =~ /\Acloudmin-clone-test-[a-f0-9]{8}-(?:cold|live|shutdown)\.example\.test\z/;
my ($root) =
	grep {
		-f "$_/virtual-server/virtual-server-lib.pl"
		} qw(/usr/libexec/webmin /usr/share/webmin);
die "Virtualmin is missing\n" if (!$root);
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin'; $ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
$main::no_acl_check = 1;
$0 = "$root/virtual-server/clone-fixture.pl";
chdir("$root/virtual-server") or die $!;
require './virtual-server-lib.pl';
set_all_null_print();
my $action = shift(@ARGV);
if ($action eq 'setup') {
	# Create the management domain only on the original disposable source.
	die "Setup requires the original fixture\n"
		unless $hostname eq 'source.example.test';
	setup_virtualmin_default_hostname_ssl();
	die "Hostname domain was not created\n"
		unless get_domain_by('defaulthostdomain', 1);
	# The fixture has no real DNS or CA certificate; a
	# self-signed one suffices.
	my $password = random_password(40);
	my $file = '/var/tmp/cloudmin-clone-fixture-password';
	open(my $fh, '>', $file) or die $!;
	chmod(0600, $file) or die $!;
	print $fh $password; close($fh);
	my $status =
		system('/usr/sbin/virtualmin', 'create-domain', '--domain',
		       'hosted.example.test',
		       '--user', 'clonewebsite', '--passfile', $file, '--dir',
		       '--unix', '--web', '--ssl', '--dns', '--no-email');
	unlink($file);
	die "Cannot create hosted fixture domain\n" if ($status);
	# Reload Virtualmin's domain maps after the separate
	# CLI process saved them.
	exec($^X, $fixture_path, 'marker') or die $!;
	}
if ($action eq 'marker') {
	# Write recognizable hosted data after reloading the
	# newly created domain.
	die "Setup requires the original fixture\n"
		unless $hostname eq 'source.example.test';
	my $hosted = get_domain_by('dom', 'hosted.example.test') ||
		     die "Hosted fixture missing\n";
	open(my $fh, '>', "$hosted->{home}/public_html/clone-marker.txt") or
		die $!;
	print $fh "preserved website\n"; close($fh);
	exit;
	}
die "Unknown fixture action\n" unless $action eq 'check';
# Report certificate paths and renewal state while verifying
# hosted data survived.
my $domain = get_domain_by('defaulthostdomain', 1) ||
	     die "No hostname domain\n";
my $hosted = get_domain_by('dom', 'hosted.example.test') ||
	     die "Hosted domain lost\n";
my $marker = read_file_contents("$hosted->{home}/public_html/clone-marker.txt");
die "Hosted data changed\n" unless $marker eq "preserved website\n";
my %miniserv;
get_miniserv_config(\%miniserv);
print encode_json({ domain => $domain->{'dom'}, certificate =>
							$domain->{'ssl_cert'},
		    hosted_certificate => $hosted->{'ssl_cert'},
		    webmin_certificate => $miniserv{'certfile'} ||
					  $miniserv{'keyfile'},
		    renewal => scalar(grep { /^letsencrypt/ &&
		$domain->{$_} } keys %$domain) }), "\n";
