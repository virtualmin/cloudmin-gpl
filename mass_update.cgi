#!/usr/local/bin/perl
# Install selected packages on multiple systems

require './server-manager-lib.pl';
&error_if_cloudmin_replica();
&ReadParse();
%d = map { $_, 1 } split(/\0/, $in{'d'});
@servers = grep { $d{$_->{'id'}} } &list_managed_servers();
@servers || &error($text{'mass_enone'});
&can_action_error(\@servers, "update");
if (@servers == 1) {
	&ui_print_header(&server_in($servers[0]), $text{'update_title'}, "");
	}
else {
	&ui_print_header(undef, $text{'update_title'}, "");
	}

# Find selected servers with updates, limiting to those we want
@upservers = ( );
$pos = 0;
%wantids = map { $_, 1 } split(/\0/, $in{'p'});
foreach $s (@servers) {
	$info = &get_server_collected($s);
	@poss = @{$info->{'allposs'}};
	@poss = @{$info->{'poss'}} if (!@poss);
	@poss = grep { $wantids{$_->{'system'}.'/'.$_->{'name'}} } @poss;
	if (@poss) {
		push(@upservers, $s);
		$pos += scalar(@poss);
		}
	foreach $pkg (@poss) {
		$k = $pkg->{'system'}."/".$pkg->{'name'};
		$pkgs{$k} ||= $pkg;
		}
	}

if (@servers == 1) {
	# Show each update in series
	$s = $servers[0];
	&$first_print(&text('update_doing', $s->{'host'}, scalar(keys %pkgs)));
	&$indent_print();
	%donedep = ( );
	@allgot = ( );
	&start_background_dot_printer(&text('update_pkgs',
	  join(", ", map { &text('update_ver', $_->{'name'}, $_->{'version'}) }
		         @poss)));
	my ($got, $errs) = &install_multiple_package_updates($s, \@poss);
	&stop_background_dot_printer();
	if (@$got && !@$errs) {
		# Worked OK
		&$second_print(&text('update_donepkg2',
			join(" ", map { "<tt>$_</tt>" } @$got)));
		push(@allgot, @$got);
		}
	elsif (@$got && @$errs) {
		# Partially worked
		&$second_print(&text('update_donepkg3',
			join(" ", map { "<tt>$_</tt>" } @$got),
			join(" ", @$errs)));
		push(@allgot, @$got);
		}
	else {
		# Totally failed
		&$second_print(&text('update_pkgerr2', join(" ", @$errs)));
		}
	&$outdent_print();
	&$second_print($text{'update_done'});

	&$first_print($text{'update_statusing'});
	&obtain_lock_server($s);
	delete($s->{'virtualmin_poss'});
	delete($s->{'all_poss'});
        &refresh_server_updates($s, \@allgot);
        &check_server_status($s);
        &save_managed_server($s);
	&release_lock_server($s);
	&$second_print($text{'update_statusok'});

	if (defined(&theme_post_save_server)) {
		&theme_post_save_server($s);
		&theme_select_server($s);
		}
	}
else {
	# Run them in parallel, and report on updates done at the end
	&start_background_dot_printer(
		&text('mass_updoing', scalar(@upservers), $pos));
	@rv = &parallel_install_package_updates(\@upservers, [ values %pkgs ]);
	&stop_background_dot_printer();
	&$indent_print();
	for($i=0; $i<@rv; $i++) {
		$s = $upservers[$i];
		if (@{$rv[$i]}) {
			&$first_print(&text('mass_upserver',
				"<tt>$s->{'host'}</tt>"));
			&$indent_print();
			$p = $rv[$i]->[0];
			&$first_print(&text('update_pkgs',
			  join(", ", map { &text('update_ver',
						 $_->{'name'},
					         $_->{'version'}) }
					 @{$p->{'want'}})));
			if (!$p->{'status'}) {
				&$second_print(&text('mass_upfailed',
						     $p->{'error'}));
				}
			elsif (@{$p->{'updates'}}) {
				&$second_print(&text('mass_uplist', 
					join(" ", map { "<tt>$_</tt>" }
						@{$p->{'updates'}})));
				}
			else {
				&$second_print($text{'mass_upnone'});
				}
			&$outdent_print();
			}
		else {
			&$second_print(&text('mass_upservernone',
					    "<tt>$s->{'host'}</tt>"));
			}
		}
	&$outdent_print();
	&$second_print($text{'mass_updone'});

	if (defined(&theme_post_save_server)) {
		&theme_post_save_server();
		}
	}
&webmin_log("update", "servers", scalar(@servers),
	    { 'hosts' => \@hostnames });

&ui_print_footer("", $text{'index_return'});

