#!/usr/local/bin/perl
# Update reverse IPs for some system

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'reverse_err'});

# Get and check system
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "reverse");

# Parse inputs
@revs = &get_server_reverse_records($server);
foreach $rev (@revs) {
	next if ($rev->{'outside'} ||
		 !defined($in{"host_".$rev->{'ip'}."_def"}));
	if ($in{"host_".$rev->{'ip'}."_def"}) {
		# No name assigned
		delete($rev->{'name'});
		}
	else {
		$name = $in{"host_".$rev->{'ip'}};
		$name =~ /^[a-z0-9\.\-\_]+$/i ||
			&error(&text('reverse_ehost', $name));
		$rev->{'name'} = $name;
		}
	}
$err = &save_server_reverse_records($server, \@revs);
&error($err) if ($err);
&release_lock_server($server);

&redirect("edit_serv.cgi?id=".$in{'id'});

