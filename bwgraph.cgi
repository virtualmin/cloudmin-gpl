#!/usr/local/bin/perl
# Show bandwidth usage for some or all systems with timeplot
# XXX option to show bar chart by system and limit over the month
# XXX all modes
# XXX host mode?
# XXX test on IE

require './server-manager-lib.pl';
&ReadParse();
$color_mapping = { 'in', '#ff0000',
		   'out', '#0000ff',
		   'total', '#ff00ff' };

# Get the server being shown
@servers = &list_managed_servers();
if ($in{'id'}) {
	($server) = grep { $_->{'id'} eq $in{'id'} } @servers;
	@showservers = ( $server );
	}
else {
	@showservers = @servers;
	}

&ui_print_header(&server_in($server),
		 $text{'graph_title'}, "", undef, 0, 0, 0, undef,
		 "<script src='timeplot/timeplot-api.js?local'></script>",
		 "onload='onLoad();' onresize='onResize();'");

# Work out which mode we are in
if ($in{'id'}) {
	$mode = "server";
	}
else {
	$mode = $in{'mode'} || "systems";
	}
$dir = $in{'dir'} || 'inout';
if ($mode ne "server") {
	# Show mode switcher
	@links = ( );
	foreach $m ("host", "total", "systems") {
		if ($mode eq $m) {
			push(@links, "<b>".$text{'graph_mode_'.$m}."</b>");
			}
		else {
			push(@links, "<a href='bwgraph.cgi?mode=$m&".
				     "ago=$in{'ago'}'>".
				     $text{'graph_mode_'.$m}."</a>");
			}
		}
	print $text{'bw_mode'}," ",&ui_links_row(\@links),"<br>\n";
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
@dirs = $dir eq 'inout' ? ( 'in', 'out' ) : ( $dir );
foreach $d (@dirs) {
	$lc = $color_mapping->{$d};
	print "<font color=$lc>&bull;</font> ",
	      $text{'graph_'.$d}," ($units)\n";
	}
print "<br>\n";

# The graph itself
print "<div id='history' style='height: 500px;'></div><br>\n";

# Direction mode
@dirsel = ( [ "inout", $text{'graph_inout'}.$umsg ],
	    [ "in", $text{'graph_in'}.$umsg ],
	    [ "out", $text{'graph_out'}.$umsg ] );
if ($config{'bw_dir_in'} && $config{'bw_dir_out'}) {
	push(@dirsel, [ "total", $text{'graph_total'}.$umsg ]);
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
		print "      dataSource: new Timeplot.ColumnSource(eventSource, $c),\n";
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

elsif ($mode eq 'systems') {
	# Show bar chart of systems and limits
	}

# Generic javascript end
print "  timeplot = Timeplot.create(document.getElementById('history'), plotInfo);\n";
print "  timeplot.loadText('bwgraph_data.cgi?id=$in{'id'}&mode=$mode&start=$start&end=$end&scale=$scale', ',', eventSource);\n";
print "}\n";

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
