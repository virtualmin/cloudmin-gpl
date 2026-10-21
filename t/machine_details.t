use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use Test::More;
use Cwd ();
# Keep the real ACL checks while the CGI fixture skips Webmin initialization.
require(Cwd::abs_path("$Bin/../cloudmin-access-lib.pl"));

# Catch redirects without exiting the test process or rendering a second page.
BEGIN { *CORE::GLOBAL::exit = sub { die bless({}, 'DetailsExit'); }; }
our (%in, %text, $whatfailed);
$INC{'./server-manager-lib.pl'} = 1;
$INC{'./cloudmin-status-lib.pl'} = 1;
$text{'vm_control_error'} = 'Cannot control virtual machine';
my $uuid = '11111111-2222-3333-4444-555555555555';

# error_html(message) escapes non-license errors in this CGI fixture.
sub error_html { return html_escape($_[0]); }
# submit(action, [method], [failure], [fields]) exercises the CGI's dispatch.
sub submit
{
my ($action, $method, $failure, $fields) = @_;
my ($url, $output, @calls) = ('', '');
local %in = (action => $action, id => $uuid, token => 'signed-token', %{$fields || {}});
local $ENV{'REQUEST_METHOD'} = $method || 'POST';
local $ENV{'CONTENT_LENGTH'} = 0;
local $whatfailed;
no warnings qw(redefine once);
local *main::ReadParse = sub { };
local *main::error_setup = sub { $whatfailed = $_[0]; };
local *main::error = sub { die "$whatfailed: $_[0]"; };
local *main::error_message = sub { return $_[0]; };
local *main::redirect = sub { $url = WebminCore::un_urlize($_[0]); };
local *main::call_vm_api = sub {
	push(@calls, [$_[0], $_[1], { %{$_[2]} }]);
	die $failure if ($failure);
	return { id => $uuid, action => $action };
	};
open(my $fh, '>', \$output) or die $!;
local *STDOUT = $fh;
do "$Bin/../machine.cgi";
my $error = $@;
$error = '' if (ref($error) eq 'DetailsExit');
return { url => $url, output => $output, error => $error, calls => \@calls };
}

# Every power action stays on details, with request feedback after the redirect.
foreach my $action (qw(start reboot shutdown force_off)) {
	my $result = submit($action);
	is($result->{'url'}, "machine.cgi?id=$uuid&vm_action=$action", "$action returns to details");
	is($result->{'output'}, '', 'redirect precedes page and theme output');
	is($result->{'error'}, '', 'accepted request has no error');
	is_deeply($result->{'calls'}, [[1, $action, {
		action => $action, id => $uuid, token => 'signed-token' }]],
		'controller receives the write request and original token');
	$result = submit($action, 'GET');
	like($result->{'error'}, qr/Use POST/, 'following a URL cannot submit a power action');
	is_deeply($result->{'calls'}, [], 'GET never reaches the controller');
	}
# Unsupported actions and backend failures use Webmin's normal error page.
my $result = submit('delete');
like($result->{'error'}, qr/Unknown virtual machine action/, 'details reject unrelated operations');
is_deeply($result->{'calls'}, [], 'unsupported actions never reach the controller');
$result = submit('reboot', 'POST', 'Guest <unavailable>');
like($result->{'error'}, qr/Cannot control virtual machine: Guest &lt;unavailable&gt;/,
	'backend failures retain operation context and safe text');
unlike($result->{'error'}, qr/<tt\b/, 'complete error messages are not technical values');
is($result->{'url'}, '', 'failed requests never redirect as successful');
# Only the editor is a valid alternate destination after emergency power-off.
$result = submit('force_off', 'POST', undef, { confirm => 1, return => 'edit_machine' });
is($result->{'url'}, "edit_machine.cgi?id=$uuid&vm_action=force_off",
	'power-off from the editor returns to editable settings');
is($result->{'calls'}->[0]->[2]->{'confirm'}, 1, 'controller receives explicit confirmation');
$result = submit('force_off', 'POST', undef, { confirm => 1, return => 'https://example.invalid/' });
is($result->{'url'}, "machine.cgi?id=$uuid&vm_action=force_off", 'foreign return URLs are ignored');
$result = submit('force_off', 'POST', 'Confirm force power off');
like($result->{'error'}, qr/Confirm force power off/, 'missing confirmation uses the error page');
is($result->{'url'}, '', 'unconfirmed request does not redirect as successful');
done_testing();
