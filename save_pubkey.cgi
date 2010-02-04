#!/usr/local/bin/perl
# Create, update or delete an SSH public key

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParseMime();
if (!$in{'new'}) {
	($key) = grep { $_->{'id'} eq $in{'id'} } &list_ssh_keys();
	$key || &error($text{'key_egone'});
	}
&error_setup($text{'pubkey_err'});
&error_if_cloudmin_replica();

if ($in{'delete'}) {
	# Remove this SSH key
	&obtain_lock_anything();
	&delete_ssh_key($key);
	&webmin_log("delete", "key", $key->{'id'},
		    { 'desc' => $key->{'desc'} });
	}
elsif ($in{'new'}) {
	# Validate and/or generate
	$in{'desc'} =~ /\S/ || &error($text{'key_edesc'});
	$key = { 'desc' => $in{'desc'},
		 'external' => 0,
		 'public' => 1,
		 'addnew' => $in{'addnew'} };
	if ($in{'gen'} eq 1) {
		# In existing server-side file
		-r $in{'file'} || &error($text{'key_efile'});
		$data = &read_file_contents($in{'file'});
		&check_ssh_public_key_data($data) || &error($text{'key_efile2'});
		$key->{'file'} = $in{'file'};
		$key->{'external'} = 1;
		}
	elsif ($in{'gen'} eq 2) {
		# Uploaded file, to be stored by module
		&check_ssh_public_key_data($in{'upload'}) ||
			&error($text{'key_eupload'});
		$key->{'keydata'} = $in{'upload'};
		}
	elsif ($in{'gen'} eq 3) {
		# Pasted text
		$in{'data'} = &cleanup_key_data($in{'data'});
		&check_ssh_public_key_data($in{'data'}) ||
			&error($text{'key_edata'}." ".$in{'data'});
		$key->{'keydata'} = $in{'data'};
		}
	&obtain_lock_anything();
	&save_ssh_key($key);
	&webmin_log("create", "key", $key->{'id'},
		    { 'desc' => $key->{'desc'} });
	}
else {
	# Update
	$in{'desc'} =~ /\S/ || &error($text{'key_edesc'});
	$key->{'desc'} = $in{'desc'};
	$key->{'addnew'} = $in{'addnew'};
	if ($key->{'external'}) {
		# Change file
		-r $in{'file'} || &error($text{'key_efile'});
		$data = &read_file_contents($in{'file'});
		&check_ssh_public_key_data($data) ||
			&error($text{'key_efile2'});
		$key->{'file'} = $in{'file'};
		}
	elsif (defined($in{'data'})) {
		# Update key data
		$in{'data'} = &cleanup_key_data($in{'data'});
		&check_ssh_public_key_data($in{'data'}) ||
			&error($text{'key_edata'});
		$key->{'keydata'} = $in{'data'};
		}
	&obtain_lock_anything();
	&save_ssh_key($key);
	&webmin_log("modify", "key", $key->{'id'},
		    { 'desc' => $key->{'desc'} });
	}
&redirect("list_keys.cgi");

