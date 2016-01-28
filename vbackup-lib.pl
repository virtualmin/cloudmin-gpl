# Functions for Virtualmin backups

# list_virtualmin_backups([keep-enabled])
# Returns a list of configured Virtualmin domain backups
sub list_virtualmin_backups
{
my ($keepenabled) = @_;
my @rv;
opendir(VSYNC, $vbackups_dir);
foreach my $f (readdir(VSYNC)) {
	next if ($f =~ /^\./);
	my $vbackup = &get_virtualmin_backup($f, $keepenabled);
	push(@rv, $vbackup) if ($vbackup);
	}
closedir(VSYNC);
return @rv;
}

# get_virtualmin_backup(id, [keep-enabled])
# Looks up a backup by ID and returns a hash ref for it
sub get_virtualmin_backup
{
my ($id, $jobs, $keepenabled) = @_;
my %vbackup;
&read_file_cached("$vbackups_dir/$id", \%vbackup) || return undef;
if (!$keepenabled) {
	my $cmd = $vbackup_cron_cmd." --id ".$vbackup{'id'};
	$job = &find_cron_script($cmd);
	$vbackup{'enabled'} = $job ? 1 : 0;
	}
return \%vbackup;
}

# save_virtualmin_backup(&vbackup)
# Creates or updates a virtualmin backup
sub save_virtualmin_backup
{
my ($vbackup) = @_;
my $wasnew = !$vbackup->{'id'};
if (!-d $vbackups_dir) {
	&lock_file($vbackups_dir);
	&make_dir($vbackups_dir, 0700);
	&unlock_file($vbackups_dir);
	}
$vbackup->{'id'} ||= &server_id();
my $file = $vbackups_dir."/".$vbackup->{'id'};
&lock_file($file);
&write_file($file, $vbackup);
&unlock_file($file);
&save_virtualmin_backup_cron($vbackup, $wasnew);
}

# save_virtualmin_backup_cron(&vbackup, [was-new])
# Update or delete backup cron job
sub save_virtualmin_backup_cron
{
my ($vbackup, $wasnew) = @_;
&foreign_require("cron", "cron-lib.pl");
my $cmd = $vbackup_cron_cmd." --id ".$vbackup->{'id'};
my $job;
if (!$wasnew) {
	($job) = &find_cron_script($cmd);
	}
if ($vbackup->{'enabled'} && $job) {
	# Fix job schedule
	&copy_cron_sched_keys($vbackup, $job);
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
elsif ($vbackup->{'enabled'} && !$job) {
	# Create cron job
	$job = { 'user' => 'root',
		 'active' => 1,
		 'command' => $cmd };
	&copy_cron_sched_keys($vbackup, $job);
	&setup_cron_script($job);
	}
elsif (!$vbackup->{'enabled'} && $job) {
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

# delete_virtualmin_backup(&vbackup)
# Remove one virtualmin backup
sub delete_virtualmin_backup
{
my ($vbackup) = @_;
my $file = $vbackups_dir."/".$vbackup->{'id'};
&unlink_logged($file);

# Delete cron too
my $cmd = $vbackup_cron_cmd." --id ".$vbackup->{'id'};
my ($job) = &find_cron_script($cmd);
if ($job) {
	&delete_cron_script($job);
	}
}

# get_virtualmin_backup_srcs(&vsync)
# Returns an array of source systems for some backup
sub get_virtualmin_backup_srcs
{
my ($vbackup) = @_;
my @rv;
foreach my $id (split(/\s+/, $vbackup->{'src'})) {
	my $s = &get_managed_server($id);
	push(@rv, $s) if ($s);
	}
return @rv;
}

# can_virtualmin_backup(&vbackup)
# Checks if the current user can edit a backup
sub can_virtualmin_backup
{
my ($vbackup) = @_;
foreach my $src (&get_virtualmin_backup_srcs($vbackup)) {
	return 0 if (!&can_action($src, "domains"));
	}
return 1;
}

# backup_virtualmin_domains_one(&server, &backup)
# Backup domains on a single system
sub backup_virtualmin_domains_one
{
my ($server, $vbackup) = @_;

# Work out which domains are wanted, and are on this system
my @doms = split(/\s+/, $vbackup->{'doms'});
my %domsmap = map { $_, 1 } @doms;
my @srcdomobjs = &get_server_domains($server);
@srcdomobjs = &sort_domains_parent_first(@srcdomobjs);
my @srcdoms;
if ($vbackups->{'doms_all'}) {
	@srcdoms = map { $_->{'dom'} } @srcdomobjs;
	}
else {
	@srcdoms = grep { $domsmap{$_} }
			map { $_->{'dom'} } @srcdomobjs;
	}

# Construct the backup command
my @args;
my $strftime = 0;
my $mkdir = 0;
foreach my $dest (split(/\s+/, $vbackup->{'dest'})) {
	$strftime = 1 if ($dest =~ /%/);
	$mkdir = 1 if ($dest =~ /^\//);
	$dest = &substitute_template($dest, \$server);
	push(@args, [ "dest", $dest ]);
	}
push(@args, map { [ "domain", $_ ] } @srcdoms);
my @tmpls = split(/\s+/, $vbackup->{'tmpls'});
push(@args, map { [ "virtualmin", $_ ] } @tmpls);
push(@args, [ "all-features" ]);
if ($dests[0] !~ /\.(gz|tgz|tar.gz|zip|tar.bz2)$/i) {
	push(@args, [ "newformat" ]);
	}
push(@args, [ "mkdir" ]) if ($mkdir);
push(@args, [ "strftime" ]) if ($strftime);

# Call the API
my ($err, $out) = &call_virtualmin_api($server, "backup-domain", \@args);
if ($err || $out !~ /Final\s+size\s+was\s+([0-9\.]+\s*\S+)/) {
	return (0, $err || $out);
	}
my $nicesize = $1;

return (1, $nicesize, scalar(@srcdoms), scalar(@tmpls));
}

# backup_virtualmin_domains(&vbackup)
# Execute a Virtualmin domain backup, printing output as it goes
sub backup_virtualmin_domains
{
my ($vbackup) = @_;
my @srcs = &get_virtualmin_backup_srcs($vbackup);
my @doms = split(/\s+/, $vbackup->{'doms'});

# Refresh status of source systems, to ensure domains list is up to date
&$first_print($text{'vbackup_refreshing'});
&parallel_check_server_status(\@srcs, 0, 1);
&$second_print($text{'create_done'});

# Backup each server in parallel
&$first_print(&text('vbackup_doing', scalar(@srcs)));
my @rv = &parallel_server_function(\@srcs, \&backup_virtualmin_domains_one,
			           $vbackup);
&$second_print($text{'vbackup_pdone'});

# Print the result messages
my $fails = 0;
for(my $i=0; $i<@rv; $i++) {
	my ($ok, $msg, $dc, $tc) = @{$rv[$i]};
	&$first_print(&text('vbackup_result', $srcs[$i]->{'host'},
			    $ok ? &text('vbackup_size', $msg, $dc, $tc)
				: &text('vbackup_fail', $msg)));
	$fails++ if (!$ok);
	}

return !$fails;
}

1;

