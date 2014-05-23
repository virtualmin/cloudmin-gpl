#!/usr/local/bin/perl
# Show a list of systems on which KVM instances can be setup. These must be
# already registered physical systems.

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'kvms_title'}, "", "kvms");

@allservers = &list_managed_servers();
@canservers = grep { &can_host_kvm($_) } @allservers;
@kvms = grep { $_->{'kvm_host'} } @canservers;
if (@kvms) {
	# Show table of systems configured to host kvms
	print &ui_form_start("set_default.cgi");
	print &ui_hidden("type", "kvm");
	@tds = ( "width=5" );
	print &ui_columns_start([ "",
				  $text{'kvms_host'},
				  $text{'kvms_dir2'},
				  $text{'index_status'},
				  $text{'kvms_users2'},
				  $text{'kvms_ram'},
				  $text{'kvms_disk'}, ]);
	foreach $s (@kvms) {
		@users = grep { $_->{'kvm_on'} eq $s->{'id'} } @allservers;
		$iserver = $s->{'kvm_iscsi'} ne '' ?
			&get_managed_server($s->{'kvm_iscsi'}) : undef;
		print &ui_columns_row([
		    &ui_oneradio("default", $s->{'id'}, "",$s->{'kvm_default'}),
		    "<a href='edit_kvm.cgi?id=$s->{'id'}'>$s->{'host'}</a>",

		    $s->{'kvm_vg'} ? "LVM VG <tt>$s->{'kvm_vg'}</tt>" :
		      $iserver ? "iSCSI <tt>$iserver->{'host'}</tt>" :
		      "<tt>$s->{'kvm_dir'}</tt>",

		    &describe_status($s, 1, 0),

		    "<a href='index.cgi?psearch=$s->{'id'}&pok=1'>".
		      scalar(@users)."</a>",

		    &describe_host_memory($s, 'kvm'),
		    &describe_host_disk($s, 'kvm'),
		    ], \@tds);
		}
	print &ui_columns_end();
	print &ui_form_end([ [ undef, $text{'kvms_default'} ] ]);
	}
elsif (@canservers) {
	# Just show link to add
	print "<b>$text{'kvms_none'}</b><p>\n";
	}
else {
	# Cannot do anything!
	print "<b>$text{'kvms_none2'}</b><p>\n";
	}

# Show form to start adding a new host
&show_host_add_form("edit_kvm.cgi", \@canservers, \@kvms);

&ui_print_footer("", $text{'index_return'});

