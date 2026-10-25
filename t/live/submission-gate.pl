#!/usr/bin/perl
# Hold the disk-work lock while the browser submits this fixture's request.
use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
BEGIN {
    # Bootstrap Webmin only inside the authorized test host.
    die "Run only on an authorized Linux test host as root\n" unless $^O eq 'linux' && $< == 0;
    my $root = abs_path("$FindBin::Bin/../../..");
    $ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
    $ENV{'WEBMIN_VAR'} = '/var/webmin';
    $ENV{'REMOTE_USER'} = 'root';
    chdir("$root/server-manager") || die $!;
    $0 = "$root/server-manager/api.pl";
}
require './server-manager-lib.pl';
my ($gate) = @ARGV;
# Restrict the coordination files to this test's temporary directory.
die "Invalid fixture gate\n" if (!$gate || $gate !~ m{\A/tmp/cloudmin-retry-[a-zA-Z0-9_-]+\z});
get_vm_jobs()->lock('vm-work', sub {
    # Signal readiness and release on the fixture's marker or a bounded timeout.
    write_file_contents("$gate/locked", '1');
    my $deadline = time()+90;
    while (!-f "$gate/release") {
        die "Fixture gate timed out\n" if (time() > $deadline);
        select(undef, undef, undef, .1);
    }
});
