#!/usr/local/bin/perl
# Update the virtual CPUs on some system

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'vcpus_err'});
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "vcpus");

# Get the CPUs
$vfunc = "type_".$server->{'manager'}."_get_vcpus";
$cpus = &$vfunc($server);
ref($cpus) || &error(&text('vcpus_eget', $cpus));

# Parse inputs
@vcpus = ( );
@nums = split(/\0/, $in{'num'});
$n = 0;
foreach $i (@nums) {
	$cpu = { 'num' => $n++ };
	if (!$in{"pin_def_$i"}) {
		@pins = sort { $a <=> $b } split(/\0/, $in{"pin_$i"});
		@pins || &error(&text('vcpus_epinnone', $i));
		if (@pins == 1) {
			$cpu->{'pin'} = $pins[0];
			}
		else {
			# Must be in a range
			for($j=1; $j<@pins; $j++) {
				$pins[$j] == $pins[$j-1]+1 ||
					&error(&text('vcpus_epinrange', $i));
				}
			$cpu->{'pin'} = $pins[0]."-".$pins[$#pins];
			}
		}
	push(@vcpus, $cpu);
	}
@vcpus || &error($text{'vcpus_nonesel'});

&ui_print_unbuffered_header(&server_in($server), $text{'vcpus_title'}, "");
&obtain_lock_server($server);

# Apply on system
&$first_print($text{'vcpus_applying'});
$vfunc = "type_".$server->{'manager'}."_save_vcpus";
$err = &$vfunc($server, \@vcpus);
&save_managed_server($server);
&release_lock_server($server);
if ($err) {
	&$second_print(&text('vcpus_failed', $err));
	}
else {
	&$second_print($text{'create_done'});

	# Offer to reboot if needed
	$cfunc = "type_".$server->{'manager'}."_can_vcpus";
	if (&$cfunc($server) == 2 && $server->{'status'} ne 'down') {
		print &ui_form_start("save_serv.cgi");
		print &ui_hidden("id", $in{'id'});
		print &ui_hidden("reboot", 1);
		print &ui_hidden("confirm", 1);
		print "<b>$text{'vcpus_needreboot'}</b><p>\n";
		print &ui_form_end([ [ undef, $text{'limits_reboot'} ] ]);
		}

	&webmin_log("vcpus", "server", $server->{'host'});
	}

&ui_print_footer("", $text{'index_return'});

