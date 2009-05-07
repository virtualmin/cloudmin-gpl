# Functions for collecting virtual system run-time usage

$usage_data_dir = "$module_config_directory/usage";

# get_server_usage(&server)
# Returns a list of usage samples for a system, each of which is a hash ref
# with the following keys :
#   start - Unix time the same begins
#   end - Unix time it ends
#   up - Set to 1 if running
#   mem - Bytes of memory allocated during the same
#   cores - CPU cores allocated
#   cpu - Average percentage of CPU used
# Each represents the time some system was known to be running or down with
# a given memory and CPU allocation (if available)
sub get_server_usage
{
my ($server) = @_;
my @rv;
open(USAGE, "$usage_data_dir/$server->{'id'}");
while(<USAGE>) {
	s/\r|\n//g;
	my %u = map { split(/=/, $_) } split(/\s+/, $_);
	}
close(USAGE);
return @rv;
}

# save_server_usage(&server, &usages)
# Write out all usage data for some system
sub save_server_usage
{
my ($server, $usages) = @_;
&open_tempfile(USAGE, ">$usage_data_dir/$server->{'id'}");
foreach my $usage (@$usages) {
	&print_tempfile(USAGE, &usage_line($usage),"\n");
	}
&close_tempfile(USAGE);
}

# append_server_usage(&server, &usage)
# Append one usage sample for a system to its data file
sub append_server_usage
{
my ($server, $usage) = @_;
&open_tempfile(USAGE, ">>$usage_data_dir/$server->{'id'}");
&print_tempfile(USAGE, &usage_line($usage),"\n");
&close_tempfile(USAGE);
}

# usage_line(&usage)
# Convert a usage sample into a line of text
sub usage_line
{
my ($usage) = @_;
return join(" ", map { $_."=".$usage->{$_} }
	     &unique("start", "end", "up", sort { $a cmp $b } keys %$usage));
}

# update_server_usage(&server, &usage)
# Replace the last usage sample line with the one given
sub update_server_usage
{
my ($server, $usage) = @_;
my $pos = &find_last_usage_pos($server);
if ($pos > 0) {
	open(USAGE, "+<$usage_data_dir/$server->{'id'}");
	seek(USAGE, $pos, 0);
	print USAGE &usage_line($usage),"\n";
	close(USAGE);
	}
else {
	&append_server_usage($server, $usage);
	}
}

# last_server_usage(&server)
# Returns the last usage sample for some server
sub last_server_usage
{
my ($server) = @_;
my $pos = &find_last_usage_pos($server);
return undef if ($pos < 0);
open(USAGE, "$usage_data_dir/$server->{'id'}");
seek(USAGE, $pos, 0);
my $line = <USAGE>;
close(USAGE);
$line =~ s/\r|\n//g;
my %u = map { split(/=/, $_) } split(/\s+/, $line);
return \%u;
}

# find_last_usage_pos(&server)
# Returns the byte offset of the last line of usage data, or -1 if none
sub find_last_usage_pos
{
my ($server) = @_;
my $file = "$usage_data_dir/$server->{'id'}";
my @st = stat($file);
return -1 if (!@st || $st[7] == 0);
open(USAGE, $file);
if ($st[7] > 1024) {
	seek(USAGE, -1024, 2);
	}
my @lines = <USAGE>;
close(USAGE);
return $st[7] - length($lines[$#lines]);
}

# refresh_server_usage(&server, [time])
# Checks the current state of some server, and adds or updates a usage entry
# for it.
sub refresh_server_usage
{
my ($server, $now) = @_;
$now ||= time();
my $usage = &last_server_usage($server);

# Get current status and usage
my $up = $server->{'status'} ne 'down';
my ($mem, $cpu, $cores);
my $mfunc = "type_".$server->{'type'}."_get_memory";
if (defined(&$mfunc)) {
	$mem = &$mfunc($server);
	}
my $cfunc = "type_".$server->{'type'}."_get_cpu";
if (defined(&$cfunc)) {
	my ($cpu) = &$cfunc($server);
	}
my $vfunc = "type_".$server->{'type'}."_get_vcpus";
if (defined(&$vfunc)) {
	my @vcpus = &$vfunc($server);
	# XXX how to compute usage?
	}

my $extend = 0;
if ($usage && $usage->{'up'} && $up) {
	# Can just extend current sample, if memory and CPU are same
	if ($cores == $usage->{'cores'} &&
	    $mem == $usage->{'mem'}) {
		$extend = 1;
		}
	}
elsif ($usage && !$usage->{'up'} && !$up) {
	# Was down, still down .. can extend
	$extend = 1;
	}
if ($extend) {
	# Update last sample
	$usage->{'end'} = $now;
	&update_server_usage($server, $usage);
	}
else {
	# Create a new one
	my $newusage = { 'up' => $up,
			 'start' => $usage ? $usage->{'end'} : $now,
			 'end' => $now };
	$newusage->{'mem'} = $mem if (defined($mem));
	$newusage->{'cpu'} = $cpu if (defined($cpu));
	$newusage->{'cores'} = $cores if (defined($cores));
	&append_server_usage($server, $newusage);
	}
}

1;

