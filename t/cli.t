use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use lib "$Bin/../lib";
use Cloudmin::CLI;
use WebminCore qw(convert_to_json convert_from_json);
use Test::More;
use File::Temp qw(tempdir);
# Use fixed records and temporary inputs without connecting to host services.
my $tmp = tempdir(CLEANUP=>1);
my $uuid = '11111111-1111-4111-8111-111111111111';
my $job = 'a' x 32;
my $machine = {id=>$uuid,name=>'guest.example.com',state=>'stopped',cpus=>2,memory_mib=>2048,disk_gib=>20,addresses=>['192.0.2.10'],autostart=>\0,created=>1700000000};
my $settings = {%$machine, revision=>'current-revision',history_revision=>'history',
    disks=>[{target=>'vda',device=>'disk',format=>'qcow2',path=>'/pool/disk'}],
    interfaces=>[{mac=>'52:54:00:12:34:56',type=>'network',source=>'default'}]};
# Stable IDs and display names exercise preset and resource-name resolution.
my $choices = {images=>[{id=>'image-id',name=>'Image'}],catalogue_images=>[{id=>'catalogue:linux',name=>'Linux'}],
    pools=>[{id=>'pool-id',name=>'default'}], networks=>[{key=>'network:network-id',id=>'network-id',name=>'default'}],
    capabilities=>{architecture=>'aarch64'},presets=>{map {$_=>{entries=>[{id=>"$_-id",name=>"Default $_"}]}} qw(template plan)}};

# Storage management includes pools omitted from creation choices.
my $storage = {pools => [{uuid => 'pool-id', name => 'default', active => 1, revision => 'pool-revision',
    type => 'dir', volumes => [{name => 'unused.raw', key => 'volume-key', capacity => 1024,
    allocation => 512, usage => {owners => [], reason => ''}}]},
    {uuid => 'stopped-id', name => 'stopped', active => 0, revision => 'stopped-revision', volumes => []}],
    lvm_groups => ['guests']};

# run_cli(args, [override]) runs an argv array against fixture services.
# Returns exit code, stdout, stderr and recorded API calls.
# override(action, input, calls) optionally replaces fixture responses.
sub run_cli
{
my ($args,$override) = @_;
my ($out,$err) = ('','');
open(my $outfh,'>',\$out) || die $!; open(my $errfh,'>',\$err) || die $!;
my @calls;
my $state = 'stopped';
my $clock = 0;
# now() reads the fake clock; sleep() advances it without waiting.
my $cli = Cloudmin::CLI->new(out=>$outfh,err=>$errfh,now=>sub {$clock},sleep=>sub {$clock++},
    # raw([action]) records dispatch without replacing the test process.
    raw=>sub {push(@calls,['raw',$_[0] // 'options']);return 0},
    # api(action, input) records requests and returns fixture responses.
    api=>sub {
        my ($action,$input) = @_;
        push(@calls,[$action,convert_from_json(convert_to_json($input,0,1))]);
        # override(action, input, calls) can supply a focused failure scenario.
        return $override->($action,$input,\@calls) if ($override);
        # Resolve names using fixture pools and presets.
        return $choices if ($action eq 'options');
        # Management inventory includes stopped pools and their volumes.
        return $storage if ($action eq 'storage');
        # Removal reviews provide the revisions used by the final requests.
        return {name => 'unused.raw', revision => 'volume-revision', usage => {owners => [], reason => ''}}
            if ($action eq 'volume_review');
        return {name => 'stopped', revision => 'pool-revision', usage => {owners => [], reason => ''}}
            if ($action eq 'pool_review');
        # Immediate storage changes return an identity rather than a job.
        return {name => $input->{name} || 'default', uuid => 'pool-id'}
            if ($action =~ /\A(?:register_pool|pool_start|pool_stop|pool_autostart|delete_volume|unregister_pool)\z/);

        # Inventory returns one record for a selector and an array otherwise.
        return $input->{id} ? {%$machine,state=>$state} : [{%$machine,state=>$state}] if ($action eq 'machines');
        # Hardware, clone and capture preflights share the fixture revision.
        return $settings if ($action eq 'settings' || $action eq 'clone_options' || $action eq 'image_options');
        # Snapshot writes must fetch their own history revision.
        return {revision=>'snapshot-revision',snapshots=>[{id=>'snap',vm=>$machine->{name}}]} if ($action eq 'snapshots');
        # Removal preflight binds the bridge name to its current Ethernet port.
        return {revision=>'bridge-revision',name=>'br0',source=>'eth0'} if ($action eq 'bridge_remove_review');
        # A bridge change stops at confirmation instead of committing itself.
        return {id=>'bridge-id',state=>'confirm'} if ($action eq 'bridge_remove' || $action eq 'bridge_status');
        # Simulate completion of explicit confirm and rollback requests.
        return {id=>'bridge-id',state=>$action eq 'bridge_confirm' ? 'confirmed' : 'rolled_back'} if ($action eq 'bridge_confirm' || $action eq 'bridge_rollback');
        # Bridge inventory remains separate from guest network selections.
        return [{name=>'br0',active=>1,addresses=>['192.0.2.2/24'],ports=>['eth0']}] if ($action eq 'bridges');
        # Job and backup lists supply public inventory rows.
        return [{id=>$job,name=>$machine->{name},state=>'complete'}] if ($action eq 'list' || $action eq 'backups');
        # Polling finishes ordinary fixture jobs after their queued response.
        return {id=>$job,name=>$machine->{name},state=>'complete',phase=>'done'} if ($action eq 'status');
        # Immediate actions update the fake host state used by power polling.
        if ($action =~ /\A(?:start|shutdown|reboot|suspend|resume|reset|force_off|autostart|reset_password)\z/) {
            $state = $action eq 'suspend' ? 'paused' : $action =~ /shutdown|force_off/ ? 'stopped' : 'running';
            return {id=>$uuid,name=>$machine->{name},action=>$action};
        }
        # Review returns validated fields without submitting a job.
        return {name=>$input->{name},password_set=>1} if ($action eq 'review');
        # Only the explicit download fixture returns private key material.
        return {private=>'fixture-private-key'} if ($action eq 'download_ssh_key');
        # Library reads supply a reviewed revision or the complete list.
        return $input->{key} ? {id=>$job,name=>'Saved',addnew=>1,revision=>'key-revision'} : [] if ($action eq 'ssh_keys');
        # Guest removal reviews a revision separate from the library record.
        return {keys=>[],revision=>'guest-key-revision'} if ($action eq 'guest_ssh_keys');
        # Key changes finish synchronously without creating durable jobs.
        return {id=>$job,name=>'Saved'} if ($action =~ /^(?:save_ssh_key|delete_ssh_key|add_guest_ssh_key|remove_guest_ssh_key)$/);
		# Statistics reads return bounded history and export batches, never jobs.
		return {version => 1, resolution => 0, series => [], entities => [], events => []} if ($action eq 'statistics');
		return {version => 1, step => $input->{step}, rows => [], more => 0, cursor => 'generation:60:0'} if ($action eq 'statistics_export');
        # Remaining mutations submit a durable job that the CLI must follow.
        return {id=>$job,name=>$input->{name} || $machine->{name},state=>'queued',phase=>'queued'};
    });
# Return output and recorded calls for separate assertions.
my $code = $cli->run($args);
return ($code,$out,$err,\@calls);
}

# Disabled templates must explain host policy for both old IDs and names.
{
    local $choices->{presets}->{template}->{entries}->[0]->{disabled} =
        "Virtualmin installation is disabled in Module Configuration. Re-enable it to use this template.\n";
    foreach my $selection ('template-id', 'Default template') {
        my ($code, $out, $err, $calls) = run_cli(['create-system', '--name', 'new.example.com', '--template', $selection]);
        isnt($code, 0, 'disabled template is refused');
        like($err, qr/Virtualmin installation is disabled in Module Configuration/, 'CLI explains the required configuration change');
        is_deeply([map { $_->[0] } @$calls], ['options'], 'disabled template never reaches creation');
    }
}

# Each entry supplies the expected API action, CLI arguments and request body.
my %cases = (
'list-systems'=>['machines',[],{}],
'get-system'=>['settings',[],{id=>$uuid}],
# Statistics reads pass their bounds and device selection to the API unchanged.
'get-statistics' => ['statistics', ['--id', $uuid, '--from', '1700000000', '--to', '1700003600', '--points', '120', '--entity', "$uuid/disk/vda"], {id => $uuid, from => 1700000000, to => 1700003600, points => 120, entity => "$uuid/disk/vda"}],
'export-statistics' => ['statistics_export', ['--step', '300', '--limit', '10', '--cursor', 'generation:300:5'], {step => 300, limit => 10, cursor => 'generation:300:5'}],
# Power operations distinguish direct actions from the full restart job.
'start-system'=>['start',[],{id=>$uuid}],
'shutdown-system'=>['shutdown',[],{id=>$uuid}],
'reboot-system'=>['reboot',[],{id=>$uuid}],
'pause-system'=>['suspend',[],{id=>$uuid}],
'unpause-system'=>['resume',[],{id=>$uuid}],
'restart-system'=>['power_cycle',[],{id=>$uuid}],
'reset-system'=>['reset',['--yes'],{id=>$uuid,confirm=>1}],
'poweroff-system'=>['force_off',['--yes'],{id=>$uuid,confirm=>1}],
# Machine mutations exercise revisions, credentials, aliases and confirmation.
'modify-system'=>['update',['--desc','New description'],{id=>$uuid,description=>'New description',cpus=>2,memory_mib=>2048,revision=>'current-revision'}],
'passwd-system'=>['reset_password',['--user','cloudmin','--password-file',"$tmp/password"],{id=>$uuid,username=>'cloudmin',password=>'test-secret'}],
'create-system'=>['create',['--name','new.example.com','--template','Default template','--plan','Default plan','--memory','2G'],{name=>'new.example.com',template=>'template-id',plan=>'plan-id',memory_mib=>2048,start=>1}],
'clone-system'=>['clone',['--new-name','copy.example.com','--mode','unchanged','--confirm-unchanged','--no-start','--no-autostart'],{id=>$uuid,name=>'copy.example.com',revision=>'current-revision',clone_mode=>'unchanged',confirm_unchanged=>1,start=>0,autostart=>0}],
'delete-system'=>['delete',['--yes','--disk','vda'],{id=>$uuid,confirm=>1,confirm_name=>$machine->{name},history_revision=>'history',revision=>'current-revision',disks=>['vda']}],
# Disk operations distinguish attachment targets from pool volume names.
'list-disks'=>['settings',[],{id=>$uuid}],
'create-disk'=>['add_disk',['--pool','default','--disk','10G'],{id=>$uuid,pool=>'pool-id',disk_gib=>10,revision=>'current-revision'}],
'attach-disk'=>['attach_disk',['--pool','default','--volume','data.qcow2'],{id=>$uuid,pool=>'pool-id',volume=>'data.qcow2',revision=>'current-revision'}],
'detach-disk'=>['detach_disk',['--target','vdb'],{id=>$uuid,target=>'vdb',revision=>'current-revision'}],
'delete-disk'=>['delete_disk',['--target','vdb','--yes'],{id=>$uuid,target=>'vdb',confirm=>1,revision=>'current-revision'}],
'resize-disk'=>['grow_disk',['--target','vda','--disk','40G'],{id=>$uuid,target=>'vda',disk_gib=>40,revision=>'current-revision'}],
'insert-media'=>['change_media',['--target','sda','--pool','default','--volume','install.iso'],{id=>$uuid,target=>'sda',pool=>'pool-id',volume=>'install.iso',revision=>'current-revision'}],
'eject-media'=>['change_media',['--target','sda'],{id=>$uuid,target=>'sda',volume=>'',revision=>'current-revision'}],
# Interface selectors use MAC addresses and preserve explicit zero limits.
'list-interfaces'=>['settings',[],{id=>$uuid}],
'add-interface'=>['add_interface',['--network','default'],{id=>$uuid,network=>'network:network-id',revision=>'current-revision'}],
'modify-interface'=>['update_interface',['--mac','52:54:00:12:34:56','--link','down','--inbound-kib','0'],{id=>$uuid,mac=>'52:54:00:12:34:56',link=>'down',inbound_kib=>0,revision=>'current-revision'}],
'delete-interface'=>['remove_interface',['--mac','52:54:00:12:34:56'],{id=>$uuid,mac=>'52:54:00:12:34:56',revision=>'current-revision'}],
# Snapshot writes carry history revisions and destructive confirmations.
'list-snapshots'=>['snapshots',[],{}],
'create-snapshot'=>['snapshot_create',['--label','Before update'],{id=>$uuid,label=>'Before update',revision=>'snapshot-revision'}],
'restore-snapshot'=>['snapshot_restore',['--snapshot','snap','--yes','--restart'],{id=>$uuid,snapshot=>'snap',confirm=>1,restart=>1,revision=>'snapshot-revision'}],
'delete-snapshot'=>['snapshot_delete',['--snapshot','snap','--yes'],{id=>$uuid,snapshot=>'snap',confirm=>1,revision=>'snapshot-revision'}],
# Backup destinations become nested API objects; restore uses an inspection ID.
'list-backups'=>['backups',[],{}],
'backup-systems'=>['backup',['--dest-mode','local','--dest-path','/srv/backups','--compression'],{id=>$uuid,target=>{mode=>'local',path=>'/srv/backups'},compression=>1}],
'inspect-backup'=>['backup_inspect',['--backup',$job],{backup=>$job}],
'restore-systems'=>['restore',['--inspection',$job,'--pool','default','--yes'],{inspection=>$job,pool=>'pool-id',confirm=>1}],
# Image choices use options; storage commands use the full host inventory.
'list-images'=>['options',[],{}],
 'list-pools'=>['storage',[],{}],
'list-volumes'=>['storage',[],{}],
'list-volume-groups'=>['storage',[],{}],
'create-pool'=>['register_pool',['--name','guests','--group','guests','--no-autostart'],{name=>'guests',group=>'guests',type=>'logical',autostart=>0}],
'start-pool'=>['pool_start',['--pool','stopped'],{id=>'stopped-id',revision=>'stopped-revision'}],
'stop-pool'=>['pool_stop',['--pool','default'],{id=>'pool-id',revision=>'pool-revision'}],
'set-pool-autostart'=>['pool_autostart',['--pool','default','--enabled','no'],{id=>'pool-id',revision=>'pool-revision',enabled=>0}],
'delete-volume'=>['delete_volume',['--pool','default','--volume','unused.raw','--yes'],{pool=>'pool-id',volume=>'unused.raw',revision=>'volume-revision',confirm=>1}],
'unregister-pool'=>['unregister_pool',['--pool','stopped','--yes'],{id=>'stopped-id',revision=>'pool-revision',confirm=>1}],
'list-networks'=>['options',[],{}],
'get-host'=>['options',[],{}],
'create-image'=>['capture_image',['--image-name','Base image','--pool','default','--clean-credentials','no'],{id=>$uuid,name=>'Base image',pool=>'pool-id',clean_credentials=>0,revision=>'current-revision'}],
# Job IDs and network transaction IDs have separate dispatch paths.
'list-jobs'=>['list',[],{}],
'get-job'=>['status',['--job',$job],{job=>$job}],
'cancel-job'=>['cancel',['--job',$job],{job=>$job}],
'recover-job'=>['recover',['--job',$job],{job=>$job}],
'discard-job'=>['discard',['--job',$job],{job=>$job}],
'list-bridges'=>['bridges',[],{}],
'get-bridge-status'=>['bridge_status',[],{}],
'remove-bridge'=>['bridge_remove',['--name','br0'],{name=>'br0',revision=>'bridge-revision'}],
'confirm-bridge'=>['bridge_confirm',['--id','bridge-id'],{id=>'bridge-id'}],
'rollback-bridge'=>['bridge_rollback',['--id','bridge-id'],{id=>'bridge-id'}],
'get-license'=>['license',[],{}],
'deregister-license'=>['deregister_license',['--yes'],{confirm=>1}],
'check-license'=>['check_license',[],{}],
'change-license'=>['change_license',['--serial','12345','--key-file',"$tmp/password"],{serial=>'12345',license_key=>'test-secret'}],
'download-ssh-key'=>['download_ssh_key',['--key',$job],{key=>$job}],
'list-ssh-keys'=>['ssh_keys',[],{}],
'create-ssh-key'=>['save_ssh_key',['--name','Saved'],{name=>'Saved',source=>'generate'}],
'modify-ssh-key'=>['save_ssh_key',['--key',$job,'--name','Renamed'],{key=>$job,name=>'Renamed',addnew=>1,revision=>'key-revision'}],
'delete-ssh-key'=>['delete_ssh_key',['--key',$job,'--yes'],{key=>$job,revision=>'key-revision',confirm=>1}],
'list-system-keys'=>['guest_ssh_keys',['--user','admin'],{id=>$uuid,username=>'admin'}],
'add-system-key'=>['add_guest_ssh_key',['--user','admin','--key',$job],{id=>$uuid,username=>'admin',key=>$job}],
'remove-system-key'=>['remove_guest_ssh_key',['--user','admin','--key','f'x64,'--yes'],{id=>$uuid,username=>'admin',key=>'f'x64,revision=>'guest-key-revision',confirm=>1}],
'api'=>['raw',['options'],'options'],
);
open(my $pw,'>',"$tmp/password") || die $!; print $pw "test-secret\n"; close($pw);

# Every command has an independently specified request contract.
is_deeply([sort keys %cases],[sort map {$_->{name}} @{Cloudmin::CLI::commands()}],'test cases cover every command');
foreach my $command (@{Cloudmin::CLI::commands()}) {
    my $name = $command->{name}; my ($action,$args,$expected) = @{$cases{$name}};
    my @args = ($name,@$args);
    # Supply required guest selection without polluting host-wide requests.
    push(@args,'--name',$machine->{name}) if (($command->{select} || '') eq 'machine');
    my ($code,$out,$err,$calls) = run_cli(\@args);
    is($code,0,"$name succeeds") or diag($err);
    my ($call) = grep {$_->[0] eq $action} @$calls;
    is_deeply($call && $call->[1],$expected,"$name builds the API request");
    unlike($out,qr/test-secret/,"$name does not print a secret");
}

# License removal uses the same --yes requirement as other destructive actions.
{
    my ($code, $out, $err, $calls) = run_cli(['deregister-license']);
    isnt($code, 0, 'CLI refuses unconfirmed license removal');
    is_deeply($calls, [], 'unconfirmed removal never calls the API');
}

# The API action set comes from its public contract, not the CLI definitions.
my @actions = qw(download_ssh_key ssh_keys save_ssh_key delete_ssh_key guest_ssh_keys add_guest_ssh_key remove_guest_ssh_key license check_license change_license deregister_license storage register_pool pool_start pool_stop pool_autostart volume_review delete_volume pool_review unregister_pool options machines statistics statistics_export review create status list cancel cancel_cleanup recover discard start shutdown reboot suspend resume reset reset_password power_cycle force_off autostart snapshots snapshot_create snapshot_restore snapshot_delete bridges bridge_remove_review bridge_remove bridge_status bridge_confirm bridge_rollback settings update add_disk attach_disk detach_disk delete_disk grow_disk add_interface update_interface remove_interface change_media delete clone_options clone image_options capture_image backups backup backup_inspect restore);
my %mapped;
foreach my $c (@{Cloudmin::CLI::commands()}) {
    $mapped{$_}=1 for grep {defined($_)} ($c->{action},$c->{prepare},$c->{summary_action},@{$c->{additional_actions} || []},map {$_->{action}} values %{$c->{options}});
}
is_deeply([sort keys %mapped],[sort @actions],'all current API actions have a named command');

# Read formats retain structured data, format sizes and expose exact selectors.
my ($code,$out,$err,$calls) = run_cli(['list-systems']);
like($out,qr/Name\s+State\s+CPUs\s+Memory\s+IP address\n-+/,'table headers and separators');
like($out,qr/guest\.example\.com\s+Stopped\s+2\s+2 GiB\s+192\.0\.2\.10/,'table formats state, sizes and arrays');
($code,$out) = run_cli(['list-systems','--multiline']);
like($out,qr/^guest\.example\.com\n/m,'multiline record heading');
like($out,qr/    Autostart: No\n/,'boolean formatting');
like($out,qr/    Created Unix time: 1700000000\n/,'creation epoch retained');
# Collector availability is a flag in text, with its numeric API type intact.
for my $available (0, 1) {
	my $response = {collector => {available => $available}};
	for my $format ([], ['--multiline']) {
		my ($status, $text) = run_cli(['get-statistics', @$format], sub { $response });
		is($status, 0, 'statistics text command succeeds');
		like($text, qr/Available: @{[$available ? 'Yes' : 'No']}\n/,
			'collector availability has no byte unit');
		}
	# Human formatting must not alter numeric flags in machine-readable output.
	my (undef, $json) = run_cli(['get-statistics', '--json'], sub { $response });
	is_deeply(convert_from_json($json)->{data}, $response,
		'statistics JSON retains numeric availability');
	# The same field name still means free bytes in storage pool results.
	my (undef, $pool) = run_cli(['list-pools'], sub { {pools => [
		{name => 'default', uuid => 'pool-id', type => 'dir', active => 1, available => $available}]} });
	like($pool, qr/\b$available B\s*$/m, 'pool table still formats free bytes');
	my (undef, $details) = run_cli(['list-pools', '--multiline'], sub { {pools => [
		{name => 'default', uuid => 'pool-id', type => 'dir', active => 1, available => $available}]} });
	like($details, qr/Available: $available B\n/, 'pool details still format free bytes');
	}
# JSON retains native types and uses no human progress or formatting.
($code,$out,$err) = run_cli(['list-systems','--json']);
my $json = convert_from_json($out);
is_deeply($json,{command=>'list-systems',status=>'success',data=>[convert_from_json(convert_to_json($machine,0,1))]},'JSON contains native fields and types');
is($err,'','JSON does not write progress');
# Identifier lists print one value per line without headings.
($code,$out) = run_cli(['list-systems','--name-only']); is($out,"guest.example.com\n",'name-only');
($code,$out) = run_cli(['list-systems','--id-only']); is($out,"$uuid\n",'id-only');
# Repeated selectors are alternatives, while separate filters narrow the result.
($code,$out) = run_cli(['list-systems','--name','missing','--name','guest.example.com','--state','stopped','--json']);
is(scalar(@{convert_from_json($out)->{data}}),1,'repeated name alternatives and state filter combine');
($code,$out) = run_cli(['list-systems','--state','running','--json']);
is_deeply(convert_from_json($out)->{data},[],'empty filter result is an array');
# Creation and bridge reviews must not call their mutating counterparts.
($code,$out,$err,$calls) = run_cli(['create-system','--name','new.example.com','--review','--no-start']);
is_deeply($calls->[-1],['review',{name=>'new.example.com',start=>0}],'review avoids create and preserves explicit false');
like($out,qr/Password Set: 1/i,'review renders details, not a completion claim');
($code,$out,$err,$calls) = run_cli(['remove-bridge','--name','br0','--review']);
is_deeply([map {$_->[0]} @$calls],['bridge_remove_review'],'bridge review makes no removal call');
# Only explicit cleanup sends the destructive cancellation action.
($code,$out,$err,$calls) = run_cli(['cancel-job','--job',$job,'--cleanup','--yes']);
is_deeply($calls->[0],['cancel_cleanup',{job=>$job,confirm=>1}],'cleanup explicitly confirmed');
# Apply autostart alone immediately, or after a successful hardware job.
($code,$out,$err,$calls) = run_cli(['modify-system','--id',$uuid,'--autostart','no']);
is_deeply($calls->[-1],['autostart',{id=>$uuid,enabled=>0}],'automatic startup changes without a hardware job');
($code,$out,$err,$calls) = run_cli(['modify-system','--id',$uuid,'--memory','4 GiB','--autostart','yes']);
is_deeply([map {$_->[0]} @$calls],[qw(machines settings update status autostart)],'startup waits for resource changes');
# --no-wait returns a job ID; JSON alone waits for the final record.
($code,$out,$err,$calls) = run_cli(['create-system','--name','new.example.com','--no-wait']);
is($out,"$job\n",'no-wait returns the job ID');
ok(!grep({$_->[0] eq 'status'} @$calls),'no-wait never polls');
($code,$out,$err,$calls) = run_cli(['create-system','--name','new.example.com','--json']);
is(convert_from_json($out)->{data}->{state},'complete','JSON waits for final job');
is($err,'','JSON job output has no phase messages');

# Usage failures never reach a mutating action.
foreach my $args (
    ['unknown'],['start-system'],['start-system','--name','x','--id',$uuid],
    ['start-system','--name','x','--name','y'],['list-systems','--bogus'],
    ['list-systems','--state','paused2'],['list-systems','--STATE','running'],
    ['list-systems','--json','--name-only'],['get-host','--name-only'],
    ['delete-system','--name','x'],['cancel-job','--job',$job,'--cleanup'],
    ['passwd-system','--name','x','--user','cloudmin','--password','test-secret']) {
    ($code,$out,$err,$calls)=run_cli($args);
    is($code,2,join(' ',@$args).' is a usage error');
    unlike($err,qr/test-secret/,'rejected password argument is not echoed');
    unlike($err,qr/HASH\(/,'usage message is readable text');
}
# A repeated singular option names the option instead of a parser internal.
($code,$out,$err)=run_cli(['start-system','--name','x','--name','y']);
like($err,qr/^Specify --name only once\n/,'repeated singular option explained');
# Selector lookup errors use the operation-failure envelope, not usage output.
($code,$out,$err) = run_cli(['get-system','--name','missing','--json']);
is($code,1,'missing machine is a validation failure');
is(convert_from_json($out)->{status},'failure','JSON failure envelope');
is($err,'','JSON failure stays on stdout');
# Combining --no-wait with hardware and autostart edits must fail before writes.
($code,$out,$err,$calls)=run_cli(['modify-system','--id',$uuid,'--desc','text','--autostart','yes','--no-wait']);
is($code,2,'mixed asynchronous startup edit is refused');
ok(!grep({$_->[0] eq 'update' || $_->[0] eq 'autostart'} @$calls),'mixed no-wait fails before writes');

# Reject directory inputs and redact file-backed secrets echoed by API errors.
($code,$out,$err,$calls)=run_cli(['passwd-system','--id',$uuid,'--user','cloudmin','--password-file',$tmp]);
is($code,1,'directory is not accepted as a password file');
($code,$out,$err,$calls)=run_cli(['passwd-system','--id',$uuid,'--user','cloudmin','--password-file',"$tmp/password",'--json'],sub {
    # api(action, input, calls) resolves the guest, then returns a
    # secret-bearing error.
    my ($action)=@_; return [$machine] if ($action eq 'machines'); die "Rejected test-secret\n";
});
is($code,1,'API secret-bearing error is a failure');
unlike($out,qr/test-secret/,'secret is redacted from API errors');
like($out,qr/redacted/,'redaction remains visible');

# Exact summaries and syntax stay stable as options grow elsewhere.
my $cli = Cloudmin::CLI->new();
is($cli->short_help($cli->command('list-systems')),<<'HELP','list-systems help');
See `cloudmin help list-systems` for more details and examples

Lists the virtual machines on this host.

cloudmin list-systems [--multiline | --json]
                      [--name-only | --id-only]
                      [--name name]*
                      [--id uuid]*
                      [--state running|stopped|paused]
                      [--template ID|name]
                      [--plan ID|name]
HELP
is($cli->short_help($cli->command('start-system')),<<'HELP','start-system help');
See `cloudmin help start-system` for more details and examples

Starts a stopped virtual machine.

cloudmin start-system [--multiline | --json]
                      [--no-wait]
                      (--name name | --id uuid)
HELP
# Every help route must stay offline, including raw API short help.
foreach my $args ([],['--help'],['help','list-systems'],['list-systems','--help'],['api','--help']) {
    ($code,$out,$err,$calls)=run_cli($args);
    is($code,0,'help succeeds'); is(scalar(@$calls),0,'help never opens a service'); is($err,'','help is quiet');
}
# Convert units, keeping fractional values for API validation.
is(Cloudmin::CLI::size('2048','MiB'),2048,'bare memory size');
is(Cloudmin::CLI::size('2 GiB','MiB'),2048,'spaced binary unit');
is(Cloudmin::CLI::size('512M','GiB'),0.5,'fractional disk size');
ok(!eval {Cloudmin::CLI::size('2x','MiB');1},'invalid unit refused');

# Partial inventory and ambiguous names must not be presented as complete data.
($code,$out,$err)=run_cli(['list-snapshots','--json'],sub {
    # api(action, input, calls) reports a partial inventory failure.
    return {snapshots=>[{id=>'one'}],errors=>['Cannot read guest snapshots']};
});
is($code,1,'partial snapshot inventory fails');
is(convert_from_json($out)->{error},'Cannot read guest snapshots','inventory error is retained');
($code,$out,$err,$calls)=run_cli(['create-system','--name','new','--image','Duplicate'],sub {
    # api(action, input, calls) returns duplicate names with distinct IDs.
    return {images=>[{id=>'one',name=>'Duplicate'},{id=>'two',name=>'Duplicate'}]};
});
is($code,1,'ambiguous image name fails');
is_deeply([map {$_->[0]} @$calls],['options'],'ambiguous image cannot create a guest');

# A failed job and a timed-out power request report failure instead of success.
($code,$out,$err)=run_cli(['create-system','--name','new','--json'],sub {
    # api(action, input, calls) accepts submission, then reports worker failure.
    my ($action)=@_;
    return {id=>$job,state=>$action eq 'create' ? 'queued' : 'failed',error=>'Disk allocation failed'};
});
is($code,1,'job failure exits unsuccessfully');
is(convert_from_json($out)->{error},'Disk allocation failed','job failure keeps the cause');
($code,$out,$err)=run_cli(['start-system','--id',$uuid,'--json'],sub {
    # api(action, input, calls) accepts start but keeps the guest stopped.
    my ($action,$input)=@_;
    return $input->{id} ? $machine : [$machine] if ($action eq 'machines');
    return {id=>$uuid};
});
is($code,1,'a pending power state times out');
like(convert_from_json($out)->{error},qr/still pending/,'timeout explains how to follow the operation');
# Unexpected positional values must not be copied into usage diagnostics.
($code,$out,$err)=run_cli(['list-systems','accidental-secret']);
is($code,2,'positional input is a usage error');
unlike($err,qr/accidental-secret/,'unexpected positional data is not echoed');
# Storage reviews do not require confirmation and never submit a mutation.
for my $case (['delete-volume', 'volume_review', '--volume', 'unused.raw'], ['unregister-pool', 'pool_review']) {
    my ($command, $review, @extra) = @$case;
    my ($status, $output, undef, $requests) = run_cli([$command, '--pool', 'default', @extra, '--review']);
    is($status, 0, "$command review succeeds without --yes");
    is($requests->[-1]->[0], $review, "$command stops after its review");
    like($output, qr/Revision/, 'review displays its structured record');
}
# Reject conflicting backends and missing confirmation before any API call.
for my $args (['create-pool','--name','new'], ['create-pool','--name','new','--path','/tmp/pool','--group','guests'],
    ['delete-volume','--pool','default','--volume','unused.raw'], ['unregister-pool','--pool','stopped']) {
    my ($status, undef, undef, $requests) = run_cli($args);
    is($status, 2, 'invalid storage arguments are usage errors');
    is(scalar(@$requests), 0, 'invalid arguments make no API requests');
}
# Flattening volumes must retain ownership and report discovery failures.
{
    my ($status, $output) = run_cli(['list-volumes','--pool','default','--json']);
    is($status, 0, 'pool-filtered volume list succeeds');
    my $rows = convert_from_json($output)->{data};
    is($rows->[0]->{pool_id}, 'pool-id', 'volume retains exact pool identity');
    is_deeply($rows->[0]->{usage}->{owners}, [], 'JSON retains ownership records');
    local $storage->{lvm_group_error} = 'LVM discovery failed';
    is((run_cli(['list-volume-groups']))[0], 1, 'group discovery failure is not an empty success');
}
# Permission to stop the pool is distinct from confirmation to remove it.
{
    my ($status, undef, undef, $requests) = run_cli(['unregister-pool', '--pool', 'default', '--stop', '--review']);
    is($status, 0, 'stop review needs no destructive confirmation');
    is_deeply($requests->[-1], ['pool_review', {id => 'pool-id', stop => 1}], 'stop permission reaches review without a mutation');
    ($status, undef, undef, $requests) = run_cli(['unregister-pool', '--pool', 'default', '--stop', '--yes']);
    is($status, 0, 'explicit combined action succeeds');
    is($requests->[-1]->[1]->{stop}, 1, 'mutation carries the reviewed stop permission');
    ($status, undef, undef, $requests) = run_cli(['unregister-pool', '--pool', 'default', '--stop']);
    is($status, 2, 'stop permission alone is not confirmation');
    is(scalar(@$requests), 0, 'missing confirmation never calls the API');
}
# A refusal returned by review prevents the final mutation even with --yes.
for my $command ('delete-volume', 'unregister-pool') {
    my @extra = $command eq 'delete-volume' ? ('--volume', 'unused.raw') : ();
    my ($status, undef, $message, $requests) = run_cli([$command, '--pool', 'default', @extra, '--yes'], sub {
        return $storage if $_[0] eq 'storage';
        return {usage => {reason => 'Still referenced'}, revision => 'old'};
    });
    is($status, 1, 'blocked review returns operation failure');
    like($message, qr/Still referenced/, 'CLI retains the refusal reason');
    is(scalar(@$requests), 2, 'blocked review never submits the mutation');
}
# Thin destination names resolve only when they identify exactly one pool.
{
    local $storage->{pools} = [{uuid => 'one', name => 'guests/thin'}, {uuid => 'two', name => 'guests/thin'}];
    is((run_cli(['start-pool', '--pool', 'guests/thin']))[0], 1, 'ambiguous thin destination name is refused');
    local $storage->{pools} = [{uuid => 'one', name => 'guests/thin', volumes => []}];
    my ($status, undef, undef, $requests) = run_cli(['delete-volume', '--pool', 'guests/thin', '--volume', 'unused', '--review']);
    is($status, 0, 'thin destination name resolves');
    is($requests->[-1]->[1]->{pool}, 'one', 'resolved thin UUID reaches review');
}

# NFS CLI options form one source and use the normal pool registration API.
{
    my ($status, undef, undef, $requests) = run_cli(['create-pool', '--name', 'shared',
        '--server', 'nas.example.test', '--export', '/guests', '--path', '/mnt/guests']);
    is($status, 0, 'NFS CLI registration accepted');
    my ($request) = grep {$_->[0] eq 'register_pool'} @$requests;
    is_deeply($request->[1], {name => 'shared', type => 'netfs', server => 'nas.example.test',
        export => '/guests', path => '/mnt/guests', autostart => 1}, 'NFS request keeps source and mount fields');
    # Reject incomplete sources and mixed backends before contacting the host.
    for my $args (['--server','nas','--path','/mnt/guests'],
                  ['--export','/guests','--path','/mnt/guests'],
                  ['--server','nas','--export','/guests','--group','guests']) {
        my ($status, undef, undef, $requests) = run_cli(['create-pool', '--name', 'shared', @$args]);
        isnt($status, 0, 'incomplete or conflicting NFS options rejected');
        ok(!@$requests, 'invalid NFS CLI does not call the API');
    }
}

done_testing();
