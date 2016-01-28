#!/usr/local/bin/perl
# Show a form for creating or editing one domain backup

require './server-manager-lib.pl';
&ReadParse();
@servers = grep { $_->{'status'} eq 'virt' }
		&list_available_managed_servers_sorted();
if ($in{'new'}) {
	&ui_print_header(undef, $text{'vbackup_title1'}, "");
	$vbackup = { 'special' => 'daily' };
	if ($access{'owner'}) {
		$vbackup->{'email'} = $access{'email'};
		}
	&can_action_error(undef, "domains");
	}
else {
	&ui_print_header(undef, $text{'vbackup_title2'}, "");
	$vbackup = &get_virtualmin_backup($in{'id'});
	$vbackup || &error($text{'vbackup_egone'});
	&can_virtualmin_backup($vbackup) || &error($text{'vbackup_ecannot'});
	}

print &ui_form_start("save_vbackup.cgi", "post");
print &ui_hidden("new", $in{'new'});
print &ui_hidden("id", $in{'id'});
print &ui_hidden_table_start($text{'vbackup_header1'}, "width=100%", 2,
                             "main", 1, [ "width=30%" ]);

# Source systems
@srcs = &get_virtualmin_backup_srcs($vbackup);
print &ui_table_row($text{'vbackup_src'},
	&ui_multi_select("src",
		[ map { [ $_->{'id'}, $_->{'host'} ] } @srcs ],
		[ map { [ $_->{'id'}, $_->{'host'} ] } @servers ],
		10, 1, 0, $text{'vsync_destopts'}, $text{'vsync_destvals'}));

# Backup destination URLs
print &ui_table_row(&hlink($text{'vbackup_dest'}, 'vbackup_dest'),
	&ui_textarea("dest", join("\n", split(/\s+/, $vbackup->{'dest'})),
		     3, 60));

# Purge old backups
print &ui_table_row($text{'vbackup_purge'},
	&ui_opt_textbox("purge", $vbackup->{'purge'}, 5,
			$text{'vbackup_nopurge'})." ".$text{'vbackup_days'});

# Domains to include
@alldoms = ( );
%seen = ( );
foreach $s (@servers) {
	push(@alldoms, grep { !$seen{$_->{'dom'}}++ } &get_server_domains($s));
	}
@doms = split(/\s+/, $vbackup->{'doms'});
@doms = sort { $a cmp $b } @doms;
@alldoms = sort { $a->{'dom'} cmp $b->{'dom'} } @alldoms;
@alldoms = grep { $_->{'dom'} } @alldoms;
print &ui_table_row($text{'vbackup_doms'},
	&ui_checkbox("doms_all", 1, $text{'vsync_doms_all'},
		     $vbackup->{'doms_all'})."\n".
	&ui_multi_select("doms",
		[ map { [ $_, &show_domain_name($_) ] } @doms ],
		[ map { [ $_->{'dom'}, &show_domain_name($_) ] } @alldoms ],
		10, 1, 0, $text{'vsync_domsopts'}, $text{'vsync_domsvals'}));

# Global settings to include
@tmpls = split(/\s+/, $vbackup->{'tmpls'});
print &ui_table_row($text{'vbackup_tmpls'},
	&ui_grid_table(
	       [ map { &ui_checkbox("tmpl", $_, $text{'vsync_tmpl_'.$_} || $_,
				    &indexof($_, @tmpls) >= 0)."<br>\n" }
		     &list_virtualmin_globals(\@servers) ], 2, 100));

print &ui_hidden_table_end("main");

print &ui_hidden_table_start($text{'vbackup_header3'}, "width=100%", 2,
                             "sched", 1, [ "width=30%" ]);

# Backup on scheduled enabled?
print &ui_table_row($text{'vbackup_enabled'},
	&ui_yesno_radio("enabled", $vbackup->{'enabled'}));

# Scheduled run time
print &ui_table_row($text{'vbackup_when'},
	&virtualmin_ui_show_cron_time("when", $vbackup, undef));

# Who to notify
if ($access{'owner'}) {
	# Owners don't see master admin option
	print &ui_table_row($text{'vbackup_email'},
		&ui_radio("emailother", $vbackup->{'email'} ? 1 : 0,
			  [ [ 0, $text{'backup_emailnone'} ],
			    [ 1, $text{'backup_emailaddr'} ] ])." ".
		&ui_textbox("email", $vbackup->{'email'}, 40));
	}
else {
	# Master admin can choose to notify self
	print &ui_table_row($text{'vbackup_email'},
		&ui_checkbox("emailmaster", 1, $text{'backup_emailmaster'},
			     $vbackup->{'emailmaster'})."<br>\n".
		&ui_checkbox("emailother", 1, $text{'backup_emailother'},
			     $vbackup->{'email'})." ".
		&ui_textbox("email", $vbackup->{'email'}, 40));
	}

print &ui_hidden_table_end("sched");
if ($in{'new'}) {
	print &ui_form_end([ [ undef, $text{'create'} ] ]);
	}
else {
	print &ui_form_end([ [ undef, $text{'save'} ],
			     [ 'run', $text{'vbackup_run'} ],
			     [ 'delete', $text{'delete'} ] ]);
	}

&ui_print_footer("list_vbackups.cgi", $text{'vbackups_return'});

