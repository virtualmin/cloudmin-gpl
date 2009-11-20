#!/usr/local/bin/perl
# Show a list of systems on which KVM instances can be setup. These must be
# already registered physical systems.

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'kvms_title'}, "", "kvms");

@allservers = &list_managed_servers();
@canservers = grep { &can_host_kvm($_) } @allservers;
@kvms = grep { $_->{'kvm_host'} } @canservers;
@links = ( "<a href='edit_kvm.cgi?new=1'>$text{'kvms_add'}</a>" );
if (@kvms) {
	# Show table of systems configured to host kvms
	if (scalar(@canservers) <= scalar(@kvms)) {
		$addmsg = $text{'kvms_doneall'};
		@links = ( );
		}
	print &ui_form_start("set_default.cgi");
	print &ui_hidden("type", "kvm");
	print &ui_links_row(\@links);
	@tds = ( "width=5" );
	print &ui_columns_start([ "",
				  $text{'kvms_host'},
				  $text{'kvms_os'},
				  $text{'kvms_dir'},
				  $text{'kvms_users'} ]);
	foreach $s (@kvms) {
		@users = grep { $_->{'kvm_on'} eq $s->{'id'} }
			      @allservers;
		$users = @users == 0 ? $text{'kvms_nousers'} :
		    @users > 4 ? &text('kvms_manyusers', scalar(@users)) :
		    join("<br>", map { "<tt>$_->{'host'}</tt>" } @users);
		print &ui_columns_row([
		    &ui_oneradio("default", $s->{'id'}, "", $s->{'kvm_default'}),
		    "<a href='edit_kvm.cgi?id=$s->{'id'}'>$s->{'host'}</a>",
		    &describe_os($s->{'type'}),
		    "<tt>$s->{'kvm_dir'}</tt>",
		    "<a href='index.cgi?psearch=$s->{'id'}&pok=1'>$users</a>",
		    ], \@tds);
		}
	print &ui_columns_end();
	print &ui_links_row(\@links);
	print &ui_form_end([ [ undef, $text{'kvms_default'} ] ]);
	print "<b>$addmsg</b><p>\n" if ($addmsg);
	}
elsif (@canservers) {
	# Just show link to add
	print "<b>$text{'kvms_none'}</b><p>\n";
	print &ui_links_row(\@links);
	}
else {
	# Cannot do anything!
	print "<b>$text{'kvms_none2'}</b><p>\n";
	}

&ui_print_footer("", $text{'index_return'});

