# Saved keys fill public-key fields on creation, clone and template forms.
use strict;
use warnings;
our ($module_root_directory, %text);

# ssh_public_key_input(value, [disabled]) renders public-key text and a picker.
# disabled defaults to false. Only Pro host administrators get the picker.

sub ssh_public_key_input
{
my ($value, $disabled) = @_;
my $input = ui_textarea('ssh_keys', $value, 4, 75, undef, $disabled);
# Locked fields, GPL and delegated sessions keep the plain input.
return $input if ($disabled || !-r "$module_root_directory/pro/SSHKeys.pm" ||
		  !defined(&get_ssh_key_manager) || !can_access('host'));
my $library = get_webprefix().'/server-manager/pro/list_keys.cgi';
# A damaged library must not block creation forms; show its error instead.
my $keys = eval { get_ssh_key_manager()->list() };
my $warning = $keys ? '' : ui_alert_box(html_escape(error_message($@)), 'warn');
$keys ||= [ ];
# Automatic keys are applied after template settings when creating a guest. Only
# optional keys carry public text for insertion into the form.
my $tools = @$keys
	? ui_dropdown($text{'keys_insert'}, [ map { {
		label_html => html_escape($_->{'name'}).($_->{'addnew'}
			? ' '.
							 ui_badge($text{'keys_automatic'}, 'success',
								  { small => 1,
								    icon => 'check' })
			: ''),
		desc => $_->{'fingerprint'}, icon => 'key',
		disabled => $_->{'addnew'},
		attrs => $_->{'addnew'}
			? { }
			: { 'data-ssh-key-insert' => $_->{'public'} } } } @$keys ],
		      { icon => 'key', size => 'small' })
	: ui_action_button($text{'keys_manage'}, 'neutral',
			   { href => $library, size => 'small',
			     icon => 'key', attrs =>
						    { target => '_blank',
						      rel => 'noopener' } });
# Keep the picker below its own field; the script supports replaced forms.
return ui_tag('div', ui_stack([ $input, ($warning
	? $warning
	: ()), $tools ], { gap => '6px' }), { 'data-ssh-key-input' => 1 }).
       ui_tag('script', '',
	      { src => get_webprefix().'/server-manager/ssh-keys.js?'.
		       ((stat("$module_root_directory/ssh-keys.js"))[9] ||
			0) });
}

# guest_ssh_account_heading(username, accounts, [count], [disabled]) Places the
# labelled account selector and optional nonzero key count together. accounts
# lists known usernames. disabled defaults to false for live pages.

sub guest_ssh_account_heading
{
my ($username, $accounts, $count, $disabled) = @_;
# Use a separate field name from Password, including its generated ID. Submit
# through the theme so account changes retain its navigation shell.
my $chooser =
	ui_select('ssh_username', $username, [ map { [ $_, $_ ] } @$accounts ],
		  1, 0,
		  1,
		  $disabled,
		  ($disabled ? '' : 'onchange="this.form.requestSubmit()" ').
		  'title="'.quote_escape($text{'keys_guest_accounts_help'}).
		  '"');
# Wrapping the select labels it even when the theme emits no ID.
my $label = ui_tag('label', ui_tag('span', html_escape($text{'keys_guest_for'}),
				   { class => 'cloudmin-ssh-account-label' }).$chooser,
		   { class =>
			     'ui_select_inline ui_select_inline_underlined cloudmin-ssh-account-select' });
# Unknown and empty inventories have no count beside the selector.
my $total = $count
	? ui_tag('small', html_escape($count == 1
		? $text{'keys_guest_count_one'}
		: text('keys_guest_count', $count)),
		 { class => 'cloudmin-ssh-count' })
	: '';
# Keep account selection usable when JavaScript is disabled.
my $fallback = $disabled
	? ''
	: ui_tag('noscript', ui_action_button($text{'keys_show'}, 'neutral',
					      { type => 'submit',
						size => 'small',
						icon => 'user' }));
# Heading content stays inline HTML; its form wraps the card on live pages.
return ui_tag('span', $label.$total.$fallback,
	      { class => 'ui_cluster ui_cluster_baseline' });
}

# show_guest_ssh_preview(vm) shows disabled account and key controls on GPL. Use
# creation metadata only; previews never query the guest agent or library.

sub show_guest_ssh_preview
{
my ($vm) = @_;
my $username = ($vm->{'cloudmin'} || { })->{'username'} || 'root';
# Match the live account heading without reading guest keys or offering changes.
my $controls =
	ui_card({ title_html =>
			  guest_ssh_account_heading($username, [ $username ],
						    undef,
						    1) });
# Match the Pro addition card with disabled input and submit controls.
$controls .= ui_card({ title_html =>
			       hlink(html_escape($text{'keys_guest_add'}),
				     'guest_ssh_keys'),
		       body =>
			       ui_field($text{'keys_guest_paste'},
					ui_textarea('public', '', 4, 70, undef,
						    1,
						    'placeholder="ssh-ed25519 AAAA... user@host"'),
					{ for => 'public', help_html =>
								   text('keys_guest_paste_help',
									ui_tag('tt', 'authorized_keys')) }),
		       footer =>
			       ui_cluster([ ui_action_button($text{'keys_guest_add'},
							     'success',
							     { icon => 'plus',
							       disabled => 1 }) ],
					  { align => 'end' }) });
return ui_page_start().ui_tag('div',
			      ui_p(html_escape($text{'keys_guest_intro'})),
			      { class => 'vui_ui_block' }).pro_feature_tip('ssh-keys').
       pro_feature_preview($controls, 'ssh-keys').ui_page_end();
}

# ssh_key_library_list(rows, [add_action]) renders the Pro list and GPL preview.
# rows is an arrayref of ui_list entries; add_action is optional button HTML.
# Omit add_action for a read-only library; an empty rows array shows guidance.

sub ssh_key_library_list
{
my ($rows, $add_action) = @_;
my $body = @$rows
	? ui_list($rows, { flush => 1 })
	: ui_empty_state({ icon => 'key', title => $text{'keys_none'}, desc =>
									       $text{'keys_none_desc'} });
return ui_p(html_escape($text{'keys_intro'})).ui_card({ title =>
								$text{'keys_saved'},
							class => 'cloudmin-ssh-card', flush => 1, actions =>
													  $add_action, body => $body });
}

# show_ssh_library_preview() advertises saved keys without loading Pro code.

sub show_ssh_library_preview
{
# Match an empty Pro library without querying storage or offering a live action.
my $controls =
	ssh_key_library_list([ ], ui_action_button($text{'keys_add'}, 'success',
						   { icon => 'plus',
						     size => 'normal',
						     disabled => 1 }));
return ui_page_start().pro_feature_tip('ssh-keys').
       pro_feature_preview($controls, 'ssh-keys').ui_page_end();
}

1;
