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
	&make_dir_logged($vsyncs_dir, 0700);
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

1;

