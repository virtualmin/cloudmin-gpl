# Networking pages use Webmin's native widgets.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Share column selection and timeout defaults with the configuration editor.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-config-lib.pl'));
our (%text);

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

1;
