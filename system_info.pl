# Provide more system info blocks specific to Cloudmin

require 'server-manager-lib.pl';
use Time::Local;

sub list_system_info
{
my ($data, $in) = @_;

# If user doesn't have access to Cloudmin, none of this makes sense
if (!&foreign_available($module_name)) {
	return ( );
	}

my @rv;

# Get own system info
my @servers = &list_available_managed_servers_sorted();
my $me = &get_managed_server(0);
my $meinfo;
if ($me) {
	$meinfo = &get_server_collected($me);
	}
my (@poss, @allposs, @inst);
if ($meinfo && $meinfo->{'poss'}) {
	# Use own collected info
	@poss = @{$meinfo->{'poss'}};
	@allposs = @{$meinfo->{'allposs'}};
	@inst = @{$meinfo->{'inst'}};
	}
elsif ($hasposs) {
	# Get possible updates directly from security-updates module
	&foreign_require("security-updates");
	@poss = &list_possible_updates();
	@inst = &list_possible_installs();
	}

# Custom URL redirect
if ($data->{'alt'} && !$in{'noalt'}) {
	push(@rv, { 'type' => 'redirect',
		    'url' => $data->{'alt'} });
	}

# Warning messages
foreach my $warn (&list_warning_messages()) {
	push(@rv, { 'type' => 'warning',
		    'level' => 'warn',
		    'warning' => $warn });
	}

# Documentation links
my $doclink = "http://www.virtualmin.com/documentation/cloudmin";
push(@rv, { 'type' => 'link',
	    'priority' => 50,
	    'desc' => $text{'right_vm2docs'},
	    'target' => 'new',
	    'link' => $doclink });
if ($config{'docs_link'}) {
	push(@rv, { 'type' => 'link',
		    'priority' => 49,
		    'desc' => $text{'right_virtdocs2'},
		    'target' => 'new',
		    'link' => $config{'docs_link'} });
	}

# Virtualmin package updates
my $hasposs = foreign_check("security-updates");
my $canposs = foreign_available("security-updates");
if (!$data->{'noupdates'} && $hasposs && $canposs && @poss) {
	my $html = &ui_form_start("/security-updates/update.cgi");
	$html .= &text(@poss > 1 ? 'right_upcount' : 'right_upcount1',
		       scalar(@poss),
		       '/security-updates/index.cgi?mode=updates')."<p>\n";
	$html .= &ui_columns_start([ $text{'right_upname'},
                                     $text{'right_updesc'},
                                     $text{'right_upver'} ], "80%");
	foreach my $p (@poss) {
		$html .= &ui_columns_row([
			$p->{'name'}, $p->{'desc'}, $p->{'version'} ]);
		$html .= &ui_hidden("u", $p->{'update'}."/".$p->{'system'});
		}
	$html .= &ui_columns_end();
	$html .= &ui_form_end([ [ undef, $text{'right_upok'} ] ]);
	push(@rv, { 'type' => 'html',
		    'id' => 'updates',
		    'desc' => $text{'right_updatesheader'},
		    'html' => $html });
	}

# Show a system owner info about his VMs, but not about the system
if ($access{'owner'}) {
	my @table;

	# General info about the account
        push(@table, { 'desc' => $text{'right_login'},
                       'value' => $remote_user });
        push(@table, { 'desc' => $text{'right_from'},
                       'value' => $ENV{'REMOTE_HOST'} });
        push(@table, { 'desc' => $text{'right_vm2'},
                       'value' => $module_info{'version'} });
	push(@table, { 'desc' => $text{'right_vm2real'},
		       'value' => $access{'real'} });
	push(@table, { 'desc' => $text{'right_vm2email'},
		       'value' => $access{'email'} });

	# Show primary system, if there is just one
	if (@servers == 1) {
		my $s = $servers[0];
		if (&can_action($s, "view")) {
			push(@table, { 'desc' => $text{'right_vm2one'},
				       'value' => &ui_link(
					  '/'.$module_name.'/edit_serv.cgi?id='.
					  $s->{'id'}, $s->{'host'}) });
			}
		else {
			push(@table, { 'desc' => $text{'right_vm2one'},
				       'value' => $s->{'host'} });
			}
		}

	push(@rv, { 'type' => 'table',
		    'id' => 'owner',
		    'priority' => 50,
		    'open' => 1,
		    'desc' => $text{'right_ownerheader'},
		    'table' => \@table });
        push(@rv, { 'type' => 'veto',
                    'veto' => 'sysinfo' });
	}

# Show system limits and counts
if ($access{'owner'} && &supports_plans()) {
	my $limits = &get_owner_limits();
	my $plan = &get_owner_plan();
	if ($limits) {
		my @table;
		if ($plan) {
			push(@table, { 'desc' => $text{'right_vm2plan'},
				       'value' => $plan->{'desc'},
				       'wide' => 1 });
			}
		foreach my $l (@plan_limit_types) {
			my $n = &indexof($l, @nice_plan_limit_types) >= 0;
			my $nice = $n ? &nice_size($limits->{$l}) :
				$l eq "cpu" ? $limits->{$l}."%"
					    : $limits->{$l};
			my $nicemax = $n ? &nice_size($limits->{'max_'.$l}) :
				   $l eq "cpu" ? $limits->{'max_'.$l}."%"
					       : $limits->{'max_'.$l};
			my $msg1 = $limits->{$l} ||
					!$limits->{$l.'_unlimited'} ?
					$nice : $text{'right_vunlimited'};
			my $msg2 = $limits->{'max_'.$l} ?
				$nicemax : $text{'right_vunlimited'};
			if ($limits->{'max_'.$l} &&
			    $limits->{$l} > $limits->{'max_'.$l}) {
				$msg1 = "<font color=red>$msg1</font>";
				$msg2 = "<font color=red>$msg2</font>";
				}
			push(@table, { 'desc' => $text{'right_vm2c'.$l},
				       'value' => $msg1 });
			push(@table, { 'desc' => $text{'right_vm2m'.$l},
				       'value' => $msg2 });
			}
		push(@rv, { 'type' => 'table',
			    'id' => 'vm2limits',
			    'open' => 0,
			    'desc' => $text{'right_vm2limitsheader'},
			    'table' => \@table });
		}
	}

# Show owner's usage
if ($access{'owner'} && defined(&server_manager::get_owner_usage)) {
	my $owner = &get_system_owner($base_remote_user);
	my @allusage = &get_owner_usage($owner);
	@allusage = sort { $a->{'start'} cmp $b->{'start'} } @allusage;
	my @usageids = &unique(map { $_->{'server'} } @allusage);
	if (@allusage) {
		my @table;

		# Period range
		my ($start, $end) = &usage_period_start_end(\@allusage, 0);
		push(@table, { 'desc' => $text{'edit_ustart'},
			       'wide' => 1,
			       'value' => &make_date($start) });

		# Total uptime over usage period
		my $up = &sum_usage_over_period(\@allusage, $start, $end, 'up');
		push(@table, { 'desc' => $text{'edit_uup'},
			       'wide' => 1,
			       'value' => &nice_hour_mins_secs($up) });

		# Memory over accounting period
		my $mem = &sum_usage_over_period(\@allusage, $start, $end,
						 'mem');
		if ($mem) {
			my $gbh = sprintf("%.2f", $mem / (3600*1024*1024*1024));
			my $avgmem = &nice_size(int($mem / ($end - $start)));
			my $upmem = &nice_size(int($mem / $up));
			push(@table, { 'desc' => $text{'edit_umem'},
				       'wide' => 1,
				       'value' => &text('edit_ugbh', $gbh,
							$avgmem, $upmem) });
			}

		# CPU allocation, in percent hours
		my $cpu = &sum_usage_over_period(\@allusage, $start, $end,
						 'cpu');
		if ($cpu) {
			my $cpuh = sprintf("%.2f", ($cpu / 3600));
			my $avgcpu = int($cpu / ($end - $start));
			my $upcpu = int($cpu / $up);
			push(@table, { 'desc' => $text{'edit_ucpu'},
				       'wide' => 1,
				       'value' => &text('edit_ucpuh', $cpuh,
							$avgcpu, $upcpu) });
			}

		# CPU load, in percent hours
		my $load = &sum_usage_over_period(\@allusage, $start, $end,
						  'load');
		if ($load) {
			my $cpuh = sprintf("%.2f", ($load / 3600));
			my $avgcpu = int($load / ($end - $start));
			my $upcpu = int($load / $up);
			push(@table, { 'desc' => $text{'edit_uload'},
				       'wide' => 1,
				       'value' => &text('edit_ucpuh', $cpuh,
							$avgcpu, $upcpu) });
			}

		# Disk assigned and used over period
		my $disk = &sum_usage_over_period(\@allusage, $start, $end,
						  'disk');
		my $space = &sum_usage_over_period(\@allusage, $start, $end,
						   'space');
		if ($disk && $disk != $space) {
			my $gbh = sprintf("%.2f",
					$disk / (3600*1024*1024*1024));
			my $avgdisk = &nice_size(int($disk / ($end - $start)));
			push(@table, { 'desc' => $text{'edit_udisk'},
				       'wide' => 1,
				       'value' => &text('edit_ugbh2', $gbh,
							$avgdisk) });
			}
		if ($space) {
			my $gbh = sprintf("%.2f",
					$space / (3600*1024*1024*1024));
			my $avgspace = &nice_size(
					int($space / ($end - $start)));
			push(@table, { 'desc' => $text{'edit_uspace'},
				       'wide' => 1,
				       'value' => &text('edit_ugbh2', $gbh,
							$avgspace) });
			}

		# Combined bandwidth usage
		if ($config{'bw_enabled'}) {
			my $bstart = &bandwidth_period_start(0);
			my $bend = &bandwidth_period_end(0);
			my $bwinfo = &get_owner_bandwidth(
					$owner, $bstart, $bend);
			my $bwtotal = 0;
			for($hh=$bstart; $hh<$bend; $hh+=3600) {
				$bwtotal += $bwinfo->{'hour_in_'.$hh};
				$bwtotal += $bwinfo->{'hour_out_'.$hh};
				}
			push(@table, { 'desc' => $text{'owner_bwusage'},
				       'wide' => 1,
				       'value' => &nice_size($bwtotal) });
			}

		# Systems included
		if (@usageids) {
			my @usagenames;
			foreach my $id (@usageids) {
				my $us = &get_managed_server($id);
				push(@usagenames, $us ? $us->{'host'} :
					&text('owner_del', $id));
				}
			push(@table, { 'desc' => $text{'owner_usagesystems'},
				       'wide' => 1,
				       'value' => &ui_links_row(\@usagenames)});
			}

		push(@rv, { 'type' => 'table',
			    'id' => 'vm2usage',
			    'open' => 0,
			    'desc' => $text{'right_vm2usageheader'},
			    'table' => \@table });
		}
	}

# Details of managed systems
if (@servers > 1) {
	my %c;
	foreach my $s (@servers) {
		$c{'all'}++;
		if (&is_parent_server($s)) {
			$c{'host'}++;
			}
		my $virt = &is_virtual_server($s);
		$c{$virt ? 'virt' : 'real'}++;
		if ($s->{'status'} eq 'alive' ||
		    &can_ssh_status($s)) {
			$c{'up'}++;
			}
		else {
			$c{'down'}++;
			}
		my $mfunc = "type_".$s->{'manager'}."_get_memory_size";
		if (defined(&$mfunc)) {
			my $mem = &$mfunc($s);
			if ($mem) {
				$c{'mem'} += $mem;
				}
			}
		my $dfunc = "type_".$s->{'manager'}."_get_disk_size";
		if (defined(&$dfunc)) {
			my $disk = &$dfunc($s);
			if ($disk) {
				$c{'disk'} += $disk;
				}
			}
		}
	my @table;
	foreach my $f ('all', 'host', 'virt', 'real', 'up', 'down',
		       'mem', 'disk') {
		push(@table, { 'desc' => $text{'right_vm2count'.$f},
			       'value' => $f eq 'mem' || $f eq 'disk' ?
					&nice_size($c{$f}) : int($c{$f}) });
		}
	push(@rv, { 'type' => 'table',
		    'id' => 'vm2servers',
		    'priority' => 40,
		    'open' => $access{'owner'} ? 1 : 0,
		    'desc' => $text{'right_vm2serversheader'},
		    'table' => \@table });
	}

# New features
my $newhtml = &get_new_features_html(undef);
if ($newhtml) {
	push(@rv, { 'type' => 'html',
		    'id' => 'newfeatures',
		    'open' => 1,
		    'desc' => $text{'right_newfeaturesheader'},
		    'html' => $newhtml });
	}

# Sections defined by plugins
foreach my $p (&list_plugin_sections()) {
	push(@rv, { 'type' => 'html',
		    'id' => 'plugin_'.$p->{'name'},
		    'desc' => $p->{'title'},
		    'html' => $p->{'html'},
		    'open' => $p->{'status'} });
	}

# Cloudmin licence info
my %sserial;
if (&read_env_file($licence_file, \%sserial) &&
    $sserial{'SerialNumber'} ne 'GPL' &&
    !$access{'owner'}) {
	my @table;  
        my $open = 0;

	# Serial and key
	push(@table, { 'desc' => $text{'right_sserial'},
		       'value' => $sserial{'SerialNumber'} });
	push(@table, { 'desc' =>  $text{'right_skey'},
		       'value' => $sserial{'LicenseKey'} });

	# Allowed system counts
	my %lstatus;
	&read_file($licence_status, \%lstatus);
	my @allservers = grep { &is_virtual_server($_) }
			      &list_managed_servers();
	push(@table, { 'desc' => $text{'right_vm2max'},
		       'value' => $lstatus{'servers'} > 0 ?
				    $lstatus{'servers'} :
				    $text{'right_vunlimited'} });
	push(@table, { 'desc' => $text{'right_vm2used'},
		       'value' => scalar(@allservers) });

	# Show license expiry date
	if ($lstatus{'expiry'} =~ /^203[2-8]-/) {
		push(@table, { 'desc' => $text{'right_expiry'},
			       'value' => $text{'right_expirynever'} });
		}
	elsif ($lstatus{'expiry'}) {
		push(@table, { 'desc' => $text{'right_expiry'},
			       'value' => $lstatus{'expiry'} });
		my $ltm = &parse_license_date($lstatus{'expiry'});
		if ($ltm) {
			my $days = int(($ltm - time()) / (24*60*60));
			push(@table, { 'desc' => $text{'right_expirydays'},
				       'value' => $days < 0 ?
					&text('right_expiryago', -$days) :
					$days });
			$open = 1 if ($days < 7);
			}
		}

	push(@rv, { 'type' => 'table',
	    'id' => 'serial',
	    'desc' => $text{'right_licenceheader'},
	    'open' => $open,
	    'table' => \@table });

	# Re-check licence link
        push(@rv, { 'type' => 'link',
                    'priority' => 20,
                    'desc' => $text{'right_slcheck'},
                    'link' => '/'.$module_name.'/licence.cgi' });
	}

return @rv;
}

sub parse_license_date
{
my ($str) = @_;
if ($str =~ /^(\d{4})-(\d+)-(\d+)$/) {
        return eval { timelocal(0, 0, 0, $3, $2-1, $1-1900) };
        }
return undef;
}

1;
