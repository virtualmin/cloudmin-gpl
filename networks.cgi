#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user, $module_root_directory);
require './server-manager-lib.pl';
# Virtual networks and host bridges are not delegated per VM.
error($text{'acl_denied'}) if (!can_access('host'));
require './cloudmin-network-lib.pl';
require './cloudmin-network-pages.pl';
error_setup($text{'net_error'});
error($text{'net_form_large'}) if (($ENV{'CONTENT_LENGTH'} || 0) > 65536);
ReadParse();
my $tab = network_page_tab($in{'tab'});
# Restore tab preferences only for page views; progress replies contain no tabs.
if (!$in{'status'}) {
	# Saved widget IDs include a prefix that the page renderer does not use.
	$tab = inventory_tab('networks', $in{'tab'}
		? 'net_'.$in{'tab'}
		: undef);
	$tab =~ s/^net_//;
	}
my $host = get_host_network();
# Polling returns only public progress; saved network files stay private. State
# changes trigger a normal page GET so the theme initializes new forms.
if ($in{'status'}) {
	my $state = $host->public_state() || { };
	my $reply = { state => $state->{'state'} || '' };
	$reply->{'remaining'} = $state->{'deadline'}
		? int($state->{'deadline'} - time())
		: 0;
	print "Cache-Control: no-store\r\n";
	print_json($reply, 0, 1);
	exit;
	}
my $action = $in{'action'} || '';
my ($review, $delete);
my $ok = eval {
	# All actions, including review requests, require a
	# writer and a form token.
	if ($action) {
		die "$text{'net_epost'}\n"
			if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
		die "Networking changes are disabled in read-only mode\n"
			if (is_readonly_mode());
		get_image_jobs()->check_token($remote_user, $in{'token'});
		# Preview a bridge plan without changing host configuration.
		if ($action eq 'bridge_review') {
			$review =
				get_network_service()->prepare_bridge(
					@in{qw(name source)});
			}
		# Removal reviews the current bridge settings, not
		# its creation backup.
		elsif ($action eq 'bridge_remove_review') {
			$review =
				get_network_service()->prepare_bridge_removal(
					$in{'name'});
			}
		# Resolve the current network before showing a
		# deletion confirmation.
		elsif ($action eq 'delete_review') {
			my $data = get_network_service()->inventory();
			($delete) =
				grep { $_->{'uuid'} eq ($in{'id'} ||
							'') } @{$data->{'networks'}};
			die "Network no longer exists\n" if (!$delete);
			}
		# Submit a confirmed change and return to its inventory tab.
		else {
			change_network($action, \%in);
			redirect('networks.cgi?tab='.$tab);
			exit;
			}
		}
	1;
	};
error(error_html(error_message($@))) if (!$ok);
my $data = eval { get_network_service()->inventory() };
error(error_html(error_message($@))) if (!$data);
my $token = is_readonly_mode()
	? ''
	: get_image_jobs()->form_token($remote_user);
ui_print_header(undef, $text{'net_title'}, '', 'networks');
print ui_page_start({ class => 'cloudmin-network-page' });
print ui_tag('link', undef, { rel => 'stylesheet',
			      href =>
				      'networks.css?'.
				      (stat("$module_root_directory/networks.css"))[9] });
# Keep bridge review separate from inventory and other mutation forms.
if ($review) {
	print show_bridge_review($review, $token);
	}
# Bind deletion confirmation to the network revision shown to the user.
elsif ($delete) {
	print ui_alert_box(text('net_delete_help',
				ui_tag('tt', html_escape($delete->{'name'}))),
			   'danger');
	print network_form('delete', $token,
			   { id => $delete->{'uuid'},
			     revision => $delete->{'revision'} });
	print ui_form_end([ [ undef, $text{'net_delete_button'} ] ]);
	}
# Poll bridge progress and reload through the theme when its state changes.
else {
	print ui_tag('div',
		     show_network_page($data, $token, $host->public_state(),
				       $remote_user, $tab, $in{'selected'}),
		     { id => 'cloudmin-network-page', 'data-url' =>
							      get_webprefix().
							      '/server-manager/networks.cgi?status=1'.
							      ($in{'selected'}
								      ? '&selected='.urlize($in{'selected'})
								      : '') });
	print ui_tag('script', '',
		     { src =>
			       'networks.js?'.
			       (stat("$module_root_directory/networks.js"))[9] });
	# Remember the selected inventory tab across page loads.
	print inventory_tab_script('networks', $token);
	}
print ui_page_end();
ui_print_footer($review || $delete
	? ( 'networks.cgi?tab='.$tab, $text{'net_return'} )
	: ());
