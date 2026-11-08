use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use Cwd ();
# Keep the real ACL checks while the CGI fixture skips Webmin initialization.
require(Cwd::abs_path("$Bin/../cloudmin-access-lib.pl"));

# Exercise the real streaming CGI without sleeping or creating a guest.

BEGIN
{
*CORE::GLOBAL::sleep = sub { return 0; };
}
our (%in, %text, $first_print, $second_print, @responses, $reads, $whatfailed,
     @calls);
our $readonly = 0;

# is_readonly_mode() supplies the fixture viewer's current permission.
sub is_readonly_mode
{
return $readonly;
}
open(my $lang, '<', "$Bin/../lang/en") || die $!;
while (<$lang>) {
	chomp;
	$text{$1} = $2 if (/^([^=]+)=(.*)$/);
	}
close($lang);
$INC{'./server-manager-lib.pl'} = 1;
$first_print = sub { print "Start: $_[0]\n"; };
$second_print = sub { print "Result: $_[0]\n"; };

# progress_callback(stage, bytes) records native download progress without HTML.
sub progress_callback
{
print "Download: $_[0] $_[1]\n";
}

# ReadParse() - Retains fixture request values.
sub ReadParse
{
}

# recover_vm_jobs() - Leaves the scripted states in charge.
sub recover_vm_jobs
{
}

# call_vm_api(version, action, input) - Supplies status or a store error.
sub call_vm_api
{
push(@calls, [ $_[1], { %{$_[2]} } ]);
$reads++;
die "Unexpected extra poll\n" if (!@responses);
my $next = shift(@responses);
die $next if (!ref($next));
return $next;
}

# error_message(error) - Preserves the useful cause for the page.
sub error_message
{
return $_[0];
}

# error_html(message) keeps non-license errors escaped in this CGI fixture.
sub error_html
{
return html_escape($_[0]);
}

# html_escape(value) - Prevents fixture error markup from becoming HTML.
sub html_escape
{
my ($value) = @_;
$value =~ s/&/&amp;/g;
$value =~ s/</&lt;/g;
$value =~ s/>/&gt;/g;
return $value;
}

# ui_link(url, label) renders a normal navigation link for the fixture.
sub ui_link
{
return '<a href="'.html_escape($_[0]).'">'.$_[1].'</a>';
}

# text(key, value) - Substitutes the status-error detail.
sub text
{
my $message = $text{$_[0]};
$message =~ s/\$1/$_[1]/g;
return $message;
}

# error(message) - Makes initial validation failures observable to the test.
sub error
{
die "$whatfailed: $_[0]";
}

# error_setup(message) - Records the action shown before a validation error.
sub error_setup
{
$whatfailed = $_[0];
}

# ui_print_unbuffered_header(args...) - Starts a captured page.
sub ui_print_unbuffered_header
{
print "Header: $_[1]\n";
print "Subtitle: $_[0]\n";
}

# ui_alert_box(message, type) - Captures an escaped warning.
sub ui_alert_box
{
return "Warning: $_[0]\n";
}

# ui_print_footer(url, label, args...) - Records the recovery destination.
sub ui_print_footer
{
print "Footer: $_[0]\n";
}

# notify_theme_save(vm, action) - Records the navigation refresh.
sub notify_theme_save
{
print "Theme: $_[1] $_[0]->{uuid}\n";
}

# render(responses...) - Runs one CGI request and returns its captured output.
sub render
{
@responses = @_;
@calls = ();
$reads = 0;
my $html = '';
open(my $fh, '>', \$html) || die $!;
{
	local *STDOUT = $fh;
	my $page = $in{vm_operation}
		? ($in{vm_operation} eq 'clone'
			? 'clone_machine'
			: 'setup_machine')
		: 'progress';
	do "$Bin/../$page.cgi";
	die $@ if ($@);
	}
return $html;
}

my $running = { state => 'running', operation => 'create', events => [ ] };
my $complete = { state => 'complete', operation => 'create',
		 uuid => 'fixture', events => [ ] };
# Reopened progress escapes saved deployment labels in its subtitle.
my $deployment = { %$complete, name => 'vm.example.test',
		   image_name => 'Rocky Linux 10 <custom>', software_name =>
								    'Virtualmin Pro with Nginx' };
like(render($deployment, $deployment),
     qr/Subtitle: vm\.example\.test &middot; Rocky Linux 10 &lt;custom&gt; &middot; Virtualmin Pro with Nginx/,
     'creation subtitle identifies the saved image and software without rendering markup');
unlike(render({ %$deployment, operation => 'update' },
	      { %$deployment, operation => 'update' }),
       qr/Subtitle: .*Rocky/, 'hardware updates do not claim to deploy an OS');
my $html = render($running, "Temporary store failure\n", $complete);
like($html, qr/Footer: machine.cgi\?id=fixture/,
     'a transient read error can recover to completion');
like($html, qr/Theme: create fixture/,
     'successful creation refreshes the theme guest list');
unlike($html, qr/Warning:/,
       'a recovered read error does not misreport a job failure');

# Return links retain each editor tab, but ignore unknown tab names.
foreach my $tab (qw(resources disks interfaces)) {
	local $in{'vm_edit_tabs'} = $tab;
	$html = render($running, { %$complete, operation => 'update' });
	like($html,
	     qr/Footer: edit_machine.cgi\?id=fixture&vm_edit_tabs=$tab\n/,
	     "successful edit returns to the $tab tab");
	}
{
	local $in{'vm_edit_tabs'} = 'disks&delete=1';
	$html = render($running, { %$complete, operation => 'update' });
	like($html, qr/Footer: edit_machine.cgi\?id=fixture\n/,
	     'unknown tab cannot add parameters to the return link');
	}

# A former writer can still view completed work after losing write access.
{
	local $readonly = 1;
	$html = render($running, { %$complete, operation => 'update' });
	like($html, qr/Footer: machine.cgi\?id=fixture/,
	     'read-only progress returns to details instead of the editor');
	}

# Snapshot progress retains only recognized return destinations.
{
	local $in{'from'} = 'all';
	$html = render($running, { %$complete,
				   operation => 'snapshot_restore' });
	like($html, qr/Footer: snapshots.cgi\n/,
	     'host snapshot actions return to the host inventory');
	}
{
	local $in{'from'} = 'https://other.example/';
	$html = render($running, { %$complete,
				   operation => 'snapshot_delete' });
	like($html, qr/Footer: snapshots.cgi\?id=fixture\n/,
	     'unknown snapshot return destinations use the guest history');
	}

# Deletion refreshes navigation and returns to the surviving overview.
$html = render($running, { %$complete, operation => 'delete' });
like($html, qr/Theme: delete fixture/, 'deletion updates the theme selection');
like($html, qr/Footer: index.cgi/, 'deletion returns to overview');
unlike($html, qr/Footer: machine.cgi/, 'deleted guest has no details link');

$html = render($running, ("Store <unavailable>\n") x 3);
is($reads, 4, 'three failed polls end the stream instead of waiting an hour');
like($html, qr/Could not read job progress: Store &lt;unavailable&gt;/,
     'a persistent error explains the failure and escapes markup');
like($html, qr/Footer: jobs.cgi/,
     'the user can return to Active Jobs');
unlike($html, qr/The operation continues/,
       'a failed status read does not claim the job is running');
unlike($html, qr/Theme:/,
       'an incomplete job does not report a created guest to the theme');

$html = render($running, ("Temporary failure\n") x 2, $running,
	       ("Another temporary failure\n") x 2, $complete);
like($html, qr/Footer: machine.cgi\?id=fixture/,
     'a successful poll resets consecutive failures');
# Image downloads report bytes, while cache reuse uses the ordinary phase label.
my $image =
	{ %$running, state => 'queued', events =>
						[ { step => 'image',
						    state => 'running' } ],
	  image_progress =>
		  { name => 'Rocky Linux 10', bytes => 40, total => 100 } };
my $downloaded = { %$complete, events => [ { step => 'image',
					     state => 'done' } ],
		   image_progress => { %{$image->{'image_progress'}},
				       bytes => 100 } };
$html = render($image, $image, $downloaded);
like($html, qr/Download: 2 100.*Download: 3 40.*Download: 3 100/s,
     'download streams native total and byte counters');
$html =
	render($running,
	       { %$image, image_progress => { name => 'Unknown',
					      bytes => 40 } },
	       { %$downloaded,
		 image_progress => { name => 'Unknown', bytes => 500 } });
like($html, qr/Download: 2 0.*Download: 3 40.*Download: 3 500/s,
     'unknown lengths use native byte-only progress as downloads grow');
$html =
	render($image, $image,
	       { %$downloaded, image_progress =>
				       { name => 'Estimated', total => 100,
					 bytes => 150 } });
unlike($html, qr/Download: 3 150/,
       'underestimated lengths cannot exceed 100 percent');
$html =
	render($running,
	       { %$downloaded, image_progress =>
				       { %{$downloaded->{'image_progress'}},
					 cached => 1 } });
unlike($html, qr/Download:/, 'cached images do not appear to download again');
like($html, qr/Preparing source image/,
     'cache reuse still reports its preparation phase');
$html =
	render($running,
	       { %$downloaded, state => 'failed',
		 error => 'Storage pool unavailable' });
like($html, qr/Storage pool unavailable/i,
     'failure after download is not hidden behind a completed image phase');
# Software cancellation has its own result, including removal during setup.
for my $message (
	'Software setup cancelled',
	'Software setup cancelled because the virtual machine was deleted' ) {
	$html =
		render($running,
		       { state => 'cancelled', operation => 'create',
			 error => $message,
			 events =>
				 [ { step => 'software_install', state =>
									 'cancelled' } ] });
	like($html, qr/Result: \Q$message\E/,
	     'cancelled setup explains its outcome');
	unlike($html, qr/Result: .*done|failed/i,
	       'cancellation is neither success nor failure');
	}
# Submissions use the same progress renderer as the reconnect endpoint.
for my $operation (qw(create clone)) {
	local $ENV{'REQUEST_METHOD'} = 'POST';
	local %in =
		( vm_operation => $operation, token => 'signed', attempt =>
									 'checked',
		  password => 'private',
		  hostname => 'hidden.example.com' );
	my $job = { %$complete, operation => $operation, id => 'a' x 32 };
	$html = render($job, $job, $job);
	is_deeply([ map { $_->[0] } @calls ], [ $operation, 'status',
						'status' ],
		  "$operation submits once before streaming status");
	is($calls[0]->[1]->{'token'}, 'signed',
	   'submission retains the signed token');
	is($calls[0]->[1]->{'attempt'}, 'checked',
	   'submission retains its retry ID');
	is_deeply($calls[1]->[1], { job => 'a' x 32 },
		  'polls omit credentials and form settings');
	is($calls[0]->[1]->{'hostname'}, '',
	   'clone ignores the unchecked hostname')
		if ($operation eq 'clone');
	like($html, qr/Header.*Footer/s,
	     'submission renders progress without a redirect');
	like($html, $operation eq 'clone'
		? qr/Header: Cloning Virtual Machine/
		: qr/Header: Creating Virtual Machine/,
	     'progress title matches the operation');
	}
# Reject mutations on GET and unknown actions before entering the controller.
for my $case ( [ 'GET', 'create', qr/Use POST/ ],
	       [ 'POST', 'delete', qr/Unknown/ ] ) {
	local $ENV{'REQUEST_METHOD'} = $case->[0];
	local %in = ( vm_operation => $case->[1], password => 'private' );
	eval { render(); };
	like($@, $case->[2],
	     'invalid submission fails before status streaming');
	is(scalar(@calls), 0,
	   'invalid submission cannot call the controller');
	ok(!exists($in{'password'}),
	   'error path discards submitted secrets');
	}
# Controller errors remain visible and cannot turn into an
# unrelated status poll.
{
	local $ENV{'REQUEST_METHOD'} = 'POST';
	local %in = ( vm_operation => 'create', password => 'private' );
	eval { render("Invalid or expired token\n"); };
	like($@, qr/Invalid or expired token/,
	     'submission propagates controller rejection');
	unlike($@, qr/<tt>/,
	       'validation sentences do not get quotation styling');
	is(scalar(@calls), 1, 'rejected creation does not start polling');
	ok(!exists($in{'password'}),
	   'controller rejection discards credentials');
	}
# Recovery guidance links to the overview without trusting backend HTML.
{
	local $ENV{'REQUEST_METHOD'} = 'POST';
	local %in = ( vm_operation => 'create', password => 'private' );
	eval { render(
		"Network <unsafe> is missing IPv4 forwarding rules. Open Host Overview and use Restore Network Rules\n"); };
	like($@,
	     qr/Network &lt;unsafe&gt;.*Open <a href="index.cgi">Host Overview<\/a> and use Restore Network Rules/,
	     'network recovery guidance contains an escaped error and a working overview link');
	is(scalar(@calls), 1, 'linked validation error does not start a job');
	ok(!exists($in{'password'}),
	   'linked error discards submitted credentials');
	}
done_testing();
