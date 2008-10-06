#!/usr/local/bin/perl
# Show a historic graph of one or more collected stats, on one or more systems
# XXX system chooser, by name, group or type
# XXX separate / average / total mode

require './virtual-server-lib.pl';
&can_show_history() || &error($text{'history_ecannot'});
&ReadParse();
@allservers = &list_managed_servers();

@history_periods = (
	[ 'year', 365*24*60*60 ],
	[ 'month', 31*24*60*60 ],
	[ 'week', 7*24*60*60 ],
	[ 'day', 24*60*60 ],
	[ 'hour', 60*60 ],
	);

&ui_print_header(undef, $text{'history_title'}, "", undef, 0, 0, 0, undef,
		 "<script src='timeplot/timeplot-api.js?local'></script>",
		 "onload='onLoad();' onresize='onResize();'");

# Show inputs for selecting systems
print &ui_form_start("historycgi");
print &show_search_form(\%in, \@allservers);

# Show inputs for graph mode
print "<b>$text{'history_mode'}</b>\n";
print &ui_radio("mode", $in{'mode'},
		[ [ "", $text{'history_mode_'} ],
		  [ "total", $text{'history_mode_total'} ],
		  [ "average", $text{'history_mode_average'} ] ]),"<br>\n";
print &ui_form_end();

# Get the systems
@servers = &apply_search_form(\%in, \@allservers);

# Build URL parameters
$in{'stat'} ||= "load";
$statsparams = "stat=$in{'stat'}";
foreach my $i (keys %in) {
	if ($i ne 'start' && $i ne 'period' && $i ne 'stat') {
		$statsparams .= "&$i=".&urlize($in{$i});
		}
	}

# Work out the stat and time range we want
$period = $in{'period'} || 24*60*60;
$start = $in{'start'} || time()-$period;
$end = $start + $period;
($first, $last) = &get_historic_first_last($in{'stat'}, \@servers);
if (!$first) {
	&ui_print_endpage($text{'history_none'});
	}
if ($end > $last) {
	# Too far in future .. shift back
	$start = $last-$period;
	$end = $start+$period;
	}

# Heading for stats being shown
# XXX
$maxes = &get_historic_maxes();
for($i=0; $i<@stats; $i++) {
	$color = $historic_graph_colors[$i % scalar(@historic_graph_colors)];
	$stat = $stats[$i];
	if ($stat eq 'memused' || $stat eq 'swapused') {
		$units = "MB";
		}
	elsif ($stat eq 'quotalimit' || $stat eq 'quotaused') {
		if ($maxes->{$stat} < 10*1024*1024*1024) {
			$units = "MB";
			}
		else {
			$units = "GB";
			}
		}
	elsif ($stat eq 'diskused') {
		$units = "GB";
		}
	elsif ($stat eq 'load' || $stat eq 'load5' || $stat eq 'load15') {
		$units = $text{'history_pc'};
		}
	else {
		$units = undef;
		}
	push(@statnames, "<font color=$color>".
			 $text{'history_stat_'.$stat}.
			 ($units ? " ($units)" : "").
			 "</font>");
	}
print "<b>",&text('history_showing', join(", ", @statnames)),"</b><p>\n";

# Move back links. The steps are 1, 2 and 4 times the period
print "<table cellpadding=0 cellspacing=0 width=100%><tr>\n";
print "<td align=left width=33%>";
@llinks = ( );
for($i=1; $i<=4; $i*=2) {
	$s = $i == 1 ? "" : "s";
	$msg = "&lt;&lt;".&text('history_'.&period_to_name($period).$s, $i);
	push(@llinks, "<a href='history.cgi?$statsparams&period=$period&".
		      "start=".($start-$period*$i)."'>$msg</a>");
	}
print &ui_links_row(\@llinks);
print "</td>\n";

# Time period links
@plinks = ( );
print "<td align=middle width=33%>";
foreach $p (map { [ $text{'history_'.$_->[0]}, $_->[1] ] } @history_periods) {
	if ($period == $p->[1]) {
		push(@plinks, "<b>$p->[0]</b>");
		}
	else {
		$nstart = $end - $p->[1];
		push(@plinks,"<a href='history.cgi?$statsparams&start=$nstart&".
			     "period=$p->[1]'>$p->[0]</a>");
		}
	}
print &ui_links_row(\@plinks);
print "</td>\n";

# Move forward links
print "<td align=right width=33%>";
@rlinks = ( );
for($i=1; $i<=4; $i*=2) {
	$s = $i == 1 ? "" : "s";
	next if ($start+$period*$i >= $last);	# Off the end
	$msg = &text('history_'.&period_to_name($period).$s, $i)."&gt;&gt;";
	push(@rlinks, "<a href='history.cgi?$statsparams&period=$period&".
		      "start=".($start+$period*$i)."'>$msg</a>");
	}
print &ui_links_row(\@rlinks);
print "</td>\n";
print "</tr></table>\n";

# The graph itself
print "<div id='history' style='height: 300px;'></div>\n";
print "<a href='history_data.cgi?$statsparams&start=$start&end=$end&nice=1'>".
      "$text{'history_rawdata'}</a><br>\n";

# Systems shown, with colours
@labels = ( );
if ($in{'mode'} eq 'total' || $in{'mode'} eq 'average') {
	push(@labels, [ $text{'history_label_'.$in{'mode'}},
			$historic_graph_colors[0] ]);
	}
else {
	for($i=0; $i<@servers; $i++) {
		push(@labels, [ $servers[$i]->{'host'},
				$historic_graph_colors[
				  $i % scalar(@historic_graph_colors)] ]);
		}
	}
@grid = map { "<font color=$l->[1]>$l->[0]</font>" } @labels;
print &ui_grid_table(\@grid, 100, 4,
	[ "width=25%", "width=25%", "width=25%", "width=25%" ]);

# Radio buttons for stats to show
print &ui_hr();
print "<b>$text{'history_showsel'}</b><br>\n";
print &ui_form_start("history.cgi");
foreach $i (keys %in) {
	if ($i ne 'stat') {
		print &ui_hidden($i, $in{$i});
		}
	}
@grid = ( );
foreach $s (sort { $text{'history_stat_'.$a} cmp
		   $text{'history_stat_'.$b} } &list_historic_stats()) {
	push(@grid, &ui_oneradio("stat", $s, $text{'history_stat_'.$s},
			   	 $s eq $in{'stat'}));
	}
print &ui_grid_table(\@grid, 4);
print &ui_form_end([ [ undef, $text{'history_ok'} ] ]);

# Javascript to generate the graph, with just one Y axis
print "<script>\n";
print "var timeplot;\n";
print "function onLoad() {\n";
print "  var eventSource = new Timeplot.DefaultEventSource();\n";
print "  var valueGeometry = new Timeplot.DefaultValueGeometry({\n";
print "        gridColor: '#B3B6B0',\n";
print "        axisLabelsPlacement: 'left',\n";
print "        $maxopt\n";	# XXX
print "        min: 0\n";
print "      });\n";
print "  var timeGeometry = new Timeplot.DefaultTimeGeometry({\n";
print "        gridColor: '#B3B6B0',\n";
print "        axisLabelsPlacement: 'top'\n";
print "      });\n";
print "  var plotInfo = [\n";
$plotno = 1;
foreach $label (@labels) {
	$color = $historic_graph_colors[
			($plotno-1) % scalar(@historic_graph_colors)];
	print "    Timeplot.createPlotInfo({\n";
	print "      id: 'plot$plotno',\n";
	print "      dataSource: new Timeplot.ColumnSource(eventSource, $plotno),\n";
	print "      valueGeometry: valuevalueGeometry,\n";
	print "      timeGeometry: timeGeometry,\n";
	print "      showValues: true,\n";
	print "      roundValues: false,\n";
	print "      lineColor: '$color'\n";
	if ($label eq $labels[$#labels]) {
		print "    })\n";
		}
	else {
		print "    }),\n";
		}
	$plotno++;
	}
print "  ];\n";
print "  timeplot = Timeplot.create(document.getElementById('history'), plotInfo);\n";
print "  timeplot.loadText('history_data.cgi?$statsparams&start=$start&end=$end&nice=1', ',', eventSource);\n";
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

sub period_to_name
{
local ($p) = @_;
foreach my $hp (@history_periods) {
	return $hp->[0] if ($p == $hp->[1]);
	}
return undef;
}
