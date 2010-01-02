#!/usr/local/bin/perl
# Save global email settings

require './server-manager-lib.pl';
&error_setup($text{'email_err'});
&can_action_error(undef, "global");
&foreign_require("mailboxes", "mailboxes-lib.pl");
&ReadParse();
&lock_file($module_config_file);
&lock_file($mailboxes::module_config_file);

# Save master admin email
$in{'master'} =~ /\S/ || &error($text{'email_emaster'});
$config{'bw_email'} = $in{'master'};

# Save SMTP server
if ($in{'smtp_def'}) {
	delete($mailboxes::config{'send_mode'});
	}
else {
	gethostbyname($in{'smtp'}) || &error($text{'email_esmtp'});
	$mailboxes::config{'send_mode'} = $in{'smtp'};
	}

# Save SMTP user and password
if ($in{'suser_def'}) {
	delete($mailboxes::config{'smtp_user'});
	delete($mailboxes::config{'smtp_pass'});
	}
else {
	$in{'suser'} =~ /^\S+$/ || &error($text{'email_esuser'});
	$in{'spass'} =~ /\S/ || &error($text{'email_espass'});
	$mailboxes::config{'smtp_user'} = $in{'suser'};
	$mailboxes::config{'smtp_pass'} = $in{'spass'};
	}

# Save from address
if ($in{'sfrom_def'}) {
	delete($config{'from_addr'});
	}
else {
	$in{'sfrom'} =~ /^\S+\@\S+$/ || &error($text{'email_esfrom'});
	$config{'from_addr'} = $in{'sfrom'};
	}

&save_module_config();
&save_module_config(\%mailboxes::config, "mailboxes");
&unlock_file($mailboxes::module_config_file);
&unlock_file($module_config_file);
&webmin_log("email");
&redirect("");

