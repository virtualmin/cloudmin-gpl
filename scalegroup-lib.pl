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
# clone - ID of virtual system to clone
# host - Hostname pattern, including ${NUM}
# conds - Array ref of rule hash refs, each of which contains
#	name - Variable to match on, like load, mem, space
#	value - Cutoff value for scaling
#	over/under - Match if variable is over or under the value
#	for - Optional period is seconds that this must be true for
#	count - Optional number of systems that this must be true for
# rate - Period in seconds between changing group size
# min - Minimum systems in the group
# max - Maximum systems in the group
# master - Send email to master when group changes
# email - Send email to this address when group changes
# interval - Period in seconds between sending emails
sub get_scalegroup
{
my ($id) = @_;
my %rr;
&read_file_cached("$scalegroups_dir/$id", \%rr) || return undef;
$rr{'id'} = $id;
my @conds;
for(my $i=0; defined($rr{"cond_$i"}); $i++) {
	push(@conds, { map { split(/=/, $_) }
		       split(/\s+/, $rr{"cond_$i"}) });
	delete($rr{"cond_$i"});
	}
$rr{'conds'} = \@conds;
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
my %rsave = %$rr;
delete($rsave{'conds'});
my $i = 0;
foreach my $r (@{$rr->{'conds'}}) {
	$rsave{'cond_'.$i} = join(" ", map { $_."=".$r->{$_} } keys %$r);
	$i++;
	}
&write_file($file, \%rsave);
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


