#!/usr/local/bin/perl
# Show bandwidth usage for some or all systems with timeplot
# XXX period selector
# XXX option to show total / breakdown by system
# XXX option to show bar chart by system and limit over the month
# XXX all modes
# XXX host mode?
# XXX scaling
# XXX option to show just the last hour

require './server-manager-lib.pl';
&ReadParse();

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
$dir = $in{'dir'} ? $in{'dir'} :
       $config{'bw_dir_in'} && $config{'bw_dir_out'} ? 'total' :
       $config{'bw_dir_in'} ? 'in' : 'out';
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
$start = &bandwidth_period_start($in{'ago'});
$end = &bandwidth_period_end($in{'ago'});
if ($in{'ago'} == 0) {
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
@agos = ( );
for($ago=0; $ago<24; $ago++) {
	$astart = &bandwidth_period_start($ago);
	$aend = &bandwidth_period_end($ago);
	last if ($aend < $oldest);
	push(@agos, [ $ago, &make_date($astart, 1)." - ".
			    &make_date($aend, 1) ]);
	}
print "<b>$text{'graph_ago'}</b> ",
      &ui_select("ago", $in{'ago'}, \@agos, 1, 0, 0, 0,
		 "onChange='form.submit()'"),"\n",
      &ui_submit($text{'graph_ok'}),"\n";
print &ui_form_end();

# The graph itself
print "</tr></table>\n";
print "<div id='history' style='height: 500px;'></div><br>\n";

# Direction mode
@dirs = ( [ "in", $text{'graph_in'} ],
	  [ "out", $text{'graph_out'} ] );
if ($config{'bw_dir_in'} && $config{'bw_dir_out'}) {
	push(@dirs, [ "total", $text{'graph_total'} ]);
	}
print &ui_form_start("bwgraph.cgi");
print &ui_hidden("mode", $mode);
print &ui_hidden("ago", $in{'ago'});
print &ui_hidden("id", $in{'id'});
print "<b>$text{'graph_dir'}</b> ",
      &ui_select("dir", $dir, \@dirs, 1, 0, 0, 0,
		 "onChange='form.submit()'"),"\n",
      &ui_submit($text{'graph_ok'}),"\n";
print &ui_form_end();

# XXX labels

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
	$c = $dir eq 'in' ? 1 : $dir eq 'out' ? 2 : 3;
	$lc = $dir eq 'in' ? '#ff0000' : $dir eq 'out' ? '#0000ff' : '#ff00ff';
	print "  var plotInfo = [\n";
	print "    Timeplot.createPlotInfo({\n";
	print "      id: 'out',\n";
	print "      dataSource: new Timeplot.ColumnSource(eventSource, $c),\n";
	print "      valueGeometry: vg,\n";
	print "      timeGeometry: tg,\n";
	print "      showValues: true,\n";
	print "      lineColor: '$lc'\n";
	print "    })\n";
	print "  ];\n";
	}

elsif ($mode eq 'systems') {
	# Show bar chart of systems and limits
	}

# Generic javascript end
print "  timeplot = Timeplot.create(document.getElementById('history'), plotInfo);\n";
print "  timeplot.loadText('bwgraph_data.cgi?id=$in{'id'}&mode=$mode&start=$start&end=$end&nice=1', ',', eventSource);\n";
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
