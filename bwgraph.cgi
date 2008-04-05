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
	@showservers = ( $server );
	}
elsif ($mode eq 'host') {
	# Servers that can host
	@showservers = grep { &is_parent_server($_) } @servers;
	}
else {
	# Servers with bandwidth
	@showservers = grep { $rfunc = "type_".$_->{'manager'}."_real_interfaces"; defined(&$rfunc) } @servers;
	}

&ui_print_header(&server_in($server),
		 $text{'graph_title'}, "", undef, 0, 0, 0, undef,
		 "<script src='timeplot/timeplot-api.js?local'></script>",
		 "onload='onLoad();' onresize='onResize();'");

if ($mode ne "server") {
	# Show mode switcher
	@links = ( );
	foreach $m ("systems", "host", "total") {
		if ($mode eq $m) {
			push(@links, "<b>".$text{'graph_mode_'.$m}."</b>");
			}
		else {
			push(@links, "<a href='bwgraph.cgi?mode=$m&".
				     "ago=$in{'ago'}'>".
				     $text{'graph_mode_'.$m}."</a>");
			}
		}
	print $text{'graph_mode'}," ",&ui_links_row(\@links),"<br>\n";
	}

# Work out age of oldest server
$oldest = undef;
foreach $s (@showservers) {
	$oldest = $s->{'created'}
		if ($s->{'created'} &&
		    (!defined($oldest) || $s->{'created'} < $oldtest));
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
print &ui_hidden("dir", $dir);
print &ui_hidden("id", $in{'id'});
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
$utotal = 0;
$ufield = $dir eq 'in' ? 'bw_usage_in' :
	  $dir eq 'out' ? 'bw_usage_out' : 'bw_usage';
foreach $s (@showservers) {
	$utotal += $s->{$ufield} / $step;
	}
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
		      $text{'graph_'.$d}," ($units)\n";
		}
	}
print "<br>\n";

if ($mode ne "systems" && $mode ne "host") {
	# The time graph itself
	print "<div id='history' style='height: 500px;'></div><br>\n";
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
		print "<tr>\n";
		print "<td width=20%><a href='edit_serv.cgi?id=$s->{'id'}'>",
		      $s->{'short_host'}."</a></td>\n";
		print "<td width=70%>";
		if ($max_total && ($b->{$dir} || $s->{'bw_limit'})) {
			print &bar_chart($max_total, $b->{$dir},
					 $s->{'bw_limit'} ? 1 : 0);
			}
		print "</td>\n";
		print "<td width=5% nowrap>",&nice_size($b->{$dir}),"</td>\n";
		if ($mode ne 'host') {
			# Only show limit for specific hosts
			print "<td>/</td>\n";
			print "<td width=5% nowrap>",
				($s->{'bw_limit'} ? &nice_size($s->{'bw_limit'})
					  : $text{'graph_unlimit'}),"</td>\n";
			}
		print "</tr>\n";
		}
	print "</table>\n";
	}

# Direction mode
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
print &ui_hidden("ago", $in{'ago'});
print &ui_hidden("id", $in{'id'});
print "<b>$text{'graph_dir'}</b> ",
      &ui_select("dir", $dir, \@dirsel, 1, 0, 0, 0,
		 "onChange='form.submit()'"),"\n",
      &ui_submit($text{'graph_ok'}),"\n";
print &ui_form_end();

# Generic javascript start
if ($mode ne "system") {
	print "<script>\n";
	print "var timeplot;\n";
	print "function onLoad() {\n";
	print "  var eventSource = new Timeplot.DefaultEventSource();\n";
	$plotno = 1;

	if ($mode eq 'server' || $mode eq 'total') {
		# Show graph for one server, with limit
		print "  var vg = new Timeplot.DefaultValueGeometry({\n";
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
		}

	# Generic javascript end
	print "  timeplot = Timeplot.create(document.getElementById('history'), plotInfo);\n";
	print "  timeplot.loadText('bwgraph_data.cgi?id=$in{'id'}&mode=$mode&start=$start&end=$end&scale=$scale', ',', eventSource);\n";
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
&ui_print_footer("", $text{'index_return'});

# bar_chart(total, used, blue-rest)
# Returns HTML for a bar chart of a single value
sub bar_chart
{
local ($total, $used, $blue) = @_;
local $rv;
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


