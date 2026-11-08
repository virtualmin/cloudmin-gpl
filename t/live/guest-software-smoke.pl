#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Copy qw(copy);

# main() tests native packages, available Pro scripts and HTTPS in the guest.
sub main
{
die "Run only as root in a disposable Linux guest or container\n"
	if ($^O ne 'linux' || $> != 0);
my $directory =
	tempdir('cloudmin-perl-smoke-XXXXXX', DIR => '/tmp', CLEANUP => 1);
# Use a temporary guest seed; never install guest helpers on the test host.
my $scripts = -r "$Bin/../../pro/guest-scripts.pl";
copy("$Bin/../../guest-software.pl", "$directory/guest-software.pl") or die $!;
copy("$Bin/../../pro/guest-scripts.pl", "$directory/guest-scripts.pl") or
	die $! if ($scripts);
require "$directory/guest-software.pl";
local $Cloudmin::GuestSoftware::DIRECTORY = $directory;
local $Cloudmin::GuestSoftware::CONFIG = "$directory/config.json";
umask(0077);
# Run the real entry point with isolated state and no Virtualmin installation.
Cloudmin::GuestSoftware::save('status.json', { stage => 'queued' });
Cloudmin::GuestSoftware::save('request.json', { });
# GPL tests package installation; Pro also brackets it with real shell scripts.
Cloudmin::GuestSoftware::write_file("$directory/config.json",
				    JSON::PP::encode_json({
					    uuid => 'fixture',
					    software => 'none', packages =>
									'tree',
					    $scripts
						    ? ( before_script => 'printf before > before.txt',
							after_script => "test -f before.txt\ntree --version\nprintf after > after.txt" )
						    : ()
				    }));
local @ARGV = ('run');
# Check the persistent outcome as well as the command's exit status.
die "Guest entry point failed\n" if (Cloudmin::GuestSoftware::main());
die Cloudmin::GuestSoftware::read_file("$directory/install.log")
	if (Cloudmin::GuestSoftware::status()->{'stage'} ne 'complete');
# A Pro success must include the final script's output, not just the package.
die "Final script did not run\n"
	if ($scripts &&
	    Cloudmin::GuestSoftware::read_file(
		    "$directory/after.txt") ne 'after');
foreach my $name (
	qw(request.json installer.sh before_script.sh after_script.sh)) {
	# Successful setup must remove temporary credentials
	# and executable copies.
	die "Temporary setup file remains: $name\n"
		if (-e "$directory/$name");
	}
print "PASS: Perl $] runs native package installation, installed script support and cleanup\n";

# Download only; the long Virtualmin installation test remains excluded.
my $installer =
	Cloudmin::GuestSoftware::download(
		'https://download.virtualmin.com/virtualmin-install', { }, 0);
die "Invalid downloaded installer\n"
	if (substr($installer, 0, 2) ne '#!' ||
	    length($installer) > 4 * 1024**2);
print "PASS: official installer downloaded with verified TLS\n";
}

main() if (!caller);
