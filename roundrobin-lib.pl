# Functions for configuring automatic DNS round-robin entries

# list_roundrobins()
# Returns a list of all configured DNS roundrobins
sub list_roundrobins
{
my @rv;
opendir(RR, $roundrobins_dir);
foreach my $f (readdir(RR)) {
	next if ($f =~ /^\./);
	my $rr = &get_roundrobin($f);
	if ($rr) {
		push(@rv, $rr);
		}
	}
close(RR);
return sort { $a->{'id'} <=> $b->{'id'} } @rv;
}

# get_roundrobin(id)
# Returns the hash ref for a single roundrobin DNS entry. Keys are :
# id - A unique ID
# desc - Human-readable description for this roundrobin
# dom - Domain name the record is in
# name - Record name within the domain
# servers - IDs of servers to include
# groups - Names of groups of servers to include
# status - List of acceptable status codes
# alerts - IDs of alerts that must not be firing
# ports - TCP ports that must be open
# url - URL on hosts that must respond with a 200
# min - Minimum hosts that should be in the roundrobin
# master - Send email to master if roundrobin is too small
# email - Send email to this address if too small
# interval - Period in seconds between sending alert emails
sub get_roundrobin
{
my ($id) = @_;
my %rr;
&read_file_cached("$roundrobins_dir/$id", \%rr) || return undef;
$rr{'id'} = $id;
return $rr;
}

# save_roundrobin(&roundrobin)
# Create or update a DNS roundrobin entry
sub save_roundrobin
{
my ($rr) = @_;
if (!-r $roundrobins_dir) {
	&lock_file($roundrobins_dir);
	&make_dir($roundrobins_dir, 0700);
	&unlock_file($roundrobins_dir);
	}
$rr->{'id'} ||= &server_id();
my $file = "$roundrobins_dir/$rr->{'id'}";
&lock_file($file);
&write_file($file, $rr);
&unlock_file($file);
}

# delete_roundrobin(&roundrobin)
# Deletes a DNS roundrobin (but not the DNS record)
sub delete_roundrobin
{
my ($rr) = @_;
my $file = "$roundrobins_dir/$rr->{'id'}";
&lock_file($file);
&unlink_file($file);
&unlock_file($file);
}

1;

