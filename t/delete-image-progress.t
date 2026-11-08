use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore qw(unique ui_brh ui_tag ui_tag_start ui_tag_end ui_br
		 error_setup);
use Test::More;

my $first_tag = qr/<span\b[^>]*\bdata-first-print\b[^>]*>/;
my $second_tag = qr/<span\b[^>]*\bdata-second-print\b[^>]*>/;
my $br_tag = qr/<br\b(?![^>]*\bdata-x-br\b)[^>]*>/;
use Cwd ();
# Keep the real ACL checks while the CGI fixture skips Webmin initialization.
require(Cwd::abs_path("$Bin/../cloudmin-access-lib.pl"));

# Advance cancellation waits without sleeping or changing any host resources.
our $fixture_time = 1000;

BEGIN
{
*CORE::GLOBAL::time = sub { return $fixture_time; };
*CORE::GLOBAL::sleep = sub { $fixture_time += $_[0]; return 0; };
}
our (%in, %text, $remote_user, $fixture);
open(my $lang, '<', "$Bin/../lang/en") || die $!;
while (<$lang>) {
	chomp;
	$text{$1} = $2 if (/^([^=]+)=(.*)$/);
	}
close($lang);
require "$Bin/../cloudmin-print.pl";

# ReadParse() - Retains the fixture request fields.
sub ReadParse
{
}

# is_readonly_mode() - Allows mutations in the in-memory job store.
sub is_readonly_mode
{
return 0;
}

# get_image_jobs() - Returns the selected job fixture.
sub get_image_jobs
{
return $fixture;
}

# error_html(message) keeps non-license errors escaped in this CGI fixture.
sub error_html
{
return html_escape($_[0]);
}

# html_escape(value) - Escapes image names and backend errors as Webmin does.
sub html_escape
{
my ($value) = @_;
$value =~ s/&/&amp;/g;
$value =~ s/</&lt;/g;
$value =~ s/>/&gt;/g;
return $value;
}

# text(key, [values...]) - Substitutes the module's translated messages.
sub text
{
my ($key, @values) = @_;
my $value = $text{$key};
$value =~ s/\$(\d+)/$values[$1 - 1]/ge;
return $value;
}

# ui_print_unbuffered_header([subtitle], title, help) - Marks the page start.
sub ui_print_unbuffered_header
{
print "<header>$_[1]</header>\n";
}

# ui_print_footer(url, label) - Marks completion of the batch.
sub ui_print_footer
{
print "<footer>$_[1]</footer>\n";
}

# error(message) - Rejects invalid fixture requests.
sub error
{
die $_[0];
}

{
	package DeleteJobs;

	# new(class, responses, states) Stores deletion
	# outcomes and current states.
	sub new
	{
	return bless({ responses => $_[1], states => $_[2],
		       calls => [ ] }, $_[0]);
	}

	# check_token(self, owner, token) - Requires the fixture's form token.
	sub check_token
	{
	die "Invalid token\n" if ($_[2] ne 'fixture-token');
	}

	# get(self, id) - Supplies a name that tests HTML escaping.
	sub get
	{
	return { id => $_[1], name => "Image <$_[1]>",
		 state => $_[0]->{'states'}->{$_[1]} || 'ready' };
	}

	# cancel(self, id) - Records each cancellation before deletion starts.
	sub cancel
	{
	push(@{$_[0]->{'calls'}}, "cancel:$_[1]");
	}

	# remove(self, id) Simulates success, worker
	# cleanup, or a backend error.
	sub remove
	{
	my ($self, $id) = @_;
	push(@{$self->{'calls'}}, "remove:$id");
	my $responses = $self->{'responses'}->{$id};
	my $result = @$responses > 1 ? shift(@$responses) : $responses->[0];
	die "$result\n" if ($result !~ /\A[01]\z/);
	return $result;
	}
	}

# render(responses, [states], [unconfirmed], [selection]) Runs the actual
# deletion CGI against current or stale selections.
sub render
{
my ($responses, $states, $unconfirmed, $selection) = @_;
$fixture = DeleteJobs->new($responses, $states || { });
%in = ( job => $selection // join(',', sort keys %$responses),
	confirm => !$unconfirmed,
	token => 'fixture-token' );
local $ENV{'REQUEST_METHOD'} = 'POST';
local $ENV{'CONTENT_LENGTH'} = 0;
local $INC{'./server-manager-lib.pl'} = 1;
my $html = '';
open(my $output, '>', \$html) || die $!;
{
	local *STDOUT = $output;
	do "$Bin/../delete_images.cgi";
	die $@ if ($@);
	}
close($output);
return $html;
}

# Delayed cancellation still produces one adjacent start/result pair per image.
my $html = render({ a => [ 0, 0, 1 ], b => [ 1 ] });
like($html,
     qr{${first_tag}Deleting <tt\b[^>]*>Image &lt;a&gt;</tt>\s* image \.\.</span>\s*${br_tag}\n${second_tag}\.\. done</span>\s*},
     'deletion uses the standard first_print/second_print pair');
is(scalar(() = $html =~ /data-first-print/g), 2, 'each deletion starts once');
is(scalar(() = $html =~ /data-second-print/g), 2,
   'each deletion has one result');
is_deeply([ @{$fixture->{'calls'}}[0 .. 2] ],
	  [ qw(cancel:a cancel:b remove:a) ],
	  'all workers receive cancellation before any deletion wait');
unlike($html, qr/: Deleted|Cancelling download/,
       'old one-line statuses are gone');

# Duplicate form values must not cancel or delete the same image twice.
$html = render({ a => [ 1 ], b => [ 1 ] }, undef, 0, "b,a\0b,a");
is_deeply($fixture->{'calls'}, [ qw(cancel:b cancel:a remove:b remove:a) ],
	  'duplicate selections are processed once in their original order');

# A protected image fails visibly without stopping the rest of the selection.
$html = render({ a => [ 'Image is used by <guest>' ], b => [ 1 ] });
like($html,
     qr{data-second-print\b[^>]*>\.\. failed : image is used by &lt;guest&gt;</span>\s*},
     'backend errors are escaped and reported through second_print');
like($html,
     qr{Deleting <tt\b[^>]*>Image &lt;b&gt;</tt>\s* image \.\..*?data-second-print\b[^>]*>\.\. done}s,
     'later images are still deleted after a failure');

# Expiring the shared wait must not claim that cleanup has completed.
$html = render({ a => [ 0 ], b => [ 1 ] });
like($html,
     qr{data-second-print\b[^>]*>\.\. failed : timed out waiting for deletion while cleanup is still running</span>\s*},
     'pending cleanup reports a timeout result');
like($html,
     qr{Deleting <tt\b[^>]*>Image &lt;b&gt;</tt>\s* image \.\..*?data-second-print\b[^>]*>\.\. done}s,
     'a slow worker does not prevent subsequent completed deletions');

# Replaying a completed POST must not treat tombstones as new deletions.
$html = render({ a => [ 1 ], b => [ 1 ] }, { a => 'deleted', b => 'deleted' });
is(scalar(
	() =
	$html =~ m{data-second-print\b[^>]*>\.\. failed : image has already been deleted</span>}g),
   2, 'a stale batch reports each image as already deleted');
unlike($html, qr/\.\. done/, 'a stale batch never reports success');
is_deeply($fixture->{'calls'}, [ ],
	  'deleted images are not cancelled or removed again');
$html = render({ a => [ 1 ], b => [ 1 ] }, { a => 'deleted' });
like($html,
     qr{Deleting <tt\b[^>]*>Image &lt;b&gt;</tt>\s* image \.\..*?data-second-print\b[^>]*>\.\. done}s,
     'a stale image does not block remaining valid images');
is_deeply($fixture->{'calls'}, [ qw(cancel:b remove:b) ],
	  'only existing images are deleted');
ok(!eval { render({ a => [ 1 ] }, { a => 'deleted' }, 1); 1 },
   'a stale selection cannot open a new deletion confirmation');
like($@, qr{These images have already been deleted: <tt\b[^>]*>Image &lt;a&gt;</tt>\s*},
     'the confirmation error identifies and escapes stale image names');

# The same request must still accept a worker completing requested cleanup.
$html = render({ a => [ 0, 1 ] }, { a => 'downloading' });
like($html, qr{data-second-print\b[^>]*>\.\. done</span>\s*},
     'active worker cleanup is still reported as successful');
done_testing();
