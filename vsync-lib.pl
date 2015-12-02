# Functions for Virtualmin domain replication

# list_virtualmin_syncs([keep-enabled])
# Returns a list of configured Virtualmin domain syncs
sub list_virtualmin_syncs
{
my ($keepenabled) = @_;
my @rv;
opendir(VSYNC, $vsyncs_dir);
foreach my $f (readdir(VSYNC)) {
	next if ($f =~ /^\./);
	my $vsync = &get_virtualmin_sync($f, $keepenabled);
	push(@rv, $vsync) if ($vsync);
	}
closedir(VSYNC);
return @rv;
}

# get_virtualmin_sync(id, [keep-enabled])
# Looks up a sync by ID and returns a hash ref for it
sub get_virtualmin_sync
{
my ($id, $jobs, $keepenabled) = @_;
my %vsync;
&read_file_cached("$vsyncs_dir/$id", \%vsync) || return undef;
if (!$keepenabled) {
	my $cmd = $vsync_cron_cmd." --id ".$vsync{'id'};
	$job = &find_cron_script($cmd);
	$vsync{'enabled'} = $job ? 1 : 0;
	}
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
&save_virtualmin_sync_cron($vsync, $wasnew);
}

# save_virtualmin_sync_cron(&vsync, [was-new])
# Update or delete cron job
sub save_virtualmin_sync_cron
{
my ($vsync, $wasnew) = @_;
&foreign_require("cron", "cron-lib.pl");
my $cmd = $vsync_cron_cmd." --id ".$vsync->{'id'};
my $job;
if (!$wasnew) {
	($job) = &find_cron_script($cmd);
	}
if ($vsync->{'enabled'} && $job) {
	# Fix job schedule
	&copy_cron_sched_keys($vsync, $job);
	if ($job->{'module'}) {
		# Webmincron
		&setup_cron_script($job);
		}
	else {
		# Classic cron
		&lock_file(&cron::cron_file($job));
		&cron::change_cron_job($job);
		&unlock_file(&cron::cron_file($job));
		}
	}
elsif ($vsync->{'enabled'} && !$job) {
	# Create cron job
	$job = { 'user' => 'root',
		 'active' => 1,
		 'command' => $cmd };
	&copy_cron_sched_keys($vsync, $job);
	&setup_cron_script($job);
	}
elsif (!$vsync->{'enabled'} && $job) {
	# Delete cron job
	if ($job->{'module'}) {
		# Webmincron
		&delete_cron_script($job);
		}
	else {
		# Classic cron
		&lock_file(&cron::cron_file($job));
		&cron::delete_cron_job($job);
		&unlock_file(&cron::cron_file($job));
		}
	}
}

# delete_virtualmin_sync(&vsync)
# Remove one virtualmin sync
sub delete_virtualmin_sync
{
my ($vsync) = @_;
my $file = $vsyncs_dir."/".$vsync->{'id'};
&unlink_logged($file);

# Delete cron too
my $cmd = $vsync_cron_cmd." --id ".$vsync->{'id'};
my ($job) = &find_cron_script($cmd);
if ($job) {
	&delete_cron_script($job);
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
	return 0 if (!&can_action($s, "domains"));
	}
return 1;
}

# list_virtualmin_globals(\@servers)
# Returns a list of codes for Virtualmin global settings that can be replicated
sub list_virtualmin_globals
{
my ($servers) = @_;
my $any_pro = 0;
foreach my $s (@servers) {
	my $info = &get_server_collected($s);
	if ($info->{'minfo'} && $info->{'minfo'}->{'version'} !~ /gpl/i) {
		$any_pro++;
		last;
		}
	}
return ( 'config', 'templates',
         $any_pro ? ( 'resellers' ) : ( ),
         'email', 'custom', 'scripts',
         $any_pro ? ( 'styles' ) : ( ),
         'scheds', 'chroot', 'mailserver' );
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
if (@dests == 1) {
	&$second_print(&text('vsync_foundone', $src->{'host'},
					       $dests[0]->{'host'}));
	}
else {
	&$second_print(&text('vsync_found', $src->{'host'}, scalar(@dests)));
	}

# Refresh status of source system, to ensure domains list is up to date
&$first_print($text{'vsync_refreshing'});
&check_server_status($src);
&save_managed_server($src);
&$second_print($text{'create_done'});

# Create temp dirs on the source and dests
&$first_print($text{'vsync_temp'});
my %tempdir;
foreach my $s ($src, @dests) {
	my $temp = &tempname_on_server($s);
	if (!$temp) {
		&$first_print(&text('vsync_etemp', $s->{'host'}));
		return 0;
		}
	my $err = &make_dir_on_server($s, $temp, 0700, 1);
	if ($err) {
		&$first_print(&text('vsync_emktemp', $s->{'host'}, $err));
		return 0;
		}
	$tempdir{$s->{'id'}} = $temp;
	}
my $srctemp = $tempdir{$src->{'id'}};
&$second_print($text{'create_done'});

# Work out domains
my @doms;
my @srcdomobjs = &get_server_domains($src);
my @srcdoms = map { $_->{'dom'} } @srcdomobjs;
if ($vsync->{'doms_all'}) {
	@doms = @srcdoms;
	}
else {
	@doms = split(/\s+/, $vsync->{'doms'});
	}

# Work out if the first domain has a shared home dir
my ($err, $out) = &call_virtualmin_api($src, "list-domains",
				       [ [ "simple-multiline" ],
					 [ "domain", $doms[0] ] ]);
my %remotes;
if ($err) {
	&$second_print(&text('vsync_remoteerr', $err));
	return 0;
	}
if ($out =~ /Remote\s+features:\s*(.*)/) {
	%remotes = map { $_, 1 } split(/\s+/, $1);
	}

# Backup all domains to the temp dir
my @args = ( [ "dest", $srctemp ] );
&$first_print(&text('vsync_backup', scalar(@doms)));
if (!@doms && !$vsync->{'tmpls'}) {
	&$second_print($text{'vsync_ebackupdoms'});
	return 0;
	}
push(@args, map { [ "domain", $_ ] } @doms);
my @tmpls = split(/\s+/, $vsync->{'tmpls'});
push(@args, map { [ "virtualmin", $_ ] } @tmpls);
my @feats = split(/\s+/, $vsync->{'feats'});
my @efeats = split(/\s+/, $vsync->{'efeats'});
if (@feats) {
	push(@args, map { [ "feature", $_ ] } @feats);
	push(@args, [ &indexof("dir", @feats) >= 0 ? "newformat"
						   : "separate" ]);
	}
elsif (@efeats) {
	push(@args, [ "all-features" ]);
	push(@args, map { [ "except-feature", $_ ] } @efeats);
	push(@args, [ &indexof("dir", @efeats) < 0 ? "newformat"
						   : "separate" ]);
	}
else {
	push(@args, [ "all-features" ]);
	push(@args, [ "newformat" ]);
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
my @rargs = grep { $_->[0] ne "dest" && $_->[0] ne "newformat" &&
		   $_->[0] ne "separate" } @args;
my $args = [ $src, \@doms, \%dompath, \%tempdir, \@rargs, $remotes{'dir'} ];
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

# On each target, find additonal Virtualmin domains and remove them
if ($vsync->{'doms_delete'}) {
	&$first_print($text{'vsync_deleting'});
	my $args = [ \@srcdoms ];
	my @deleteouts = &parallel_server_function(
		\@okdests, \&delete_virtualmin_domains, $args);
	foreach my $t (@deleteouts) {
		if (!$t->[0]) {
			# Deletion failed
			&$second_print(&text('vsync_deletedfailed',
					$t->[2], $t->[1], scalar(@{$t->[3]})));
			}
		elsif ($t->[0] && $t->[3]) {
			# Deleted OK
			&$second_print(&text('vsync_deleted',
					$t->[2], scalar(@{$t->[3]})));
			}
		else {
			# Nothing to do
			&$second_print(&text('vsync_deletednone',
					$t->[2]));
			}
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
my ($src, $doms, $dompath, $tempdir, $rargs, $remote_dir) = @{$_[1]};
my $vinfo = &get_server_collected($dest);
my $desttemp = $tempdir->{$dest->{'id'}};
my @rargs = @$rargs;
push(@rargs, [ "source", $desttemp ]);
push(@rargs, [ "skip-warnings" ]);
if ($remote_dir) {
	push(@rargs, [ "no-reuid" ]);
	}
push(@rargs, [ "option", "dir delete 1" ]);
if ($vinfo->{'minfo'}->{'version'} >= 4.161) {
	# Use replication mode
	push(@rargs, [ "replication" ]);
	}
my ($err, $out) = &call_virtualmin_api($dest, "restore-domain", \@rargs);
if (!$err && $out =~ /Restore\s+failed/) {
	$err = $out;
	}
if ($err) {
	return ( 0, $err, $dest->{'host'} );
	}

# Re-read domains list
&check_server_status($dest);
&save_managed_server($dest);
return ( 1 );
}

# delete_virtualmin_domains(&dest, &args)
# Delete from a virtual system any domains that aren't on the source
sub delete_virtualmin_domains
{
my $dest = $_[0];
my ($srcdoms) = @{$_[1]};
my @ddoms = map { $_->{'dom'} } &get_server_domains($dest);
my %srcmap = map { $_, 1 } @$srcdoms;
my @ddelete = grep { !$srcmap{$_} } @ddoms;
if (@ddelete) {
	my @dargs = ( map { [ "domain", $_ ] } @ddelete );
	my ($err, $out) = &call_virtualmin_api($dest, "delete-domain", \@dargs);
	if ($err) {
		return ( 0, $err, $dest->{'host'}, \@ddelete );
		}
	&check_server_status($dest);
	&save_managed_server($dest);
	return ( 1, undef, $dest->{'host'}, \@ddelete );
	}
return ( 1, undef, $dest->{'host'}, undef );
}

# run_all_vsyncs_for_server(&server, domain-name)
# Called after creating a domain on a system to run all vsyncs that use it
# as a source
sub run_all_vsyncs_for_server
{
my ($server, $dname) = @_;
foreach my $vsync (grep { $_->{'src'} eq $server->{'id'} &&
			  $_->{'doms_all'} }
			&list_virtualmin_syncs(1)) {
	&$first_print(&text('dcreate_vsync', $server->{'host'}, $dname));
	my $vsync_copy = { %$vsync };
	delete($vsync_copy->{'doms_all'});
	$vsync_copy->{'doms'} = $dname;
	&$indent_print();
	&sync_virtualmin_domains($vsync_copy);
	&$outdent_print();
	}
}

1;

