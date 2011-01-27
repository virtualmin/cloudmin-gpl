#!/usr/local/bin/perl
# Show bandwidth usage for some or all systems with timeplot

require './server-manager-lib.pl';
&ReadParse();
$color_mapping = { 'in', '#ff0000',
		   'out', '#0000ff',
		   'total', '#ff00ff' };
$bar_width = 100;

# Work out which mode we are in
if ($in{'id'}) {
	$mode = "server";
	}
elsif ($in{'owner'}) {
	$mode = "owner";
	}
else {
	$mode = $in{'mode'} || "systems";
	}
$dir = $in{'dir'} ? $in{'dir'} :
       $mode eq 'systems' || $mode eq 'host' ? 'total' : 'inout';

# Get the server being shown
@servers = &list_managed_servers();
if ($in{'id'}) {
	# One server
	($server) = grep { $_->{'id'} eq $in{'id'} } @servers;
	$server || &error($text{'graph_eserver'});
	@showservers = ( $server );
	$title = &server_in($server);
	}
elsif ($in{'owner'}) {
	# Servers for some owner
	&can_action_error(undef, "global");
	$owner = &get_system_owner($in{'owner'});
	$owner || &error($text{'graph_eowner'});
	@showservers = &get_owner_servers($owner);
	$title = &text('graph_owner', "<tt>$owner->{'name'}</tt>");
	}
elsif ($mode eq 'host') {
	# Servers that can host
	@showservers = grep { &is_parent_server($_) } @servers;
	}
else {
	# Servers with bandwidth
	@showservers = grep { $rfunc = "type_".$_->{'manager'}."_real_interfaces"; defined(&$rfunc) } @servers;
	if ($mode eq 'total') {
		# Limit to virtual systems
		@showservers = grep { &get_parent_server($_) } @showservers;
		}
	}
&can_action_error(\@showservers, "graph");

&ui_print_header($title,
		 $text{'graph_title'}, "", undef, 0, 0, 0, undef,
		 "<script src='timeplot/timeplot-api.js?local'></script>",
		 "onload='onLoad();' onresize='onResize();'");

if ($mode ne "server" && $mode ne "owner") {
	# Show mode switcher (systems separate, by host system, total)
	@links = ( );
	foreach $m ("systems", "host", "total") {
		if ($mode eq $m) {
			push(@links, "<b>".$text{'graph_mode_'.$m}."</b>");
			}
		else {
			push(@links, "<a href='bwgraph.cgi?mode=$m&".
				     "ago=$in{'ago'}&units=$in{'units'}&".
				     "empty=$in{'empty'}'>".
				     $text{'graph_mode_'.$m}."</a>");
			}
		}
	print $text{'graph_mode'}," ",&ui_links_row(\@links);
	}

# Work out age of oldest server
$oldest = undef;
foreach $s (@showservers) {
	$oldest = $s->{'created'}
		if ($s->{'created'} &&
		    (!defined($oldest) || $s->{'created'} < $oldest));
	}

# Work out time range to show
if ($in{'ago'} == -1) {
	# Special mode - last hour
	$end = int(time()/60)*60;
	$start = $end - 3600;
	}
elsif ($in{'ago'} == -2) {
	# Last day
	$end = int(time()/60)*60;
	$start = $end - 24*3600;
	}
else {
	# Some accounting period
	$start = &bandwidth_period_start($in{'ago'});
	$end = &bandwidth_period_end($in{'ago'});
	}
if ($in{'ago'} <= 0) {
	# End shouldn't be later than last collection
	$max_last = 0;
	foreach $s (@showservers) {
		$lt = &get_bandwidth_time($s);
		$max_last = $lt if ($lt > $max_last);
		}
	if ($end > $max_last && $max_last) {
		$end = $max_last;
		}
	}

# Period selector
print &ui_form_start("bwgraph.cgi");
print &ui_hidden("mode", $mode);
print &ui_hidden("owner", $in{'owner'});
print &ui_hidden("dir", $dir);
print &ui_hidden("id", $in{'id'});
print &ui_hidden("log", $in{'log'});
print &ui_hidden("units", $in{'units'});
print &ui_hidden("empty", $in{'empty'});
@agos = ( [ -1, $text{'graph_lasthour'} ],
	  [ -2, $text{'graph_lastday'} ] );
for($ago=0; $ago<24; $ago++) {
	$astart = &bandwidth_period_start($ago);
	$aend = &bandwidth_period_end($ago);
	last if ($aend < $oldest);
	push(@agos, [ $ago, &make_date($astart, 1)." - ".
			    &make_date($aend, 1) ]);
	}
print "<b>$text{'graph_ago'}</b> ",
      &ui_select("ago", $in{'ago'} || 0, \@agos, 1, 0, 0, 0,
		 "onChange='form.submit()'"),"\n",
      &ui_submit($text{'graph_ok'}),"\n";
print &ui_form_end();

# Work out range size
$range = $end - $start;
if ($range > 24*60*60) {
	# By hour
	$step = 3600;
	$prefix = "hour";
	}
else {
	# By minute
	$step = 60;
	$prefix = "min";
	}

# Work out units, based on average of graphed systems
if ($mode ne 'systems' && $mode ne 'host') {
	$utotal = 0;
	if ($in{'ago'} < 0) {
		# Get total over last hour or day
		my ($stotal, $scount);
		foreach $s (@showservers) {
			$b = &get_bandwidth($s);
			for($i=$start; $i<=$end; $i+=$step) {
				if ($dir eq 'in') {
					$stotal += $b->{$prefix.'_in_'.$i};
					}
				elsif ($dir eq 'out') {
					$stotal += $b->{$prefix.'_out_'.$i};
					}
				elsif ($dir eq 'total') {
					$stotal += $b->{$prefix.'_in_'.$i} +
						   $b->{$prefix.'_out_'.$i};
					}
				else {
					$stotal += ($b->{$prefix.'_in_'.$i} +
						    $b->{$prefix.'_out_'.$i})/2;
					}
				$scount++;
				}
			if ($scount) {
				$utotal += $stotal / $scount;
				}
			}
		}
	else {
		# Get usage over for the current accounting period
		$ufield = $dir eq 'in' ? 'bw_usage_in' :
			  $dir eq 'out' ? 'bw_usage_out' : 'bw_usage';
		foreach $s (@showservers) {
			$utotal += $s->{$ufield};
			}
		}

	# Convert to average
	$utotal /= scalar(@showservers) if ($mode ne 'total');
	if ($utotal > 10*1024*1024*1024) {
		$scale = 1024*1024*1024;
		$units = "GB";
		}
	elsif ($utotal > 10*1024*1024) {
		$scale = 1024*1024;
		$units = "MB";
		}
	elsif ($utotal > 10*1024) {
		$scale = 1024;
		$units = "kB";
		}
	else {
		$scale = 1;
		$units = "bytes";
		}
	}

# Labels
if ($mode eq 'systems' || $mode eq 'host') {
	# One direction and limit
	print "<font color=#ff0000>&bull;</font> ",
	      $text{'graph_'.$dir},"\n";
	if ($mode eq 'systems') {
		print "<font color=#0000ff>&bull;</font> ",
		      $text{'graph_limit'},"\n";
		}
	}
else {
	@dirs = $dir eq 'inout' ? ( 'in', 'out' ) : ( $dir );
	foreach $d (@dirs) {
		$lc = $color_mapping->{$d};
		print "<font color=$lc>&bull;</font> ",
		      $text{'graph_'.$d}," ($units/minute)\n";
		}
	}
print "<br>\n";

if ($mode ne "systems" && $mode ne "host") {
	# The time graph itself
	$datalink = "bwgraph_data.cgi?id=$in{'id'}&mode=$mode&start=$start&end=$end&scale=$scale&owner=$in{'owner'}";
	print "<div id='history' style='height: 500px;'></div>\n";
	print "<a href='$datalink'>$text{'graph_raw'}</a><br>\n";
	}
else {
	# A bar chart by system .. first need to work out usage for each one
	$bwmap = { };
	$max_total = 0;
	foreach $s (@showservers) {
		my $b = { 'in' => 0, 'out' => 0 };
		@adding = ( );
		if ($mode eq 'systems') {
			# This system's bandwidth
			@adding = ( $s );
			}
		else {
			# All hosted systems
			@adding = &list_child_servers($s);
			}
		foreach $as (@adding) {
			$bwinfo = &get_bandwidth($as);
			for($hh=$start; $hh<$end; $hh+=$step) {
				$b->{'in'} += $bwinfo->{$prefix.'_in_'.$hh};
				$b->{'out'} += $bwinfo->{$prefix.'_out_'.$hh};
				}
			}
		$b->{'total'} = $b->{'in'} + $b->{'out'};
		$max_total = $b->{$dir} if ($b->{$dir} > $max_total);
		$max_total = $s->{'bw_limit'} if ($s->{'bw_limit'} >$max_total);
		$bwmap->{$s->{'id'}} = $b;
		}

	# Sort by usage, and show
	@showservers = sort { $bwmap->{$b->{'id'}}->{$dir} <=>
			      $bwmap->{$a->{'id'}}->{$dir} } @showservers;
	print "<table width=100%>\n";
	foreach $s (@showservers) {
		$b = $bwmap->{$s->{'id'}};
		if ($in{'empty'} && !$b->{$dir}) {
			# No usage, so skip
			next;
			}

		# System name
		print "<tr>\n";
		print "<td width=20%><a href='bwgraph.cgi?id=$s->{'id'}&",
		      "ago=$in{'ago'}'>$s->{'short_host'}</a></td>\n";

		# Usage and limit
		print "<td width=5% nowrap>",
		      &nice_size_units($b->{$dir}),"</td>\n";
		if ($mode ne 'host') {
			# Only show limit for specific hosts
			print "<td>&nbsp;/&nbsp;</td>\n";
			print "<td width=5% nowrap>",
			  ($s->{'bw_limit'} ? &nice_size_units($s->{'bw_limit'})
			  	            : $text{'graph_unlimit'}),"</td>\n";
			}

		# Bar chart
		print "<td>&nbsp;&nbsp;</td>\n";
		print "<td width=70%>";
		if ($max_total && ($b->{$dir} || $s->{'bw_limit'})) {
			if ($s->{'bw_limit'} && $b->{$dir} > $s->{'bw_limit'}) {
				# Over limit, show usage in purple
				print &bar_chart_three($max_total,
					0, $b->{$dir}, 0);
				}
			elsif (!$s->{'bw_limit'}) {
				# No limit
				print &bar_chart_three($max_total,
					$b->{$dir}, 0, 0);
				}
			else {
				# Show usage and limit
				print &bar_chart_three($max_total,
					$b->{$dir}, 0,
					$s->{'bw_limit'} - $b->{$dir});
				}
			}
		print "</td>\n";

		print "</tr>\n";
		}
	print "</table><br>\n";
	}

if ($mode ne "systems" && $mode ne "host") {
	# Form to change direction and axis scaling
	@dirsel = ( );
	if ($mode ne 'systems') {
		push(@dirsel, [ "inout", $text{'graph_inout'} ]);
		}
	push(@dirsel, [ "in", $text{'graph_in'} ],
		      [ "out", $text{'graph_out'} ] );
	if ($config{'bw_dir_in'} && $config{'bw_dir_out'}) {
		push(@dirsel, [ "total", $text{'graph_total'} ]);
		}
	print &ui_form_start("bwgraph.cgi");
	print &ui_hidden("mode", $mode);
	print &ui_hidden("owner", $in{'owner'});
	print &ui_hidden("ago", $in{'ago'});
	print &ui_hidden("id", $in{'id'});
	print &ui_hidden("units", $in{'units'});
	print &ui_hidden("empty", $in{'empty'});
	print &ui_table_start(undef, undef, 2);

	# Direction mode
	print &ui_table_row($text{'graph_dir'},
	      &ui_select("dir", $dir, \@dirsel, 1, 0, 0, 0,
			 "onChange='form.submit()'")." ".
	      &ui_submit($text{'graph_ok'}));

	# Log or integer mode
	if ($mode ne "system") {
		print &ui_table_row($text{'graph_log'},
		      &ui_radio("log", int($in{'log'}),
				[ [ 0, $text{'graph_log0'} ],
				  [ 1, $text{'graph_log1'} ] ]));
		}

	print &ui_table_end();
	print &ui_form_end();
	}
else {
	# Form to change units
	print &ui_form_start("bwgraph.cgi");
	print &ui_hidden("mode", $mode);
	print &ui_hidden("owner", $in{'owner'});
	print &ui_hidden("ago", $in{'ago'});
	print &ui_table_start(undef, undef, 2);

	# Units
	print &ui_table_row($text{'graph_units'},
		&ui_select("units", $in{'units'},
			   [ [ "", $text{'graph_unitsauto'} ],
			     map { [ $_, $text{'graph_units'.$_} ] }
				 ( 1, 1024, 1024*1024, 1024*1024*1024 ) ])." ".
		&ui_submit($text{'graph_ok'}));

	# Show systems with no traffic?
	print &ui_table_row($text{'graph_empty'},
		&ui_yesno_radio("empty", $in{'empty'}));

	print &ui_table_end();
	print &ui_form_end();
	}

# Generic javascript start
if ($mode ne "system") {
	print "<script>\n";
	print "var timeplot;\n";
	print "function onLoad() {\n";
	print "  var eventSource = new Timeplot.DefaultEventSource();\n";
	$plotno = 1;

	# Show graph for one or all servers, with limit
	$geom = $in{'log'} ? 'LogarithmicValueGeometry'
			   : 'DefaultValueGeometry';
	print "  var vg = new Timeplot.${geom}({\n";
	print "        gridColor: '#B3B6B0',\n";
	print "        axisLabelsPlacement: 'left',\n";
	print "        min: 0\n";
	print "      });\n";
	print "  var tg = new Timeplot.DefaultTimeGeometry({\n";
	print "        gridColor: '#B3B6B0',\n";
	print "        axisLabelsPlacement: 'top'\n";
	print "      });\n";
	print "  var plotInfo = [\n";
	foreach $d (@dirs) {
		$c = $d eq 'in' ? 1 : $d eq 'out' ? 2 : 3;
		$lc = $color_mapping->{$d};
		print "    Timeplot.createPlotInfo({\n";
		print "      id: '$d',\n";
		print "      dataSource: ",
		      "new Timeplot.ColumnSource(eventSource, $c),\n";
		print "      valueGeometry: vg,\n";
		print "      timeGeometry: tg,\n";
		print "      showValues: true,\n";
		print "      lineColor: '$lc'\n";
		if ($d eq $dirs[$#dirs]) {
			print "    })\n";
			}
		else {
			print "    }),\n";
			}
		}
	print "  ];\n";

	# Generic javascript end
	print "  timeplot = Timeplot.create(document.getElementById('history'), plotInfo);\n";
	print "  timeplot.loadText('$datalink', ',', eventSource);\n";
	print "}\n";
	}

# Resize handler Javascript
print <<EOF;
var resizeTimerID = null;
function onResize() {
    if (resizeTimerID == null) {
        resizeTimerID = window.setTimeout(function() {
            resizeTimerID = null;
            timeplot.repaint();
        }, 100);
    }
}
</script>
EOF

if ($in{'id'}) {
	if ($server && defined(&theme_select_server)) {
		&theme_select_server($server);
		}
	&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
	}
else {
	&ui_print_footer("", $text{'index_return'});
	}

# bar_chart(total, used, blue-rest)
# Returns HTML for a bar chart of a single value
sub bar_chart
{
my ($total, $used, $blue) = @_;
my $rv;
$rv .= sprintf "<div class='barchart'><img src=images/red.gif width=%s%% height=12px>",
  int($bar_width*$used/$total);
if ($blue) {
  $rv .= sprintf "<img src=images/blue.gif width=%s%% height=12px></div>",
    $bar_width - int($bar_width*$used/$total);
  }
else {
  $rv .= sprintf "<img src=images/white.gif width=%s%% height=12px></div>",
    $bar_width - int($bar_width*$used/$total);
  }
return $rv;
}

# bar_chart_three(total, used1, used2, used3)
# Returns HTML for a bar chart of three values, stacked
sub bar_chart_three
{
my ($total, $used1, $used2, $used3) = @_;
my $rv;
my $w1 = int($bar_width*$used1/$total);
my $w2 = int($bar_width*$used2/$total);
my $w3 = int($bar_width*$used3/$total);
if ($w1) { $w1++; }
elsif ($w2) { $w2++; }
elsif ($w3) { $w3++; }
$w1 = 100 if ($w1 > 100);
$w2 = 100 if ($w2 > 100);
$w3 = 100 if ($w3 > 100);
my $w4 = int($bar_width - $w1 - $w2 - $w3);
$w4 = 100 if ($w4 > 100);
$rv .= "<div class='barchart' nowrap='nowrap'>";
if ($w1) {$rv .= sprintf "<img src=images/red.gif width=%s%% height=12px>", $w1;}
if ($w2) {$rv .= sprintf "<img src=images/purple.gif width=%s%% height=12px>", $w2;}
if ($w3) {$rv .= sprintf "<img src=images/blue.gif width=%s%% height=12px>", $w3;}
if ($w4) {$rv .= sprintf "<img src=images/grey.gif width=%s%% height=12px>", $w4;}
$rv .= "</div>";
return $rv;
}

# nice_size_units(num)
# Convert some number into the selected units, or a nice size
sub nice_size_units
{
local ($n) = @_;
if (!$in{'units'}) {
	return &nice_size($n);
	}
else {
	return int($n / $in{'units'})." ".$text{'graph_units'.$in{'units'}};
	}
}
