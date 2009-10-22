# Functions for Virtualmin domain replication

# list_virtualmin_syncs()
# Returns a list of configured Virtualmin domain syncs
sub list_virtualmin_syncs
{
my @rv;
&foreign_require("cron", "cron-lib.pl");
my @jobs = &cron::list_cron_jobs();
opendir(VSYNC, $vsyncs_dir);
foreach my $f (readdir(VSYNC)) {
	next if ($f =~ /^\./);
	my $vsync = &get_virtualmin_sync($f, \@jobs);
	push(@rv, $vsync) if ($vsync);
	}
closedir(VSYNC);
return @rv;
}

# get_virtualmin_sync(id, [&cronjobs])
# Looks up a sync by ID and returns a hash ref for it
sub get_virtualmin_sync
{
my ($id, $jobs) = @_;
my %vsync;
&read_file("$vsyncs_dir/$id", \%vsync) || return undef;
if (!$jobs) {
	&foreign_require("cron", "cron-lib.pl");
	$jobs = [ &cron::list_cron_jobs() ];
	}
my $cmd = $vsync_cron_cmd." --id ".$vsync{'id'};
$job = &find_server_manager_cron_job($cmd, $jobs);
$vsync{'enabled'} = $job ? 1 : 0;
return \%vsync;
}

# save_virtualmin_sync(&vsync)
# Creates or updates a virtualmin sync
sub save_virtualmin_sync
{
my ($vsync) = @_;
my $wasnew = !$vsync->{'id'};
if (!-d $vsyncs_dir) {
	&lock_file($vsyncs_dir);
	&make_dir($vsyncs_dir, 0700);
	&unlock_file($vsyncs_dir);
	}
$vsync->{'id'} ||= &server_id();
my $file = $vsyncs_dir."/".$vsync->{'id'};
&lock_file($file);
&write_file($file, $vsync);
&unlock_file($file);

# Update or delete cron job
&foreign_require("cron", "cron-lib.pl");
my $cmd = $vsync_cron_cmd." --id ".$vsync->{'id'};
my $job;
if (!$wasnew) {
	($job) = &find_server_manager_cron_job($cmd);
	}
if ($vsync->{'enabled'} && $job) {
	# Fix job schedule
	&copy_cron_sched_keys($vsync, $job);
	&lock_file(&cron::cron_file($job));
	&cron::change_cron_job($job);
	&unlock_file(&cron::cron_file($job));
	}
elsif ($vsync->{'enabled'} && !$job) {
	# Create cron job
	$job = { 'user' => 'root',
		 'active' => 1,
		 'command' => $cmd };
	&copy_cron_sched_keys($vsync, $job);
	&lock_file(&cron::cron_file($job));
	&cron::create_cron_job($job);
	&unlock_file(&cron::cron_file($job));
	}
elsif (!$vsync->{'enabled'} && $job) {
	# Delete cron job
	&lock_file(&cron::cron_file($job));
	&cron::delete_cron_job($job);
	&unlock_file(&cron::cron_file($job));
	}
&cron::create_wrapper($vsync_cron_cmd, $module_name, "vsync.pl");
}

# delete_virtualmin_sync(&vsync)
# Remove one virtualmin sync
sub delete_virtualmin_sync
{
my ($vsync) = @_;
my $file = $vsyncs_dir."/".$vsync->{'id'};
&unlink_logged($file);

# Delete cron too
&foreign_require("cron", "cron-lib.pl");
my $cmd = $vsync_cron_cmd." --id ".$vsync->{'id'};
my ($job) = &find_server_manager_cron_job($cmd);
if ($job) {
	&lock_file(&cron::cron_file($job));
	&cron::delete_cron_job($job);
	&unlock_file(&cron::cron_file($job));
	}
}

# get_virtualmin_sync_dests(&vsync)
# Returns an array of destination systems for some sync
sub get_virtualmin_sync_dests
{
my ($vsync) = @_;
my @rv;
foreach my $id (split(/\s+/, $vsync->{'dest'})) {
	my $s = &get_managed_server($id);
	push(@rv, $s) if ($s);
	}
return @rv;
}

# can_virtualmin_sync(&vsync)
# Checks if the current user can edit a sync
sub can_virtualmin_sync
{
my ($vsync) = @_;
my $src = &get_managed_server($vsync->{'src'});
my @dests = &get_virtualmin_sync_dests($vsync);
foreach my $s ($src, @dests) {
	return 0 if (!&can_action("domains", $s));
	}
return 1;
}

# list_virtualmin_globals()
# Returns a list of codes for Virtualmin global settings that can be replicated
sub list_virtualmin_globals
{
return ( 'config', 'templates', 'scheds', 'resellers', 'email', 'custom',
	 'scripts', 'styles', 'chroot' );
}

# sync_virtualmin_domains(&vsync)
# Execute a Virtualmin domain sync, printing output as it goes
sub sync_virtualmin_domains
{
my ($vsync) = @_;

&$first_print($text{'vsync_finding'});
my $src = &get_managed_server($vsync->{'src'});
my @dests = &get_virtualmin_sync_dests($vsync);
if (!$src) {
	&$second_print($text{'vsync_efindsrc'});
	return 0;
	}
if (!@dests) {
	&$second_print($text{'vsync_efinddest'});
	return 0;
	}
&$second_print(&text('vsync_found', $src->{'host'}, scalar(@dests)));

# Create temp dirs on the source and dests
&$first_print($text{'vsync_temp'});
my %tempdir;
foreach my $s ($src, @dests) {
	my $temp = &tempname_on_server($s);
	if (!$temp) {
		&$first_print(&text('vsync_etemp', $s->{'host'}));
		return 0;
		}
	my ($out, $ex, $err) = &execute_command_on_server($s,
				"mkdir -p ".quotemeta($temp));
	if ($ex || $err) {
		&$first_print(&text('vsync_emktemp',
				    $s->{'host'}, $err || $out));
		return 0;
		}
	$tempdir{$s->{'id'}} = $temp;
	}
my $srctemp = $tempdir{$src->{'id'}};
&$second_print($text{'create_done'});

# Backup all domains to the temp dir
&$first_print($text{'vsync_backup'});
my @args = ( [ "newformat" ],
	     [ "dest", $srctemp ] );
my @doms = split(/\s+/, $vsync->{'doms'});
push(@args, map { [ "domain", $_ ] } @doms);
my @tmpls = split(/\s+/, $vsync->{'tmpls'});
push(@args, map { [ "virtualmin", $_ ] } @tmpls);
my @feats = split(/\s+/, $vsync->{'feats'});
if (@feats) {
	push(@args, map { [ "feature", $_ ] } @feats);
	}
else {
	push(@args, [ "all-features" ]);
	}
my ($err, $out) = &call_virtualmin_api($src, "backup-domain", \@args);
if ($err || $out !~ /Final\s+size\s+was\s+([0-9\.]+\s*\S+)/) {
	&delete_file_on_server($src, $srctemp);
	&$second_print(&text('vsync_ebackup', $err));
	return 0;
	}
my $nicesize = $1;

# Find the created file for each domain
my %dompath;
if (@tmpls) {
	push(@doms, "virtualmin");
	}
foreach my $dname (@doms) {
	foreach my $sfx ("tar.gz", "tar.bz2", "tar", "zip") {
		my $path = "$srctemp/$dname.$sfx";
		my @st = &stat_file_on_server($src, $path);
		if (@st && $st[7]) {
			$dompath{$dname} = $path;
			last;
			}
		}
	if (!$dompath{$dname}) {
		&delete_file_on_server($src, $srctemp);
		&$second_print(&text('vsync_ebackupfile', $dname));
		return 0;
		}
	}
&$second_print(&text('vsync_backed', $nicesize));

# Transfer each to the targets, in parallel
&$first_print($text{'vsync_transfer'});
my @rargs = grep { $_->[0] ne "dest" && $_->[0] ne "newformat" } @args;
my $args = [ $src, \@doms, \%dompath, \%tempdir, \@rargs ];
my @transouts = &parallel_server_function(
			\@dests, \&transfer_virtualmin_domains, $args);
my @transok = grep { $_->[0] } @transouts;
my @transfailed = grep { !$_->[0] } @transouts;
my $ok = 1;
if (@transfailed) {
	&$second_print(&text('vsync_etransfer',
			     scalar(@transok), scalar(@transfailed)));
	foreach my $t (@transfailed) {
		&$second_print(&text('vsync_etransfer2',
				     $t->[1], $t->[3], $t->[2]));
		}
	$ok = 0;
	}
else {
	&$second_print($text{'create_done'});
	}

# Clean up on source
if ($srctemp) {
	&delete_file_on_server($src, $srctemp);
	}

# Restore on the targets for which the transfer worked, in parallel
&$first_print($text{'vsync_restore'});
my @okdests;
for(my $i=0; $i<@dests; $i++) {
	if ($transouts[$i]->[0]) {
		push(@okdests, $dests[$i]);
		}
	}
my @restoreouts = &parallel_server_function(
			\@okdests, \&restore_virtualmin_domains, $args);
my @restoreok = grep { $_->[0] } @restoreouts;
my @restorefailed = grep { !$_->[0] } @restoreouts;
if (@restorefailed) {
	&$second_print(&text('vsync_erestore',
			     scalar(@restoreok), scalar(@restorefailed)));
	foreach my $t (@restorefailed) {
		&$second_print(&text('vsync_erestore2', $t->[2], $t->[1]));
		}
	$ok = 0;
	}
else {
	&$second_print($text{'create_done'});
	}

# Clean up on targets
foreach my $dest (@dests) {
	my $desttemp = $tempdir{$dest->{'id'}};
	if ($desttemp) {
		&delete_file_on_server($dest, $desttemp);
		}
	}

return $ok;
}

# transfer_virtualmin_domains(&dest, &args)
# Transfer all domain files to a remote system
sub transfer_virtualmin_domains
{
my $dest = $_[0];
my ($src, $doms, $dompath, $tempdir) = @{$_[1]};
my $desttemp = $tempdir->{$dest->{'id'}};
foreach my $dname (@$doms) {
	my $filename = $dompath->{$dname};
	$filename =~ s/^.*\///;
	my $err = &transfer_file_between_servers(
		$src, $dest, $dompath->{$dname}, "$desttemp/$filename");
	if ($err) {
		return ( 0, $err, $dest->{'host'} );
		}
	}
return ( 1 );
}

# restore_virtualmin_domains(&dest, &args)
# Restore all domain files on a remote system
sub restore_virtualmin_domains
{
my $dest = $_[0];
my ($src, $doms, $dompath, $tempdir, $rargs) = @{$_[1]};
my $desttemp = $tempdir->{$dest->{'id'}};
my @rargs = @$rargs;
push(@rargs, [ "source", $desttemp ]);
my ($err, $out) = &call_virtualmin_api($dest, "restore-domain", \@rargs);
if ($err) {
	return ( 0, $err, $dest->{'host'} );
	}
return ( 1 );
}



1;

