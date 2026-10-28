#!/usr/bin/perl
# Exercise licensing against an installed module without changing its license.
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
    $0 = "$root/server-manager/check-license.pl";
}
require './server-manager-lib.pl';
require './cloudmin-storage-lib.pl';
our ($module_var_directory);
my $dir = tempdir('/var/tmp/cloudmin-license-check-XXXXXX', CLEANUP => 1);
my $native = get_libvirt(1)->connect();
# inventory() records existing machine states without changing any guest.
sub inventory
{
return [sort map { join(':', $_->get_uuid_string(), $_->is_active()) } $native->list_all_domains()];
}
my $before = inventory();
# Fake only licensing; pool operations below still use the real installed backend.
my $now = time();
my $reply = 'OK 2099-12-31 100 1 1 0 N product=cloudmin';
my $service = Cloudmin::License->new(directory => "$dir/license-state", file => "$dir/license",
    host => cloudmin_license_host(), now => sub { $now }, request => sub { $reply });
my $name = 'cm-license-'.substr(Digest::SHA::sha256_hex($dir), 0, 12);
my $pool;
my $ok = eval {
    no warnings qw(redefine once);
    local *main::cloudmin_pro = sub { 1 };
    local *main::get_cloudmin_license = sub { $service };
    # Test tokens and journals stay separate from the host's real jobs.
    local $module_var_directory = "$dir/var";
    $service->change('12345', 'license-fixture-key');
    my $token = get_image_jobs()->form_token('root');
    call_vm_api(1, 'register_pool', {token => $token, name => $name,
        type => 'dir', path => "$dir/pool", autostart => 0});
    $pool = $native->get_storage_pool_by_name($name);
    ok($pool->is_active(), 'valid license admits a real pool registration');
    my $id = $pool->get_uuid_string();
    # Queue work while valid, then expire the license before submitting more.
    my $jobs = get_vm_jobs();
    my $job_id = 'a'x32;
    $jobs->submit($job_id, 'root', 'vm:license-fixture', {name => 'license-fixture'});
    $reply = 'EXP 2020-01-01 100 1 1 0 N product=cloudmin';
    $service->status(1, 1);
    ok(can_access('manage'), 'expired license leaves management controls visible');
    for my $action (qw(create delete start register_pool pool_stop unregister_pool)) {
        ok(!eval { call_vm_api(1, $action, {token => $token, id => $id}); 1 }, "$action refused after grace");
        like($@, qr/license has expired/, "$action has an actionable license error");
    }
    ok($pool->is_active(), 'refused changes leave the registered pool active');
    # Reads and accepted work remain available after the admission check closes.
    ok(ref(call_vm_api(1, 'storage', {})) eq 'HASH', 'live storage inventory remains available');
    ok(ref(call_vm_api(1, 'machines', {})) eq 'ARRAY', 'live machine inventory remains available');
    is(call_vm_api(1, 'license', {})->{'state'}, 'expired', 'API reports expiry');
    is($jobs->submit($job_id, 'root', 'vm:license-fixture', {})->{'state'}, 'queued', 'accepted job remains resumable');
    ok(!eval { $jobs->submit('b'x32, 'root', 'vm:license-new', {}); 1 }, 'durable submission also refuses new work');
    $jobs->update($job_id, sub { $_[0]->{'state'} = 'complete' });
    is($jobs->get($job_id)->{'state'}, 'complete', 'worker can finish its accepted job');
    ok(eval { require_access('recover'); 1 }, 'recovery permission survives expiry');
    # Renewal restores normal API access, including removal of our fixture pool.
    $reply = 'OK 2099-12-31 100 1 1 0 N product=cloudmin';
    $service->status(1, 1);
    ok(eval { require_access('manage'); 1 }, 'renewal permits management changes');
    my $review = call_vm_api(1, 'pool_review', {id => $id, stop => 1, token => $token});
    call_vm_api(1, 'unregister_pool', {id => $id, stop => 1, confirm => 1,
        revision => $review->{'revision'}, token => $token});
    $pool = undef;
    ok(!eval { $native->get_storage_pool_by_name($name) }, 'renewed license permits fixture removal');
    is_deeply(inventory(), $before, 'existing machines keep their original active states');
    1;
};
my $error = $@;
# Cleanup only the exact pool created above, even if a licensing assertion fails.
if ($pool) {
    eval { $pool->destroy() if ($pool->is_active()); $pool->undefine(); };
    die "Fixture cleanup failed: $@" if ($@);
}
die $error if (!$ok);
done_testing();
