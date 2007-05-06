#!/usr/local/bin/perl
# Create a Virtualmin domain on some remote server, by calling the API

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'dcreate_err'});
@vservers = grep { $_->{'status'} eq 'virt' &&
		   !$_->{'novirt'} &&
		   $_->{'virtualmin_checked'} } &list_managed_servers();

# Validate inputs, and store in args list
@args = ( );
$in{'dom'} = lc($in{'dom'});
$in{'dom'} =~ /^[a-z0-9\.\-\_]+$/ || &error($text{'dcreate_edom'});
push(@args, [ "domain", $in{'dom'} ]);
if ($in{'desc'}) {
	push(@args, [ "desc", $in{'desc'} ]);
	}
$in{'pass'} =~ /\S/ || &error($text{'dcreate_epass'});
push(@args, [ "pass", $in{'pass'} ]);
@features = split(/\0/, $in{'feature'});
@features || &error($text{'dcreate_efeatures'});
push(@args, map { [ $_ ] } @features);
push(@args, [ "limits-from-template" ]);
if ($in{'virt_mode'} == 1) {
	push(@args, [ "allocate-ip" ]);
	}
elsif ($in{'virt_mode'} == 1) {
	&check_ipaddress($in{'virt'}) || &error($text{'dcreate_evirt'});
	push(@args, [ "ip", $in{'virt'} ]);
	}

# Check for a clash
foreach $s (@vservers) {
	@doms = &get_server_domains($s);
	($clash) = grep { $_->{'dom'} eq $in{'dom'} } @doms;
	$clash && &error(&text('dcreate_eclash', "<tt>$s->{'host'}</tt>"));
	}

# Find the target server
if ($in{'server'} == -1) {
	# Look for fewest domains
	foreach $s (@vservers) {
		@doms = &get_server_domains($s);
		if (scalar(@doms) < $min_domains || !$min_domains) {
			$min_domains = scalar(@doms);
			$server = $s;
			}
		}
	}
elsif ($in{'server'} == -2) {
	# Look for most free space
	foreach $s (@vservers) {
		$info = &get_server_collected($s);
		if ($info->{'disk_free'} > $max_free) {
			$max_free = $info->{'disk_free'};
			$server = $s;
			}
		}
	}
elsif ($in{'server'} == -3) {
	# Look for lowest CPU load
	foreach $s (@vservers) {
		$info = &get_server_collected($s);
		if ($info->{'load'}->[0] < $min_load || !$min_load) {
			$min_load = $info->{'load'}->[0];
			$server = $s;
			}
		}
	}
else {
	($server) = grep { $_->{'id'} eq $in{'server'} } @vservers;
	}
$server || &error($text{'dcreate_eserver'});

# Make sure the server has the selected features
$info = &get_server_collected($server);
@sfeatures = $info->{'features'} ? @{$info->{'features'}}
				 : @standard_virtualmin_features;
foreach $f (@features) {
	($sf) = grep { $_->{'feature'} eq $f } @sfeatures;
	$sf && $sf->{'enabled'} || &error(&text('dcreate_efeature', $f,
						"<tt>$server->{'host'}</tt>"));
	}

# Do it
&ui_print_unbuffered_header(undef, $text{'dcreate_title'}, "");

print &text('dcreate_doing', "<tt>$in{'dom'}</tt>",
	    "<tt>$server->{'host'}</tt>"),"<br>\n";
($err, $out) = &call_virtualmin_api($server, "create-domain", \@args);
if ($err) {
	print &text('dcreate_failed', &html_escape($err)),"<p>\n";
	}
else {
	print "<pre>",&html_escape($out),"</pre>\n";
	print $text{'dcreate_done'},"<p>\n";

	# Re-check and save the status
	print $text{'dcreate_statusing'},"<br>\n";
	&check_server_status($server);
	&save_managed_server($server);
	print $text{'dcreate_statusok'},"<p>\n";
	}

&ui_print_footer("list_domains.cgi", $text{'domains_return'},
		 "", $text{'index_return'});

