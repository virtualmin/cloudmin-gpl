#!/usr/local/bin/perl
# Install selected packages on multiple systems

require './server-manager-lib.pl';
&error_if_cloudmin_replica();
&ReadParse();
%d = map { $_, 1 } split(/\0/, $in{'d'});
@servers = grep { $d{$_->{'id'}} } &list_managed_servers();
@servers || &error($text{'mass_enone'});
&can_action_error(\@servers, "update");
$in{'packages'} =~ s/^\s+//;
$in{'packages'} =~ s/\s+$//;
$in{'install'} && !$in{'packages'} && &error($text{'update_epackages'});

$title = $in{'install'} ? $text{'update_title2'} : $text{'update_title'};
if (@servers == 1) {
	&ui_print_header(&server_in($servers[0]), $title, "");
	}
else {
	&ui_print_header(undef, $title, "");
	}

# Find selected servers with updates, limiting to those we want
@upservers = ( );
$pos = 0;
if ($in{'install'}) {
	# Installing possibly new packages
	@upservers = @servers;
	foreach $s (@servers) {
		$info = &get_server_collected($s);
		next if (!$info || !$info->{'update_system'});
		@poss = ( );
		foreach $p (split(/\s+/, $in{'packages'})) {
			my $pkg = { 'name' => $p,
				    'system' => $info->{'update_system'} };
			$k = $pkg->{'system'}."/".$pkg->{'name'};
			if ($in{'newonly'}) {
				# Skip if already installed
				@uposs = @{$info->{'allposs'}};
				@uposs = @{$info->{'poss'}} if (!@uposs);
				($existing) = grep {
					$_->{'system'} eq $pkg->{'system'} &&
					$_->{'name'} eq $pkg->{'name'}
					} @uposs;
				next if ($existing);
				}
			push(@poss, $pkg);
			$pkgs{$k} ||= $pkg;
			}
		$pos += scalar(@poss);
		}
	if (!%pkgs) {
		&ui_print_endpage("<b>$text{'update_nothingtodo'}</b>");
		}
	}
else {
	# Updating packages .. find them from list of known updates
	%wantids = map { $_, 1 } split(/\0/, $in{'p'});
	foreach $s (@servers) {
		$info = &get_server_collected($s);
		@poss = @{$info->{'allposs'}};
		@poss = @{$info->{'poss'}} if (!@poss);
		@poss = grep { $wantids{$_->{'system'}.'/'.$_->{'name'}} }
			     @poss;
		if (@poss) {
			push(@upservers, $s);
			$pos += scalar(@poss);
			}
		foreach $pkg (@poss) {
			$k = $pkg->{'system'}."/".$pkg->{'name'};
			$pkgs{$k} ||= $pkg;
			}
		}
	}

if (@servers == 1) {
	# Show each update in series, as we are just installing on one system
	$s = $servers[0];
	&$first_print(&text($in{'install'} ? 'update_doingi' : 'update_doing',
			    $s->{'host'}, scalar(keys %pkgs)));
	&$indent_print();
	%donedep = ( );
	@allgot = ( );
	#&start_background_dot_printer(&get_update_msg(@poss));
	my ($got, $errs) = &install_multiple_package_updates($s, \@poss);
	#&stop_background_dot_printer();
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
	# Run them in parallel, and report on updates done at the end, as we
	# are installing on multiple systems
	&start_background_dot_printer(
		&text($in{'install'} ? 'mass_updoingi' : 'mass_updoing',
		      scalar(@upservers), $pos));
	@rv = &parallel_install_package_updates(\@upservers, [ values %pkgs ],
						$in{'install'});
	&stop_background_dot_printer();
	&$indent_print();
	for($i=0; $i<@rv; $i++) {
		$s = $upservers[$i];
		if (@{$rv[$i]}) {
			&$first_print(&text($in{'install'} ? 'mass_upserveri'
							   : 'mass_upserver',
					    "<tt>$s->{'host'}</tt>"));
			&$indent_print();
			$p = $rv[$i]->[0];
			&$first_print(&get_update_msg(@{$p->{'want'}}));
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
@hostnames = map { $_->{'host'} } @servers;
&webmin_log("update", "servers", scalar(@servers),
	    { 'hosts' => \@hostnames });

&ui_print_footer("", $text{'index_return'});

sub get_update_msg
{
my @poss = @_;
if ($in{'install'}) {
	return &text('update_pkgsi',
		  join(", ", map { "<tt>$_->{'name'}</tt>" } @poss));
	}
else {
	return &text('update_pkgs',
		  join(", ", map { &text('update_ver', $_->{'name'},
						  $_->{'version'}) } @poss));
	}
}

