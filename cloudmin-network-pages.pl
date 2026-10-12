# Networking pages use Webmin's native widgets.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Share column selection and timeout defaults with the configuration editor.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-config-lib.pl'));
our (%text);

# network_page_tab(value)
# Accepts inventory tabs, defaulting to the overview on an ordinary page visit.
sub network_page_tab
{
my ($value) = @_;
return defined($value) && $value =~ /\A(?:networks|bridges|interfaces)\z/ ? $value : 'overview';
}

# network_form(action, token, [fields])
# Starts an independent POST form that returns to the relevant inventory tab.
sub network_form
{
my ($action, $token, $fields) = @_;
my %values = (%{$fields || {}});
$values{'tab'} ||= $action =~ /\A(?:bridge|confirm|rollback)/ ? 'bridges' : 'networks';
return ui_form_start('networks.cgi', 'post').ui_hidden('action', $action).
	ui_hidden('token', $token).join('', map { ui_hidden($_, $values{$_}) } sort keys %values);
}

# network_values(values, [empty])
# Keeps addresses on separate lines, wrapping long IPv6 values only when needed.
sub network_values
{
my ($values, $empty) = @_;
return ui_tag('span', html_escape($empty || $text{'net_none'}),
	{ class => 'cloudmin-network-muted' }) if (!@$values);
return join('', map { ui_tag('span', html_escape($_),
	{ class => 'cloudmin-network-value' }) } @$values);
}

# show_network_guests(guests)
# Displays each attached VM once, even when it has several matching interfaces.
sub show_network_guests
{
my ($guests) = @_;
return ui_tag('span', html_escape($text{'net_no_guests'}),
	{ class => 'cloudmin-network-muted' }) if (!@$guests);
my %seen;
return ui_cluster([ map { ui_tag('a', ui_svg_icon('terminal').
	ui_tag('span', html_escape($_->{'name'})),
	{ href => 'machine.cgi?id='.urlize($_->{'uuid'}), class => 'cloudmin-network-guest' }) }
	grep { !$seen{$_->{'uuid'}}++ } @$guests ]);
}

# show_network_overview(data)
# Summarizes the inventory and links each network or bridge to its detail card.
sub show_network_overview
{
my ($data) = @_;
my @networks = @{$data->{'networks'}};
# Inventory already excludes bridges owned by NAT, routed and isolated networks.
my @bridges = @{$data->{'bridges'}};
my %guests = map { $_->{'uuid'} => 1 }
	map { @{$_->{'guests'}} } (@networks, @bridges);
my $active = grep { $_->{'active'} } @networks;
my $html = ui_stats([
	{ value => scalar(@networks), label => $text{'net_networks'},
		desc => $text{'net_networks_desc'}, icon => 'globe', state => 'info', href => 'networks.cgi?tab=networks' },
	{ value => $active, label => $text{'net_active_networks'},
		desc => $text{'net_active_desc'}, icon => 'check-circle', state => $active ? 'success' : 'neutral' },
	{ value => scalar(@bridges), label => $text{'net_bridges'},
		desc => $text{'net_bridges_desc'}, icon => 'server', href => 'networks.cgi?tab=bridges' },
	{ value => scalar(keys %guests), label => $text{'net_guests'},
		desc => $text{'net_guests_desc'}, icon => 'terminal' },
], { class => 'cloudmin-network-summary', shape => 'square' });
my @rows;
foreach my $section (qw(networks bridges)) {
	my $virtual = $section eq 'networks';
	foreach my $item (@{$data->{$section}}) {
		my $identity = ui_tag('a', html_escape($item->{'name'}), {
			href => 'networks.cgi?tab='.$section.'&selected='.urlize($virtual ? $item->{'uuid'} : $item->{'name'}) });
		my $type = $virtual ? $text{'net_mode_'.$item->{'forward'}} || $item->{'forward'} : $text{'net_host_bridge'};
		push(@rows, [$identity, html_escape($type), network_status_badge($item->{'active'}),
			network_values($virtual ? [$item->{'bridge'} || $item->{'uplink'} || ()] : $item->{'ports'}),
			show_network_guests($item->{'guests'})]);
		}
	}
# Keep setup in its own tab, including when the host has no networks yet.
return $html.ui_empty_state({ icon => 'globe', title => $text{'net_empty_overview'},
	desc => $text{'net_empty_networks_desc'}, actions => ui_action_button(
		$text{'net_networks_button'}, 'info', { icon => 'arrow-right', href => 'networks.cgi?tab=networks' }) }) if (!@rows);
# Filter the overview columns without changing inventory or guest links.
my ($heads, $visible, $types) = table_columns('network_columns', \@rows);
return $html.ui_tag('div', ui_columns_table(
	$heads, 100, $visible, $types, 0, undef, undef, 1),
	{ class => 'cloudmin-network-overview-table' });
}

# show_network_status(state, token, owner)
# Groups bridge progress, errors and recovery actions in one native card.
# An empty token hides actions; owner is the user viewing the transaction.
sub show_network_status
{
my ($state, $token, $owner) = @_;
# Hosts without a transaction need no status card.
return '' if (!$state);
my $status = $state->{'state'};
# Removal needs its own progress messages; recovery messages are shared.
my $key = 'net_state_'.(($state->{'operation'} || '') eq 'remove' &&
	$status =~ /\A(?:armed|applying|confirm|complete)\z/ ? 'remove_' : '').$status;
my $message = text($key, '<tt>'.html_escape($state->{'name'}).'</tt>',
	'<tt>'.html_escape($state->{'source'} || '').'</tt>');
my $tone = $status eq 'complete' ? 'success' : $status eq 'rollback_failed' ? 'danger' : 'info';
my $html = $state->{'error'} ? ui_p(html_escape($state->{'error'})) : '';
# The marker keeps progress polling active even when another tab is selected.
if ($status =~ /\A(?:armed|applying|confirm)\z/) {
	$html .= ui_tag('p', text('net_remaining', ui_tag('span',
		int($state->{'deadline'}-time()) > 0 ? int($state->{'deadline'}-time()) : 0,
		{ id => 'cloudmin-network-countdown' })),
		{ id => 'cloudmin-network-pending', 'data-state' => $status,
		'data-remaining' => int($state->{'deadline'}-time()) });
	}
# Recovery has no confirmation countdown, but still needs live status updates.
elsif ($status eq 'rolling_back') {
	$html .= ui_tag('span', '', { id => 'cloudmin-network-pending',
		'data-state' => $status, hidden => '' });
	}
my @actions;
# Other writers can restore an expired transaction or retry failed recovery.
if ($token && $status =~ /\A(?:armed|applying|confirm|rollback_failed)\z/ &&
	($state->{'owner'} eq $owner || $status eq 'rollback_failed' || time() >= $state->{'deadline'})) {
	# Only the initiating user may keep a change within its confirmation window.
	push(@actions, network_form('confirm', $token, { id => $state->{'id'} }).
		ui_action_button($text{'net_confirm'}, 'success', { size => 'small', type => 'submit', icon => 'check' }).
		ui_form_end()) if ($status eq 'confirm' && $state->{'owner'} eq $owner && time() < $state->{'deadline'});
	# Recovery stays available to eligible writers until its worker starts.
	push(@actions, network_form('rollback', $token, { id => $state->{'id'} }).
		ui_action_button($text{'net_rollback'}, 'danger', { size => 'small', type => 'submit', icon => 'refresh' }).
		ui_form_end());
	}
return ui_tag('div', ui_card({
	title_html => ui_svg_icon('server').ui_tag('span', html_escape($state->{'name'})),
	desc_html => $message, body => $html, state => $tone,
	actions => ui_badge($text{'net_bridge_status_'.$status}, $tone, { small => 1, dot => 1 }),
	footer => @actions ? ui_cluster(\@actions) : undef,
	class => 'cloudmin-network-card',
}), { class => 'ui_stack cloudmin-network-status', role => 'status' });
}

# network_status_badge(active)
# Uses the same compact status treatment for networks, bridges and interfaces.
sub network_status_badge
{
my ($active) = @_;
return ui_badge($text{$active ? 'net_active' : 'net_inactive'},
	$active ? 'success' : 'neutral', { small => 1, dot => 1 });
}

# show_virtual_network(net, token, [selected])
# Separates identity, addressing, attached guests and lifecycle controls.
sub show_virtual_network
{
my ($net, $token, $selected) = @_;
my @actions;
# Protected networks expose their attachment state instead of unusable controls.
if ($token) {
	my @names = ($net->{'active'} ? 'stop' : 'start');
	push(@names, 'delete') if (!$net->{'active'} && $net->{'persistent'});
	foreach my $action (@names) {
		next if (@{$net->{'guests'}} && $action ne 'start');
		push(@actions, network_form($action eq 'delete' ? 'delete_review' : $action,
			$token, { id => $net->{'uuid'}, revision => $net->{'revision'} }).
			ui_action_button($text{'net_'.$action}, $action eq 'delete' ? 'danger' : 'neutral',
			{ size => 'small', type => 'submit', icon => $action eq 'delete' ? 'trash' : $action eq 'start' ? 'play' : 'stop' }).
			ui_form_end());
		}
	}
my $autostart = html_escape($text{$net->{'autostart'} ? 'net_enabled' : 'net_disabled'});
# A small explicit action keeps the saved boot policy accessible without a column.
if ($token && $net->{'persistent'}) {
	$autostart = network_form('autostart', $token, { id => $net->{'uuid'}, revision => $net->{'revision'},
		enabled => $net->{'autostart'} ? 0 : 1 }).ui_action_button(
		$text{$net->{'autostart'} ? 'net_enabled' : 'net_disabled'}, 'neutral',
		{ size => 'small', type => 'submit', icon => $net->{'autostart'} ? 'check' : 'x',
		  title => $text{'net_toggle_boot'} }).ui_form_end();
	}
my @facts = ([$text{'net_bridge'}, network_values([$net->{'bridge'} || ()])]);
# IPv4, IPv6 and DHCP are distinct facts, never combined into an ambiguous cell.
foreach my $family (4, 6) {
	my @addresses = grep { $family == 6 ? /:/ : !/:/ } @{$net->{'addresses'}};
	push(@facts, [$text{'net_addresses'.$family}, ui_tag('span', network_values(\@addresses),
		{ class => 'cloudmin-network-address'.$family })]) if (@addresses);
	}
push(@facts, [$text{'net_dhcp_range'}, network_values($net->{'ranges'}, $text{'net_disabled'})],
	[$text{'net_boot'}, $autostart]);
# Isolated networks have no outgoing connection; avoid implying one exists.
push(@facts, [$text{'net_uplink'}, network_values([$net->{'uplink'} || $text{'net_automatic'}])])
	if ($net->{'uplink'} || $net->{'forward'} =~ /\A(?:nat|route)\z/);
my $guests = ui_tag('div', ui_tag('span', html_escape($text{'net_guests'}),
	{ class => 'cloudmin-network-label' }).show_network_guests($net->{'guests'}),
	{ class => 'cloudmin-network-attachments' });
my $footer = ui_cluster([$guests, ui_cluster(\@actions)], { align => 'between' });
# Explain why attachment protection hides the stop and delete controls.
$footer .= ui_tag('p', html_escape($text{'net_in_use'}), { class => 'cloudmin-network-hint' })
	if ($token && @{$net->{'guests'}});
return ui_tag('div', ui_card({
	title_html => ui_svg_icon('globe').ui_tag('span', html_escape($net->{'name'})),
	actions => ui_cluster([
		ui_badge($text{'net_mode_'.$net->{'forward'}} || $net->{'forward'}, 'neutral', { small => 1 }),
		network_status_badge($net->{'active'})]),
	body => ui_dl(\@facts, { class => 'cloudmin-network-facts' }), footer => $footer,
	class => 'cloudmin-network-card'.($selected ? ' cloudmin-network-selected' : ''),
}), { 'data-network-name' => $net->{'name'} });
}

# show_host_network(item, [interface], [selected], [token])
# Gives bridges and Ethernet interfaces the same readable address layout.
# interface and selected default to false; token enables bridge removal review.
sub show_host_network
{
my ($item, $interface, $selected, $token) = @_;
my @badges = (network_status_badge($item->{'active'}));
push(@badges, ui_badge($text{'net_management'}, 'info', { small => 1 })) if ($item->{'management'});
my @facts;
push(@facts, [$text{$interface ? 'net_bridge' : 'net_ports'},
	network_values($interface ? [$item->{'master'} || ()] : $item->{'ports'})]);
foreach my $family (4, 6) {
	my @addresses = grep { $family == 6 ? /:/ : !/:/ } @{$item->{'addresses'}};
	push(@facts, [$text{'net_addresses'.$family}, ui_tag('span', network_values(\@addresses),
		{ class => 'cloudmin-network-address'.$family })]) if (@addresses);
	}
push(@facts, [$text{'net_mac'}, network_values([$item->{'mac'} || ()])],
	[$text{'net_persistent'}, html_escape($text{$item->{'persistent'} ? 'index_yes' : 'index_no'})]);
my $footer;
if (!$interface) {
	# Place removal beside the guest list and hide it while the bridge is in use.
	my @actions;
	my $used = @{$item->{'guests'}} || @{$item->{'networks'} || []};
	# Offer review only for unused persistent bridges with one port. The server
	# checks saved configuration and dependent interfaces before accepting it.
	if ($token && !$used && $item->{'persistent'} && @{$item->{'ports'}} == 1) {
		push(@actions, network_form('bridge_remove_review', $token, { name => $item->{'name'} }).
			ui_action_button($text{'net_remove_bridge'}, 'danger',
				{ size => 'small', type => 'submit', icon => 'unplug' }).ui_form_end());
		}
	$footer = ui_cluster([show_network_guests($item->{'guests'}), ui_cluster(\@actions)], {align => 'between'});
	# Explain the missing action when a guest or virtual network still uses it.
	$footer .= ui_tag('p', html_escape($text{'net_bridge_in_use'}), {class => 'cloudmin-network-hint'})
		if ($token && $used);
	}
return ui_card({ title_html => ui_svg_icon('server').ui_tag('span', html_escape($item->{'name'})),
	actions => ui_cluster(\@badges),
	class => 'cloudmin-network-card'.($selected ? ' cloudmin-network-selected' : ''),
	body => ui_dl(\@facts, { class => 'cloudmin-network-facts' }),
	footer => $footer,
});
}

# show_network_page(data, token, state, owner, [tab], [selected])
# Uses native Webmin tabs and the card, list and empty-state widgets from ui-demo.
# tab defaults to overview; selected optionally identifies a card to show first.
sub show_network_page
{
my ($data, $token, $state, $owner, $tab, $selected) = @_;
$selected ||= '';
$tab = network_page_tab($tab);
# Pending or failed recovery blocks setup forms and bridge removal actions.
my $pending = $state && $state->{'state'} =~ /\A(?:armed|applying|confirm|rolling_back|rollback_failed)\z/;
my $editable = $pending ? '' : $token;
my $html = ui_tabs_start([
	['net_overview', $text{'net_overview_tab'}],
	['net_networks', $text{'net_networks'}], ['net_bridges', $text{'net_bridges'}],
	['net_interfaces', $text{'net_interfaces_tab'}],
	], 'cloudmin_network_tabs', 'net_'.$tab, 1);
# Each inventory owns its setup controls; forms never enclose other forms.
foreach my $section (qw(overview networks bridges interfaces)) {
	# Overview has no mutation forms; all actions remain in the detail tabs.
	if ($section eq 'overview') {
		$html .= ui_tabs_start_tab('cloudmin_network_tabs', 'net_overview').
			ui_tag('div', ui_tag('div', ui_p(html_escape($text{'net_overview_intro'})),
				{ class => 'vui_ui_block' }).show_network_overview($data),
				{ 'data-network-tab' => 'overview', class => 'cloudmin-network-tab' }).
			ui_tabs_end_tab('cloudmin_network_tabs', 'net_overview');
		next;
		}
	my @items = $section eq 'interfaces' ? grep {
		!$_->{'loopback'} && !$_->{'bridge'} && !$_->{'kind'}
		} @{$data->{'interfaces'}} : @{$data->{$section}};
	my $key = $section eq 'networks' ? 'uuid' : 'name';
	my $highlight = $section eq $tab ? $selected : '';
	# Put a linked card first so navigation also works inside frames.
	@items = (grep({ $_->{$key} eq $highlight } @items),
		grep({ $_->{$key} ne $highlight } @items));
	# Unsupported host backends remain readable but cannot offer bridge removal.
	my @cards = map { $section eq 'networks' ? show_virtual_network($_, $editable, $_->{$key} eq $highlight)
		: show_host_network($_, $section eq 'interfaces', $_->{$key} eq $highlight,
			$data->{'supported'} ? $editable : '') } @items;
	my $intro = $section eq 'bridges' && !@cards ? 'net_bridges_intro_empty' : 'net_'.$section.'_intro';
	my $body = ui_tag('div', ui_p(html_escape($text{$intro})),
		{ class => 'vui_ui_block' });
	# Bridge recovery belongs beside bridge details, including a removed bridge.
	$body .= show_network_status($state, $token, $owner) if ($section eq 'bridges');
	# Empty bridges lead directly into setup, without a second large introduction.
	if (@cards) {
		$body .= ui_stack(\@cards);
		}
	# Other empty inventories retain a short explanation above their setup form.
	elsif ($section ne 'bridges') {
		$body .= ui_empty_state({ icon => $section eq 'networks' ? 'globe' : 'server',
			title => $text{'net_empty_'.$section}, desc => $text{'net_empty_'.$section.'_desc'} });
		}
	$body .= show_network_create_form($data, $editable) if ($editable && $section eq 'networks');
	$body .= show_bridge_create_form($data, $editable, !@cards) if ($editable && $section eq 'bridges');
	$html .= ui_tabs_start_tab('cloudmin_network_tabs', 'net_'.$section).
		ui_tag('div', $body, { 'data-network-tab' => $section, class => 'cloudmin-network-tab' }).
		ui_tabs_end_tab('cloudmin_network_tabs', 'net_'.$section);
	}
return $html.ui_tabs_end(1);
}

# show_network_create_form(data, token)
# Explains connection choices beside their radios, then groups address settings.
sub show_network_create_form
{
my ($data, $token) = @_;
my $html = network_form('create', $token).
	ui_hidden_table_start($text{'net_create'}, 'width=100%', 2, 'create_network', 0);
$html .= ui_table_row(undef, ui_choice('mode', 'nat', [map { {
	value => $_, label => $text{'net_mode_'.$_}, desc => $text{'net_explain_'.$_}
	} } qw(nat route isolated)], { class => 'cloudmin-network-choices' }), 2);
$html .= ui_table_row($text{'net_name'}, ui_textbox('name', '', 18));
$html .= ui_table_row($text{'net_ipv4'}, ui_textbox('ipv4', '', 24, 0, undef,
	'placeholder="192.168.130.1/24"').ui_tag('p', html_escape($text{'net_subnet_hint'}), { class => 'cloudmin-network-hint' }));
$html .= ui_table_row($text{'net_ipv6'}, ui_textbox('ipv6', '', 30, 0, undef,
	'placeholder="'.quote_escape($text{'net_optional_ipv6'}).'"'));
$html .= ui_table_row($text{'net_uplink'}, ui_select('uplink', '',
	[['', $text{'net_automatic'}], map { [$_->{'name'}, $_->{'name'}] }
	grep { $_->{'active'} && !$_->{'loopback'} } @{$data->{'interfaces'}}]));
$html .= ui_table_row($text{'net_boot'}, ui_checkbox('autostart', 1, $text{'net_start_automatically'}, 1));
$html .= ui_table_row($text{'net_dhcp'}, ui_checkbox('dhcp', 1, $text{'net_dhcp_assign'}, 0));
$html .= ui_table_row($text{'net_dhcp_range'}, ui_tag('div',
	ui_textbox('dhcp_start', '', 18, 0, undef, 'aria-label="'.quote_escape($text{'net_dhcp_from'}).'"').
	ui_tag('span', ' &ndash; ', { 'aria-hidden' => 'true' }).
	ui_textbox('dhcp_end', '', 18, 0, undef, 'aria-label="'.quote_escape($text{'net_dhcp_to'}).'"'),
	{ class => 'cloudmin-network-range', 'data-network-dhcp' => 1 }));
$html .= ui_table_row(undef, ui_action_button($text{'net_create'}, 'success', { icon => 'plus', type => 'submit' }), 2);
return $html.ui_hidden_table_end('create_network').ui_form_end();
}

# show_bridge_create_form(data, token, [open])
# Presents the eligible Ethernet port, expanded when there are no host bridges.
sub show_bridge_create_form
{
my ($data, $token, $open) = @_;
my $html = network_form('bridge_review', $token).
	ui_hidden_table_start($text{'net_bridge_create'}, 'width=100%', 2, 'create_bridge', $open);
# Unsupported hosts still explain where their networking can be configured.
if (!$data->{'supported'}) {
	$html .= ui_table_row(undef, ui_note($text{'net_backend_unsupported'}), 2);
	}
# Offer bridge conversion only for interfaces the backend can preserve.
else {
	my @ports = grep { $_->{'candidate'} } @{$data->{'interfaces'}};
	$html .= ui_table_row(undef, ui_p($text{'net_bridge_help'}), 2);
	# Avoid empty selectors when every physical interface is already attached.
	if (@ports) {
		$html .= ui_table_row($text{'net_bridge_name'}, ui_textbox('name', 'br0', 18));
		$html .= ui_table_row($text{'net_port'}, ui_select('source', '',
			[map { [$_->{'name'}, $_->{'name'}.' - '.join(', ', @{$_->{'addresses'}})] } @ports]));
		$html .= ui_table_row(undef, ui_note($text{'net_explain_bridge'}), 2);
		$html .= ui_table_row(undef, ui_action_button($text{'net_review'}, 'info', { type => 'submit', icon => 'arrow-right' }), 2);
		}
	# All usable ports are already attached or lack persistent configuration.
	else {
		$html .= ui_table_row(undef, ui_note($text{'net_no_ports'}), 2);
		}
	}
return $html.ui_hidden_table_end('create_bridge').ui_form_end();
}

# show_bridge_review(plan, token)
# Shows a creation or removal plan and includes its signed form token.
sub show_bridge_review
{
my ($p, $token) = @_;
my $remove = ($p->{'operation'} || '') eq 'remove';
# Show the reviewed timeout; older plans fall back to the current setting.
return ui_alert_box(text($remove ? 'net_bridge_remove_help' : 'net_bridge_review_help',
	$p->{'confirm_timeout'} || config_number('bridge_confirm_timeout')), 'warn').
	ui_card({ title => $text{$remove ? 'net_remove_bridge_review' : 'net_review'}, class => 'cloudmin-network-card',
	body => ui_dl([[$text{'net_bridge_name'}, '<tt>'.html_escape($p->{'name'}).'</tt>'],
		[$text{'net_port'}, '<tt>'.html_escape($p->{'source'}).'</tt>'],
		[$text{'net_addresses'}, network_values($p->{'addresses'})],
		[$text{'net_management'}, $text{$p->{'management'} ? 'index_yes' : 'index_no'}]],
		{ class => 'cloudmin-network-facts' }) }).
	network_form($remove ? 'bridge_remove' : 'bridge', $token,
		{ map { $_ => $p->{$_} } qw(name source revision) }).
	ui_action_button($text{$remove ? 'net_remove_bridge' : 'net_apply_bridge'},
		$remove ? 'danger' : 'info', {size => 'small', type => 'submit', icon => $remove ? 'unplug' : 'check'}).
	ui_form_end();
}

1;
