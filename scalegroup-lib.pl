# Functions for managing auto-scaling groups

# list_scalegroups()
# Returns a list of all configured auto-scaling groups
sub list_scalegroups
{
my @rv;
opendir(RR, $scalegroups_dir);
foreach my $f (readdir(RR)) {
	next if ($f =~ /^\./);
	my $rr = &get_scalegroup($f);
	if ($rr) {
		push(@rv, $rr);
		}
	}
close(RR);
return sort { $a->{'id'} <=> $b->{'id'} } @rv;
}

# get_scalegroup(id)
# Returns the hash ref for a single auto-scaling group. Keys are :
# id - A unique ID
# desc - Human-readable description for this scalegroup
# manager - Virtualization type to create
# image - Image to create systems from
# host - Hostname pattern, including ${NUM}
#
sub get_scalegroup
{
my ($id) = @_;
my %rr;
&read_file_cached("$scalegroups_dir/$id", \%rr) || return undef;
$rr{'id'} = $id;
return \%rr;
}

# save_scalegroup(&scalegroup)
# Create or update an auto-scaling group
sub save_scalegroup
{
my ($rr) = @_;
if (!-r $scalegroups_dir) {
	&lock_file($scalegroups_dir);
	&make_dir($scalegroups_dir, 0700);
	&unlock_file($scalegroups_dir);
	}
$rr->{'id'} ||= &server_id();
my $file = "$scalegroups_dir/$rr->{'id'}";
&lock_file($file);
&write_file($file, $rr);
&unlock_file($file);
}

# delete_scalegroup(&scalegroup)
# Deletes an auto-scaling group (but not the systems)
sub delete_scalegroup
{
my ($rr) = @_;
my $file = "$scalegroups_dir/$rr->{'id'}";
&lock_file($file);
&unlink_file($file);
&unlock_file($file);
}


