#!/usr/local/bin/perl
# Show the virtual CPUs on some system

require './server-manager-lib.pl';
&ReadParse();
@servers = &list_managed_servers();
($server) = grep { $_->{'id'} == $in{'id'} } @servers;
$server || &error($text{'edit_egone'});

# Get the CPUs
$vfunc = "type_".$server->{'manager'}."_get_vcpus";
$cpus = &$vfunc($server);
ref($cpus) || &error(&text('vcpus_eget', $cpus));
@$cpus || &error($text{'vcpus_enone'});

# Get real CPUs
$pfunc = "type_".$server->{'manager'}."_list_pin_cpus";
$pins = &$pfunc($server);
@pinsel = map { [ $_->{'num'}, $_->{'num'}." - ".$_->{'desc'} ] } @$pins;

&ui_print_header(&server_in($server), $text{'vcpus_title'}, "", "vcpus");

@tds = ( "width=5% valign=top", "width=10% valign=top", "width=85%" );
print &ui_form_start("save_vcpus.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_columns_start([ $text{'vcpus_enabled'},
			  $text{'vcpus_num'},
			  $text{'vcpus_pin'} ], undef, 0, \@tds);
$i = 0;
foreach $cpu (@$cpus, { }) {
	@cpins = $cpu->{'pin'} =~ /^(\d+)\-(\d+)$/ ? ($1..$2) :
		 $cpu->{'pin'} =~ /^\d+$/ ? ( $cpu->{'pin'} ) : ( );
	print &ui_checked_columns_row([
		$cpu->{'num'} eq '' ? $i : $cpu->{'num'},
		&ui_radio("pin_def_$i",
			  $cpu->{'pin'} eq '' ? 1 : 0,
			  [ [ 1, $text{'vcpus_any'} ],
			    [ 0, $text{'vcpus_sel'} ] ])."<br>\n".
		&ui_select("pin_$i", \@cpins, \@pinsel, scalar(@pinsel), 1),
		], \@tds, "num", $i, $cpu->{'num'} ne '');
	$i++;
	}
print &ui_columns_end();
print &ui_form_end([ [ undef, $text{'save'} ] ]);

&ui_print_footer("", $text{'index_return'});

