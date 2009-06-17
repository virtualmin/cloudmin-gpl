#!/usr/local/bin/perl
# Create, update or delete a server owner

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($text{'owner_err'});
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
	exit;
	}
elsif ($in{'delete'}) {
	# Just remove owner account
	&delete_system_owner($owner);
	}
else {
	# Validate inputs, starting with login
	$in{'oname'} =~ /^[a-z0-9\.\-\_]+$/i ||
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
		$owner->{'pass'} = &acl::encrypt_password($in{'opass'});
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
		$in{'actions'} eq '' && &error($text{'owner_eactions'});
		$owner->{'acl'}->{'actions'} =
			join(" ", split(/\0/, $in{'actions'}));
		}

	# Create or update
	&save_system_owner($owner, $old);

	# Apply this plan, if any
	if (&supports_plans()) {
		$plan = &get_plan($in{'plan'});
		&apply_plan($plan);
		}
	}

&redirect("list_owners.cgi");

