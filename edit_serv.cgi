#!/usr/local/bin/perl
# Show the status of some server, with a limited set of editable fields and
# sections showing domains and status

require './server-manager-lib.pl';
&ReadParse();
@servers = &list_managed_servers();
($server) = grep { $_->{'id'} == $in{'id'} } @servers;
$server || &error($text{'edit_egone'});
$status = $server->{'status'};
$info = &get_server_collected($server);
&can_action($server, "edit") || &can_action_error($server, "view");
$view = !&can_action($server, "edit");

# Heading and form start
@tds = ( "width=30%" );
$in{'basic'} = 1 if (!defined($in{'basic'}));
if ($view) {
	&ui_print_header(&server_in($server), $text{'view_title'}, "");

	print &ui_hidden_table_start($text{'edit_bheader'}, "width=100%", 2,
				     "basic", $in{'basic'}, \@tds);
	}
else {
	&ui_print_header(&server_in($server), $text{'edit_title'}, "", "edit");

	print &ui_form_start("save_serv.cgi", "post");
	print &ui_hidden("id", $in{'id'});
	print &ui_hidden_table_start($text{'edit_bheader'}, "width=100%", 2,
				     "basic", $in{'basic'}, \@tds);
	}

# Hostname (editable for anything except this host)
if ($server->{'id'} != 0 && !$view) {
	print &ui_table_row($text{'edit_host'},
			    &ui_textbox("host", $server->{'host'}, 50));
	}
else {
	print &ui_table_row($text{'edit_host'}, "<tt>$server->{'host'}</tt>");
	}

# System type
$t = $server->{'manager'};
$tfunc = "type_".$t."_desc";
print &ui_table_row($text{'edit_type'}, &$tfunc());

if ($server->{'id'} != 0) {
	# Description (maybe editable)
	print &ui_table_row($text{'edit_desc'},
		$view ? $server->{'desc'}
		      : &ui_textbox("desc", $server->{'desc'}, 50), 3);
	}

# OS type
if ($view) {
	($os) = grep { $_->[0] eq $server->{'type'} }
		     @servers::server_types;
	print &ui_table_row($text{'edit_type2'}, $os->[1]);
	}
else {
	print &ui_table_row($text{'edit_type2'},
		    &ui_select("type", $server->{'type'} || 'unknown',
		      [ map { [ $_->[0], $_->[1] ] }
			sort { $a->[1] cmp $b->[1] } @servers::server_types ]));
	}

# Kernel info
$k = $info->{'kernel'};
if ($k->{'version'}) {
	print &ui_table_row($text{'edit_kernel'},
		&text('edit_kernelon', $k->{'os'},
		       $k->{'version'}, $k->{'arch'}));
	}

if (!$view) {
	# Groups
	@groups = &unique(map { split(/\t/, $_->{'group'}) } @servers);
	%ingroups = map { $_, 1 } split(/\t/, $server->{'group'});
	@grid = ( );
	foreach $g (@groups) {
		push(@grid, &ui_checkbox("group", $g, $g, $ingroups{$g}));
		}
	push(@grid, (@grid ? "&nbsp;&nbsp;&nbsp;" : "").
		    &text('edit_newgroup', &ui_textbox("newgroup", undef, 10)));
	$gtable = &ui_grid_table(\@grid, 4);
	print &ui_table_row($text{'edit_groups'}, $gtable);

	# Start at boot
	$bfunc = "type_".$t."_get_atboot";
	if (defined(&$bfunc)) {
		print &ui_table_row($text{'edit_atboot'},
			    &ui_yesno_radio("atboot",&$bfunc($server) ? 1 : 0));
		}
	}

# Last status
print &ui_table_row($text{'edit_status'},
		    &text('edit_statustime', &describe_status($server, 1, 0),
				     &make_date($server->{'statustime'})));
if ($server->{'status_msg'}) {
	print &ui_table_row($text{'edit_statusmsg'},
			    $server->{'status_msg'});
	}

# Virtualmin config error
if ($status eq 'virt' && $server->{'virtualmin_error'}) {
	print &ui_table_row($text{'edit_configerr'},
	      "<font color=#ff0000>$server->{'virtualmin_error'}</font>");
	}

# Webmin version
if ($status eq 'virt' || $status eq 'novirt') {
	print &ui_table_row($text{'edit_webmin'},
			    $info->{'general'}->{'version'});
	}

if ($status eq 'virt') {
	# Virtualmin version
	print &ui_table_row($text{'edit_vversion'},
	    $info->{'minfo'}->{'version'}.' ('.
	    ($info->{'minfo'}->{'virtualmin'} eq 'gpl' ? 'GPL' : 'Pro').')');

	if (!$view) {
		# Enabled for Virtualmin domain creation
		print &ui_table_row($text{'add_canvirt'},
		    &ui_yesno_radio("canvirt", $server->{'novirt'} ? 0 : 1));
		}

	# Virtualmin licence
	if ($info->{'serial'}) {
		print &ui_table_row($text{'edit_vlicence'},
		    &text('edit_vsk', "<tt>$info->{'serial'}->{'serial'}</tt>",
				      "<tt>$info->{'serial'}->{'key'}</tt>"));
		}
	}

# Cluster package management
$pkgs = &get_server_cluster_software($server);
if ($pkgs >= 0) {
	print &ui_table_row($text{'edit_managepackages'},
		$view ? ($pkgs ? $text{'yes'} : $text{'no'})
		      : &ui_yesno_radio("packages", $pkgs));
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

# Resource usage, if supported
if (defined(&get_server_usage)) {
	print &ui_hidden_table_start($text{'edit_uheader'},
				     "width=100%", 2, "usage", 0, \@tds);

	# Accounting period
	print &ui_table_row($text{'edit_uperiod'},
		$config{'bw_period'} ? $text{'bw_last_'.$config{'bw_period'}}
				     : &text('bw_days', $config{'bw_days'}));

	# Get usage and current period
	$start = &bandwidth_period_start();
	$now = time();
	@usage = &get_server_usage($server);
	if (@usage && $start < $usage[0]->{'start'}) {
		# Cannot be older than first sample
		$start = $usage[0]->{'start'};
		}

	# Uptime and percentage
	$up = &sum_usage_over_period(\@usage, $start, $now, 'up');
	$pc = $up ? int($up * 100 / ($now - $start)) : 0;
	print &ui_table_row($text{'edit_uup'},
			    &text('edit_ulen', &nice_hour_mins_secs($up), $pc));

	# Memory usage, in GB hours and average
	$mem = &sum_usage_over_period(\@usage, $start, $now, 'mem');
	if ($mem) {
		$gbh = sprintf("%.2f", ($mem / (3600*1024*1024*1024)));
		$avgmem = &nice_size(int($mem / ($now - $start)));
		$upmem = &nice_size(int($mem / $up));
		print &ui_table_row($text{'edit_umem'},
				    &text('edit_ugbh', $gbh, $avgmem, $upmem));
		}

	# CPU cores, in core hours
	# XXX not implemented yet

	# CPU allocation, in percent hours
	$cpu = &sum_usage_over_period(\@usage, $start, $now, 'cpu');
	if ($cpu) {
		$cpuh = sprintf("%.2f", ($cpu / 3600));
		$avgcpu = int($cpu / ($now - $start));
		$upcpu = int($cpu / $up);
		print &ui_table_row($text{'edit_ucpu'},
			    &text('edit_ucpuh', $cpuh, $avgcpu, $upcpu));
		}

	# CPU load, in percent hours
	$load = &sum_usage_over_period(\@usage, $start, $now, 'load');
	if ($load) {
		$cpuh = sprintf("%.2f", ($load / 3600));
		$avgcpu = int($load / ($now - $start));
		$upcpu = int($load / $up);
		print &ui_table_row($text{'edit_uload'},
			    &text('edit_ucpuh', $cpuh, $avgcpu, $upcpu));
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

	# Feature statuses
	if ($info->{'startstop'} && @{$info->{'startstop'}}) {
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

# Show authentication form (if needed)
if ($view) {
	# Cannot edit authentication options in view mode
	$haswebmin = $hasssh = 0;
	}
else {
	$haswebmin = ($status eq 'nowebminlogin' || $status eq 'novirt' ||
		      $status eq 'downwebmin' || $status eq 'virt') &&
		     $server->{'id'} != 0;
	$sfunc = "type_".$t."_no_ssh";
	$hasssh = !defined(&$sfunc) || !&$sfunc();
	}
if ($haswebmin || $hasssh) {
	print &ui_hidden_table_start($text{'edit_aheader'},
				     "width=100%", 2,
				     "auth", $in{'auth'}, \@tds,
				     &hlink($text{'edit_help'}, "editauth"));
	}

# SSH login details
if ($hasssh) {
	&show_ssh_login_form($server);
	print &ui_table_hr() if ($haswebmin);
	}

# Webmin login details
if ($haswebmin) {
	&show_webmin_login_form($server);
	}

if ($haswebmin || $hasssh) {
	print &ui_hidden_table_end("auth");
	}

# Action buttons at end of form (depends on status)
$down = $status eq 'down' || $status eq 'nossh' || $status eq 'nohost';
if ($view) {
	# No form, so no buttons
	}
elsif ($main::cloudmin_no_edit_buttons) {
	# Theme provides it's own action links
	print &ui_form_end([ [ "save", $text{'save'} ] ]);
	}
else {
	# Show our own buttons
	local @buts = ( [ "save", $text{'save'} ] );
	foreach my $b (&get_server_actions($server)) {
		if (!$b) {
			push(@buts, undef);
			}
		elsif ($b->{'link'}) {
			# Opens a separate URL
			local $js = $b->{'target'} ?
				"window.open(\"$b->[3]\")" :
				"document.location = \"$b->[3]\"";
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

# bar_chart(total, used, blue-rest)
# Returns HTML for a bar chart of a single value
sub bar_chart
{
local ($total, $used, $blue) = @_;
local $bar_width = 100;
local $rv = "<div class='barchart'>";
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

