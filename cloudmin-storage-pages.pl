# Storage pages use the same native tabs and compact cards as Networking.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Share visible-column definitions with the module configuration editor.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-config-lib.pl'));
our %text;

# storage_form(action, token, [fields], [tab])
# Keeps each action in its own POST form, outside other forms.
sub storage_form
{
my ($action, $token, $fields, $tab) = @_;
return ui_form_start('storage.cgi', 'post').ui_hidden('action', $action).
	ui_hidden('token', $token).ui_hidden('tab', $tab || 'pools').
	join('', map { ui_hidden($_, $fields->{$_}) } sort keys %{$fields || {}});
}

# show_storage_overview(data)
# Shows storage totals, pool links and each pool's capacity bar.
sub show_storage_overview
{
my ($data) = @_;
my $counts = $data->{'overview'};
my $space = defined($counts->{'available'}) && $counts->{'active'};
my $html = ui_stats([
	{ value => $counts->{'pools'}, label => $text{'storage_pools'},
		desc => $text{'storage_pools_desc'}, icon => 'hard-drive', state => 'info', href => 'storage.cgi?tab=pools' },
	{ value => $counts->{'active'}, label => $text{'storage_active'},
		desc => $text{'storage_active_desc'}, icon => 'check-circle', state => $counts->{'active'} ? 'success' : 'neutral' },
	{ value_html => defined($counts->{'volumes'}) ? html_escape($counts->{'volumes'}) : '&mdash;', label => $text{'storage_volumes'},
		desc => $text{$counts->{'volumes_unknown'} ? 'storage_count_unavailable' : 'storage_volumes_desc'},
		icon => 'server', href => 'storage.cgi?tab=volumes' },
	{ value_html => $space ? html_escape(nice_size_text($counts->{'available'})) : '&mdash;', label => $text{'storage_available'},
		desc => $space ? text('storage_unique_capacity', nice_size_text($counts->{'capacity'}))
			: $text{$counts->{'active'} ? 'storage_space_unavailable' : 'storage_no_active'}, icon => 'download' },
], { class => 'cloudmin-storage-summary', shape => 'square' });
return $html.ui_empty_state({ icon => 'hard-drive', title => $text{'storage_none'},
	desc => $text{'storage_none_desc'}, actions => ui_action_button(
		$text{'storage_pool_list'}, 'info', { icon => 'arrow-right', href => 'storage.cgi?tab=pools' }) }) if (!@{$data->{'pools'}});
my @rows;
foreach my $pool (@{$data->{'pools'}}) {
	my $identity = ui_tag('a', html_escape($pool->{'name'}), {
		href => 'storage.cgi?tab=pools&pool='.urlize($pool->{'uuid'}), class => 'cloudmin-storage-pool-link' }).
		ui_tag('span', $pool->{'target'} ? '<tt>'.html_escape($pool->{'target'}).'</tt>'
			: html_escape($text{'index_unknown'}), { class => 'cloudmin-storage-location' });
	my $state = $pool->{'state'} || 'unknown';
	my %tones = (running => 'success', degraded => 'warning', building => 'info', inaccessible => 'danger');
	my $status = ui_badge($text{'storage_state_'.$state} || $text{'storage_state_unknown'},
		$tones{$state} || 'neutral', { small => 1, dot => 1 }).
		ui_tag('span', html_escape($text{'storage_type_'.$pool->{'type'}} || $pool->{'type'}),
			{ class => 'cloudmin-storage-pool-type' });
	my $usage = html_escape($text{'storage_unavailable'});
	# Show measured filesystem usage only when capacity is available.
	if ($pool->{'active'} && $pool->{'capacity'}) {
		$usage = ui_tag('span', nice_size($pool->{'available'}).' '.html_escape($text{'storage_free'}),
			{ class => 'cloudmin-storage-free' }).
			ui_tag('span', text('storage_total_capacity', nice_size($pool->{'capacity'})),
				{ class => 'cloudmin-storage-total' }).
			ui_progress($pool->{'allocation'}, { max => $pool->{'capacity'}, thresholds => 1,
				small => 1, label => $text{($pool->{'type'} || '') =~ /\A(?:dir|fs|netfs)\z/
					? 'storage_filesystem_usage' : 'storage_pool_usage'} });
		}
	my $boot = $pool->{'persistent'} ? ui_badge($text{$pool->{'autostart'} ? 'storage_enabled' : 'storage_disabled'},
		'neutral', { small => 1, icon => $pool->{'autostart'} ? 'check' : 'x' })
		: html_escape($text{'storage_not_saved'});
	push(@rows, [$identity, $status,
		$pool->{'active'} && !$pool->{'volume_error'} ? $pool->{'volume_count'} : '&mdash;', $usage, $boot]);
	}
# Reduced tables use automatic widths instead of full-layout column positions.
my ($heads, $visible, $types) = table_columns('storage_pool_columns', \@rows);
$html .= ui_tag('div', ui_columns_table(
	$heads, 100, $visible, $types, 0, undef, undef, 1),
	{ id => 'cloudmin-storage-overview-table', class => 'cloudmin-storage-table cloudmin-storage-overview-table'.
		(@$heads < 5 ? ' cloudmin-storage-compact-columns' : '') });
return $html;
}

# storage_action(pool, token, action, label, icon, [enabled])
# Identifies the exact pool and rendered revision for a small lifecycle control.
sub storage_action
{
my ($pool, $token, $action, $label, $icon, $enabled) = @_;
return storage_form($action, $token, { id => $pool->{'uuid'}, revision => $pool->{'revision'},
	(defined($enabled) ? (enabled => $enabled) : ()) }).
	ui_action_button($label, 'neutral', { type => 'submit', size => 'small', icon => $icon,
		($action eq 'autostart' ? (title => $text{'storage_toggle_boot'}) : ()) }).ui_form_end();
}

1;
