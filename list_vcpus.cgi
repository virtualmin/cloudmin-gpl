#!/usr/local/bin/perl
# Show the virtual CPUs on some system

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "vcpus");

# Work out if we support just a number of VCPUs, or arbitrary pinning
$canvfunc = "type_".$server->{'manager'}."_can_vcpus";
$cansfunc = "type_".$server->{'manager'}."_can_smp";

if (defined(&$canvfunc) && &$canvfunc($server)) {
	# Arbitrary pinning supported

	# Get the CPUs
	$vfunc = "type_".$server->{'manager'}."_get_vcpus";
	$cpus = &$vfunc($server);
	ref($cpus) || &error(&text('vcpus_eget', $cpus));
	@$cpus || &error($text{'vcpus_enone'});

	# Get real CPUs on the host
	$pfunc = "type_".$server->{'manager'}."_list_pin_cpus";
	$pins = &$pfunc($server);
	@pinsel = map { [ $_->{'num'}, $_->{'num'}." - ".$_->{'desc'} ] }
		      @$pins;

	&ui_print_header(&server_in($server), $text{'vcpus_title'}, "","vcpus");

	@tds = ( "width=5% valign=top", "width=10% valign=top", "width=85%" );
	print &ui_form_start("save_vcpus.cgi", "post");
	print &ui_hidden("id", $in{'id'});
	print &ui_columns_start([ $text{'vcpus_enabled'},
				  $text{'vcpus_num'},
				  $text{'vcpus_pin'} ], undef, 0, \@tds);
	$i = 0;
	@cpuslist = @$cpus;
	while(scalar(@cpuslist) < scalar(@pinsel)) {
		push(@cpuslist, {});
		}
	foreach $cpu (@cpuslist) {
		@cpins = $cpu->{'pin'} =~ /^(\d+)\-(\d+)$/ ? ($1..$2) :
			 $cpu->{'pin'} =~ /^\d+$/ ? ( $cpu->{'pin'} ) : ( );
		print &ui_checked_columns_row([
			$cpu->{'num'} eq '' ? $i : $cpu->{'num'},
			&ui_radio("pin_def_$i",
				  $cpu->{'pin'} eq '' ? 1 : 0,
				  [ [ 1, $text{'vcpus_any'} ],
				    [ 0, $text{'vcpus_sel'} ] ])."<br>\n".
			&ui_select("pin_$i", \@cpins, \@pinsel,
				   scalar(@pinsel), 1),
			], \@tds, "num", $i, $cpu->{'num'} ne '');
		$i++;
		}
	print &ui_columns_end();
	print &ui_form_end([ [ undef, $text{'save'} ] ]);

	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}
elsif (defined(&$cansfunc) && &$cansfunc($server)) {
	# Only CPU count supported
	$sfunc = "type_".$server->{'manager'}."_get_smp";
	($smp, $cores) = &$sfunc($server);

	&ui_print_header(&server_in($server), $text{'vcpus_title'}, "",
			 "vcpus2");

	print &ui_form_start("save_vcpus.cgi", "post");
	print &ui_hidden("id", $in{'id'});
	print &ui_table_start($text{'vcpus_header'}, undef, 2);

	# Virtual CPUs
	print &ui_table_row($text{'vcpus_smp'},
		&ui_textbox("smp", $smp, 4));

	if (defined($cores)) {
		# Virtual cores
		print &ui_table_row($text{'vcpus_cores'},
			&ui_textbox("cores", $cores, 4));
		}

	# CPUs on host system
	$vhost = &get_parent_server($server);
	$hostcores = &list_server_cpus($vhost);
	if (ref($hostcores)) {
		print &ui_table_row($text{'vcpus_host'},
			join("<br>\n", map { $_->{'desc'} } @$hostcores));
		}

	print &ui_table_end();
	print &ui_form_end([ [ undef, $text{'save'} ] ]);

	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}
else {
	&error("VCPUs not supported!");
	}

