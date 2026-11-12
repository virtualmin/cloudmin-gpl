# Notification history and settings use the shared Webmin page widgets.
use strict;
use warnings;
our (%text, $remote_user, $module_root_directory);

# notification_action(action, id, label, token) creates a row action form.
# action is an API action, id identifies its record, label is button text, and
# token is the caller's signed form token. Deletions ask for confirmation.
sub notification_action
{
my ($action, $id, $label, $token) = @_;
# Deletions use the danger style, a trash icon and a confirmation prompt.
my $delete = $action =~ /\Adelete_/;
return ui_form_start('notification_save.cgi', 'post').
	ui_hidden('action', $action).ui_hidden('object', $id).
	ui_hidden('token', $token).
	ui_action_button($label, $delete ? 'danger' : 'neutral', {
		type => 'submit', size => 'small',
		icon => $delete ? 'trash' : 'refresh',
		attrs => $delete
			? { 'data-ui-confirm' =>
				$text{notifications_delete_confirm} }
			: { },
	}).ui_form_end();
}

# show_notification_history(data, config, token, guest) renders scoped events.
# data contains events and states; config supplies saved rule and target names.
# An empty token hides retry controls; guest views omit delivery destinations.
sub show_notification_history
{
my ($data, $cfg, $token, $guest) = @_;
# Encode saved names once for Webmin's byte-based page output.
my %targets = map { $_->{id} => notification_bytes($_->{name}) } @{$cfg->{targets} || [ ]};
my %rules = map { $_->{id} => notification_bytes($_->{name}) } @{$cfg->{rules} || [ ]};
my @attention = map {
	# A paused record without a saved reason uses the generic label.
	my $status = $text{'notifications_'.$_->{status}};
	$status = $text{'notifications_paused_'.($_->{pause_reason} || '')} ||
		$status if $_->{status} eq 'paused';
	{ title => notification_bytes($_->{label}),
	  desc => $rules{$_->{rule}} || notification_bytes($_->{name}),
	  badge => [ $status,
		     $_->{status} eq 'active' ? 'danger' : 'warning' ] }
	} grep { $_->{status} ne 'ok' } @{$data->{states}};
# List active, pending and paused conditions above the event history.
my @cards;
push @cards, ui_card({ title => $text{notifications_conditions},
	body => ui_list(\@attention) }) if @attention;
my @rows;
for my $event (reverse @{$data->{events}}) {
	# Escape event text and delivery errors; date and
	# badge helpers return HTML.
	my $phase = $event->{phase};
	my $severity = $event->{severity};
	my @row = ( make_date($event->{created}),
		html_escape(notification_bytes($event->{name})),
		html_escape(notification_bytes($event->{label})),
		ui_badge($text{'notifications_'.$severity},
			$severity eq 'error' ? 'danger' : $severity,
			{ small => 1 }),
		ui_badge($text{'notifications_'.$phase},
			$phase eq 'resolved' ? 'success' : 'neutral',
			{ small => 1 }) );
	if (!$guest) {
		# Keep each receipt and any retry beside its event.
		my @receipts = map {
			ui_tag('div', html_escape(
				($targets{$_->{target}} || $_->{target}).': '.
				$text{'notifications_'.$_->{state}}.
				($_->{error} ? ': '.notification_bytes($_->{error}) : '')))
			} @{$event->{deliveries} || [ ]};
		# Offer a retry to editors when a delivery has failed.
		push @receipts, notification_action('retry_notification',
			$event->{id}, $text{notifications_retry}, $token)
			if $token && grep { $_->{state} eq 'failed' }
				@{$event->{deliveries} || [ ]};
		push @row, join('', @receipts);
		}
	push @rows, \@row;
	}
# Host history includes receipts; guest history exposes only event details.
my @heads = map { $text{'notifications_'.$_} }
	qw(time name subject severity state);
push @heads, $text{notifications_delivery} unless $guest;
# Show the retention note above events, or an empty state without them.
push @cards, ui_card({ id => 'notification-history',
	desc => @rows ? $text{notifications_retention} : undef,
	body => @rows
		? ui_columns_table(\@heads, 100, \@rows, undef, 0,
				   undef, undef, 1)
		: ui_empty_state({ icon => 'clock',
			title => $text{notifications_empty},
			desc => $text{notifications_empty_desc} }),
});
return ui_stack(\@cards);
}

# notification_delivery_status([receipt]) shows an attempt or no delivery.
# Receipts without a recorded attempt time show only their state.
# receipt contains state, error and an optional Unix attempt time in at.
sub notification_delivery_status
{
my ($last) = @_;
# No receipt means this destination has had no delivery yet.
return ui_chip($text{notifications_no_delivery},
	{ state => 'neutral', class => 'notification-delivery-status' })
	unless $last;
my $state = $last->{state};
# A failed attempt waiting for retry must not look like a first queued send.
my $failed = $last->{error} && $state eq 'queued';
# Choose the wording and chip color for the receipt's state.
my $label = $text{$failed ? 'notifications_retry_pending'
	: $state eq 'sent' ? 'notifications_delivered'
	: 'notifications_'.$state};
my $color = $state eq 'sent' ? 'success'
	: $state eq 'failed' || $failed ? 'danger'
	: $state eq 'sending' || $state eq 'queued' ? 'info' : 'neutral';
# Queue and cancellation changes are not evidence of a new delivery attempt.
# Chips escape their labels, so discard the theme's date wrapper first.
$label .= ' · '.html_strip(make_date($last->{at}))
	if $last->{at} && ($state eq 'sent' || $state eq 'failed' || $failed);
return ui_chip($label, { state => $color,
	class => 'notification-delivery-status' }).
	($last->{error} ? ui_tag('div', html_escape(notification_bytes($last->{error})),
		{ class => 'notification-delivery-error' }) : '');
}

# notification_destination_icon(type) keeps icons visible without a theme font.
# Use an envelope for email and a globe for HTTP delivery methods.
sub notification_destination_icon
{
my ($type) = @_;
return ui_svg_icon('globe', { size => 20 }) if $type ne 'email';
# The shared SVG set has no envelope yet; draw it with the same stroke style.
return ui_tag('svg', ui_tag('path', undef, {
	d => 'M2 3h12v10H2z M2 3l6 5 6-5' }), {
	class => 'notification-envelope', width => 20, height => 20,
	viewBox => '0 0 16 16', fill => 'none', stroke => 'currentColor',
	'stroke-width' => 1.5, 'stroke-linecap' => 'round',
	'stroke-linejoin' => 'round', 'aria-hidden' => 'true' });
}

# show_notification_destinations(config, token) renders the destination list.
# An empty token keeps switches read-only and hides editing actions. config
# contains the redacted targets and rules used for reference counts.
sub show_notification_destinations
{
my ($cfg, $token) = @_;
my @rows;
my @columns = qw(destination used_by last_delivery enabled actions);
for my $row (@{$cfg->{targets}}) {
	# Escape saved identity and show the address only
	# when it adds information.
	my $id = $row->{id};
	my $edit = 'notification_form.cgi?kind=target&object='.$id;
	my $name = html_escape(notification_bytes($row->{name}));
	$name = ui_link($edit, $name, 'text-link') if $token;
	# Private chat URLs are listed by hostname only.
	my $type = $text{'notifications_'.$row->{type}};
	my $address = notification_bytes(
		$row->{address} || $row->{address_host} || '');
	my $identity = ui_tag('span', notification_destination_icon($row->{type}),
		{ class => 'notification-destination-icon' }).
		ui_tag('div', ui_tag('div', $name,
			{ class => 'notification-destination-name' }).
			ui_tag('div', html_escape($type.(!$address ||
				notification_bytes($row->{name}) eq $address
				? '' : ' · '.$address)),
				{ class => 'notification-destination-type',
				  title => html_escape($address) }),
			{ class => 'notification-destination-text' });
	# Count all references, including disabled rules, just as deletion does.
	my $count = grep { my $r = $_;
		grep { $_ eq $id } @{$r->{targets}} } @{$cfg->{rules}};
	my $usage = $count ? ui_link('notifications.cgi?tab=rules&target='.$id,
		html_escape($count == 1 ? $text{notifications_one_rule}
			: text('notifications_rule_count', $count)), 'text-link')
		: ui_tag('span', html_escape($text{notifications_unused}),
			{ class => 'notification-muted' });
	# Keep read-only state visible without offering a submit action.
	my $toggle = ui_toggle({ name => 'enabled', value => 1,
		id => 'notification-enabled-'.$id,
		checked => $row->{enabled}, disabled => !$token,
		state => 'primary', round => 1,
		attrs => { 'aria-label' => html_escape(text('notifications_enable_target',
			notification_bytes($row->{name}))),
			$token ? ( onchange => 'this.form.requestSubmit()' ) : () } });
	my $actions = '';
	if ($token) {
		# State changes and progress actions use separate signed forms.
		$toggle = ui_form_start('notification_save.cgi', 'post').
			ui_hidden('action', 'set_notification_target_enabled').
			ui_hidden('object', $id).ui_hidden('token', $token).
			$toggle.ui_form_end();
		# Testing and deletion share this destination's progress form.
		$actions = ui_form_start('notification_action_progressive.cgi',
			'post').ui_hidden('kind', 'target').
			ui_hidden('object', $id).ui_hidden('token', $token).
			ui_cluster([
				ui_action_button($text{notifications_send_test}, 'neutral',
					{ type => 'submit', name => 'send', value => 1,
					  icon => 'refresh', size => 'small', shape => 'rounded',
					  disabled => !$row->{enabled} }),
				ui_action_button($text{delete}, 'danger',
					{ type => 'submit', name => 'delete', value => 1,
					  icon => 'trash', size => 'small', shape => 'rounded' })
			], { gap => '6px', class => 'notification-row-actions' }).
			ui_form_end();
		}
	# Cell labels replace the shared heading on narrow screens.
	my @cells = ( $identity, $usage,
		notification_delivery_status($row->{last_delivery}), $toggle, $actions );
	push @rows, ui_tag('div', join('', map {
		ui_tag('div', $cells[$_], { role => 'cell',
			class => 'notification-cell notification-'.$columns[$_],
			'data-label' => $text{'notifications_'.$columns[$_]} })
		} 0 .. $#columns), { role => 'row',
		id => 'notification-target-'.$id, class => 'notification-row' });
	}
return notification_rows('target', \@rows, \@columns, $token);
}

# notification_rows(kind, rows, columns, token) builds the list and toolbar.
# kind is rule or target; rows is an array of rendered HTML and columns is an
# array of suffixes for notifications_ translation keys. An empty
# token hides the Add action.
sub notification_rows
{
my ($kind, $rows, $columns, $token) = @_;
my $tab = $kind.'s';
my $noun = $kind eq 'target' ? 'destination' : 'rule';
# Only editors get the Add button.
my $create = $token ? ui_action_button($text{'notifications_add_'.$noun},
	'info', { icon => 'plus', size => 'normal',
		class => 'notification-add',
		href => 'notification_form.cgi?kind='.$kind }) : '';
# Empty lists need a setup action but no unused column headings.
return ui_empty_state({ icon => $kind eq 'target' ? 'external' : 'filter',
	title => $text{'notifications_'.$tab.'_empty'},
	desc => $text{'notifications_'.$tab.'_desc'}, actions => $create }) unless @$rows;
# Show the count and add action above a table that adapts to narrow screens.
my $count = @$rows == 1 ? $text{'notifications_one_'.$noun}
	: text('notifications_'.$noun.'_count', scalar(@$rows));
# Headings and rows are div elements with ARIA table roles.
my $head = ui_tag('div', join('', map { ui_tag('div',
	html_escape($text{'notifications_'.$_}), { role => 'columnheader' }) }
	@$columns), { role => 'row', class => 'notification-row notification-head' });
return ui_stack([
	ui_cluster([ ui_tag('span', html_escape($count),
		{ class => 'notification-muted' }), $create ], { align => 'between' }),
	ui_tag('div', $head.ui_tag('div', join('', @$rows), { role => 'rowgroup' }),
		{ role => 'table', 'aria-label' => $text{'notifications_'.$tab},
		  class => 'notification-records notification-'.
			($kind eq 'target' ? 'destinations' : 'rules') })
	]);
}

# show_notification_list(kind, config, token, scopes) renders saved records.
# kind is rule or target; config contains redacted rules and destinations.
# scopes maps guest IDs and host selectors to labels. An empty token hides
# editing controls.
sub show_notification_list
{
my ($kind, $cfg, $token, $scopes) = @_;
# Destinations have their own row layout.
return show_notification_destinations($cfg, $token) if $kind eq 'target';
my (@rows, @columns);
@columns = qw(name condition scope enabled actions);
for my $row (@{$cfg->{rules}}) {
	# Keep the name readable without an edit link in read-only views.
	my $id = $row->{id};
	my $name = html_escape(notification_bytes($row->{name}));
	$name = ui_link('notification_form.cgi?kind=rule&object='.$id,
		$name, 'text-link') if $token;
	my $identity = ui_tag('span', ui_svg_icon('filter'),
		{ class => 'notification-destination-icon' }).
		ui_tag('div', ui_tag('div', $name,
			{ class => 'notification-rule-name' }).
			ui_tag('div', html_escape($text{'notifications_'.$row->{severity}}),
				{ class => 'notification-rule-severity' }));
	# Show the saved condition and resolve guest names
	# without changing scope.
	my $condition = $text{'notifications_'.$row->{metric}};
	my $definition = Cloudmin::NotificationTypes::metric($row->{metric});
	if ($definition->{numeric}) {
		# Thresholds retain their actual units and comparison direction.
		$condition .= (($row->{comparison} || 'ge') eq 'le' ? ' <= ' : ' >= ').
			$row->{threshold}.($definition->{unit} eq '%' ? '%' :
				length($definition->{unit}) ? ' '.$definition->{unit} : '');
		}
	my @owners = ref($row->{scope}) eq 'ARRAY'
		? @{$row->{scope}} : ($row->{scope});
	my $scope = join(', ', map { $scopes->{$_} || $_ } @owners);
	# Keep read-only state visible without offering a submit action.
	my $toggle = ui_toggle({ name => 'enabled', value => 1,
		id => 'notification-rule-enabled-'.$id,
		checked => $row->{enabled}, disabled => !$token,
		state => 'primary', round => 1,
		attrs => { 'aria-label' => html_escape(text('notifications_enable_rule',
			notification_bytes($row->{name}))),
			$token ? ( onchange => 'this.form.requestSubmit()' ) : () } });
	my $actions = '';
	if ($token) {
		# Each switch and deletion submits only this
		# rule and its signed token.
		$toggle = ui_form_start('notification_save.cgi', 'post').
			ui_hidden('action', 'set_notification_rule_enabled').
			ui_hidden('object', $id).ui_hidden('token', $token).
			$toggle.ui_form_end();
		# A separate delete form avoids submitting stale rule settings.
		$actions = ui_form_start('notification_action_progressive.cgi', 'post').
			ui_hidden('kind', 'rule').ui_hidden('object', $id).
			ui_hidden('token', $token).
			ui_action_button($text{delete}, 'danger', {
				type => 'submit', name => 'delete', value => 1,
				icon => 'trash', size => 'small', shape => 'rounded' }).
			ui_form_end();
		}
	# Use the same responsive cell labels as destination rows.
	my @cells = ( $identity, html_escape($condition), html_escape($scope),
		$toggle, $actions );
	push @rows, ui_tag('div', join('', map {
		ui_tag('div', $cells[$_], { role => 'cell',
			class => 'notification-cell notification-'.$columns[$_],
			'data-label' => $text{'notifications_'.$columns[$_]} })
		} 0 .. $#columns), { role => 'row', id => 'notification-rule-'.$id,
		class => 'notification-row' });
	}
return notification_rows('rule', \@rows, \@columns, $token);
}

# show_notifications(tab, [owner], [target]) renders history and settings.
# tab is history, rules or targets. A guest UUID in owner restricts history;
# host or an omitted owner includes host and guest events. An optional
# destination ID in target filters the rule list only.
sub show_notifications
{
my ($tab, $owner, $target) = @_;
my $guest = defined($owner) && $owner ne 'host';
# Read history first. The API checks access to the requested scope.
my $data = call_notification_api('notifications',
	defined($owner) ? { id => $owner } : { });
# Guest views never read host rules, targets or another guest's history.
return ui_page_start().show_notification_history($data, { }, '', 1).
	ui_page_end() if $guest;
my $cfg = call_notification_api('notification_config', { });
# A usage link filters only Rules, leaving destination counts unchanged.
my ($destination) = grep { $_->{id} eq ($target || '') } @{$cfg->{targets}};
die "Notification destination not found\n" if $target && !$destination;
# Editing controls need management access outside read-only mode.
my $token = !is_readonly_mode() && can_access('manage')
	? get_image_jobs()->form_token($remote_user) : '';
# Label scopes by name. Fall back to saved IDs if the host inventory is
# temporarily unavailable.
my %scopes = ( map { $_ => $text{'notifications_'.$_} } qw(host guests all) );
my $vms = eval { get_api_machines({ }) } || [ ];
$scopes{$_->{id}} = $_->{name} for @$vms;
# Add the file's modification time so browsers reload a changed stylesheet.
my $html = ui_page_start().ui_tag('link', undef, {
	rel => 'stylesheet', href => get_webprefix().'/server-manager/notifications.css?'.
		(stat("$module_root_directory/notifications.css"))[9] });
my $worker = $cfg->{worker};
# Enabled rules show a warning after three missed checks. Wait at least three
# minutes, so short intervals do not warn during one slow run.
my $stale = 3 * config_number('notifications_interval');
$stale = 180 if $stale < 180;
$html .= ui_alert_box(html_escape($text{notifications_worker_stale}), 'warn')
	if (grep { $_->{enabled} } @{$cfg->{rules}}) &&
		(!$worker || time() - $worker->{checked_at} > $stale);
# Show the worker's safe error separately from the last-completion warning.
$html .= ui_alert_box(html_escape(notification_bytes($worker->{error})), 'danger')
	if $worker && $worker->{error};
# Render all sections so tab changes need no additional request.
$html .= ui_tabs_start([ map { [ 'notifications_'.$_,
	$text{'notifications_'.$_} ] } qw(history rules targets) ],
	'notification_tabs', 'notifications_'.$tab, 1);
for my $section (qw(history rules targets)) {
	$html .= ui_tabs_start_tab('notification_tabs',
				   'notifications_'.$section);
	my $section_cfg = $cfg;
	if ($section eq 'rules' && $destination) {
		# Filter a copy so other tabs retain their
		# full settings and counts.
		$section_cfg = { %$cfg, rules => [ grep {
			my $r = $_; grep { $_ eq $target } @{$r->{targets}}
			} @{$cfg->{rules}} ] };
		$html .= ui_cluster([
			html_escape(text('notifications_rules_using',
				notification_bytes($destination->{name}))),
			ui_link('notifications.cgi?tab=rules',
				html_escape($text{notifications_all_rules}), 'text-link')
		]);
		}
	# History lists events. The other tabs list rules or destinations.
	$html .= $section eq 'history'
		? show_notification_history($data, $cfg, $token, 0)
		: show_notification_list(
			$section eq 'rules' ? 'rule' : 'target',
			$section_cfg, $token, \%scopes);
	$html .= ui_tabs_end_tab('notification_tabs',
				 'notifications_'.$section);
	}
return $html.ui_tabs_end(1).ui_page_end();
}

# notification_field(name, key, input, [options]) adds a table row with help.
# name supplies the default row ID; key selects the notifications_ label
# and help topic. input is rendered control HTML. options defaults to an
# empty hash and may override help or id, or set visible to false. Hidden
# rows keep their IDs for the shared change handlers.
sub notification_field
{
my ($name, $key, $input, $opts) = @_;
$opts ||= { };
my $attrs = 'id="'.quote_escape($opts->{id} || 'notification-'.$name).'"';
$attrs .= ' style="display:none"'
	if exists($opts->{visible}) && !$opts->{visible};
return ui_table_row(hlink($text{'notifications_'.$key},
			 'notifications_'.($opts->{help} || $key)),
		    $input, 1, undef, [ $attrs ]);
}

# notification_multiselect(name, values, options, [disabled]) renders a native
# list sized to its options, including saved values absent from the inventory.
# values is an array of selected IDs; options contains [value, label] pairs.
# disabled defaults to false. Missing saved IDs remain selectable.
sub notification_multiselect
{
my ($name, $values, $options, $disabled) = @_;
my %items = map { $_ => 1 } (@$values, map { $_->[0] } @$options);
my $size = keys(%items);
# Keep a list box even with one option; CSS limits its rendered height.
$size = 2 if $size < 2;
return ui_select($name, $values, $options, $size, 1, 1, $disabled);
}

# notification_address_fields(record) renders the selected destination fields.
# record supplies type, address and secret; missing type defaults to email.
# Authorized destination editors show saved tokens for editing.
sub notification_address_fields
{
my ($record) = @_;
# Each method shows its own address field. Only generic webhooks and ntfy
# take a bearer token.
my $type = $record->{type} || 'email';
my $email = $type eq 'email';
my $telegram = $type eq 'telegram';
my $pushover = $type eq 'pushover';
my $gotify = $type eq 'gotify';
my $webhook = $type =~ /\A(?:webhook|slack|discord|teams|ntfy)\z/;
my $bearer = $type eq 'webhook' || $type eq 'ntfy';
my $secret = ui_textbox('secret', $bearer ? notification_bytes($record->{secret}) : '',
	40, !$bearer,
	2048, 'autocomplete="off" spellcheck="false"');
# Disable hidden method fields so stale values cannot enter the submission.
return notification_field('email_address', 'email_address',
		ui_textbox('email_address', $email ? notification_bytes($record->{address}) : '',
			   60, !$email, 2048,
			   'placeholder="ops@example.com"'),
		{ id => 'notification-email-address', visible => $email }).
	notification_field('webhook_url', 'webhook_url',
		ui_textbox('webhook_url', $webhook ? notification_bytes($record->{address}) : '',
			   60, !$webhook, 2048,
			   'placeholder="https://alerts.example.com/cloudmin"'),
		{ id => 'notification-webhook-url', visible => $webhook }).
	notification_field('secret', 'secret', $secret,
		{ id => 'notification-webhook-secret', visible => $bearer }).
	notification_field('telegram_chat', 'telegram_chat',
		ui_textbox('telegram_chat', $telegram ? notification_bytes($record->{address}) : '',
			40, !$telegram, 2048, 'placeholder="-1001234567890"'),
		{ id => 'notification-telegram-chat', visible => $telegram }).
	notification_field('telegram_token', 'telegram_token',
		ui_textbox('telegram_token', $telegram ? notification_bytes($record->{secret}) : '',
			40, !$telegram, 2048,
			'autocomplete="off" spellcheck="false"'),
		{ id => 'notification-telegram-token', visible => $telegram }).
	notification_field('pushover_user', 'pushover_user',
		ui_textbox('pushover_user', $pushover
			? notification_bytes($record->{address}) : '',
			40, !$pushover, 30,
			'autocomplete="off" spellcheck="false"'),
		{ id => 'notification-pushover-user', visible => $pushover }).
	notification_field('pushover_token', 'pushover_token',
		ui_textbox('pushover_token', $pushover
			? notification_bytes($record->{secret}) : '',
			40, !$pushover, 30,
			'autocomplete="off" spellcheck="false"'),
		{ id => 'notification-pushover-token', visible => $pushover }).
	notification_field('gotify_url', 'gotify_url',
		ui_textbox('gotify_url', $gotify
			? notification_bytes($record->{address}) : '',
			60, !$gotify, 2048,
			'placeholder="https://gotify.example.com"'),
		{ id => 'notification-gotify-url', visible => $gotify }).
	notification_field('gotify_token', 'gotify_token',
		ui_textbox('gotify_token', $gotify
			? notification_bytes($record->{secret}) : '',
			40, !$gotify, 2048,
			'autocomplete="off" spellcheck="false"'),
		{ id => 'notification-gotify-token', visible => $gotify });
}

# notification_address_state(control) returns delivery-method change handlers.
# control names the selector; hidden address and token fields stay disabled.
sub notification_address_state
{
# Show only fields used by the selected method and exclude hidden inputs.
return ui_form_field_state_javascript(
	$_[0], [ 'email' ], [ 'notification-email-address' ],
	[ 'email_address' ]).
	ui_form_field_state_javascript(
		$_[0], [ qw(webhook slack discord teams ntfy) ],
		[ 'notification-webhook-url' ], [ 'webhook_url' ]).
	ui_form_field_state_javascript(
		$_[0], [ 'webhook', 'ntfy' ],
		[ 'notification-webhook-secret' ], [ 'secret' ]).
	ui_form_field_state_javascript(
		$_[0], [ 'telegram' ],
		[ 'notification-telegram-chat', 'notification-telegram-token' ],
		[ 'telegram_chat', 'telegram_token' ]).
	ui_form_field_state_javascript(
		$_[0], [ 'pushover' ],
		[ 'notification-pushover-user', 'notification-pushover-token' ],
		[ 'pushover_user', 'pushover_token' ]).
	ui_form_field_state_javascript(
		$_[0], [ 'gotify' ],
		[ 'notification-gotify-url', 'notification-gotify-token' ],
		[ 'gotify_url', 'gotify_token' ]);
}

# show_notification_form(kind, [edit]) renders only the chosen editor.
# kind is rule or target; edit is an existing record ID, omitted for creation.
sub show_notification_form
{
my ($kind, $edit) = @_;
die "Invalid notification form\n" unless $kind =~ /\A(?:target|rule)\z/;
# Editors need host and management access outside read-only mode.
require_access('host');
require_access('manage');
die "Notification changes are disabled in read-only mode\n"
	if is_readonly_mode();
# Unknown edit IDs must fail rather than silently opening a new record.
my $cfg = call_notification_api('notification_config', { });
my $rows = $cfg->{$kind.'s'};
my $token = get_image_jobs()->form_token($remote_user);
my ($record) = defined($edit) ? grep { $_->{id} eq $edit } @$rows : ();
die "Notification not found\n" if defined($edit) && !$record;
if ($kind eq 'target' && defined($edit)) {
	# Load this destination's token only after editor access checks pass.
	$record = get_notifications()->target($edit);
	}
# A new record starts from the default rule settings.
$record ||= { enabled => 1, recovery => 1, duration => 5,
	threshold => 90, reminder => 0, cooldown => 5, scope => 'host' };
# Both editors submit a signed record to the same save handler.
my $html = ui_page_start({ id => 'notification-editor' }).
	ui_tag('link', undef, { rel => 'stylesheet',
		href => get_webprefix().'/server-manager/notifications.css?'.
			(stat("$module_root_directory/notifications.css"))[9] }).
	ui_form_start('notification_save.cgi', 'post').
	ui_hidden('action', 'save_notification_'.$kind).
	ui_hidden('token', $token).ui_hidden('object', $record->{id} || '');
# Keep the native table layout and natural control widths in both editors.
$html .= ui_table_start($text{'notifications_'.$kind}, 'width=100%', 2);
$html .= notification_field('enabled', 'enabled',
	ui_yesno_radio('enabled', $record->{enabled}, 1, 0),
	{ help => $kind.'_enabled', id => 'notification-enabled-field' });
$html .= notification_field('name', 'name',
	ui_textbox('name', notification_bytes($record->{name}), 40, 0, 100));
if ($kind eq 'target') {
	# Separate the delivery selector from the destination's identity.
	my @methods = map { [ $_, $text{'notifications_'.$_} ] }
		Cloudmin::NotificationTypes::transports();
	$html .= ui_table_hr();
	$html .= notification_field('type', 'type',
		ui_select('type', $record->{type} || 'email', \@methods));
	$html .= notification_address_fields($record);
	}
else {
	# Keep severity with the rule's identity and enabled state.
	$html .= notification_field('severity', 'severity',
		ui_select('severity', $record->{severity} || 'warning',
			[ map { [ $_, $text{'notifications_'.$_} ] }
			  qw(notice warning error) ]));
	$html .= ui_table_hr();
	# Hide settings that do not apply to the
	# selected condition on first render.
	my @metrics = map { [ $_, $text{'notifications_'.$_} ] }
		Cloudmin::NotificationTypes::metrics();
	my $metric = $record->{metric} || 'cpu';
	my $definition = Cloudmin::NotificationTypes::metric($metric);
	my $usage = $definition->{numeric};
	my $device = $definition->{device};
	my $sustained = $metric ne 'job_failed';
	# A scope holding one guest UUID opens as one selected guest.
	my $scope = $record->{scope};
	my $mode = ref($scope) || $scope !~ /\A(?:host|guests|all)\z/
		? 'selected' : $scope;
	my $selected = ref($scope) eq 'ARRAY'
		? $scope : $mode eq 'selected' ? [ $scope ] : [ ];
	my @modes = ( [ host => $text{notifications_host} ],
		      [ guests => $text{notifications_guests} ] );
	# Keep saved UUIDs even when guests are absent from the inventory.
	my $vms = get_api_machines({ });
	my @guests = map { [ $_->{id}, $_->{name} ] } @$vms;
	push @modes, [ selected => $text{notifications_selected_guests} ]
		if @guests || @$selected;
	push @modes, [ all => $text{notifications_all} ];
	my $monitor = ui_select('scope_mode', $mode, \@modes);
	if (@guests || @$selected) {
		# Preserve selections while other monitor modes hide the list.
		$monitor .= ui_tag('div', notification_multiselect(
			'scope', $selected, \@guests, $mode ne 'selected'),
			{ id => 'notification-selected-guests',
			  style => $mode eq 'selected' ? '' : 'display:none' });
		}
	# Give conditional fields stable IDs so hidden controls can be disabled.
	$html .= notification_field('metric', 'condition',
		ui_select('metric', $metric, \@metrics));
	$html .= notification_field('scope_mode', 'scope', $monitor);
	$html .= notification_field('device', 'device',
		ui_textbox('device', notification_bytes($record->{device}), 40, !$device),
		{ id => 'notification-device', visible => $device });
	# Units change with the metric; controls keep their natural width.
	my $units = '';
	for my $unit ('%', 'GiB', 'MiB/s') {
		my $id = $unit eq '%' ? 'percent' : $unit eq 'GiB' ? 'gib' : 'rate';
		$units .= ui_tag('span', ' '.html_escape($unit), {
			id => 'notification-unit-'.$id,
			style => $definition->{unit} eq $unit ? '' : 'display:none' });
		}
	# Numeric conditions need a comparison and a
	# threshold in the shown units.
	$html .= notification_field('comparison', 'comparison',
		ui_select('comparison', $record->{comparison} || 'ge',
			[ map { [ $_, $text{'notifications_'.$_} ] } qw(ge le) ],
			1, 0, 0, !$usage),
		{ id => 'notification-comparison', visible => $usage });
	$html .= notification_field('threshold', 'threshold',
		ui_textbox('threshold', $record->{threshold}, 8, !$usage).$units,
		{ id => 'notification-threshold', visible => $usage });
	# Job failures are immediate; other conditions can
	# require a waiting period.
	$html .= notification_field('duration', 'duration',
		ui_textbox('duration', $record->{duration}, 8, !$sustained),
		{ id => 'notification-duration', visible => $sustained });
	# Job failures have no recovery, cooldown or reminder settings.
	$html .= notification_field('recovery', 'recovery',
		ui_yesno_radio('recovery', $record->{recovery}, 1, 0,
			       !$sustained),
		{ id => 'notification-timing', visible => $sustained });
	for my $field (qw(cooldown reminder)) {
		my $label = $field eq 'reminder' ? 'repeat' : $field;
		$html .= notification_field($field, $label,
			ui_textbox($field, $record->{$field}, 8, !$sustained),
			{ visible => $sustained });
		}
	$html .= ui_table_hr();
	# With no saved destinations, offer inline creation directly.
	my $delivery = @{$cfg->{targets}} ? 'saved' : 'email';
	my @delivery = map { [ $_, $text{'notifications_new_'.$_} ] }
		Cloudmin::NotificationTypes::transports();
	unshift @delivery, [ saved => $text{notifications_saved_targets} ]
		if @{$cfg->{targets}};
	$html .= notification_field('delivery', 'send_to',
		ui_select('delivery', $delivery, \@delivery));
	if (@{$cfg->{targets}}) {
		# Reuse saved destinations without exposing their credentials.
		$html .= notification_field('targets', 'targets',
			notification_multiselect(
				'targets', $record->{targets} || [ ],
				[ map { [ $_->{id}, notification_bytes($_->{name}) ] }
				  @{$cfg->{targets}} ]),
			{ id => 'notification-saved-targets', visible => 1 });
		}
	# New destination details stay disabled
	# while a saved selection is active.
	$html .= notification_field('target_name', 'destination_name',
		ui_textbox('target_name', '', 40, $delivery eq 'saved', 100),
		{ id => 'notification-destination-name',
		  visible => $delivery ne 'saved' });
	$html .= notification_address_fields({ type => $delivery });
	}
# Keep the signed submission inside the form and below all settings.
$html .= ui_table_end().ui_action_button(
	$text{$record->{id} ? 'save' : 'create'}, 'success',
	{ type => 'submit', icon => $record->{id} ? 'check' : 'plus' }).
	ui_form_end();
$html .= notification_address_state($kind eq 'target' ? 'type' : 'delivery');
if ($kind eq 'rule') {
	# Only selected-guest mode submits individual guest IDs.
	$html .= ui_form_field_state_javascript(
		'scope_mode', [ 'selected' ], [ 'notification-selected-guests' ],
		[ 'scope' ]);
	# New destinations and saved selections are mutually exclusive.
	$html .= ui_form_field_state_javascript(
		'delivery', [ 'saved' ], [ 'notification-saved-targets' ],
		[ 'targets' ]);
	$html .= ui_form_field_state_javascript(
		'delivery', [ Cloudmin::NotificationTypes::transports() ],
		[ 'notification-destination-name' ], [ 'target_name' ]);
	# Show only the inputs used by the selected condition.
	$html .= ui_form_field_state_javascript(
		'metric', [ grep { Cloudmin::NotificationTypes::metric($_)->{device} }
			Cloudmin::NotificationTypes::metrics() ],
		[ 'notification-device' ], [ 'device' ]);
	$html .= ui_form_field_state_javascript(
		'metric', [ grep { Cloudmin::NotificationTypes::metric($_)->{numeric} }
			Cloudmin::NotificationTypes::metrics() ],
		[ 'notification-threshold', 'notification-comparison' ],
		[ 'threshold', 'comparison' ]);
	for my $unit ('%', 'GiB', 'MiB/s') {
		# Show only the units used by the selected condition.
		my $id = $unit eq '%' ? 'percent' : $unit eq 'GiB' ? 'gib' : 'rate';
		$html .= ui_form_field_state_javascript('metric',
			[ grep { Cloudmin::NotificationTypes::metric($_)->{unit} eq $unit }
				Cloudmin::NotificationTypes::metrics() ],
			[ 'notification-unit-'.$id ], [ ]);
		}
	# Timing and recovery controls do not apply to job failures.
	$html .= ui_form_field_state_javascript(
		'metric', [ grep { $_ ne 'job_failed' }
			Cloudmin::NotificationTypes::metrics() ],
		[ 'notification-duration', 'notification-timing',
		  'notification-cooldown', 'notification-reminder' ],
		[ 'duration', 'recovery', 'cooldown', 'reminder' ]);
	# Share the server's defaults with the condition-change handler.
	my $defaults = Cloudmin::Notifications::encode({ map {
		$_ => Cloudmin::NotificationTypes::metric($_)
		} Cloudmin::NotificationTypes::metrics() });
	$html .= <<EOF;
<script>
// setup() remembers the current condition so unit changes can reset defaults.
(function() {
	var form = document.querySelector('#notification-editor form');
	var metric = form.elements.metric, defaults = $defaults;
	var previous = metric.value;
	// change() resets defaults when the units change; the event is unused.
	metric.addEventListener('change', function() {
		var next = defaults[metric.value], old = defaults[previous];
		if (next.numeric && (next.unit !== old.unit || !old.numeric)) {
			// The old threshold has different units.
			form.elements.threshold.value = next.threshold;
			form.elements.comparison.value = next.comparison;
		}
		previous = metric.value;
	});
})();
</script>
EOF
	}
return $html.ui_page_end();
}

1;
