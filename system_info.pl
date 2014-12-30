# Provide more system info blocks specific to Cloudmin

require 'server-manager-lib.pl';

sub list_system_info
{
my ($data, $in) = @_;

# If user doesn't have access to Cloudmin, none of this makes sense
if (!&foreign_available($module_name)) {
	return ( );
	}

my @rv;

# Get own system info
my $me = &get_managed_server(0);
my $meinfo;
if ($me) {
	$meinfo = &get_server_collected($me);
	}
my (@poss, @allposs, @inst);
if ($meinfo && $meinfo->{'poss'}) {
	# Use own collected info
	@poss = @{$meinfo->{'poss'}};
	@allposs = @{$meinfo->{'allposs'}};
	@inst = @{$meinfo->{'inst'}};
	}
elsif ($hasposs) {
	# Get possible updates directly from security-updates module
	&foreign_require("security-updates");
	@poss = &list_possible_updates();
	@inst = &list_possible_installs();
	}

# Custom URL redirect
if ($data->{'alt'} && !$in{'noalt'}) {
	push(@rv, { 'type' => 'redirect',
		    'url' => $data->{'alt'} });
	}

# Warning messages
foreach my $warn (&list_warning_messages()) {
	push(@rv, { 'type' => 'warning',
		    'level' => 'warn',
		    'warning' => $warn });
	}

# Documentation links
my $doclink = "http://www.virtualmin.com/documentation/cloudmin";
push(@rv, { 'type' => 'link',
	    'priority' => 50,
	    'desc' => $text{'right_vm2docs'},
	    'target' => 'new',
	    'link' => $doclink });
if ($config{'docs_link'}) {
	push(@rv, { 'type' => 'link',
		    'priority' => 49,
		    'desc' => $text{'right_virtdocs2'},
		    'target' => 'new',
		    'link' => $config{'docs_link'} });
	}

# Virtualmin package updates
my $hasposs = foreign_check("security-updates");
my $canposs = foreign_available("security-updates");
if (!$data->{'noupdates'} && $hasposs && $canposs && @poss) {
	my $html = &ui_form_start("/security-updates/update.cgi");
	$html .= &text(@poss > 1 ? 'right_upcount' : 'right_upcount1',
		       scalar(@poss),
		       '/security-updates/index.cgi?mode=updates')."<p>\n";
	$html .= &ui_columns_start([ $text{'right_upname'},
                                     $text{'right_updesc'},
                                     $text{'right_upver'} ], "80%");
	foreach my $p (@poss) {
		$html .= &ui_columns_row([
			$p->{'name'}, $p->{'desc'}, $p->{'version'} ]);
		$html .= &ui_hidden("u", $p->{'update'}."/".$p->{'system'});
		}
	$html .= &ui_columns_end();
	$html .= &ui_form_end([ [ undef, $text{'right_upok'} ] ]);
	push(@rv, { 'type' => 'html',
		    'id' => 'updates',
		    'desc' => $text{'right_updatesheader'},
		    'html' => $html });
	}

# New features
my $newhtml = &get_new_features_html(undef);
if ($newhtml) {
	push(@rv, { 'type' => 'html',
		    'id' => 'newfeatures',
		    'open' => 1,
		    'desc' => $text{'right_newfeaturesheader'},
		    'html' => $newhtml });
	}

# Sections defined by plugins
foreach my $p (&list_plugin_sections()) {
	push(@rv, { 'type' => 'html',
		    'id' => 'plugin_'.$p->{'name'},
		    'desc' => $p->{'title'},
		    'html' => $p->{'html'},
		    'open' => $p->{'status'} });
	}

return @rv;
}

