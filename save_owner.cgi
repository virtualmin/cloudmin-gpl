#!/usr/local/bin/perl
# Create, update or delete a server owner

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($text{'owner_err'});
&foreign_require("acl", "acl-lib.pl");
if (!$in{'new'}) {
	$owner = &get_system_owner($in{'old'});
	$old = { %$owner };
	}

if ($in{'delete'}) {
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
	$in{'servers'} eq '' && &error($text{'owner_eservers'});
	$owner->{'acl'}->{'servers'} =
		join(" ", split(/\0/, $in{'servers'}));

	# Allowed actions
	$in{'actions'} eq '' && &error($text{'owner_eactions'});
	$owner->{'acl'}->{'actions'} =
		join(" ", split(/\0/, $in{'actions'}));

	# Create or update
	&save_system_owner($owner, $old);
	}

&redirect("list_owners.cgi");

