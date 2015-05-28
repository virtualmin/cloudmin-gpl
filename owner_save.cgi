#!/usr/local/bin/perl
# Update a system owner's password and email

require './server-manager-lib.pl';
&error_setup($text{'oform_err'});
&error_if_cloudmin_replica();
$access{'owner'} || &error($text{'oform_ecannot'});
$owner = &get_system_owner($base_remote_user);
$owner || &error($text{'oform_eowner'});
$old = { %$owner };
&ReadParse();

# Validate inputs
if (!$in{'opass_def'}) {
	$in{'opass'} =~ /\S/ || &error($text{'owner_epass'});
	$in{'opass'} =~ /:/ && &error($text{'owner_epass2'});
	$owner->{'pass'} = &acl::encrypt_password($in{'opass'});
	}
$in{'email'} =~ /^\S+\@\S+$/ || &error($text{'owner_eemail'});
$owner->{'acl'}->{'email'} = $in{'email'};
if (!$config{'noowner_lang'}) {
	if ($in{'lang'}) {
		$owner->{'lang'} = $in{'lang'};
		}
	else {
		delete($owner->{'lang'});
		}
	}

# Save him
&save_system_owner($owner, $old);
&webmin_log("modify", "owner", $owner->{'name'});
&redirect("");

