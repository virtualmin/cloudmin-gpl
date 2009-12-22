#!/usr/local/bin/perl
# Show a form for searching for domains, and a form to add a new one

require './server-manager-lib.pl';
&ReadParse();
&ui_print_header(undef, $text{'domains_title'}, "", "domains");
@vservers = grep { $_->{'status'} eq 'virt' } &list_available_managed_servers();
foreach $s (@vservers) {
	$totaldomains += $s->{'virtualmin_domains'};
	}
&can_action_error(\@vservers, "domains");

$formno = 0;
if ($totaldomains) {
	# Search form
	print &ui_form_start("list_domains.cgi");
	print "<b>$text{'domains_find'}</b>\n";
	print &ui_textbox("search", $in{'search'}, 30);
	print &ui_submit($text{'domains_ok'});
	print &ui_form_end();
	$formno++;
	}

if ($in{'search'}) {
	# Search across all servers
	$parsedsearch = &parse_domain_name($in{'search'});
	foreach $s (@vservers) {
		foreach $d (&get_server_domains($s)) {
			if ($d->{'dom'} =~ /\Q$in{'search'}\E/i ||
			    $d->{'dom'} =~ /\Q$parsedsearch\E/i) {
				push(@doms, $d);
				$d->{'_server'} = $s;
				}
			}
		}

	# Show results, if any
	if (@doms) {
		print &text('domains_matches', scalar(@doms)),"<p>\n";
		@links = ( &select_all_link("d", $formno),
			   &select_invert_link("d", $formno) );
		@tds = ( "width=5" );
		print &ui_form_start("mass_domains.cgi", "post");
		print &ui_links_row(\@links);
		print &ui_columns_start([ "",
					  $text{'domains_dom'},
					  $text{'domains_server'},
					  $text{'domains_type'},
					  $text{'domains_desc'},
					  $text{'domains_quota'},
					  $text{'domains_uquota'} ], 100, 0, \@tds);
		foreach $d (@doms) {
			$server = $d->{'_server'};
			$bs = &get_server_blocksize($server);
			$info = &get_server_collected($server);
			if ($info->{'quota'}) {
				($dquota) = grep { $_->[0]->{'id'} == $d->{'id'} }
						 @{$info->{'quota'}};
				}
			$di1 = $d->{'disabled'} ? "<i>" : "";
			$di2 = $d->{'disabled'} ? "</i>" : "";
			print &ui_checked_columns_row([
				$di1.&domain_link($server, $d).$di2,
				"<a href='edit_serv.cgi?id=$server->{'id'}'>".
				 $server->{'host'}."</a>",
				$d->{'alias'} ? $text{'domains_alias'} :
				 $d->{'subdom'} ? $text{'domains_subdom'} :
				 $d->{'parent'} ? $text{'domains_sub'} :
						  $text{'domains_top'},
				$d->{'owner'},
				$info->{'quota'} ? (
				    $d->{'parent'} ? $text{'domains_fromparent'} :
				    $d->{'quota'} ? &nice_size($d->{'quota'}*$bs)
					          : $text{'domains_unlimited'},
				    $dquota ? &nice_size($dquota->[1]) : "") :
				    ( $text{'domains_unlimited'},
				      $text{'domains_unknown'} )
				], \@tds, "d", $server->{'id'}."/".$d->{'id'});
			}
		print &ui_columns_end();
		print &ui_links_row(\@links);
		print &ui_form_end([ [ "delete", $text{'domains_delete'} ],
				     undef,
				     [ "disable", $text{'domains_disable'} ],
				     [ "enable", $text{'domains_enable'} ],
				     undef,
				     [ "move", $text{'domains_move'} ],
				   ]);
		}
	else {
		print "<b>$text{'domains_none'}</b><p>\n";
		}
	}

# Creation form (hidden by default). For top-level servers only, limited options
@vservers = grep { !$_->{'novirt'} &&
		   $_->{'virtualmin_checked'} } @vservers;
print &ui_hidden_start($text{'domains_hidden'}, "create",
		       $in{'create'} || !$totaldomains,
		       "list_domains.cgi");
print $text{'domains_desc2'},"<p>\n";
print &ui_form_start("create_domain.cgi", "post");
print &ui_hidden("create", $in{'create'});
print &ui_table_start($text{'domains_header'}, undef, 2);

# Domain name, description, password (the core fields)
print &ui_table_row($text{'domains_cdom'},
		    &ui_textbox("dom", undef, 40));
print &ui_table_row($text{'domains_cdesc'},
		    &ui_textbox("desc", undef, 60));
print &ui_table_row($text{'domains_cpass'},
		    &ui_textbox("pass", undef, 20));

# Server to create on
print &ui_table_row($text{'domains_cserver'},
	&ui_select("server", $in{'create'} ? $in{'id'} : -1,
		   [ [ -1, $text{'domains_cfewest'} ],
		     [ -2, $text{'domains_cspace'} ],
		     [ -3, $text{'domains_cload'} ],
		     [ -4, $text{'domains_cmem'} ],
		     map { [ $_->{'id'}, $_->{'host'} ] } @vservers ]));

# Enabled features .. find those available across all servers
foreach $s (sort { $a->{'host'} cmp $b->{'host'} } @vservers) {
	$info = &get_server_collected($s);
	foreach $f (@{$info->{'features'}}) {
		if (!$donefeat{$f->{'feature'}}++) {
			push(@features, $f);
			}
		}
	}
if (!@features) {
	# Fall back to standard core Virtualmin features
	@features = @standard_virtualmin_features;
	}
%defs = map { $_, 1 } split(/\s+/, $config{'defs'});
@grid = map { &ui_checkbox("feature", $_->{'feature'}, $_->{'desc'},
			   %defs ? $defs{$_->{'feature'}} : $_->{'default'}) }
	    grep { $_->{'enabled'} } @features;
print &ui_table_row($text{'domains_cfeatures'},
		    &ui_grid_table(\@grid, 2));

# Private IP
print &ui_table_row($text{'domains_cvirt'},
		    &ui_radio("virt_mode", 0,
			[ [ 0, $text{'domains_cvirt0'} ],
			  [ 1, $text{'domains_cvirt1'} ],
			  [ 2, &text('domains_cvirt2',
				&ui_textbox("virt", undef, 20)) ] ]));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'domains_cok'} ] ]);
print &ui_hidden_end();
print "<p>\n";

# Form to restore a backup
print &ui_hidden_start($text{'domains_rhidden'}, "restore",
		       0, "list_domains.cgi");
print $text{'domains_rdesc'},"<p>\n";
print &ui_form_start("restore_domain.cgi", "form-data");
print &ui_hidden("create", $in{'create'});
print &ui_table_start($text{'domains_rheader'}, undef, 2);

# File to restore from
$master = &get_managed_server(0);
@rtable = ( [ 0, $text{'domains_rfile0'}, &ui_upload("upload", 40) ] );
if (&can_action($master, "transfer")) {
	# File on cloudmin master
	push(@rtable, [ 1, $text{'domains_rfile1'},
		        &ui_filebox("file", undef, 40) ]);
	}
push(@rtable, [ 2, $text{'domains_rfile2'},
		&ui_select("server", $in{'create'},
		   [ map { [ $_->{'id'}, $_->{'host'} ] }
			 &list_available_managed_servers_sorted() ])." ".
		&ui_textbox("serverfile", undef, 40) ]);
print &ui_table_row($text{'domains_rfile'},
	&ui_radio_table("rfile_mode", 0, \@rtable));

# System to restore on
print &ui_table_row($text{'domains_rserver'},
	&ui_select("server", $in{'create'} ? $in{'id'} : -1,
		   [ [ -1, $text{'domains_cfewest'} ],
		     [ -2, $text{'domains_cspace'} ],
		     [ -3, $text{'domains_cload'} ],
		     [ -4, $text{'domains_cmem'} ],
		     map { [ $_->{'id'}, $_->{'host'} ] } @vservers ]));

# Domains to restore
print &ui_table_row($text{'domains_rdoms'},
	&ui_opt_textbox("dom", undef, 50, $text{'domains_rall'}));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'domains_rok'} ] ]);
print &ui_hidden_end();
print "<p>\n";

# Form to migrate a domain
# XXX

if ($in{'create'}) {
	&ui_print_footer("edit_serv.cgi?id=$in{'id'}&doms=1", $text{'edit_return'});
	}
else {
	&ui_print_footer("", $text{'index_return'});
	}

