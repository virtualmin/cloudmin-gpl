# Provide more system info blocks specific to Cloudmin

require 'server-manager-lib.pl';
use Time::Local;

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

# Details of managed systems
my @servers = &list_available_managed_servers_sorted();
if (@servers > 1) {
	my %c;
	foreach my $s (@servers) {
		$c{'all'}++;
		if (&is_parent_server($s)) {
			$c{'host'}++;
			}
		my $virt = &is_virtual_server($s);
		$c{$virt ? 'virt' : 'real'}++;
		if ($s->{'status'} eq 'alive' ||
		    &can_ssh_status($s)) {
			$c{'up'}++;
			}
		else {
			$c{'down'}++;
			}
		my $mfunc = "type_".$s->{'manager'}."_get_memory_size";
		if (defined(&$mfunc)) {
			my $mem = &$mfunc($s);
			if ($mem) {
				$c{'mem'} += $mem;
				}
			}
		my $dfunc = "type_".$s->{'manager'}."_get_disk_size";
		if (defined(&$dfunc)) {
			my $disk = &$dfunc($s);
			if ($disk) {
				$c{'disk'} += $disk;
				}
			}
		}
	my @table;
	foreach my $f ('all', 'host', 'virt', 'real', 'up', 'down',
		       'mem', 'disk') {
		push(@table, { 'desc' => $text{'right_vm2count'.$f},
			       'value' => $f eq 'mem' || $f eq 'disk' ?
					&nice_size($c{$f}) : int($c{$f}) });
		}
	push(@rv, { 'type' => 'table',
		    'id' => 'vm2servers',
		    'desc' => $text{'right_vm2serversheader'},
		    'table' => \@table });
	}

# XXX system owner info?

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

# Cloudmin licence info
my %sserial;
if (&read_env_file($licence_file, \%sserial) &&
    $sserial{'SerialNumber'} ne 'GPL' &&
    !$access{'owner'}) {
	my @table;  
        my $open = 0;

	# Serial and key
	push(@table, { 'desc' => $text{'right_sserial'},
		       'value' => $sserial{'SerialNumber'} });
	push(@table, { 'desc' =>  $text{'right_skey'},
		       'value' => $sserial{'LicenseKey'} });

	# Allowed system counts
	my %lstatus;
	&read_file($licence_status, \%lstatus);
	my @allservers = grep { &is_virtual_server($_) }
			      &list_managed_servers();
	push(@table, { 'desc' => $text{'right_vm2max'},
		       'value' => $lstatus{'servers'} > 0 ?
				    $lstatus{'servers'} :
				    $text{'right_vunlimited'} });
	push(@table, { 'desc' => $text{'right_vm2used'},
		       'value' => scalar(@allservers) });

	# Show license expiry date
	if ($lstatus{'expiry'} =~ /^203[2-8]-/) {
		push(@table, { 'desc' => $text{'right_expiry'},
			       'value' => $text{'right_expirynever'} });
		}
	elsif ($lstatus{'expiry'}) {
		push(@table, { 'desc' => $text{'right_expiry'},
			       'value' => $lstatus{'expiry'} });
		my $ltm = &parse_license_date($lstatus{'expiry'});
		if ($ltm) {
			my $days = int(($ltm - time()) / (24*60*60));
			push(@table, { 'desc' => $text{'right_expirydays'},
				       'value' => $days < 0 ?
					&text('right_expiryago', -$days) :
					$days });
			$open = 1 if ($days < 7);
			}
		}

	push(@rv, { 'type' => 'table',
	    'id' => 'serial',
	    'desc' => $text{'right_licenceheader'},
	    'open' => $open,
	    'table' => \@table });

	# XXX re-check licence link
	}

return @rv;
}

sub parse_license_date
{
my ($str) = @_;
if ($str =~ /^(\d{4})-(\d+)-(\d+)$/) {
        return eval { timelocal(0, 0, 0, $3, $2-1, $1-1900) };
        }
return undef;
}

1;
