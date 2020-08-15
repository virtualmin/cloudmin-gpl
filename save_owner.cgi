#!/usr/local/bin/perl
# Create, update or delete a server owner

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($text{'owner_err'});
&error_if_cloudmin_replica();
&foreign_require("acl", "acl-lib.pl");
if (!$in{'new'}) {
	$owner = &get_system_owner($in{'old'});
	$owner || &error($text{'owner_egone'});
	$old = { %$owner };
	}

if ($in{'switch'}) {
	# Special case - switch to the Webmin user for this owner
	&ui_print_header(undef, $text{'owner_title2'}, "");
	print &text('owner_switching', "<tt>$in{'name'}</tt>"),"<p>\n";
	print "<script>\n";
	print "var w = window;\n";
	print "while(w.parent && w.parent != w) { w = w.parent; }\n";
	print "w.location = \"switch.cgi?name=$in{'old'}\";\n";
	print "</script>\n";
	&ui_print_footer();
	}
elsif ($in{'bw'}) {
	# Redirect to bandwidth graph for owner
	&redirect("bwgraph.cgi?owner=".&urlize($owner->{'name'}));
	}
elsif ($in{'logs'}) {
	# Redirect to Webmin Actions Log module for user
	&redirect("../webminlog/search.cgi?tall=4&uall=0&user=".
		  &urlize($owner->{'name'})."&mall=1");
	}
elsif ($in{'delete'}) {
	# Get owners systems
	@sids = split(/\s+/, $owner->{'acl'}->{'servers'});
	@oservers = grep { $_ } map { &get_managed_server($_) } @sids;

	if ($in{'confirm'}) {
		if ($in{'systems'}) {
			# Also delete his systems
			&set_all_null_print();
			foreach my $s (@oservers) {
				&obtain_lock_server($s);
				&run_system_script($s, 'before', 'delete') ||
					next;
				&delete_all_domains($s);
				$dfunc = "type_".$s->{'manager'}."_delete";
				$err = &$dfunc($s, 0);
				if (!$err) {
					&clear_ssh_host_key($s);
					&delete_managed_server($s, 0);
					run_system_script($s, 'after','delete');
					}
				&release_lock_server($s);
				}
			}

		# Remove owner account
		&delete_system_owner($owner);
		&webmin_log("delete", "owner", $owner->{'name'});
		&redirect("list_owners.cgi");
		}
	else {
		# Ask for confirmation, with option to delete systems
		&ui_print_header(undef, $text{'owner_title2'}, "");

		if (!@oservers) {
			# Has no systems, so only show one button
			@buts = ( [ undef, $text{'owner_sure'} ] );
			}
		elsif ($config{'owner_delete'}) {
			# Always delete systems
			@buts = ( [ 'systems', &text('owner_sure2',
						     scalar(@oservers)) ] );
			$msg = &text('owner_surelist2',
				     join(" ", map { $_->{'host'} } @oservers));
			}
		else {
			# Give the user a choice
			@buts = ( [ undef, $text{'owner_sure'} ],
				  [ 'systems', &text('owner_sure2',
						     scalar(@oservers)) ] );
			$msg = &text('owner_surelist',
				     join(" ", map { $_->{'host'} } @oservers));
			}
		print &ui_confirmation_form(
			"save_owner.cgi",
			&text('owner_rusure', "<tt>$owner->{'name'}</tt>"),
			[ [ "old", $in{'old'} ],
			  [ "delete", 1 ],
			  [ "confirm", 1 ] ],
			\@buts,
			undef,
			$msg,
			);

		&ui_print_footer("list_owners.cgi", $text{'owners_return'});
		}
	}
else {
	# Validate inputs, starting with login
	$in{'oname'} =~ /^[a-z0-9\.\-\_\@]+$/i ||
		&error($text{'owner_ename'});
	if ($in{'new'} || $in{'oname'} ne $owner->{'name'}) {
		($clash) = grep { $_->{'name'} eq $in{'oname'} }
				&acl::list_users();
		$clash && &error($text{'owner_eclash'});
		}
	$owner->{'name'} = $in{'oname'};

	# Validate password
	if (!$in{'opass_def'}) {
		$in{'opass'} =~ /\S/ || &error($text{'owner_epass'});
		$in{'opass'} =~ /:/ && &error($text{'owner_epass2'});
		$owner->{'pass'} = &acl::encrypt_password($in{'opass'});
		$owner->{'acl'}->{'pass'} = $in{'opass'};
		}

	# Update lock setting
	$owner->{'pass'} =~ s/^!//;
	if ($in{'lock'}) {
		$owner->{'pass'} = "!".$owner->{'pass'};
		}

	# Description and email
	$owner->{'real'} = $in{'real'};
	$in{'email'} =~ /^\S+\@\S+$/ ||
		&error($text{'owner_eemail'});
	$owner->{'acl'}->{'email'} = $in{'email'};

	# Allowed servers
	#$in{'servers'} eq '' && &error($text{'owner_eservers'});
	$owner->{'acl'}->{'servers'} =
		join(" ", split(/\0/, $in{'servers'}));

	# Plan, if any
	if (&supports_plans()) {
		$owner->{'acl'}->{'plan'} = $in{'plan'};
		}

	# Allowed actions
	if ($in{'actions_def'}) {
		$owner->{'acl'}->{'actions_def'} = 1;
		}
	else {
		$owner->{'acl'}->{'actions_def'} = 0;
		$owner->{'acl'}->{'actions'} =
			join(" ", split(/\0/, $in{'actions'}));
		}

	# Allowed bridges
	if (defined($in{'bridges_def'})) {
		if ($in{'bridges_def'} == 1) {
			delete($owner->{'acl'}->{'bridges'});
			}
		elsif ($in{'bridges_def'} == 2) {
			$owner->{'acl'}->{'bridges'} = 'none';
			}
		else {
			@bridges = split(/\s+/, $in{'bridges'});
			@bridges || &error($text{'owner_ebridges'});
			foreach my $b (@bridges) {
				$b =~ /^[a-z]+[0-9]+$/ ||
					&error(&text('owner_ebridge', $b));
				}
			$owner->{'acl'}->{'bridges'} = join(" ", @bridges);
			}
		}

	# Plan limit overrides
	if (&supports_plans()) {
		$acl = $owner->{'acl'};
		foreach $l (@plan_limit_types) {
			if ($in{'max_'.$l.'_def'} == 2) {
				delete($acl->{'custom_'.$l});
				}
			elsif ($in{'max_'.$l.'_def'} == 1) {
				$acl->{'max_'.$l} = 0;
				$acl->{'custom_'.$l} = 1;
				}
			else {
				$in{'max_'.$l} =~ /^[1-9][0-9]*$/ ||
					&error($text{'plan_emax_'.$l});
				$acl->{'max_'.$l} = $in{'max_'.$l};
				if (defined($in{'max_'.$l.'_units'})) {
					$acl->{'max_'.$l} *=
						$in{'max_'.$l.'_units'};
					}
				$acl->{'custom_'.$l} = 1;
				}
			}
		}

	# Plugin defined limits
	foreach $p (@plugins) {
		if (&plugin_defined($p, "parse_owner_inputs")) {
			&plugin_call($p, "parse_owner_inputs",
				     $owner, $in{'new'}, \%in);
			}
		}

	# Create or update
	if (&supports_plans()) {
                $plan = &get_plan($in{'plan'});
		&apply_plan_to_owner($plan, $owner);
		}
	&save_system_owner($owner, $old);
	&webmin_log($in{'new'} ? "create" : "modify",
		    "owner", $owner->{'name'});
	&redirect("list_owners.cgi");
	}
