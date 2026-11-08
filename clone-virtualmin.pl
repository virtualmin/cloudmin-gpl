#!/usr/bin/perl
# clone-virtualmin.pl webmin-root old-hostname new-hostname mode
# Runs inside the copied guest's isolated libguestfs appliance. Both modes reset
# Pro credentials; prepared mode also updates the management hostname.
package virtual_server;
use strict;
use warnings;
# The Webmin library is loaded at run time, so its globals look unused here.
no warnings 'once';
our ($module_name, $module_config_directory, %config, $first_print,
     $second_print, $virtualmin_pro);
my ($root, $old, $new, $mode) = @ARGV;
# Accept only supported Webmin roots and a hostname valid for the chosen mode.
die "Invalid clone hostname arguments\n" unless $root &&
	$root =~ m{\A/usr/(?:share|libexec)/webmin\z} &&
	defined($old) && defined($mode) &&
	$mode =~ /\A(?:prepared|unchanged)\z/ &&
	($mode eq 'unchanged' || $new &&
	 $new =~ /\A[a-zA-Z0-9][a-zA-Z0-9.-]+\z/);
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
# Load the copied guest's Webmin configuration with noninteractive output.
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
$main::no_acl_check = 1;
chdir("$root/virtual-server") or die $!;
$0 = "$root/virtual-server/clone-virtualmin.pl";
require './virtual-server-lib.pl';
set_all_null_print();

# Both clone modes must discard the source's Pro credentials before boot. Older
# installations must be updated rather than bypassing this requirement.
if ($virtualmin_pro) {
	require './virtualmin-licence.pl';
	die "Update Virtualmin on the source to support offline license replacement before cloning\n"
		unless defined(&change_licence_offline);
	my ($error, $message) = change_licence('CLONE_REQUIRES_LICENSE',
					       'CLONE_REQUIRES_LICENSE', 1, 1,
					       1, 1);
	die "Cannot remove the cloned Virtualmin Pro credentials\n" if ($error);
	}
# Copies without guest setup keep application settings and certificates.
if ($mode eq 'unchanged') {
	print "CLOUDMIN_CLONE_READY\n";
	exit(0);
	}

# Replace only explicit references to the machine hostname in Postfix settings.
if (foreign_installed('postfix')) {
	foreign_require('postfix');
	foreach my $key (qw(myhostname myorigin mydestination)) {
		my $value = postfix::get_current_value($key);
		$value =~ s/(?<![\w.-])\Q$old\E(?![\w.-])/$new/g if ($old);
		postfix::set_current_value($key, $value);
		}
	}
my $domain = get_domain_by('defaulthostdomain', 1);
if ($domain) {
	# A clone must not renew the source's hostname certificate. Give only
	# the management domain a fresh key/certificate before
	# the supported rename.
	my @services = get_all_domain_service_ssl_certs($domain);
	delete(@$domain{grep { /^letsencrypt/ } keys %$domain});
	delete($domain->{'ssl_same'});
	# Preserve certificates already used by hosted domains
	# that shared this one.
	foreach my $shared (get_domain_by('ssl_same', $domain->{'id'})) {
		delete($shared->{'ssl_same'});
		save_domain($shared);
		}
	my $directory = '/etc/webmin/virtual-server/clone-hostname-ssl';
	make_dir($directory, 0700, 1) or
		die "Cannot prepare cloned hostname certificate directory\n";
	$domain->{'ssl_cert'} = "$directory/cert.pem";
	$domain->{'ssl_key'} = "$directory/key.pem";
	$domain->{'ssl_combined'} = "$directory/combined.pem";
	$domain->{'ssl_everything'} = "$directory/everything.pem";
	# Generate a local certificate; no CA request belongs
	# in clone preparation.
	my $error =
		generate_self_signed_cert($domain->{'ssl_cert'},
					  $domain->{'ssl_key'},
					  3072, 1825, undef, undef, undef,
					  undef, undef, $new,
					  undef, [ $new ], $domain);
	die "Cannot prepare the cloned management certificate\n" if ($error);
	delete($domain->{'ssl_chain'});
	save_domain($domain);
	sync_combined_ssl_cert($domain);
	die "Cannot update the cloned Virtualmin hostname\n"
		unless rename_default_domain_ssl($domain, $new);
	update_all_domain_service_ssl_certs($domain, \@services, 1);
	# Renaming updates SNI entries, but Webmin's default certificate may
	# have been installed separately. Replace that reference as well.
	my %miniserv;
	get_miniserv_config(\%miniserv);
	$miniserv{'keyfile'} = $domain->{'ssl_key'};
	$miniserv{'certfile'} = $domain->{'ssl_cert'};
	delete($miniserv{'extracas'});
	put_miniserv_config(\%miniserv);
	}
else {
	# Installations without a hostname domain still need
	# fresh management TLS.
	foreign_require('webmin');
	my $path = '/etc/webmin/miniserv-clone.pem';
	my $error =
		webmin::parse_ssl_key_form({ commonName => $new,
					     countryName => '--',
					     size => 3072, days => 1825 },
					   $path);
	die "Cannot prepare the cloned Webmin certificate\n" if ($error);
	my %miniserv;
	get_miniserv_config(\%miniserv);
	$miniserv{'keyfile'} = $path;
	delete(@miniserv{qw(certfile extracas)});
	put_miniserv_config(\%miniserv);
	}
# Drop only Webmin's hostname-certificate renewal, leaving hosted domains alone.
foreign_require('webmin');
if (foreign_check('webmincron')) {
	# Remove the hostname renewal job only when Webmin's
	# scheduler is available.
	foreign_require('webmincron');
	my $renewal = webmin::find_letsencrypt_cron_job();
	webmincron::delete_webmin_cron($renewal) if ($renewal);
	}
# No global configuration check: it can trigger unrelated repairs and renewals.
print "CLOUDMIN_CLONE_READY\n";
exit(0);
