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

# show_storage_pool(pool, token, [selected])
# Separates pool identity, capacity, location and lifecycle controls.
sub show_storage_pool
{
my ($pool, $token, $selected) = @_;
my $editable = $token && $pool->{'manageable'};
my $state = $pool->{'state'} || 'unknown';
my %tones = (running => 'success', degraded => 'warning', building => 'info', inaccessible => 'danger');
my $boot = html_escape($text{$pool->{'autostart'} ? 'storage_enabled' : 'storage_disabled'});
$boot = $text{'storage_not_saved'} if (!$pool->{'persistent'});
if ($editable) {
	# Writable managed pools expose boot settings as signed actions.
	$boot = storage_action($pool, $token, 'autostart',
		$text{$pool->{'autostart'} ? 'storage_enabled' : 'storage_disabled'},
		$pool->{'autostart'} ? 'check' : 'x', $pool->{'autostart'} ? 0 : 1);
	}
my $volumes = $pool->{'active'} && !$pool->{'volume_error'} ? $pool->{'volume_count'} : $text{'storage_unavailable'};
my @facts = ([$text{'storage_location'}, ui_tag('span',
	$pool->{'target'} ? '<tt>'.html_escape($pool->{'target'}).'</tt>'
		: html_escape($text{'index_unknown'}), { class => 'cloudmin-storage-path' })],
	[$text{'storage_volume_count'}, html_escape($volumes)], [$text{'storage_autostart'}, $boot]);
my $body = ui_dl(\@facts, { class => 'cloudmin-storage-facts' });
if ($pool->{'active'} && $pool->{'capacity'}) {
	# File pools share filesystem space; block pools report their own allocation.
	my $percent = int(100 * $pool->{'allocation'} / $pool->{'capacity'} + 0.5);
	$percent = 0 if ($percent < 0);
	$percent = 100 if ($percent > 100);
	$body .= ui_progress($pool->{'allocation'}, { max => $pool->{'capacity'}, thresholds => 1,
		label => html_escape(text(($pool->{'type'} || '') =~ /\A(?:dir|fs|netfs)\z/
			? 'storage_filesystem_used' : 'storage_pool_used', $percent)), value => text('storage_free_of',
		nice_size_text($pool->{'available'}), nice_size_text($pool->{'capacity'})) });
	}
elsif (!$pool->{'active'}) {
	# Inactive pools have no current capacity measurement.
	$body .= ui_tag('p', html_escape($text{'storage_inactive_help'}), { class => 'cloudmin-storage-hint' });
	}
if ($pool->{'volume_error'}) {
	# Keep a volume-list failure visible beside usable pool settings.
	$body .= ui_alert_box(text('storage_volume_error', html_escape($pool->{'volume_error'})), 'warn');
	}
if ($pool->{'type'} eq 'lvmthin' && defined($pool->{'metadata_percent'})) {
	# Thin metadata can fill before data space does; expose both measurements.
	$body .= ui_p(html_escape(text('storage_thin_usage',
		$pool->{'data_percent'}, $pool->{'metadata_percent'})));
	$body .= ui_alert_box($text{'storage_thin_full'}, 'warn')
		if ($pool->{'data_percent'} >= 95 || $pool->{'metadata_percent'} >= 90);
	}
my @footer;
if (@{$pool->{'guests'} || []}) {
	# VM identities belong beside their volumes; keep the stop restriction here.
	push(@footer, ui_tag('span', html_escape($text{'storage_pool_busy'})));
	}
if ($editable && (!@{$pool->{'guests'} || []} || !$pool->{'active'})) {
	# Offer lifecycle changes only when the pool state allows them.
	my $action = $pool->{'active'} ? 'stop' : 'start';
	push(@footer, storage_action($pool, $token, $action, $text{'storage_'.$action},
		$pool->{'active'} ? 'stop' : 'play'));
	}
if ($token && $pool->{'unregisterable'}) {
	# Review explains active-pool or ownership restrictions before confirmation.
	push(@footer, storage_action($pool, $token, 'review_pool',
		$text{'storage_unregister'}, 'unlink'));
	}
return ui_card({ id => 'cloudmin-pool-'.$pool->{'uuid'},
	class => 'cloudmin-storage-card'.($selected ? ' cloudmin-storage-selected' : ''),
	title_html => ui_svg_icon('hard-drive').ui_tag('span', html_escape($pool->{'name'})),
	actions => ui_cluster([
		ui_badge($text{'storage_type_'.$pool->{'type'}} || $pool->{'type'}, 'neutral', { small => 1 }),
		ui_badge($text{'storage_state_'.$state} || $text{'storage_state_unknown'},
			$tones{$state} || 'neutral', { small => 1, dot => 1 })]),
	body => $body, footer => ui_cluster(\@footer, { align => @{$pool->{'guests'} || []} ? 'between' : 'end' }) });
}

# show_storage_volume_usage(usage, [empty])
# Shows each VM once, including references retained by its snapshots or saves.
# Empty table cells use a dash; callers can supply a different placeholder.
sub show_storage_volume_usage
{
my ($usage, $empty) = @_;
my (@owners, %seen);
foreach my $owner (@{$usage->{'owners'} || []}) {
	# Imported images and backing volumes are classified separately from VMs.
	next if (!$owner->{'uuid'} || $seen{$owner->{'uuid'}}++);
	push(@owners, ui_tag('div', ui_tag('a', html_escape($owner->{'name'}),
		{ href => 'machine.cgi?id='.urlize($owner->{'uuid'}) })));
	}
return @owners ? ui_tag('div', join('', @owners), { class => 'cloudmin-storage-owners' }) : ($empty // '&mdash;');
}

# show_storage_volume_type(usage)
# Keeps additional volume roles in an inline disclosure below the first type.
sub show_storage_volume_type
{
my ($usage) = @_;
my %kinds = map { $_->{'kind'} => 1 } @{$usage->{'owners'} || []};
my @types;
foreach my $kind (grep { $kinds{$_} } qw(image vm saved snapshot checkpoint backing)) {
	# Explain why a base disk cannot be removed while another volume uses it.
	my $label = html_escape($text{'storage_owner_'.$kind});
	$label = ui_tag('span', $label, { title => $text{'storage_owner_backing_help'} }) if ($kind eq 'backing');
	push(@types, $label);
	}
if (@types > 1) {
	# Keep table rows compact until the user expands the remaining roles.
	my $first = shift(@types);
	return ui_details({ html => 1, class => 'inline inlined',
		title => $first, content => join('<br>', @types) });
	}
return $types[0] if (@types);
return html_escape($text{!$usage || !$usage->{'checked'} ? 'index_unknown'
	: $usage->{'reason'} ? 'storage_volume_other' : 'storage_unused'});
}

# show_storage_volumes(pools, [token], [local], [formno])
# Lists owners and capacity, linking local directories to File Manager and
# offering deletion only for verified unused files.
sub show_storage_volumes
{
my ($pools, $token, $local, $formno) = @_;
my (@rows, @unavailable);
my $selectable = 0;
foreach my $pool (@$pools) {
	# Inactive pools cannot report volumes; zero would falsely imply emptiness.
	if (!$pool->{'active'} || $pool->{'volume_error'}) {
		push(@unavailable, $pool->{'name'});
		next;
		}
	foreach my $volume (@{$pool->{'volumes'} || []}) {
		# Generated names become readable labels
		# with full paths under details.
		my $identity = ui_tag('span', html_escape(storage_volume_label($volume)),
			{ class => 'cloudmin-storage-volume-name' }).
			show_disk_location($volume->{'path'} || $volume->{'name'}, $local);
		my $directory = '&mdash;';
		if (($volume->{'path'} || '') =~ m{^/}) {
			# Remote libvirt paths must never open this Webmin host's files.
			my $dir = $volume->{'path'};
			$dir =~ s{/[^/]+$}{};
			$dir ||= '/';
			$directory = $local ? show_filemin_directory($dir)
				: ui_tag('tt', html_escape($dir));
			}
		my $usage = $volume->{'usage'};
		# LVM volume deletion is independent of the pool's start/stop controls.
		my $unused = $token && ($pool->{'manageable'} || $pool->{'volume_manageable'}) &&
			$usage && $usage->{'checked'} &&
			!$usage->{'reason'} && !@{$usage->{'owners'} || []};
		$selectable++ if ($unused);
		push(@rows, [$token ? { type => 'checkbox', name => 'volume',
			value => $pool->{'uuid'}.'/'.$volume->{'name'}, disabled => !$unused } : '',
			$identity, $directory, ui_tag('a', html_escape($pool->{'name'}),
			{ href => 'storage.cgi?tab=pools&pool='.urlize($pool->{'uuid'}) }),
			show_storage_volume_type($usage), show_storage_volume_usage($usage),
			nice_size($volume->{'capacity'}), nice_size($volume->{'allocation'})]);
		}
	}
my $html = @unavailable ? ui_note(text('storage_volumes_unavailable',
	join(', ', map { '<tt>'.html_escape($_).'</tt>' } @unavailable))) : '';
if (@rows) {
	# Keep each selection checkbox attached to its volume when columns are hidden.
	my ($heads, $visible, $types) =
		table_columns('storage_volume_columns', \@rows, 1);
	# Match Images' standard selection controls even when all rows are
	# protected. The form index is relative to the module's content.
	$html .= $token ? ui_form_columns_table('storage.cgi',
		[['delete', $text{'storage_delete_selected'}, undef, !$selectable]], 1, undef,
		[['action', 'review_volumes'], ['tab', 'volumes'], ['token', $token]],
		$heads, 100, $visible, $types, 0, undef, undef, $formno || 0, 1)
		: ui_columns_table($heads, 100, $visible, $types, 0, undef, undef, 1);
	}
else {
	# The preceding notice still distinguishes unavailable pools from empty ones.
	$html .= ui_empty_state({ icon => 'hard-drive', title => $text{'storage_no_volumes'},
		desc => $text{'storage_no_volumes_help'} });
	}
return $html;
}

1;
