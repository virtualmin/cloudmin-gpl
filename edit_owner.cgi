#!/usr/local/bin/perl
# Show a form for creating or editing an owner

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
@plans = &list_plans();
if ($in{'new'}) {
	&ui_print_header(undef, $text{'owner_title1'}, "");
	if (&supports_plans()) {
		$owner = { 'acl' => { 'actions_def' => 1,
				      'plan' => $plans[0]->{'id'} } };
		}
	else {
		$owner = { 'acl' => { 'actions' =>
				join(' ', &list_safe_owner_actions()) } };
		}
	}
else {
	&ui_print_header(undef, $text{'owner_title2'}, "");
	$owner = &get_system_owner($in{'name'});
	}
@allservers = &list_managed_servers_sorted();

print &ui_form_start("save_owner.cgi", "post");
print &ui_hidden("new", $in{'new'});
print &ui_hidden("old", $in{'name'});
print &ui_hidden_table_start($text{'owner_header'}, "width=100%", 2, "main", 1,
			     [ 'width=30%' ]);

# Username
print &ui_table_row($text{'owner_name'},
	&ui_textbox("oname", $owner->{'name'}, 40));

# Password
print &ui_table_row($text{'owner_pass'},
	($in{'new'} ? "" : &ui_radio("opass_def", 1, 
			    [ [ 1, $text{'owner_leave'} ],
			      [ 0, $text{'owner_set'} ] ])).
	&ui_password("opass", undef, 20)."<br>\n".
	&ui_checkbox("lock", 1, $text{'owner_lock'}, $owner->{'pass'} =~ /^!/));

# Description
print &ui_table_row($text{'owner_real'},
	&ui_textbox("real", $owner->{'real'}, 60));

# Contact email
print &ui_table_row($text{'owner_email'},
	&ui_textbox("email", $owner->{'acl'}->{'email'}, 60));

# Managed servers
@sids = split(/\s+/, $owner->{'acl'}->{'servers'});
print &ui_table_row($text{'owner_servers'},
	&ui_select("servers", \@sids,
		   [ map { [ $_->{'id'}, ("&nbsp;&nbsp;" x $_->{'indent'}).
					 $_->{'short_host'} ] } @allservers ],
		   10, 1));

print &ui_hidden_table_end();

print &ui_hidden_table_start($text{'owner_header3'}, "width=100%", 2,
			     "limits", 0, [ 'width=30%' ]);

# Account plan, if any
if (&supports_plans()) {
	print &ui_table_row($text{'owner_plan'},
		&ui_select("plan", $owner->{'acl'}->{'plan'},
		   [ map { [ $_->{'id'}, &describe_plan($_) ] } @plans ]));
	}

# Allowed actions
%actions = map { $_, 1 } split(/\s+/, $owner->{'acl'}->{'actions'});
$afield = '';
if (&supports_plans()) {
	$dis1 = &js_disable_inputs([ "actions" ], [ ], "onClick");
	$dis0 = &js_disable_inputs([ ], [ "actions" ], "onClick");
	$afield .= &ui_radio("actions_def",
		     $owner->{'acl'}->{'actions_def'} ? 1 : 0,
		     [ [ 1, $text{'owner_actions_def1'}, $dis1 ],
		       [ 0, $text{'owner_actions_def0'}, $dis0 ] ])."<br>\n";
	}
$afield .= join("<br>\n",
	     map { &ui_checkbox("actions", $_, $text{'owner_action_'.$_},
				$actions{$_}, undef,
				$owner->{'acl'}->{'actions_def'}) }
		 &list_owner_actions());
print &ui_table_row($text{'owner_actions'}, $afield);

print &ui_hidden_table_end();

# Section for usage data, if we have it
if (defined(&get_server_usage) && !$in{'new'}) {
	print &ui_hidden_table_start($text{'owner_header2'}, "width=100%", 2,
				     "usage", 0, [ 'width=30%' ]);

	# Accounting period
	print &ui_table_row($text{'edit_uperiod'},
		$config{'bw_period'} ? $text{'bw_last_'.$config{'bw_period'}}
				     : &text('bw_days', $config{'bw_days'}));

	# Total uptime over usage period
	@allservers = &list_managed_servers();
	@allusage = ( );
	foreach $id (@sids) {
		my ($server) = grep { $_->{'id'} eq $id } @allservers;
		if ($server) {
			push(@allusage, &get_server_usage($server));
			}
		}
	@allusage = sort { $a->{'start'} cmp $b->{'start'} } @allusage;
	($start, $now) = &usage_period_start_end(\@usage);
	$up = &sum_usage_over_period(\@allusage, $start, $now, 'up');
	print &ui_table_row($text{'edit_uup'}, &nice_hour_mins_secs($up));
	
	# Memory over accounting period
	$mem = &sum_usage_over_period(\@allusage, $start, $now, 'mem');
	if ($mem) {
		$gbh = sprintf("%.2f", ($mem / (3600*1024*1024*1024)));
		$avgmem = &nice_size(int($mem / ($now - $start)));
		$upmem = &nice_size(int($mem / $up));
		print &ui_table_row($text{'edit_umem'},
				    &text('edit_ugbh', $gbh, $avgmem, $upmem));
		}

	# CPU allocation, in percent hours
	$cpu = &sum_usage_over_period(\@allusage, $start, $now, 'cpu');
	if ($cpu) {
		$cpuh = sprintf("%.2f", ($cpu / 3600));
		$avgcpu = int($cpu / ($now - $start));
		$upcpu = int($cpu / $up);
		print &ui_table_row($text{'edit_ucpu'},
			    &text('edit_ucpuh', $cpuh, $avgcpu, $upcpu));
		}

	# CPU load, in percent hours
	$load = &sum_usage_over_period(\@allusage, $start, $now, 'load');
	if ($load) {
		$cpuh = sprintf("%.2f", ($load / 3600));
		$avgcpu = int($load / ($now - $start));
		$upcpu = int($load / $up);
		print &ui_table_row($text{'edit_uload'},
			    &text('edit_ucpuh', $cpuh, $avgcpu, $upcpu));
		}

	print &ui_hidden_table_end();
	}

# Section for current usage and limits from plan
if (&supports_plans() && !$in{'new'}) {
	print &ui_hidden_table_start($text{'owner_header4'}, "width=100%", 2,
				     "planlimits", 0, [ 'width=30%' ]);
	$limits = &get_owner_limits($owner->{'name'});

	# Limit on systems and count
	print &ui_table_row($text{'owner_serverlimit'},
		&text('owner_outof',
		      $limits->{'servers'},
		      $limits->{'max_servers'} || $text{'owner_unlimit'}));

	# Limit on RAM and count
	print &ui_table_row($text{'owner_ramlimit'},
		&text('owner_outof',
		      &nice_size($limits->{'ram'}),
		      $limits->{'max_ram'} ? &nice_size($limits->{'max_ram'})
					   : $text{'owner_unlimit'}).' '.
		($limits->{'ram_unlimited'} ?
		  &text('owner_nolimit', $limits->{'ram_unlimited'}) : ''));

	# Limit on disk and count
	print &ui_table_row($text{'owner_disklimit'},
		&text('owner_outof',
		      &nice_size($limits->{'disk'}),
		      $limits->{'max_disk'} ? &nice_size($limits->{'max_disk'})
					   : $text{'owner_unlimit'}).' '.
		($limits->{'disk_unlimited'} ?
		  &text('owner_nolimit', $limits->{'disk_unlimited'}) : ''));

	# Limits on CPU
	print &ui_table_row($text{'owner_cpulimit'},
		&text('owner_outof',
		      $limits->{'cpu'}.'%',
		      $limits->{'max_cpu'} ? $limits->{'max_cpu'}.'%'
					   : $text{'owner_unlimit'}).' '.
		($limits->{'cpu_unlimited'} ?
		  &text('owner_nolimit', $limits->{'cpu_unlimited'}) : ''));

	# Limit on bandwidth and usage
	if ($limits->{'bw'}) {
		print &ui_table_row($text{'owner_bwlimit'},
			&text('owner_outof',
			      &nice_size($limits->{'bw'}),
			      $limits->{'max_bw'} ?
				&nice_size($limits->{'max_bw'}) :
				$text{'owner_unlimit'}).
			" ".&describe_bandwidth_period(1));
		}

	print &ui_hidden_table_end();
	}

print &ui_form_end(
    $in{'new'} ? [ [ undef, $text{'create'} ] ]
	       : [ [ undef, $text{'save'} ],
		   &supports_switch() ? ( [ 'switch', $text{'owner_switch'} ] )
				      : ( ),
		   $config{'bw_enabled'} ? ( [ 'bw', $text{'owner_bwgraph'} ] )
					 : ( ),
		   [ 'delete', $text{'delete'} ] ]); 

&ui_print_footer("list_owners.cgi", $text{'owners_return'});

