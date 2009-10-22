#!/usr/local/bin/perl
# Show a form for creating or editing one domain sync

require './server-manager-lib.pl';
&ReadParse();
@servers = grep { $_->{'status'} eq 'virt' }
		&list_available_managed_servers_sorted();
if ($in{'new'}) {
	&ui_print_header(undef, $text{'vsync_title1'}, "");
	$vsync = { 'special' => 'daily' };
	if ($access{'owner'}) {
		$vsync->{'email'} = $access{'email'};
		}
	&can_action_error(undef, "domains");
	}
else {
	&ui_print_header(undef, $text{'vsync_title2'}, "");
	$vsync = &get_virtualmin_sync($in{'id'});
	$vsync || &error($text{'vsync_egone'});
	&can_virtualmin_sync($vsync) || &error($text{'vsync_ecannot'});
	}

print &ui_form_start("save_vsync.cgi", "post");
print &ui_hidden("new", $in{'new'});
print &ui_hidden("id", $in{'id'});
print &ui_hidden_table_start($text{'vsync_header1'}, "width=100%", 2,
                             "main", 1, [ "width=30%" ]);

# Source system
print &ui_table_row($text{'vsync_src'},
		&ui_select("src", $vsync->{'src'} || $servers[0]->{'id'},
			   [ map { [ $_->{'id'}, $_->{'host'} ] } @servers ],
			   1, 0, 1));

# Destination systems
@dests = &get_virtualmin_sync_dests($vsync);
print &ui_table_row($text{'vsync_dest'},
	&ui_multi_select("dest",
		[ map { [ $_->{'id'}, $_->{'host'} ] } @dests ],
		[ map { [ $_->{'id'}, $_->{'host'} ] } @servers ],
		10, 1, 0, $text{'vsync_destopts'}, $text{'vsync_destvals'}));

# Domains to include
@alldoms = ( );
%seen = ( );
foreach $s (@servers) {
	push(@alldoms, grep { !$seen{$_->{'dom'}}++ } &get_server_domains($s));
	}
@doms = split(/\s+/, $vsync->{'doms'});
@doms = sort { $a cmp $b } @doms;
@alldoms = sort { $a->{'dom'} cmp $b->{'dom'} } @alldoms;
print &ui_table_row($text{'vsync_doms'},
	&ui_multi_select("doms",
		[ map { [ $_, &show_domain_name($_) ] } @doms ],
		[ map { [ $_->{'dom'}, &show_domain_name($_) ] } @alldoms ],
		10, 1, 0, $text{'vsync_domsopts'}, $text{'vsync_domsvals'}));

print &ui_hidden_table_end("main");

print &ui_hidden_table_start($text{'vsync_header2'}, "width=100%", 2,
                             "doms", 0, [ "width=30%" ]);

# Global settings to include
@tmpls = split(/\s+/, $vsync->{'tmpls'});
print &ui_table_row($text{'vsync_tmpls'},
	&ui_grid_table(
	       [ map { &ui_checkbox("tmpl", $_, $text{'vsync_tmpl_'.$_},
				    &indexof($_, @tmpls) >= 0)."<br>\n" }
		     &list_virtualmin_globals(\@servers) ], 2, 100));

# Domain features to sync
print &ui_table_row($text{'vsync_feats'},
	&ui_radio("feats_def", $vsync->{'feats'} ? 0 : 1,
		  [ [ 1, $text{'vsync_feats1'} ],
		    [ 0, $text{'vsync_feats0'} ] ])."<br>\n".
	&ui_select("feats",
		   [ split(/\s+/, $vsync->{'feats'}) ],
		   [ map { [ $_->{'feature'}, $_->{'desc'} ] }
			 @standard_virtualmin_features ],
		   scalar(@standard_virtualmin_features), 1));

print &ui_hidden_table_end("doms");

print &ui_hidden_table_start($text{'vsync_header3'}, "width=100%", 2,
                             "sched", 1, [ "width=30%" ]);

# Backup on scheduled enabled?
print &ui_table_row($text{'vsync_enabled'},
	&ui_yesno_radio("enabled", $vsync->{'enabled'}));

# Scheduled run time
print &ui_table_row($text{'vsync_when'},
	&virtualmin_ui_show_cron_time("when", $vsync, undef));

# Who to notify
print &ui_table_row($text{'vsync_email'},
	&ui_opt_textbox("email", $vsync->{'email'}, 40,
			$text{'backup_noemail'}));

print &ui_hidden_table_end("sched");
if ($in{'new'}) {
	print &ui_form_end([ [ undef, $text{'create'} ] ]);
	}
else {
	print &ui_form_end([ [ undef, $text{'save'} ],
			     [ 'run', $text{'vsync_run'} ],
			     [ 'delete', $text{'delete'} ] ]);
	}

&ui_print_footer("list_vsyncs.cgi", $text{'vsyncs_return'});

