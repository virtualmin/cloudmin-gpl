#!/usr/local/bin/perl
# Show the status of some server, with a limited set of editable fields and
# sections showing domains and status

require './server-manager-lib.pl';
&ReadParse();
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$server || &error($text{'edit_egone'});
$status = $server->{'status'};
$info = &get_server_collected($server);
&ui_print_header(&server_in($server), $text{'edit_title'}, "", "edit");

# Basic details section
@tds = ( "width=30%" );
print &ui_form_start("save_serv.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_hidden_table_start($text{'edit_bheader'}, "width=100%", 2,
			     "basic", 1, \@tds);

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
	print &ui_table_row($text{'edit_os'},
			    &describe_os($server->{'type'}));

	print &ui_table_row($text{'edit_webmin'},
			    $info->{'general'}->{'version'});
	}

if ($status eq 'virt') {
	# Virtualmin version
	print &ui_table_row($text{'edit_vversion'},
			    $info->{'minfo'}->{'version'});

	# Enabled for Virtualmin domain creation
	print &ui_table_row($text{'add_canvirt'},
		    &ui_yesno_radio("canvirt", $server->{'novirt'} ? 0 : 1));
	}

# Type-specific information
$efunc = "type_".$t."_edit_form";
if (defined(&$efunc)) {
	print &$efunc($server);
	}

print &ui_hidden_table_end("basic");

# Show authentication form (if needed)
$haswebmin = ($status eq 'nowebminlogin' || $status eq 'novirt' ||
	      $status eq 'virt') && $server->{'id'} != 0;
$sfunc = "type_".$t."_no_ssh";
$hasssh = !defined(&$sfunc) || !&$sfunc();
if ($haswebmin || $hasssh) {
	print &ui_hidden_table_start($text{'edit_aheader'}, "width=100%", 2,
				     "auth", 0, \@tds);
	}

# SSH
if ($hasssh) {
	print &ui_table_row($text{'edit_auth'},
	   &ui_radio("auth_mode", $server->{'ssh_pass'} ? 0 : 1,
	      [ [ 0, &text('add_auth0',
		   &ui_textbox("upass", $server->{'ssh_pass'}, 20))."<br>" ],
		[ 1, &text('add_auth1',
			&ssh_key_menu("key", $t,$server->{'key'}))] ]));
	}

# Webmin
if ($haswebmin) {
	print &ui_table_row($text{'edit_wauth'},
	    &ui_radio("webmin_mode", $server->{'ssh_pass_same'} ? 1 : 2,
	      [ [ 1, $text{'add_webmin1'}."<br>" ],
	        [ 2, &text('add_webmin2',
		           &ui_textbox("wuser", $server->{'user'}, 20),
		           &ui_textbox("wpass", $server->{'pass'}, 20)) ] ]));
	}

if ($haswebmin || $hasssh) {
	print &ui_hidden_table_end("auth");
	}

# Action buttons at end of form (depends on status)
if ($status eq 'down' || $status eq 'nossh') {
	# System is down, so we can only save and perhaps startup
	$sfunc = "type_".$t."_no_startup";
	$nostart = defined(&$sfunc) && &$sfunc($server);
	print &ui_form_end([
		[ "save", $text{'save'} ],
		  undef,
		  $nostart ? ( ) : ( [ "startup", $text{'edit_startup'} ] ),
		]);
	}
else {
	# Running, so all options are available
	$sfunc = "type_".$t."_no_shutdown";
	$noshut = defined(&$sfunc) && &$sfunc($server);
	$rfunc = "type_".$t."_no_reboot";
	$noreboot = defined(&$rfunc) && &$rfunc($server);
	$wurl = &webmin_link($server);
	print &ui_form_end([
		[ "save", $text{'save'} ],
		  undef,
		  [ 'shell', $text{'edit_shell'} ],
		  ($status eq 'novirt' || $status eq 'virt') &&
		     $server->{'id'} ?
			( [ "webmin", $text{'edit_webmin2'}, undef, undef,
			    "onClick='window.open(\"$wurl\"); return false'" ] ) : ( ),
		  undef,
		  $status eq 'novirt' ?
			( [ "installvirt", $text{'edit_installvirt'} ] ) :
		  $status eq 'nowebmin' ?
			( [ "installwebmin", $text{'edit_installwebmin'} ] ) :
			( ),
		  $noreboot ? ( ) : ( [ "reboot", $text{'edit_reboot'} ] ),
		  $noshut ? ( ) : ( [ "shutdown", $text{'edit_shutdown'} ] ),
		]);
	}

# Virtualmin status
if ($info && scalar(keys %$info) > 1) {
	print &ui_hidden_table_start($text{'edit_cheader'}, "width=100%", 2,
				     "coll", 0, \@tds);

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
@doms = &get_server_domains($server);
if ($status eq 'virt' || @doms) {
	print &ui_hidden_table_start($text{'edit_dheader'}, "width=100%", 2,
				     "doms", 0, \@tds);

	if (@doms) {
		$bs = &get_server_blocksize($server);
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

