use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
our $module_root_directory = "$Bin/..";
our $module_var_directory = tempdir(CLEANUP=>1);
our ($remote_user, %access);
$remote_user = 'fixture';
require "$module_root_directory/cloudmin-lib.pl";
{
    package CaptureAPIJobs;
    # lock(self, resource, callback) runs without host lock files.
    sub lock { $_[2]->() }
    # assert_guest_available(self, uuid) records which source was checked.
    sub assert_guest_available { $_[0]->{reserved}=$_[1] }
    # get(self, id, [owner]) returns the saved fixture attempt.
    sub get { $_[0]->{$_[1]} }
    # submit(self, id, owner, resource, request) journals inputs in memory.
    sub submit { $_[0]->{$_[1]}={id=>$_[1],state=>'queued',resource=>$_[3],request=>$_[4],resources=>{}} }
    # spawn(self, id, callback) counts launches without running a worker.
    sub spawn { $_[0]->{spawned}++ }
    package CaptureAPIImages;
    # check_token(self, owner, token) rejects mutations with a forged token.
    sub check_token { die "Bad token\n" if (($_[2] || '') ne 'token') }
    package CaptureAPIService;
    # prepare(self, input, id) records validation without inspecting disks.
    sub prepare { $_[0]->{prepared}++; return {%{$_[1]},operation=>'capture_image',source_uuid=>$_[1]->{id},uuid=>$_[1]->{id}} }
    # run(self, id) records dispatch without touching libvirt.
    sub run { $_[0]->{ran}=$_[1] }
}
my $jobs=bless({},'CaptureAPIJobs');
my $capture=bless({},'CaptureAPIService');
my $readonly=0;
{
    no warnings qw(redefine once);
    local *main::get_vm_service=sub {{jobs=>$jobs,images=>bless({},'CaptureAPIImages')}};
    local *main::get_vm_jobs=sub {$jobs};
    local *main::is_readonly_mode=sub {$readonly};
    my $input={id=>'source',name=>'image',token=>'token'};
    %access=(admin=>1);
    # A module tree without the extension must reject both form and API routes.
    {
        local $module_root_directory=$module_var_directory;
        ok(!eval {call_vm_api(1,'capture_image',{%$input});1},'GPL rejects direct capture submission');
        like($@,qr/requires Cloudmin Pro/,'GPL restriction is explicit');
        ok(!eval {call_vm_api(1,'image_options',{%$input});1},'GPL rejects capture form choices');
    }
    local *main::get_vm_image_service=sub {$capture};
    # Installing Pro does not grant read-only or delegated users host writes.
    $readonly=1;
    ok(!eval {call_vm_api(1,'capture_image',{%$input});1},'read-only administrator cannot capture');
    $readonly=0; %access=(admin=>0,power=>1,vms=>'source');
    for my $action (qw(capture_image image_options)) {
        ok(!eval {call_vm_api(1,$action,{%$input});1},'delegated guest access cannot capture disk data');
        like($@,qr/Access denied/,'host permission is required');
    }
    %access=(admin=>1);
    # Authentication failures must precede source preparation or allocation.
    ok(!eval {call_vm_api(1,'capture_image',{%$input,token=>'bad'});1},'bad CSRF token rejected');
    ok(!$capture->{prepared},'rejected calls cannot inspect or allocate a disk');
    # Identical attempts reuse the job; changed settings cannot reuse its ID.
    my $first=call_vm_api(1,'capture_image',{%$input});
    my $again=call_vm_api(1,'capture_image',{%$input});
    is($again->{id},$first->{id},'repeated form returns the same image job');
    is($capture->{prepared},1,'retry does not prepare another capture');
    is($jobs->{$first->{id}}->{resource},'guest:source','capture reserves the source UUID');
    ok(!eval {call_vm_api(1,'capture_image',{%$input,name=>'changed'});1},'a submitted form cannot change settings');
    ok(!exists($first->{request}),'public result omits private request');
    # Worker dispatch trusts the stored operation rather than caller input.
    run_vm_job($first->{id});
    is($capture->{ran},$first->{id},'stored operation dispatches to the Pro service');
}
done_testing();
