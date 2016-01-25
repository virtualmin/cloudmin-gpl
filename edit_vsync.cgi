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
		&ui_select("src", $vsync->{'src'},
			   [ map { [ $_->{'id'}, $_->{'host'} ] } @servers ],
			   1, 0, 0));

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
@alldoms = grep { $_->{'dom'} } @alldoms;
print &ui_table_row($text{'vsync_doms'},
	&ui_checkbox("doms_all", 1, $text{'vsync_doms_all'},
		     $vsync->{'doms_all'})."\n".
	&ui_checkbox("doms_delete", 1, $text{'vsync_doms_delete'},
		     $vsync->{'doms_delete'})."\n".
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
	       [ map { &ui_checkbox("tmpl", $_, $text{'vsync_tmpl_'.$_} || $_,
				    &indexof($_, @tmpls) >= 0)."<br>\n" }
		     &list_virtualmin_globals(\@servers) ], 2, 100));

# Work out what features exist
if ($in{'new'}) {
	$fhost = $servers[0];
	}
else {
	$fhost = &get_managed_server($vsync->{'src'});
	}
if ($fhost) {
	$finfo = &get_server_collected($fhost);
	if ($finfo) {
		@features = @{$finfo->{'features'}};
		}
	}
if (!@features) {
	@features = @standard_virtualmin_features;
	}

# Domain features to sync
print &ui_table_row($text{'vsync_feats'},
	&ui_radio("feats_def", $vsync->{'feats'} ? 0 :
			       $vsync->{'efeats'} ? 2 : 1,
		  [ [ 1, $text{'vsync_feats1'}."<br>" ],
		    [ 0, $text{'vsync_feats0'}."<br>" ],
		    [ 2, $text{'vsync_feats2'} ] ])."<br>\n".
	&ui_select("feats",
		   [ split(/\s+/, $vsync->{'efeats'} || $vsync->{'feats'}) ],
		   [ [ 'virtualmin', 'Virtual server configuration' ],
		     map { [ $_->{'feature'}, $_->{'desc'} ] }
			 @features ],
		   scalar(@features), 1));

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
if ($access{'owner'}) {
	# Owners don't see master admin option
	print &ui_table_row($text{'vsync_email'},
		&ui_radio("emailother", $vsync->{'email'} ? 1 : 0,
			  [ [ 0, $text{'backup_emailnone'} ],
			    [ 1, $text{'backup_emailaddr'} ] ])." ".
		&ui_textbox("email", $vsync->{'email'}, 40));
	}
else {
	# Master admin can choose to notify self
	print &ui_table_row($text{'vsync_email'},
		&ui_checkbox("emailmaster", 1, $text{'backup_emailmaster'},
			     $vsync->{'emailmaster'})."<br>\n".
		&ui_checkbox("emailother", 1, $text{'backup_emailother'},
			     $vsync->{'email'})." ".
		&ui_textbox("email", $vsync->{'email'}, 40));
	}

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

