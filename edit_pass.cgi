#!/usr/local/bin/perl
# Show a form for changing a server's actual passwords, or the passwords
# Cloudmin uses to login

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "pass");

# Work out if password can be changed
$pfunc = "type_".$server->{'manager'}."_can_password";
$canpass = !$in{'force'} &&
	   !$server->{'ssh_nologin'} &&
	   defined(&$pfunc) && &$pfunc($server);

# Work out if Cloudmin logs into the system or not
$haswebmin = ($server->{'status'} eq 'nowebminlogin' ||
	      $server->{'status'} eq 'novirt' ||
	      $server->{'status'} eq 'downwebmin' ||
	      $server->{'status'} eq 'virt' ||
	      $server->{'status'} eq 'nowebmin' &&
		$server->{'no_webmin_login'}) &&
	     $server->{'id'} != 0;
$sfunc = "type_".$server->{'manager'}."_no_ssh";
$hasssh = !defined(&$sfunc) || !&$sfunc();

&ui_print_header(&server_in($server), $text{'pass_title'}, "",
		 $canpass ? "pass" : "pass2");

if ($canpass) {
	print $text{'pass_desc'},"<p>\n";
	}
else {
	print $text{'pass_desc2'},"<p>\n";
	}

print &ui_form_start("save_pass.cgi", "post");
print &ui_hidden("id", $in{'id'});
$right = $canpass && ($haswebmin || $hasssh) ?
	"<a href='edit_pass.cgi?id=$in{'id'}&force=1'>$text{'pass_force'}</a>" :
	undef;
print &ui_table_start($text{'pass_header'}, undef, 2, undef, $right);

if ($canpass) {
	# Can change actual password
	print &ui_hidden("mode", 1);
	@keys = &list_ssh_keys();
	$passpop = $server->{'ssh_pass'} ? &show_password_popup($server, "ssh")
					 : undef;
	if (&can_action(undef, "sshkeys") && @keys) {
		# SSH password or key
		print &ui_table_row($text{'pass_ssh2'},
			&ui_radio_table("ssh_pass_def", 1,
			[ [ 1, $text{'pass_leave'}.$passpop ],
			  [ 0, $text{'pass_set'},
			    &ui_textbox("ssh_pass", undef, 20) ],
			  [ 2, $text{'pass_sshkey'},
			    &ssh_key_menu("ssh_key", undef, undef) ] ], 1));
		}
	else {
		# SSH password
		print &ui_table_row($text{'pass_ssh'},
			&ui_opt_textbox("ssh_pass", undef, 20,
					$text{'pass_leave'}.$passpop,
					$text{'pass_set'}));
		}

	# Webmin password
	if ($server->{'status'} eq 'virt' ||
	    $server->{'status'} eq 'novirt' ||
	    $server->{'status'} eq 'nowebminlogin') {
		$passpop = $server->{'pass'} ?
				&show_password_popup($server, "webmin") :
				undef;
		print &ui_table_row(&text('pass_webmin', $server->{'user'}),
			&ui_radio("webmin_pass_def",
				  $server->{'ssh_pass_same'} ? 2 : 1,
				  [ [ 1, $text{'pass_leave'}.$passpop ],
				    $server->{'user'} eq 'root' ? 
					( [ 2, $text{'pass_same'} ] ) : ( ),
				    [ 0, $text{'pass_set'} ] ])." ".
			&ui_textbox("webmin_pass", undef, 20));
		}
	}
else {
	# Can only change password used to login
	print &ui_hidden("mode", 0);

	if ($hasssh) {
		&show_ssh_login_form($server);

		$defmsg = $text{'default'};
		if ($config{'ssh_ciphers'}) {
			$defmsg .= " (".$config{'ssh_ciphers'}.")";
			}
		print &ui_table_row($text{'pass_ciphers'},
			&ui_select("ssh_ciphers", $server->{'ssh_ciphers'},
				[ [ "", $defmsg ],
				  map { [ $_->[0], $_->[0]." - ".$_->[1] ] }
				      &list_ssh_ciphers() ]));
		}

	if ($haswebmin) {
		&show_webmin_login_form($server);
		}
	}

# VNC password
$cfunc = "type_".$server->{'manager'}."_can_graphical_password";
if (defined(&$cfunc) && &$cfunc($server)) {
	$gfunc = "type_".$server->{'manager'}."_get_graphical_password";
	$pass = &$gfunc($server);
	$passpop = $pass ? &show_password_popup($server, "vnc") : undef;
	print &ui_table_row($text{'pass_vnc'},
		&ui_radio("vnc_def", 1,
		  [ [ 1, $pass ? $text{'pass_leave'}.$passpop
			       : $text{'pass_vnone'} ],
		    [ 0, $text{'pass_set'}." ".
			 &ui_textbox("vnc_pass", undef, 20) ] ]));
	}

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'pass_ok'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
