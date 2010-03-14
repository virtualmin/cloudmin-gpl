# Functions for managing scheduled changes

# get_scheduled_change(&server, type, id)
# Returns the hash ref for a scheduled change of some type, or undef
sub get_scheduled_change
{
my ($server, $type, $id) = @_;
my $idfile = $id;
$idfile =~ s/^\/+//;
$idfile =~ s/\//_/g;
my $file = "$scheduled_changes_dir/$server->{'id'}-$type-$idfile";
my %rv;
&read_file_cached($file, \%rv) || return undef;
return \%rv;
}

# save_scheduled_change(&server, type, id, [&change])
# Creates, updates or deletes a scheduled change
sub save_scheduled_change
{
my ($server, $type, $id, $sched) = @_;
my $idfile = $id;
$idfile =~ s/^\/+//;
$idfile =~ s/\//_/g;
my $file = "$scheduled_changes_dir/$server->{'id'}-$type-$idfile";
if (!-d $scheduled_changes_dir) {
	&make_dir($scheduled_changes_dir, 0700);
	}
if ($sched) {
	# Create or update
	$sched->{'id'} = $id;
	$sched->{'type'} = $type;
	$sched->{'server'} = $server->{'id'};
	&lock_file($file);
	&write_file($file, $sched);
	&unlock_file($file);
	}
else {
	# Delete
	&unlink_logged($file);
	}
}

# list_scheduled_changes()
# Returns a list of all known scheduled changes
sub list_scheduled_changes
{
my @rv;
opendir(SCHEDS, $scheduled_changes_dir);
foreach my $f (readdir(SCHEDS)) {
	if ($f =~ /^(\d+)\-([^\-]+)-(\S+)$/) {
		my %sched;
		if (&read_file_cached("$scheduled_changes_dir/$f", \%sched)) {
			push(@rv, \%sched);
			}
		}
	}
closedir(SCHEDS);
return @rv;
}

# run_scheduled_changes()
# Finds any scheduled changes due to happen, runs them, sends email notifcation
# and deletes them
sub run_scheduled_changes
{
# XXX
}

1;

