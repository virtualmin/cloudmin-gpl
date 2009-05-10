#!/usr/local/bin/perl
# Show a form for creating or editing an owner

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
if ($in{'new'}) {
	&ui_print_header(undef, $text{'owner_title1'}, "");
	$owner = { 'acl' => { 'actions' => join(' ', &list_owner_actions()) } };
	}
else {
	&ui_print_header(undef, $text{'owner_title2'}, "");
	$owner = &get_system_owner($in{'name'});
	}
@allservers = &list_managed_servers_sorted();

print &ui_form_start("save_owner.cgi", "post");
print &ui_hidden("new", $in{'new'});
print &ui_hidden("old", $in{'name'});
print &ui_hidden_table_start($text{'owner_header'}, "width=100%", 2, "main", 1);

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
# XXX left / right chooser
@sids = split(/\s+/, $owner->{'acl'}->{'servers'});
print &ui_table_row($text{'owner_servers'},
	&ui_select("servers", \@sids,
		   [ map { [ $_->{'id'}, ("&nbsp;&nbsp;" x $_->{'indent'}).
					 $_->{'short_host'} ] } @allservers ],
		   10, 1));

# Allowed actions
%actions = map { $_, 1 } split(/\s+/, $owner->{'acl'}->{'actions'});
print &ui_table_row($text{'owner_actions'},
	join("<br>\n",
	     map { &ui_checkbox("actions", $_, $text{'owner_action_'.$_},
				$actions{$_}) } &list_owner_actions()));

print &ui_hidden_table_end();

# Section for usage data, if we have it
if (defined(&get_server_usage)) {
	print &ui_hidden_table_start($text{'owner_header2'}, "width=100%", 2,
				     "usage", 1);

	# Accounting period
	print &ui_table_row($text{'edit_uperiod'},
		$config{'bw_period'} ? $text{'bw_last_'.$config{'bw_period'}}
				     : &text('bw_days', $config{'bw_days'}));

	# Total uptime over usage period
	$start = &bandwidth_period_start();
	$now = time();
	@allservers = &list_managed_servers();
	@allusage = ( );
	foreach $id (@sids) {
		my ($server) = grep { $_->{'id'} eq $id } @allservers;
		if ($server) {
			my @usage = &get_server_usage($server);
			if (@usage && $start < $usage[0]->{'start'}) {
				$start = $usage[0]->{'start'};
				}
			push(@allusage, @usage);
			}
		}
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

print &ui_form_end(
    $in{'new'} ? [ [ undef, $text{'create'} ] ]
	       : [ [ undef, $text{'save'} ], [ 'delete', $text{'delete'} ] ]); 

&ui_print_footer("list_owners.cgi", $text{'owners_return'});

