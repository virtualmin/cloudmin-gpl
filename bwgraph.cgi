#!/usr/local/bin/perl
# Show bandwidth usage for some or all systems with timeplot
# XXX period selector
# XXX option to show total / breakdown by system
# XXX option to show bar chart by system and limit over the month

require './server-manager-lib.pl';
if ($in{'id'}) {
	($server) = grep { $_->{'id'} eq $in{'id'} } &list_managed_servers();
	}
&ui_print_header(&server_in($server),
		 $text{'graph_title'}, "", undef, 0, 0, 0, undef,
		 "<script src='timeplot/timeplot-api.js?local'></script>",
		 "onload='onLoad();' onresize='onResize();'");
&ReadParse();

# Work out which mode we are in
if ($in{'id'}) {
	$mode = "server";
	}
else {
	$mode = $in{'mode'} || "systems";
	}
if ($mode ne "server") {
	# Show mode switcher
	@links = ( );
	foreach $m ("host", "total", "systems") {
		if ($mode eq $m) {
			push(@links, "<b>".$text{'bw_mode_'.$m}."</b>");
			}
		else {
			push(@links, "<a href='bwgraph.cgi?mode=$m&".
				     "ago=$in{'ago'}'>".
				     $text{'bw_mode_'.$m}."</a>");
			}
		}
	print $text{'bw_mode'}," ",&ui_links_row(\@links),"<br>\n";
	}

# Work out time range to show
$start = &bandwidth_period_start($in{'ago'});
$end = &bandwidth_period_end($in{'ago'});

# Period selector
# XXX

# Generic javascript start
print "<script>\n";
print "var timeplot;\n";
print "function onLoad() {\n";
print "  var eventSource = new Timeplot.DefaultEventSource();\n";
print "  var plotInfo = [\n";
$plotno = 1;

if ($in{'mode'} eq 'server') {
	# Show graph for one server, with limit
	print "    Timeplot.createPlotInfo({\n";
	print "      id: 'plot$plotno',\n";
	print "      dataSource: new Timeplot.ColumnSource(eventSource, $plotno),\n";
	print "      valueGeometry: new Timeplot.DefaultValueGeometry({\n";
	print "        gridColor: '#B3B6B0',\n";
	print "        axisLabelsPlacement: 'left',\n";
	print "        $maxopt\n";
	print "        min: 0\n";
	print "      }),\n";
	print "      timeGeometry: new Timeplot.DefaultTimeGeometry({\n";
	print "        gridColor: '#B3B6B0',\n";
	print "        axisLabelsPlacement: 'top'\n";
	print "      }),\n";
	print "      showValues: true,\n";
	print "      lineColor: '$color'\n";
	print "    })\n";
	$plotno++;
	}

elsif ($in{'mode'} eq 'total') {
	# Show total for all servers
	}

elsif ($in{'mode'} eq 'systems') {
	# Show bar chart of systems and limits
	}

# Generic javascript end
print "  ];\n";
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
