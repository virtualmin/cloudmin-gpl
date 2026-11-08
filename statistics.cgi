#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text);
require './server-manager-lib.pl';
error_setup($text{'statistics_error'});
# Bound form parsing before accepting a host or guest statistics request.
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 8192);
ReadParse();

# Authorize the requested scope before looking up guest details or history.
my $vm;
my $ok = eval {
	# Guest pages need a valid UUID and view access
	# before libvirt is queried.
	if (defined($in{'id'})) {
		die "Invalid statistics VM ID\n" if $in{'id'} !~
			/\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/i;
		require_access('view', $in{'id'});
		$vm = get_libvirt()->get_domain($in{'id'}, 1) ||
		      die "Virtual machine not found\n";
		}
	else {
		# An absent VM ID opens host statistics, which
		# delegates cannot view.
		require_access('host');
		}
	1;
	};
# Escape permission and lookup errors before rendering them as HTML.
error(error_html(error_message($@))) if (!$ok);

# Keep guest selection in the sidebar and use the standard page help control.
ui_print_header(html_escape($vm ? $vm->{'name'} : get_system_hostname()),
		$text{$vm
			? 'statistics_guest_title'
			: 'statistics_host_title'}, '', 'statistics');
select_theme_server($vm) if ($vm);
require './cloudmin-statistics-lib.pl';
print show_statistics($vm ? $vm->{'uuid'} : 'host');
ui_print_footer($vm
	? ( 'machine.cgi?id='.urlize($vm->{'uuid'}), $text{'vm_view'} )
	: ( 'index.cgi', $text{'vm_return'} ));
