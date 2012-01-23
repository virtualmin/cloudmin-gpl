#!/usr/local/bin/perl
# Create, update or delete an auto-scaling group

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($in{'delete'} ? $text{'scalegroup_err2'}
			   : $text{'scalegroup_err'});
&error_if_cloudmin_replica();

# Get the scalegroup being edited
if (!$in{'new'}) {
	$scalegroup = &get_scalegroup($in{'id'});
	$scalegroup || &error($text{'scalegroup_egone'});
	}

if ($in{'delete'} && $in{'confirm'}) {
	# Just delete the scalegroup
	&delete_scalegroup($scalegroup);
	&webmin_log("delete", "scalegroup", $scalegroup->{'id'},
		    { 'name' => $scalegroup->{'host'} });
	&redirect("list_scalegroups.cgi");
	}
elsif ($in{'delete'} && !$in{'confirm'}) {
	# Ask for confirmation first before deleting
	&ui_print_header(undef, $text{'dscalegroups_title'}, "");

	print &ui_confirmation_form("save_scalegroup.cgi",
		&text('scalegroup_drusure', "<tt>$scalegroup->{'host'}</tt>"),
		[ [ 'delete', 1 ],
		  [ 'id', $in{'id'} ] ],
		[ [ 'confirm', $text{'scalegroup_dok'} ] ],
		);

	&ui_print_footer("list_scalegroups.cgi", $text{'scalegroups_return'});
	}
else {
	# Validate inputs
	$scalegroup ||= { 'manager' => $in{'manager'},
			  'id' => &server_id() };

	# Group description
	$scalegroup->{'desc'} = $in{'desc'};

	# Min systems in group
	$in{'min'} =~ /^\d+$/ && $in{'min'} > 0 ||
		&error($text{'scalegroup_emin'});
	$scalegroup->{'min'} = $in{'min'};

	# Max systems in group
	$in{'max'} =~ /^\d+$/ && $in{'max'} >= $in{'min'} ||
		&error($text{'scalegroup_emax'});
	$scalegroup->{'max'} = $in{'max'};

	$scalegroup->{'enabled'} = $in{'enabled'};

	# Gap between changes
	$in{'gap'} =~ /^\d+$/ || &error($text{'scalegroup_egap'});
	$scalegroup->{'gap'} = &join_for_units($in{'gapunit'}, $in{'gap'});

	# Hostname template
	$in{'host'} =~ /^\S+$/ || &error($text{'scalegroup_ehost'});
	$in{'host'} =~ /\$NUM/i || $in{'host'} =~ /\$\{NUM\}/i ||
		&error($text{'scalegroup_ehostnum'});
	$scalegroup->{'host'} = $in{'host'};

	if ($scalegroup->{'manager'} eq 'ec2') {
		# EC2 account
		$scalegroup->{'ec2_account'} = $in{'ec2_account'};

		# AMI to create system from
		$in{'ec2_image'} =~ /^ami-(\S+)$/ ||
			&error($text{'ec2_eimage'});
		$scalegroup->{'ec2_image'} = $in{'ec2_image'};

		# SSH key
		$scalegroup->{'ec2_key'} = $in{'ec2_key'};

		# Instance size
		$scalegroup->{'ec2_size'} = $in{'ec2_size'};

		# Availability zone
		$scalegroup->{'ec2_azone'} = $in{'ec2_azone'};

		# VPC subnet
		$scalegroup->{'ec2_subnet'} = $in{'ec2_subnet'};
		}
	else {
		# System to clone
		$scalegroup->{'clone'} = $in{'clone'};

		# Possible host systems
		delete($scalegroup->{'dest_location'});
		delete($scalegroup->{'dest_hosts'});
		if ($in{'dest_mode'} == 1) {
			$in{'dest_hosts'} eq '' &&
				&error($text{'scalegroup_edesthosts'});
			$scalegroup->{'dest_hosts'} =
				join(" ", split(/\0/, $in{'dest_hosts'}));
			}
		elsif ($in{'dest_mode'} == 2) {
			$scalegroup->{'dest_location'} = $in{'dest_location'};
			}
		}

	# Parse scaling conditions
	foreach $sect ("conds", "downconds") {
		my @conds = ( );
		for(my $i=0; defined($in{$sect."_name_$i"}); $i++) {
			next if (!$in{$sect."_name_$i"});
			my $r = { 'name' => $in{$sect."_name_$i"} };
			if ($in{$sect."_over_$i"}) {
				$r->{'over'} = 1;
				}
			else {
				$r->{'under'} = 1;
				}
			$in{$sect."_value_$i"} =~ s/\s//g;
			$in{$sect."_value_$i"} =~ /^[0-9\.]+((K|M|G|T)B?)?$/i ||
				&error(&text('alert_evalue', $i+1));
			$r->{'value'} = $in{$sect."_value_$i"};
			$in{$sect."_for_$i"} =~ /^[0-9\.]+$/ ||
				&error(&text('alert_efor', $i+1));
			$r->{'for'} = &join_for_units(
				$in{$sect."_forunit_$i"}, $in{$sect."_for_$i"});
			if ($in{$sect."_count_${i}_def"}) {
				$r->{'count'} = 0;
				}
			else {
				$in{$sect."_count_$i"} =~ /^[0-9]+$/ &&
				    $in{$sect."_count_$i"} > 0 ||
					&error(&text('alert_ecount', $i+1));
				$r->{'count'} = $in{$sect."_count_$i"};
				}
			push(@conds, $r);
			}
		#@conds || &error($text{'scalegroup_econds'});
		$scalegroup->{$sect} = \@conds;
		$scalegroup->{$sect.'_and'} = $in{$sect.'_and'};
		$scalegroup->{$sect.'_or'} = !$in{$sect.'_and'};
		}
	delete($scalegroup->{'and'});
	delete($scalegroup->{'or'});

	# Parse email notification
	$scalegroup->{'notify_inc'} = $in{'notify_inc'};
	$scalegroup->{'notify_dec'} = $in{'notify_dec'};
	$scalegroup->{'notify_over'} = $in{'notify_over'};
	$scalegroup->{'master'} = $in{'master'};
	if ($in{'email'}) {
		$in{'emailto'} =~ /\S/ || &error($text{'alert_eemail'});
		$scalegroup->{'email'} = $in{'emailto'};
		}
	else {
		$scalegroup->{'email'} = '';
		}
	$in{'int'} =~ /^\d+$/ || &error($text{'alert_einterval'});
	$scalegroup->{'interval'} = &join_for_units($in{'intunit'}, $in{'int'});

	# Manually added systems
	@oldmanual = grep { $_->{'scalegroup_reason'} eq 'manual' }
		  &get_managed_server_by("scalegroup", $scalegroup->{'id'});
	@newmanualids = split(/\s+/, $in{'manual'});
	foreach $oldmember (@oldmanual) {
		if (&indexof($oldmember->{'id'}, @newmanual) < 0) {
			&obtain_lock_server($oldmember);
			delete($oldmember->{'scalegroup'});
			delete($oldmember->{'scalegroup_reason'});
			delete($oldmember->{'scalegroup_index'});
			&save_managed_server($oldmember);
			&release_lock_server($oldmember);
			}
		}
	foreach $id (@newmanualids) {
		my $newmember = &get_managed_server($id);
		if ($newmember && !$newmember->{'scalegroup'}) {
			&obtain_lock_server($newmember);
			$newmember->{'scalegroup'} = $scalegroup->{'id'};
			$newmember->{'scalegroup_reason'} = 'manual';
			&save_managed_server($newmember);
			&release_lock_server($newmember);
			}
		}
	$scalegroup->{'manual'} = join(" ", @newmanualids);

	# Save or create
	&save_scalegroup($scalegroup);
	&webmin_log($in{'new'} ? "create" : "modify", "scalegroup",
		    $scalegroup->{'id'},
		    { 'name' => $scalegroup->{'host'} });
	&redirect("list_scalegroups.cgi");
	}


