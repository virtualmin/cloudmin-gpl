#!/usr/local/bin/perl
# Show the status of some server, with a limited set of editable fields and
# sections showing domains and status

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
@servers = &list_managed_servers();
$status = $server->{'status'};
$info = &get_server_collected($server);
&can_action($server, "edit") || &can_action_error($server, "view");
$view = !&can_action($server, "edit");

# Heading and form start
@tds = ( "width=30%" );
$in{'basic'} = 1 if (!defined($in{'basic'}));
$in{'notes'} = 1 if (!defined($in{'notes'}) && $server->{'notes'});
if ($view) {
	&ui_print_header(&server_in($server), $text{'view_title'}, "");

	print &ui_form_start("save_view.cgi", "post");
	print &ui_hidden_table_start($text{'edit_bheader'}, "width=100%", 2,
				     "basic", $in{'basic'}, \@tds);
	}
else {
	&ui_print_header(&server_in($server), $text{'edit_title'}, "", "edit");

	print &ui_form_start("save_serv.cgi", "post");
	print &ui_hidden_table_start($text{'edit_bheader'}, "width=100%", 2,
				     "basic", $in{'basic'}, \@tds);
	}
print &ui_hidden("id", $in{'id'});

# Hostname (editable for anything except this host)
if ($server->{'id'} != 0 && !$view) {
	print &ui_table_row($text{'edit_host'},
			    &ui_textbox("host", $server->{'host'}, 50));
	}
else {
	print &ui_table_row($text{'edit_host'}, "<tt>$server->{'host'}</tt>");
	}

# Unix hostname
if ($server->{'unix_hostname'} &&
    $server->{'unix_hostname'} ne $server->{'host'}) {
	print &ui_table_row($text{'edit_unixhost'},
			    "<tt>$server->{'unix_hostname'}</tt>");
	}

# IP address used by Cloudmin
if ($server->{'ip_force'} || !&check_ipaddress($server->{'host'})) {
	$ip = &get_server_ip($server);
	if ($view) {
		print &ui_table_row($text{'edit_ipaddr'}, "<tt>$ip</tt>");
		}
	else {
		print &ui_table_row($text{'edit_ipaddr'},
		    &ui_opt_textbox("ip", $server->{'ip_force'}, 20,
			$text{'edit_ipaddrauto'}.
			($server->{'ip_force'} ? "" : " (<tt>$ip</tt>)"),
			$text{'edit_ipaddrset'}));
		}
	}

# IPv6 address
$ip6 = &get_server_ip6($server);
if ($ip6) {
	print &ui_table_row($text{'edit_ipaddr6'}, "<tt>$ip6</tt>");
	}

# System type
$t = $server->{'manager'};
$tfunc = "type_".$t."_desc";
print &ui_table_row($text{'edit_type'}, &$tfunc());

if ($server->{'id'} != 0) {
	# Description (always editable)
	print &ui_table_row($text{'edit_desc'},
		&ui_textbox("desc", $server->{'desc'}, 50), 3);
	}

# Kernel info
$k = $info->{'kernel'};
if ($k->{'version'}) {
	$kfield = " ".&text('edit_kernelon', $k->{'os'},
		            $k->{'version'}, $k->{'arch'});
	}

# OS type
if ($view) {
	($os) = grep { $_->[0] eq $server->{'type'} }
		     @servers::server_types;
	print &ui_table_row($text{'edit_type2'}, $os->[1]." : ".$kfield);
	}
else {
	if ($server->{'type'} eq 'unknown' || !$server->{'type'}) {
		$guessbutton = " ".&ui_button($text{'edit_guesstype'}, undef, 0,
                                "onClick='document.location=\"guesstype.cgi?id=$server->{'id'}\"'");
		}
	print &ui_table_row($text{'edit_type2'},
		    &ui_select("type", $server->{'type'} || 'unknown',
		      [ map { [ $_->[0], $_->[1] ] }
			sort { $a->[1] cmp $b->[1] } @servers::server_types ]).
		    $guessbutton.$kfield);
	}

# Original image
if ($server->{'image'}) {
	$imgid = $server->{'image'};
	$img = &get_server_image($imgid);
	if ($img) {
		$imgid .= " ($img->{'desc'})";
		if (&can_action(undef, "global")) {
			$imgid ="<a href='edit_image.cgi?id=$img->{'id'}'>".
				"$imgid</a>";
			}
		}
	print &ui_table_row($text{'edit_imagefrom'}, $imgid);
	}

# Host system
$vhost = &get_parent_server($server);
if ($vhost) {
	print &ui_table_row($text{'edit_parent'},
	  &can_action($vhost, "view") ?
	    "<a href='edit_serv.cgi?id=$vhost->{'id'}'>$vhost->{'host'}</a>" :
            $vhost->{'host'});
	}

if (!$view) {
	# Groups
	if (&can_action($server, "groups")) {
		print &ui_table_row($text{'edit_groups'},
			&show_groups_form($server, \@servers));
		}

	# Start at boot
	$bfunc = "type_".$t."_get_atboot";
	if (defined(&$bfunc)) {
		print &ui_table_row($text{'edit_atboot'},
			    &ui_yesno_radio("atboot",&$bfunc($server) ? 1 : 0));
		}
	}

@allowners = &list_system_owners();
if (!$view && !$access{'owner'} && @allowners) {
	# System owner(s)
	my @owners = &get_server_owners($server);
	if (@owners > 1) {
		print &ui_table_row($text{'edit_owners'},
			join(" ", map { "<tt>$_->{'name'}</tt>" } @owners));
		}
	else {
		print &ui_table_row($text{'edit_owner'},
			&ui_select("owner",
				   @owners ? $owners[0]->{'name'} : undef,
				   [ [ undef, $text{'edit_noowner'} ],
				     map { $_->{'name'} } @allowners ]));
		}
	}

# Last status
print &ui_table_row($text{'edit_status'},
		    &text('edit_statustime', &describe_status($server, 1, 0),
				     &make_date($server->{'statustime'})));
if ($server->{'status_msg'}) {
	my $clearkey;
	if ($server->{'status_hostkey'}) {
		$clearkey = " ".&ui_button($text{'edit_hostkey'}, undef, 0,
				"onClick='document.location=\"hostkey.cgi?id=$server->{'id'}\"'");
		}
	print &ui_table_row($text{'edit_statusmsg'},
			    $server->{'status_msg'}.$clearkey);
	}

# Read-only bandwidth limit
$rfunc = "type_".$t."_real_interfaces";
if ($view && defined(&$rfunc) && $config{'bw_enabled'}) {
	# Limit
	print &ui_table_row($text{'edit_lbw'},
		$server->{'bw_limit'} ? &nice_size($server->{'bw_limit'})." ".
					&describe_bandwidth_period(0)
				      : $text{'bw_unlimited'});

	# Usage over this period
	print &ui_table_row($text{'edit_lusage'},
		&bandwidth_usage_message($server));
	}

print &ui_hidden_table_end("basic");

if ($status eq 'virt' || $status eq 'novirt') {
	print &ui_hidden_table_start($text{'edit_wheader'}, "width=100%", 2,
				     "webmin", $in{'webmin'}, \@tds);

	# Virtualmin config error
	if ($status eq 'virt' && $server->{'virtualmin_error'}) {
		print &ui_table_row($text{'edit_configerr'},
	          "<font color=#ff0000>$server->{'virtualmin_error'}</font>");
		}

	# Webmin version
	print &ui_table_row($text{'edit_webmin'},
			    $info->{'general'}->{'version'});

	# OS according to Webmin
	if ($info->{'general'}->{'real_os_type'}) {
		print &ui_table_row($text{'edit_webminos'},
			$info->{'general'}->{'real_os_type'}." ".
			$info->{'general'}->{'real_os_version'});
		}

	if ($status eq 'virt') {
		# Virtualmin version
		print &ui_table_row($text{'edit_vversion'},
		    $info->{'minfo'}->{'version'}.' ('.
		    ($info->{'minfo'}->{'virtualmin'} eq 'gpl' ?
		     'GPL' : 'Pro').')');

		if (!$view) {
			# Enabled for Virtualmin domain creation
			print &ui_table_row($text{'add_canvirt'},
			    &ui_yesno_radio("canvirt",
					    $server->{'novirt'} ? 0 : 1));
			}

		# Virtualmin licence
		if ($info->{'serial'}) {
			$exp = $info->{'serial'}->{'expiry'};
			$expired = &check_licence_expiry($exp);
			if ($expired == 2) {
				$exp = "<font color=red>$exp</font>";
				}
			elsif ($expired == 1) {
				$exp = "<font color=orange>$exp</font>";
				}
			print &ui_table_row($text{'edit_vlicence'},
			    &text('edit_vsk',
				  "<tt>$info->{'serial'}->{'serial'}</tt>",
				  "<tt>$info->{'serial'}->{'key'}</tt>", $exp));
			}
		}

	print &ui_hidden_table_end("webmin");
	}

# Resource usage, if supported
if (defined(&get_server_usage)) {
	print &ui_hidden_table_start($text{'edit_uheader'},
		     "width=100%", 2, "usage", defined($in{'ago'}), \@tds);

	# System owner
	if (defined(&get_server_owners)) {
		foreach $o (&get_server_owners($server)) {
			print &ui_table_row($text{'edit_owner'},
			    &can_action(undef, 'global') ?
				"<a href='edit_owner.cgi?name=".
				  &urlize($o->{'name'})."'>".
				  &html_escape($o->{'name'})."</a>" :
				&html_escape($o->{'name'}));
			}
		}

	# Created on
	print &ui_table_row($text{'edit_created'},
		&make_date($server->{'created'}));
	print &ui_table_row($text{'edit_age'},
		&nice_hour_mins_secs(time() - $server->{'created'}));

	# Accounting period
	print &ui_table_row($text{'edit_uperiod'},
		&usage_period_selector("ago", $in{'ago'},
			"edit_serv.cgi?id=$in{'id'}"));

	# Get usage and current period
	@usage = &get_server_usage($server);
	($start, $end) = &usage_period_start_end(\@usage, $in{'ago'});

	# Uptime and percentage
	$up = &sum_usage_over_period(\@usage, $start, $end, 'up');
	$pc = $up ? int($up * 100 / ($end - $start)) : 0;
	print &ui_table_row($text{'edit_uup'},
			    &text('edit_ulen', &nice_hour_mins_secs($up), $pc));

	# Memory usage, in GB hours and average
	$mem = &sum_usage_over_period(\@usage, $start, $end, 'mem');
	if ($mem) {
		$gbh = sprintf("%.2f", ($mem / (3600*1024*1024*1024)));
		$avgmem = &nice_size(int($mem / ($end - $start)));
		$upmem = &nice_size(int($mem / $up));
		print &ui_table_row($text{'edit_umem'},
				    &text('edit_ugbh', $gbh, $avgmem, $upmem));
		}

	# CPU allocation, in percent hours
	$cpu = &sum_usage_over_period(\@usage, $start, $end, 'cpu');
	if ($cpu) {
		$cpuh = sprintf("%.2f", ($cpu / 3600));
		$avgcpu = int($cpu / ($end - $start));
		$upcpu = int($cpu / $up);
		print &ui_table_row($text{'edit_ucpu'},
			    &text('edit_ucpuh', $cpuh, $avgcpu, $upcpu));
		}

	# CPU load, in percent hours
	$load = &sum_usage_over_period(\@usage, $start, $end, 'load');
	if ($load) {
		$cpuh = sprintf("%.2f", ($load / 3600));
		$avgcpu = int($load / ($end - $start));
		$upcpu = int($load / $up);
		print &ui_table_row($text{'edit_uload'},
			    &text('edit_ucpuh', $cpuh, $avgcpu, $upcpu));
		}

	# Disk assigned and used over period
	$disk = &sum_usage_over_period(\@usage, $start, $end, 'disk');
	$space = &sum_usage_over_period(\@usage, $start, $end, 'space');
	if ($disk && $disk != $space) {
		$gbh = sprintf("%.2f", ($disk / (3600*1024*1024*1024)));
		$avgdisk = &nice_size(int($disk / ($end - $start)));
		print &ui_table_row($text{'edit_udisk'},
				    &text('edit_ugbh2', $gbh, $avgdisk));
		}
	if ($space) {
		$gbh = sprintf("%.2f", ($space / (3600*1024*1024*1024)));
		$avgspace = &nice_size(int($space / ($end - $start)));
		print &ui_table_row($text{'edit_uspace'},
				    &text('edit_ugbh2', $gbh, $avgspace));
		}

	print &ui_hidden_table_end("usage");
	}

# Type-specific extra information, if any
$efunc = "type_".$t."_edit_form";
if (defined(&$efunc)) {
	print &ui_hidden_table_start(&text('edit_eheader', &$tfunc()),
				     "width=100%", 2,
				     "extra", $in{'extra'}, \@tds);
	print &$efunc($server, $view);
	print &ui_hidden_table_end("extra");
	}

# Show status form, if any info
if (keys %$info) {
	@down = grep { !$_->{'status'} } @{$info->{'startstop'}};
	print &ui_hidden_table_start($text{'edit_cheader'}, "width=100%", 2,
				     "status", @down ? 1 : 0, \@tds);

	# CPU load and running processes
	if ($info->{'load'}) {
		@l = @{$info->{'load'}};
		print &ui_table_row($text{'edit_iload'},
			&text($info->{'procs'} ? 'edit_iloadlevel'
					       : 'edit_iloadlevel2',
			      @l[0..2], $info->{'procs'}));
		}

	# Memory used
	if ($info->{'mem'}) {
		@m = @{$info->{'mem'}};
		if ($m[0]) {
			# Real memory
			print &ui_table_row($text{'edit_imem'},
				&bar_chart($m[0], $m[0]-$m[1], 1)." ".
				&text('edit_outof',
				      &nice_size($m[0]*1024),
				      &nice_size(($m[0]-$m[1])*1024)));
			}
		if ($m[2]) {
			# Swap space
			print &ui_table_row($text{'edit_iswap'},
				&bar_chart($m[2], $m[2]-$m[3], 1)." ".
				&text('edit_outof',
				      &nice_size($m[2]*1024),
				      &nice_size(($m[2]-$m[3])*1024)));
			}
		}

	# Disk used
	if ($info->{'disk_total'}) {
		print &ui_table_row($text{'edit_idisk'},
			&bar_chart($info->{'disk_total'},
			   $info->{'disk_total'}-$info->{'disk_free'}, 1)." ".
			&text('edit_outof',
			      &nice_size($info->{'disk_total'}),
			      &nice_size($info->{'disk_total'}-
					 $info->{'disk_free'})));
		}

	# Host memory and disk used
	foreach my $manager (&is_parent_server($server)) {
		# Memory used
		my ($memfree, $memtotal) = &host_free_memory(
						$server, $manager, 0);
		if ($memfree && $memfree != $m[1]*1024) {
			print &ui_table_hr();
			print &ui_table_row(
				&text('edit_hmem', $text{$manager.'_typedesc'}),
				&bar_chart($memtotal, $memtotal-$memfree, 1).
				" ".
				&text('edit_outof',
				      &nice_size($memtotal),
				      &nice_size($memtotal-$memfree)));
			}

		# Guaranteed memory used
		my ($gmemfree, $gmemtotal) = &host_free_memory(
						$server, $manager, 1);
		if ($gmemfree && $gmemfree != $memfree) {
			print &ui_table_row(
				&text('edit_hgmem',$text{$manager.'_typedesc'}),
				&bar_chart($gmemtotal, $gmemtotal-$gmemfree, 1).
				" ".
				&text('edit_outof',
				      &nice_size($gmemtotal),
				      &nice_size($gmemtotal-$gmemfree)));
			}

		# Disk used
		my ($diskfree, $disktotal) = &host_free_disk($server, $manager);
		if ($diskfree && $diskfree != $info->{'disk_free'}) {
			print &ui_table_row(
				&text('edit_hdisk',$text{$manager.'_typedesc'}),
				&bar_chart($disktotal,
					   $disktotal-$diskfree, 1)." ".
				&text('edit_outof',
				      &nice_size($disktotal),
				      &nice_size($disktotal - $diskfree)));
			}
		}

	# Feature statuses
	if ($info->{'startstop'} && @{$info->{'startstop'}} &&
	    &can_ssh_status($server)) {
		@grid = ( );
		foreach $ss (@{$info->{'startstop'}}) {
			push(@grid, $ss->{'name'});
			push(@grid, ($ss->{'status'} ?
			    "<font color=#00aa00>$text{'edit_iup'}</font>" :
			    "<font color=#ff0000>$text{'edit_idown'}</font>"));
			}
		print &ui_table_row($text{'edit_istatus'},
				    &ui_grid_table(\@grid, 4, 75));
		}

	print &ui_hidden_table_end();
	}

# Show status history, if any
@history = &list_status_history($server);
if (@history > 1) {
	print &ui_hidden_table_start($text{'edit_hheader'},
				     "width=100%", 2,
				     "history", $in{'history'}, \@tds);
	@history = reverse(@history);

	$htable = &ui_columns_start([ $text{'edit_htime'},
				      $text{'edit_hold'},
				      $text{'edit_hnew'},
				      $text{'edit_hby'} ], 100);
	$hcount = 0;
	foreach $h (@history) {
		$htable .= &ui_columns_row([
			&make_date($h->{'time'}),
			&describe_status({ 'status' => $h->{'old'} }, 1),
			&describe_status({ 'status' => $h->{'new'} }, 1),
			$text{'status_by_'.$h->{'by'}}.
			  ($h->{'user'} ? " (<tt>$h->{'user'}</tt>)" : ""),
			]);
		last if ($hcount++ > 100);
		}
	$htable .= &ui_columns_end();
	if ($hcount != scalar(@history)) {
		$htable .= &text('edit_hcutoff', scalar(@history),100)."<br>\n";
		}
	print &ui_table_row(undef, $htable, 2);

	print &ui_hidden_table_end();
	}

# Section for notes
if (!$view) {
	print &ui_hidden_table_start($text{'edit_nheader'},
			     "width=100%", 2, "notes", $in{'notes'}, \@tds);
	print &ui_table_row(undef,
	    &ui_textarea("notes", join("\n", split(/\t/, $server->{'notes'})),
			 10, 80, undef, 0, "style='width:100%'"), 2);
	print &ui_hidden_table_end("notes");
	}

# Action buttons at end of form (depends on status)
$down = $status eq 'down' || $status eq 'nossh' || $status eq 'nohost';
if ($view) {
	# Just save button
	print &ui_form_end([ [ "save", $text{'save'} ] ]);
	}
elsif ($main::cloudmin_no_edit_buttons) {
	# Theme provides it's own action links
	print &ui_form_end([ [ "save", $text{'save'} ] ]);
	}
else {
	# Show our own buttons
	my @buts = ( [ "save", $text{'save'} ] );
	foreach my $b (&get_server_actions($server)) {
		if (!$b) {
			push(@buts, undef);
			}
		elsif ($b->{'link'}) {
			# Opens a separate URL
			my $js = $b->{'target'} ?
				"window.open(\"$b->{'link'}\")" :
				"document.location = \"$b->{'link'}\"";
			push(@buts, [ $b->{'id'}, $b->{'desc'}, undef, undef,
			    "onClick='$js; return false'" ] );
			}
		else {
			push(@buts, [ $b->{'id'}, $b->{'desc'} ]);
			}
		}
	print &ui_form_end(\@buts);
	}

&ui_print_footer("", $text{'index_return'});

if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}
if ($in{'refresh'} && defined(&theme_post_save_server)) {
	&theme_post_save_server($server);
	}

# bar_chart(total, used, blue-rest)
# Returns HTML for a bar chart of a single value
sub bar_chart
{
my ($total, $used, $blue) = @_;
$used = $total-1 if ($used > $total);
return undef if (!int($total));
my $bar_width = 100;
my $rv = "<div class='barchart'>";
$rv .= sprintf "<img src=images/red.gif width=%s%% height=12>",
	  int($bar_width*$used/$total)+1;
if ($blue) {
  $rv .= sprintf "<img src=images/blue.gif width=%s%% height=12></div>",
	    $bar_width - int($bar_width*$used/$total)-1;
  }
else {
  $rv .= sprintf "<img src=images/white.gif width=%s%% height=12></div>",
	    $bar_width - int($bar_width*$used/$total)-1;
  }
return $rv;
}

