#!/usr/local/bin/perl
# Show the status of some server, with a limited set of editable fields and
# sections showing domains and status

require './server-manager-lib.pl';
&ReadParse();
&ui_print_header(undef, $text{'edit_title'}, "", "edit");
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$server || &error($text{'edit_egone'});
$status = $server->{'status'};

# Basic details section
print &ui_form_start("save_serv.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_hidden_table_start($text{'edit_bheader'}, "width=100%", 2,
			     "basic", 1);

# Hostname
print &ui_table_row($text{'edit_host'}, "<tt>$server->{'host'}</tt>");

# System type
$t = $server->{'manager'};
$tfunc = "type_".$t."_desc";
print &ui_table_row($text{'edit_type'}, &$tfunc());

if ($server->{'id'} != 0) {
	# Description (editable)
	print &ui_table_row($text{'edit_desc'},
			    &ui_textbox("desc", $server->{'desc'}, 50), 3);
	}

# Last status
print &ui_table_row($text{'edit_status'},
		    &text('edit_statustime', &describe_status($server, 1, 0),
				     &make_date($server->{'statustime'})));

if ($status eq 'virt' || $status eq 'novirt') {
	# Has Webmin .. show more info
	$info = &get_server_collected($server);
	print &ui_table_row($text{'edit_os'},
			    &describe_os($server->{'type'}));

	print &ui_table_row($text{'edit_webmin'},
			    $info->{'general'}->{'version'});
	}

if ($status eq 'virt') {
	# Enabled for Virtualmin domain creation
	print &ui_table_row($text{'add_canvirt'},
		    &ui_yesno_radio("canvirt", $server->{'novirt'} ? 0 : 1));
	}

print &ui_hidden_table_end("basic");
print &ui_form_end([ [ "save", $text{'save'} ],
		     undef,
		     $status eq 'novirt' ?
		     	( [ "installvirt", $text{'edit_installvirt'} ] ) :
		     $status eq 'nowebmin' ?
		     	( [ "installwebmin", $text{'edit_installwebmin'} ] ) :
			( ),
		     [ "reboot", $text{'edit_reboot'} ] ]);

# Virtualmin status
if ($status eq 'virt' && $info) {
	print &ui_hidden_table_start($text{'edit_cheader'}, "width=100%", 2,
				     "coll");

	# CPU load and running processes
	if ($info->{'load'}) {
		@l = @{$info->{'load'}};
		print &ui_table_row($text{'edit_iload'},
			&text('edit_iloadlevel', @l[0..2], $info->{'procs'}));
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
	if ($info->{'startstop'}) {
		$stable = "<table>\n";
		foreach $ss (@{$info->{'startstop'}}) {
			$stable .= "<tr>\n";
			$stable .= "<td>$ss->{'name'}</td>\n";
			$stable .= "<td>".($ss->{'status'} ?
			    "<font color=#00aa00>$text{'edit_iup'}</font>" :
			    "<font color=#ff0000>$text{'edit_idown'}</font>").
			    "</td>\n";
			$stable .= "</tr>\n";
			}
		$stable .= "</table>\n";
		print &ui_table_row($text{'edit_istatus'}, $stable);
		}

	# Packages to update
	if ($info->{'poss'} && @{$info->{'poss'}}) {
		print &ui_table_row($text{'edit_iposs'},
		    join(", ", map { "$_->{'name'} ($_->{'version'})" }
				   @{$info->{'poss'}})." ".
		    "<input type=button value='$text{'edit_iupdates'}' ".
		    "onClick='document.location=\"update.cgi?id=$in{'id'}\"'>");
		}

	# IP allocation
	if ($info->{'ips'}) {
		$ipcounts = { };
		@iptypes = ( );
		foreach $ip (@{$info->{'ips'}}) {
			$ipcounts{$ip->[1]} += $ip->[3];
			@iptypes = &unique(@iptypes, $ip->[1]);
			$defip = $ip->[0] if ($ip->[1] eq 'def');
			}
		print &ui_table_row($text{'edit_ips'},
			join(", ", map { &text('edit_ip'.$_, $ipcounts{$_}) }
				       @iptypes));
		if ($defip) {
			print &ui_table_row($text{'edit_idefip'},
					    "<tt>$defip</tt>");
			}
		}

	print &ui_hidden_table_end("coll");
	}

# Hosted domains 
if ($status eq 'virt') {
	@doms = &get_server_domains($server);
	print &ui_hidden_table_start($text{'edit_dheader'}, "width=100%", 2,
				     "doms");

	if (@doms) {
		$bs = &get_server_blocksize($server);
		$info = &get_server_collected($server);
		print &ui_columns_start([ $text{'domains_dom'},
					  $text{'domains_type'},
					  $text{'domains_desc'},
					  $text{'domains_quota'},
					  $text{'domains_uquota'} ]);
		foreach $d (sort { $a->{'dom'} cmp $b->{'dom'} } @doms) {
			($dquota) = grep { $_->[0]->{'id'} == $d->{'id'} }
					 @{$info->{'quota'}};
			print &ui_columns_row([
				&domain_link($server, $d),
				$d->{'alias'} ? $text{'domains_alias'} :
				 $d->{'subdom'} ? $text{'domains_subdom'} :
				 $d->{'parent'} ? $text{'domains_sub'} :
						  $text{'domains_top'},
				$d->{'owner'},
				$d->{'quota'} ? &nice_size($d->{'quota'}*$bs)
					      : $text{'domains_unlimited'},
				$dquota ? &nice_size($dquota->[1]) : "",
				]);
			}
		print &ui_columns_end();
		}
	else {
		print &ui_table_row(undef, "<b>$text{'edit_nodoms'}</b>", 2);
		}

	print &ui_hidden_table_end("doms");
	}

&ui_print_footer("", $text{'index_return'});

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

