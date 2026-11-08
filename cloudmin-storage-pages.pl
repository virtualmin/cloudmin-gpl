# Storage pages use the same native tabs and compact cards as Networking.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Share visible-column definitions with the module configuration editor.
require(
	Cwd::abs_path(File::Basename::dirname(__FILE__).
		      '/cloudmin-config-lib.pl'));
our %text;

# storage_page_tab(value) Accepts inventory tabs only, including
# after a form submission.
sub storage_page_tab
{
return ($_[0] || '') =~ /\A(?:pools|volumes)\z/ ? $_[0] : 'overview';
}

# storage_form(action, token, [fields], [tab]) Keeps each action in its own POST
# form, outside other forms.
sub storage_form
{
my ($action, $token, $fields, $tab) = @_;
return ui_form_start('storage.cgi', 'post').ui_hidden('action', $action).
       ui_hidden('token', $token).ui_hidden('tab', $tab || 'pools').
       join('', map { ui_hidden($_,
				$fields->{$_}) } sort keys %{$fields || { }});
}

# show_storage_overview(data) Shows storage totals, pool links and each
# pool's capacity bar.
sub show_storage_overview
{
my ($data) = @_;
my $counts = $data->{'overview'};
my $space = defined($counts->{'available'}) && $counts->{'active'};
my $html = ui_stats([
	{ value => $counts->{'pools'}, label => $text{'storage_pools'},
	  desc => $text{'storage_pools_desc'}, icon =>
						       'hard-drive',
	  state => 'info', href =>
				   'storage.cgi?tab=pools' },
	{ value => $counts->{'active'}, label => $text{'storage_active'},
	  desc => $text{'storage_active_desc'}, icon =>
							'check-circle',
	  state => $counts->{'active'} ? 'success' : 'neutral' },
	{ value_html => defined($counts->{'volumes'})
		? html_escape($counts->{'volumes'})
		: '&mdash;', label => $text{'storage_volumes'},
	  desc => $text{$counts->{'volumes_unknown'}
		  ? 'storage_count_unavailable'
		  : 'storage_volumes_desc'},
	  icon => 'server', href => 'storage.cgi?tab=volumes' },
	{ value_html => $space
		? html_escape(nice_size_text($counts->{'available'}))
		: '&mdash;', label => $text{'storage_available'},
	  desc => $space
		  ? text('storage_unique_capacity',
			 nice_size_text($counts->{'capacity'}))
		  : $text{$counts->{'active'}
			  ? 'storage_space_unavailable'
			  : 'storage_no_active'}, icon => 'download' },
], { class => 'cloudmin-storage-summary', shape => 'square' });
return $html.ui_empty_state({ icon => 'hard-drive', title =>
							    $text{'storage_none'},
			      desc => $text{'storage_none_desc'},
			      actions => ui_action_button(
				      $text{'storage_pool_list'}, 'info',
				      { icon => 'arrow-right', href =>
								       'storage.cgi?tab=pools' }) })
	if (!@{$data->{'pools'}});
my @rows;
foreach my $pool (@{$data->{'pools'}}) {
	my $identity = ui_tag('a', html_escape($pool->{'name'}), {
		href =>
			'storage.cgi?tab=pools&pool='.
			urlize($pool->{'uuid'}), class =>
							 'cloudmin-storage-pool-link' }).
		       ui_tag('span', $pool->{'target'}
			       ? ui_tag('tt', html_escape($pool->{'target'}))
			       : html_escape($text{'index_unknown'}),
			      { class => 'cloudmin-storage-location' });
	my $state = $pool->{'state'} || 'unknown';
	my %tones =
		( running => 'success', degraded => 'warning',
		  building => 'info',
		  inaccessible => 'danger' );
	my $status =
		ui_badge($text{'storage_state_'.$state} ||
			 $text{'storage_state_unknown'},
			 $tones{$state} || 'neutral', { small => 1, dot => 1 }).
		ui_tag('span',
		       html_escape($text{'storage_type_'.$pool->{'type'}} ||
				   $pool->{'type'}),
		       { class => 'cloudmin-storage-pool-type' });
	my $usage = html_escape($text{'storage_unavailable'});
	# Show measured filesystem usage only when capacity is available.
	if ($pool->{'active'} && $pool->{'capacity'}) {
		$usage =
			ui_tag('span',
			       nice_size($pool->{'available'}).' '.
			       html_escape($text{'storage_free'}),
			       { class => 'cloudmin-storage-free' }).
			ui_tag('span',
			       text('storage_total_capacity',
				    nice_size($pool->{'capacity'})),
			       { class => 'cloudmin-storage-total' }).
			ui_progress($pool->{'allocation'},
				    { max => $pool->{'capacity'},
				      thresholds => 1,
				      small => 1,
				      label => $text{($pool->{'type'} || '') =~ /\A(?:dir|fs|netfs)\z/
					      ? 'storage_filesystem_usage'
					      : 'storage_pool_usage'} });
		}
	my $boot = $pool->{'persistent'}
		? ui_badge($text{$pool->{'autostart'}
			? 'storage_enabled'
			: 'storage_disabled'},
			   'neutral', { small => 1, icon => $pool->{'autostart'}
				   ? 'check'
				   : 'x' })
		: html_escape($text{'storage_not_saved'});
	push(@rows, [ $identity, $status,
		      $pool->{'active'} && !$pool->{'volume_error'}
			      ? $pool->{'volume_count'}
			      : '&mdash;', $usage, $boot ]);
	}
# Reduced tables use automatic widths instead of full-layout column positions.
my ($heads, $visible, $types) = table_columns('storage_pool_columns', \@rows);
$html .= ui_tag('div', ui_columns_table(
	$heads, 100, $visible, $types, 0, undef, undef, 1),
		{ id => 'cloudmin-storage-overview-table', class =>
								   'cloudmin-storage-table cloudmin-storage-overview-table'.
								   (@$heads < 5
									   ? ' cloudmin-storage-compact-columns'
									   : '') });
return $html;
}

# storage_action(pool, token, action, label, icon, [enabled]) Identifies the
# exact pool and rendered revision for a small lifecycle control.
sub storage_action
{
my ($pool, $token, $action, $label, $icon, $enabled) = @_;
return storage_form($action, $token,
		    { id => $pool->{'uuid'}, revision => $pool->{'revision'},
		      (defined($enabled) ? ( enabled => $enabled ) : ()) }).
       ui_action_button($label, 'neutral',
			{ type => 'submit', size => 'small', icon => $icon,
			  ($action eq 'autostart'
				  ? ( title => $text{'storage_toggle_boot'} )
				  : ()) }).ui_form_end();
}

# show_storage_pool(pool, token, [selected]) Separates pool identity, capacity,
# location and lifecycle controls.
sub show_storage_pool
{
my ($pool, $token, $selected) = @_;
my $editable = $token && $pool->{'manageable'};
my $state = $pool->{'state'} || 'unknown';
my %tones =
	( running => 'success', degraded => 'warning', building => 'info',
	  inaccessible => 'danger' );
my $boot = html_escape($text{$pool->{'autostart'}
	? 'storage_enabled'
	: 'storage_disabled'});
$boot = $text{'storage_not_saved'} if (!$pool->{'persistent'});
if ($editable) {
	# Writable managed pools expose boot settings as signed actions.
	$boot = storage_action($pool, $token, 'autostart',
			       $text{$pool->{'autostart'}
				       ? 'storage_enabled'
				       : 'storage_disabled'},
			       $pool->{'autostart'} ? 'check' : 'x',
			       $pool->{'autostart'} ? 0 : 1);
	}
my $volumes = $pool->{'active'} && !$pool->{'volume_error'}
	? $pool->{'volume_count'}
	: $text{'storage_unavailable'};
my @facts = (
	[ $text{'storage_location'}, ui_tag(
		'span', $pool->{'target'}
			? ui_tag('tt', html_escape($pool->{'target'}))
			: html_escape($text{'index_unknown'}),
		{ class => 'cloudmin-storage-path' }) ],
	[ $text{'storage_volume_count'}, html_escape($volumes) ],
	[ $text{'storage_autostart'}, $boot ] );
my $body = ui_dl(\@facts, { class => 'cloudmin-storage-facts' });
if ($pool->{'active'} && $pool->{'capacity'}) {
	# File pools share filesystem space; block pools report
	# their own allocation.
	my $percent =
		int(100 * $pool->{'allocation'} / $pool->{'capacity'} + 0.5);
	$percent = 0 if ($percent < 0);
	$percent = 100 if ($percent > 100);
	$body .= ui_progress($pool->{'allocation'},
			     { max => $pool->{'capacity'}, thresholds => 1,
			       label => html_escape(text(($pool->{'type'} ||
							  '') =~ /\A(?:dir|fs|netfs)\z/
								  ? 'storage_filesystem_used'
								  : 'storage_pool_used', $percent)),
			       value => text('storage_free_of',
					     nice_size_text($pool->{'available'}),
					     nice_size_text($pool->{'capacity'})) });
	}
elsif (!$pool->{'active'}) {
	# Inactive pools have no current capacity measurement.
	$body .= ui_tag('p', html_escape($text{'storage_inactive_help'}),
			{ class => 'cloudmin-storage-hint' });
	}
if ($pool->{'volume_error'}) {
	# Keep a volume-list failure visible beside usable pool settings.
	$body .= ui_alert_box(text('storage_volume_error',
				   html_escape($pool->{'volume_error'})),
			      'warn');
	}
if ($pool->{'type'} eq 'lvmthin' && defined($pool->{'metadata_percent'})) {
	# Thin metadata can fill before data space does;
	# expose both measurements.
	$body .= ui_p(html_escape(text('storage_thin_usage',
				       $pool->{'data_percent'},
				       $pool->{'metadata_percent'})));
	$body .= ui_alert_box($text{'storage_thin_full'}, 'warn')
		if ($pool->{'data_percent'} >= 95 ||
		    $pool->{'metadata_percent'} >= 90);
	}
my @footer;
if (@{$pool->{'guests'} || [ ]}) {
	# VM identities belong beside their volumes; keep the
	# stop restriction here.
	push(@footer, ui_tag('span', html_escape($text{'storage_pool_busy'})));
	}
if ($editable && (!@{$pool->{'guests'} || [ ]} || !$pool->{'active'})) {
	# Offer lifecycle changes only when the pool state allows them.
	my $action = $pool->{'active'} ? 'stop' : 'start';
	push(@footer,
	     storage_action($pool, $token, $action,
			    $text{'storage_'.$action},
			    $pool->{'active'} ? 'stop' : 'play'));
	}
if ($token && $pool->{'unregisterable'}) {
	# Review explains active-pool or ownership restrictions
	# before confirmation.
	push(@footer, storage_action($pool, $token, 'review_pool',
				     $text{'storage_unregister'}, 'unlink'));
	}
return ui_card({ id => 'cloudmin-pool-'.$pool->{'uuid'},
		 class => 'cloudmin-storage-card'.($selected
			 ? ' cloudmin-storage-selected'
			 : ''),
		 title_html =>
			 ui_svg_icon('hard-drive').ui_tag('span',
							  html_escape($pool->{'name'})),
		 actions => ui_cluster([
			 ui_badge($text{'storage_type_'.$pool->{'type'}} ||
				  $pool->{'type'}, 'neutral', { small => 1 }),
			 ui_badge($text{'storage_state_'.$state} ||
				  $text{'storage_state_unknown'},
				  $tones{$state} || 'neutral', { small => 1,
								 dot => 1 }) ]),
		 body => $body, footer =>
					ui_cluster(\@footer,
						   { align => @{$pool->{'guests'} || [ ]}
							   ? 'between'
							   : 'end' }) });
}

# show_storage_volume_usage(usage, [empty]) Shows each VM once, including
# references retained by its snapshots or saves. Empty table cells use a dash;
# callers can supply a different placeholder.
sub show_storage_volume_usage
{
my ($usage, $empty) = @_;
my (@owners, %seen);
foreach my $owner (@{$usage->{'owners'} || [ ]}) {
	# Imported images and backing volumes are classified
	# separately from VMs.
	next if (!$owner->{'uuid'} || $seen{$owner->{'uuid'}}++);
	push(@owners, ui_tag('div', ui_tag('a', html_escape($owner->{'name'}),
					   { href => 'machine.cgi?id='.urlize($owner->{'uuid'}) })));
	}
return @owners
	? ui_tag('div', join('', @owners),
		 { class => 'cloudmin-storage-owners' })
	: ($empty // '&mdash;');
}

# show_storage_volume_type(usage) Keeps additional volume roles in an inline
# disclosure below the first type.
sub show_storage_volume_type
{
my ($usage) = @_;
my %kinds = map { $_->{'kind'} => 1 } @{$usage->{'owners'} || [ ]};
my @types;
foreach my $kind (
	grep { $kinds{$_} } qw(image vm saved snapshot checkpoint backing)) {
	# Explain why a base disk cannot be removed while
	# another volume uses it.
	my $label = html_escape($text{'storage_owner_'.$kind});
	$label =
		ui_tag('span', $label,
		       { title => $text{'storage_owner_backing_help'} })
		if ($kind eq 'backing');
	push(@types, $label);
	}
if (@types > 1) {
	# Keep table rows compact until the user expands the remaining roles.
	my $first = shift(@types);
	return ui_details({ html => 1, class => 'inline inlined',
			    title => $first,
			    content => join(ui_br(), @types) });
	}
return $types[0] if (@types);
return html_escape($text{!$usage || !$usage->{'checked'}
	? 'index_unknown'
	: $usage->{'reason'} ? 'storage_volume_other' : 'storage_unused'});
}

# show_storage_volumes(pools, [token], [local], [formno]) Lists owners and
# capacity, linking local directories to File Manager and offering deletion only
# for verified unused files.
sub show_storage_volumes
{
my ($pools, $token, $local, $formno) = @_;
my (@rows, @unavailable);
my $selectable = 0;
foreach my $pool (@$pools) {
	# Inactive pools cannot report volumes; zero would
	# falsely imply emptiness.
	if (!$pool->{'active'} || $pool->{'volume_error'}) {
		push(@unavailable, $pool->{'name'});
		next;
		}
	foreach my $volume (@{$pool->{'volumes'} || [ ]}) {
		# Generated names become readable labels with full
		# paths under details.
		my $identity =
			ui_tag('span',
			       html_escape(storage_volume_label($volume)),
			       { class => 'cloudmin-storage-volume-name' }).
			show_disk_location($volume->{'path'} ||
					   $volume->{'name'}, $local);
		my $directory = '&mdash;';
		if (($volume->{'path'} || '') =~ m{^/}) {
			# Remote libvirt paths must never open this
			# Webmin host's files.
			my $dir = $volume->{'path'};
			$dir =~ s{/[^/]+$}{};
			$dir ||= '/';
			$directory = $local
				? show_filemin_directory($dir)
				: ui_tag('tt', html_escape($dir));
			}
		my $usage = $volume->{'usage'};
		# LVM volume deletion is independent of the pool's
		# start/stop controls.
		my $unused = $token &&
			     ($pool->{'manageable'} ||
			      $pool->{'volume_manageable'}) &&
			     $usage && $usage->{'checked'} &&
			     !$usage->{'reason'} && !@{$usage->{'owners'} || [ ]};
		$selectable++ if ($unused);
		push(@rows, [ $token
			? { type => 'checkbox', name => 'volume',
			    value => $pool->{'uuid'}.'/'.$volume->{'name'},
			    disabled => !$unused }
			: '',
			      $identity, $directory,
			      ui_tag('a', html_escape($pool->{'name'}),
				     { href => 'storage.cgi?tab=pools&pool='.
					       urlize($pool->{'uuid'}) }),
			      show_storage_volume_type($usage),
			      show_storage_volume_usage($usage),
			      nice_size($volume->{'capacity'}),
			      nice_size($volume->{'allocation'}) ]);
		}
	}
my $html = @unavailable
	? ui_note(text('storage_volumes_unavailable',
		       join(', ',
			    map { ui_tag('tt', html_escape($_)) }
			    @unavailable)))
	: '';
if (@rows) {
	# Keep each selection checkbox attached to its volume
	# when columns are hidden.
	my ($heads, $visible, $types) =
		table_columns('storage_volume_columns', \@rows, 1);
	# Match Images' standard selection controls even when all rows are
	# protected. The form index is relative to the module's content.
	$html .= $token
		? ui_form_columns_table('storage.cgi',
					[ [ 'delete',
					    $text{'storage_delete_selected'},
					    undef,
					    !$selectable ] ], 1, undef,
					[ [ 'action', 'review_volumes' ],
					  [ 'tab',
					    'volumes' ],
					  [ 'token', $token ] ],
					$heads, 100, $visible, $types, 0, undef,
					undef,
					$formno || 0, 1)
		: ui_columns_table($heads, 100, $visible, $types, 0, undef,
				   undef, 1);
	}
else {
	# The preceding notice still distinguishes unavailable
	# pools from empty ones.
	$html .= ui_empty_state({ icon => 'hard-drive', title =>
								$text{'storage_no_volumes'},
				  desc => $text{'storage_no_volumes_help'} });
	}
return $html;
}

# show_storage_delete_volumes(volumes, token) Lists the exact selected files and
# carries each reviewed revision into POST.
sub show_storage_delete_volumes
{
my ($volumes, $token) = @_;
my $form = storage_form('delete_volumes', $token, { }, 'volumes');
my @rows;
foreach my $volume (@$volumes) {
	$form .= ui_hidden('volume',
			   $volume->{'uuid'}.'/'.$volume->{'name'}).
		 ui_hidden('revision', $volume->{'revision'});
	# Presentation labels never replace the submitted volume identifier.
	push(@rows,
	     [ html_escape(storage_volume_label($volume)),
	       html_escape($volume->{'pool'}),
	       show_disk_location($volume->{'path'} ||
				  $volume->{'name'}),
	       nice_size_text($volume->{'capacity'}),
	       nice_size_text($volume->{'allocation'}) ]);
	}
return $form.ui_card({ title => $text{'storage_delete_selected'}, class =>
									  'cloudmin-storage-delete',
		       body =>
			       ui_alert(html_escape($text{'storage_delete_warning'}),
					'warning', [ 'fa-exclamation-triangle',
						     '', 1 ]).
			       ui_tag('div', ui_columns_table(
				       [ map {
			$text{$_} } qw(storage_name storage_pool storage_location storage_virtual_size storage_allocated) ],
				       100, \@rows, undef, 1),
				      { class => 'cloudmin-storage-table' }).
			       ui_checkbox('confirm', 1,
					   $text{'storage_delete_confirm'}, 0),
		       footer => ui_cluster([
			       ui_action_button($text{'storage_cancel'},
						'neutral',
						{ href => 'storage.cgi?tab=volumes' }),
			       ui_action_button($text{'storage_delete_selected'},
						'danger',
						{ type => 'submit',
						  icon => 'trash' }) ],
					    { align => 'end' }) }).
       ui_form_end();
}

# show_storage_unregister(record, token) renders the service's pool review.
# Clicking the submit button confirms removal and any reviewed stop.
sub show_storage_unregister
{
my ($record, $token) = @_;
my $reason = $record->{'usage'}->{'reason'};
my $label = $text{$record->{'stop_required'}
	? 'storage_stop_unregister'
	: 'storage_unregister'};
my @details = ( [ $text{'storage_name'}, html_escape($record->{'name'}) ],
		[ $text{'storage_location'},
		  ui_tag('tt', html_escape($record->{'path'})) ] );
# Keep machine links with the pool details and omit unused ownership rows.
my $owners = show_storage_volume_usage($record->{'usage'}, '');
push(@details, [ $text{'storage_used_by'}, $owners ]) if ($owners);
my $body = ui_p(html_escape($text{'storage_unregister_help'})).
	   ui_dl(\@details,
		 { wide => '5.5em',
		   class => 'cloudmin-storage-review-details' });
if ($record->{'stop_required'}) {
	# Explain the stop, including whole-group deactivation for LVM pools.
	$body .= ui_alert_box(html_escape($text{$record->{'type'} eq 'logical'
		? 'storage_unregister_lvm_stop'
		: 'storage_unregister_stop'}), 'warn');
	}
my @actions =
	(ui_action_button($text{'storage_cancel'}, 'neutral',
			  { href => 'storage.cgi?tab=pools' }));
if ($reason) {
	# A blocked review displays its reason without a submission control.
	$body .= ui_alert_box(html_escape($reason), 'warn');
	return ui_card({ title => $label, body => $body,
			 footer => ui_cluster(\@actions, { align => 'end' }) });
	}
# Submitting the reviewed action confirms removal without a second toggle.
push(@actions, ui_action_button($label, 'danger',
				{ type => 'submit', icon => 'unlink' }));
# Match the review's stop permission; an inactive pool requires no stop.
return storage_form('unregister', $token,
		    { id => $record->{'id'}, revision => $record->{'revision'},
		      confirm => 1,
		      stop => 1 }).
       ui_card({ title => $label, body => $body,
		 footer =>
			 ui_cluster(\@actions,
				    { align => 'end' }) }).ui_form_end();
}

# show_storage_create(token, values, [groups], [group_error]) Renders storage
# registration, retaining entered values after failure. groups defaults to an
# empty list; group_error reports discovery failures.
sub show_storage_create
{
my ($token, $values, $groups, $group_error) = @_;
$groups ||= [ ];
# A missing or removed group must never select a different group implicitly.
my $group = (grep { $_ eq ($values->{'group'} || '') } @$groups)
	? $values->{'group'}
	: '';
my @groups = ( [ '', $text{@$groups
	? 'storage_group_select'
	: 'storage_group_none'}, 'disabled' ],
	       map { [ $_, $_ ] } @$groups );
my $html = storage_form('create', $token).
	   ui_table_start(undef, 'width=100%', 2);
$html .= ui_table_row(undef, ui_p($text{'storage_create_help'}), 2);
$html .= ui_table_row($text{'storage_name'},
		      ui_textbox('name', $values->{'name'} || '', 24,
				 0, 64, 'placeholder="extra"'));
# Keep each backend's inputs together using the shared choice widget.
$html .= ui_table_row($text{'storage_backend'},
		      ui_choice('type', $values->{'type'} || 'dir', [
			      { value => 'dir',
				label => $text{'storage_directory'},
				content =>
					ui_textbox('path',
						   $values->{'path'} || '', 45,
						   0, 4096,
						   'placeholder="/var/lib/libvirt/extra"') },
			      # Wrap compact NFS fields together, without
			      # ui_field sibling margins.
			      { value => 'netfs', label => $text{'storage_nfs'},
				fields => [ [ undef, ui_cluster([
					map { ui_tag('div', $_,
						     { style => 'min-width:0' }) }
					ui_field($text{'storage_nfs_server'},
						 ui_textbox('server',
							    $values->{'server'} || '', 30,
							    0, undef,
							    'placeholder="nas.example.com"'), { for => 'server' }),
					ui_field($text{'storage_nfs_export'},
						 ui_textbox('export',
							    $values->{'export'} || '', 30,
							    0, 4096,
							    'placeholder="/exports/guests"'), { for => 'export' }),
					ui_field($text{'storage_nfs_mount'},
						 ui_textbox('mount',
							    $values->{'mount'} || '', 30,
							    0, 4096,
							    'placeholder="/var/lib/libvirt/nfs"'), { for => 'mount' }) ]) ] ] },
			      { value => 'logical',
				label => $text{'storage_group'},
				content => ui_cluster([
					ui_select('group', $group, \@groups, 1,
						  0, 0),
					ui_action_button($text{'storage_lvm_manage'},
							 'neutral',
							 { href => '../lvm/',
							   icon => 'hard-drive' }) ]) }
		      ]), 1, undef, undef, 1);
# Failed VG discovery must still leave directory registration available.
$html .= ui_table_row(undef,
		      ui_alert_box(text('storage_group_error',
					html_escape($group_error)),
				   'warn'), 2)
	if ($group_error);
$html .= ui_table_row(undef, ui_p($text{'storage_lvm_help'}), 2);
# Default startup on for a new form, but preserve an unchecked submitted value.
$html .= ui_table_row($text{'storage_autostart'},
		      ui_toggle({ name => 'autostart', value => 1,
				  label => $text{'storage_start_automatically'},
				  state =>
					  'success', round => 1,
				  checked => exists($values->{'action'})
					  ? $values->{'autostart'}
					  : 1 }));
$html .= ui_table_row(undef,
		      ui_action_button($text{'storage_create'}, 'success',
				       { type => 'submit', icon => 'plus' }),
		      2);
return $html.ui_table_end().ui_form_end();
}

# show_storage_pools(data, token, values, error, selected) Separates existing
# pools from creation, reopening creation after a failure.
sub show_storage_pools
{
my ($data, $token, $values, $error, $selected) = @_;
my @pools = @{$data->{'pools'} || [ ]};
# Open the selected card first without relying on theme-specific anchors.
my @ordered = ( grep({ $_->{'uuid'} eq $selected } @pools),
		grep({ $_->{'uuid'} ne $selected } @pools) );
my $list = @pools
	? ui_stack([ map { show_storage_pool($_, $token,
					     $_->{'uuid'} eq $selected) } @ordered ])
	: ui_empty_state({ icon => 'hard-drive', title => $text{'storage_none'},
			   desc => $text{'storage_none_desc'} });
# Remote connections and read-only users cannot create pools.
return $list if (!$token || !$data->{'local'});
# Nested tabs must not change which outer inventory tab is visible.
local $main::ui_tabs_selected = $main::ui_tabs_selected;
my $tab = $error && ($values->{'action'} || '') eq 'create' ? 'create' : 'list';
# Creation errors retain the form; ordinary visits and
# successful saves list pools.
my $html = ui_tabs_start([
	[ 'storage_pool_list', $text{'storage_existing'} ],
	[ 'storage_pool_create', $text{'storage_create'} ] ],
			 'cloudmin_storage_pool_tabs', 'storage_pool_'.$tab, 1);
$html .= ui_tabs_start_tab('cloudmin_storage_pool_tabs', 'storage_pool_list').
	 ui_tag('div', $list, { 'data-storage-pool-tab' => 'list' }).
	 ui_tabs_end_tab('cloudmin_storage_pool_tabs', 'storage_pool_list');
$html .= ui_tabs_start_tab('cloudmin_storage_pool_tabs',
			   'storage_pool_create').
	 ui_tag('div',
		show_storage_create($token, $values, $data->{'lvm_groups'},
				    $data->{'lvm_group_error'}),
		{ class => 'cloudmin-storage-tab cloudmin-storage-create',
		  'data-storage-pool-tab' => 'create' }).
	 ui_tabs_end_tab('cloudmin_storage_pool_tabs', 'storage_pool_create');
return $html.ui_tabs_end(1);
}

# show_storage_page(data, [token], [tab], [values], [error], [selected],
#                   [deletion], [pool_review])
# Builds storage tabs; a review replaces its inventory when token is present.
# values retains form inputs, selected focuses a pool, and tab defaults to
# overview. Without token, the page offers no changes.
sub show_storage_page
{
my ($data, $token, $tab, $values, $error, $selected, $deletion,
    $pool_review) =
	@_;
$selected ||= '';
my @pools = @{$data->{'pools'} || [ ]};
$values ||= { };
$tab = storage_page_tab($tab);
my $html = $error ? ui_alert_box(html_escape($error), 'danger') : '';
return $html.ui_alert_box(text('error_storage',
			       html_escape($data->{'error'})),
			  'danger') if ($data->{'error'});
$html .= ui_tabs_start([ [ 'storage_overview', $text{'storage_overview_tab'} ],
			 [ 'storage_pools', $text{'storage_pools'} ],
			 [ 'storage_volumes', $text{'storage_volumes'} ] ],
		       'cloudmin_storage_tabs', 'storage_'.$tab, 1);
foreach my $section (qw(overview pools volumes)) {
	my $body =
		ui_tag('div',
		       ui_p(html_escape($text{'storage_'.$section.'_intro'})),
		       { class => 'vui_ui_block' });
	if ($section eq 'overview') {
		# Summarize shared filesystem capacity
		# without counting it twice.
		$body .= show_storage_overview($data);
		}
	elsif ($section eq 'pools') {
		# A pool review replaces both the list and the creation form.
		$body .= $pool_review && $token
			? show_storage_unregister($pool_review, $token)
			: show_storage_pools($data, $token, $values, $error,
					     $selected);
		}
	else {
		# The volumes tab contains either the reviewed
		# deletion or the inventory.
		if ($deletion && $token) {
			# Keep the confirmation focused on the selected volumes.
			$body .= show_storage_delete_volumes($deletion, $token);
			}
		else {
			# Explain incomplete ownership checks before
			# showing protected rows.
			$body .= ui_alert_box(text('storage_usage_incomplete',
						   html_escape(join(' ',
								    @{$data->{'usage_errors'}}))),
					      'warn') if (@{$data->{'usage_errors'} || [ ]});
			# Count emitted forms, since theme callbacks can also
			# increment Webmin's global form counter without
			# adding another form.
			my $formno = () = $html =~ /<form\b/g;
			$body .= show_storage_volumes(\@pools, $token,
						      $data->{'local'},
						      $formno);
			}
		}
	# Fixed positional widths apply only when the volume
	# table has every column.
	$html .= ui_tabs_start_tab('cloudmin_storage_tabs',
				   'storage_'.$section).
		 ui_tag('div', $body, { class => 'cloudmin-storage-tab'.
						 ($section eq 'volumes' &&
						  scalar(view_selection(
							  'storage_volume_columns')) < 7
								  ? ' cloudmin-storage-compact-columns'
								  : ''),
					'data-storage-tab' => $section,
					$section eq 'volumes'
						? ( id => 'cloudmin-storage-volumes' )
						: () }).
		 ui_tabs_end_tab('cloudmin_storage_tabs', 'storage_'.$section);
	}
return $html.ui_tabs_end(1);
}

1;
