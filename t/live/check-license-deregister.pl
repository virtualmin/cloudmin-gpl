#!/usr/bin/perl
# Check removal and reactivation with fixture credentials on an installed host.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use Test::More;
my $root;
# Bootstrap the installed module only on an explicitly selected Linux test host.
BEGIN {
    die "Run on an authorized Linux test host as root\n" unless $^O eq 'linux' && $< == 0;
    die "Run from a shell, not HTTP\n" if ($ENV{'REQUEST_METHOD'});
    $root = abs_path("$Bin/../../..");
    $ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
    $ENV{'WEBMIN_VAR'} = '/var/webmin';
    $ENV{'REMOTE_USER'} = 'root';
    chdir("$root/server-manager") or die $!;
    unshift(@INC, $root);
    $0 = "$root/server-manager/check-license-deregister.pl";
}
require './server-manager-lib.pl';

# Record existing guest states without starting or stopping any machine.
my $native = get_libvirt(1)->connect();
my $before = [sort map { join(':', $_->get_uuid_string(), $_->is_active()) } $native->list_all_domains()];
# All credential and repository writes go to disposable fixture files.
my $dir = tempdir('/var/tmp/cloudmin-deregister-check-XXXXXX', CLEANUP => 1);
my ($file, $repo) = ("$dir/license", "$dir/repository");
Cloudmin::License::write_private($repo, "deb https://download.cloudmin.com/pro/ stable main\n");
my $requests = 0;
my $service = Cloudmin::License->new(directory => "$dir/state", file => $file,
    host => 'deregister-fixture', request => sub {
        $requests++;
        return 'OK 2099-12-31 100 1 1 0 N product=cloudmin';
    }, replace => \&save_cloudmin_license);

{
    no warnings qw(redefine once);
    # Only this process uses the fixture. Web requests keep the host's real license.
    local *main::get_cloudmin_license = sub { $service };
    local *main::cloudmin_license_files = sub { ([$file, 1], [$repo, 0]) };
    local *main::cloudmin_pro = sub { 1 };
    local *main::setup_cloudmin_license_check = sub { };
    my @audit;
    local *main::webmin_log = sub { push(@audit, [@_]); };
    # Rejected removal requests must leave the previously validated key intact.
    my $token = get_image_jobs()->form_token('root');
    call_vm_api(1, 'change_license', {token => $token, serial => '12345', license_key => 'isolated-fixture-key'});
    ok(cloudmin_license_status()->{'allowed'}, 'fixture starts licensed');
    ok(!eval { call_vm_api(1, 'deregister_license', {token => $token}); 1 }, 'API requires explicit confirmation');
    ok(cloudmin_license_status()->{'allowed'}, 'rejected request keeps the fixture license');
    ok(!eval { call_vm_api(1, 'deregister_license', {token => 'bad', confirm => 1}); 1 }, 'API requires a valid token');
    # Confirmation clears credentials without a server call or loss of recovery.
    my $calls = $requests;
    my $result = call_vm_api(1, 'deregister_license', {token => $token, confirm => 1});
    is($result->{'state'}, 'missing', 'confirmed removal clears the license');
    ok(!$result->{'allowed'}, 'new changes are blocked after removal');
    is($requests, $calls, 'removal does not contact a license server');
    is_deeply($service->credentials(), {serial => '', key => ''}, 'saved fixture credentials are empty');
    unlike(Cloudmin::License::read_private($repo), qr/isolated-fixture-key|12345:/, 'repository no longer contains the key');
    ok(!eval { require_access('manage'); 1 }, 'management changes are refused');
    ok(eval { require_access('recover'); 1 }, 'recovery remains available');
    is_deeply($audit[-1], ['deregister_license', 'license'], 'removal logs only the action');
    # Adding another license restores both management and repository access.
    call_vm_api(1, 'change_license', {token => $token, serial => '54321', license_key => 'new-isolated-fixture-key'});
    ok(cloudmin_license_status()->{'allowed'}, 'a replacement restores management');
    like(Cloudmin::License::read_private($repo), qr/new-isolated-fixture-key/, 'replacement restores repository authentication');
}
is_deeply([sort map { join(':', $_->get_uuid_string(), $_->is_active()) } $native->list_all_domains()],
    $before, 'existing guests keep their original active states');
done_testing();
