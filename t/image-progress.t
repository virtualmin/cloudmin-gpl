use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore qw(ui_brh ui_tag ui_tag_start ui_tag_end ui_br);
use Test::More;

my $first_tag = qr/<span\b[^>]*\bdata-first-print\b[^>]*>/;
my $second_tag = qr/<span\b[^>]*\bdata-second-print\b[^>]*>/;
my $br_tag = qr/<br\b(?![^>]*\bdata-x-br\b)[^>]*>/;
my $spacer_tag = qr/<br\b[^>]*\bdata-x-br\b[^>]*>/;
my $indent_tag = qr/<ul\b[^>]*\bdata-indent-print\b[^>]*>/;

# Drive the real CGI through deterministic states without waiting or using VMs.

BEGIN
{
*CORE::GLOBAL::sleep = sub { return 0; };
}
our (%in, %text, $progress_callback_url, $fixture, @callbacks, $raw_progress,
     $whatfailed, $imports_started);
open(my $lang, '<', "$Bin/../lang/en") || die $!;
while (<$lang>) {
	chomp;
	$text{$1} = $2 if (/^([^=]+)=(.*)$/);
	}
close($lang);
# Webmin provides the download completion label alongside module strings.
$text{'progress_done'} = '.. download complete';
require "$Bin/../cloudmin-pages.pl";
require "$Bin/../cloudmin-print.pl";

# ReadParse() - Keeps the request fields supplied by the fixture.
sub ReadParse
{
}

# get_image_jobs() - Supplies the scripted job store.
sub get_image_jobs
{
return $fixture;
}

# start_image_imports(input) Models token validation and records attempts to
# start new background work.
sub start_image_imports
{
my ($input) = @_;
# A progress request needs no token; any attempted import must validate one.
die "This form has expired\n" if (($input->{'token'} || '') ne 'fixture-token');
$imports_started++;
return [ { id => 'a' } ];
}

# error_html(message) escapes non-license errors in this CGI fixture.
sub error_html
{
return html_escape($_[0]);
}

# html_escape(value) - Models Webmin's escaping for progress and failure text.
sub html_escape
{
my ($value) = @_;
$value =~ s/&/&amp;/g;
$value =~ s/</&lt;/g;
$value =~ s/>/&gt;/g;
return $value;
}

# html_strip(value) - Size fixtures contain no markup.
sub html_strip
{
return $_[0];
}

# nice_size(bytes) - Makes byte counters easy to assert without a theme.
sub nice_size
{
return "$_[0] bytes";
}

# text(key, [values...]) - Substitutes Webmin language placeholders.
sub text
{
my ($key, @values) = @_;
my $value = $text{$key};
$value =~ s/\$(\d+)/$values[$1 - 1]/ge;
return $value;
}

# ui_p(text) - Preserves the progress page's explanatory paragraph.
sub ui_p
{
return "<p>$_[0]</p>\n";
}

# ui_link(url, label) - Detects an unwanted extra navigation button.
sub ui_link
{
return "<a href='$_[0]'>$_[1]</a>\n";
}

# ui_print_unbuffered_header([title], heading, help) - Captures the heading.
sub ui_print_unbuffered_header
{
print "<header>$_[1]</header>\n";
}

# ui_print_footer(url, label) - Webmin adds its own Return to prefix.
sub ui_print_footer
{
print "<footer>Return to $_[1]</footer>\n";
}

# error(message) - Stops a fixture request if the CGI rejects it.
sub error
{
die "$whatfailed: $_[0]";
}

# error_setup(message) - Records the action shown before a validation error.
sub error_setup
{
$whatfailed = $_[0];
}

# progress_callback(mode, [bytes]) - Records exactly which HTTP events are used.
sub progress_callback
{
my ($mode, $bytes) = @_;
push(@callbacks, [ $progress_callback_url, $mode, $bytes ]);
print 'Downloading '.html_escape($progress_callback_url).
	($bytes ? " ($bytes bytes)" : '')." ..\n" if ($mode == 2);
print "Received $bytes bytes\n" if ($mode == 3);
print ".. download complete\n" if ($mode == 4);
}

{
	package ProgressJobs;

	# new(class, scripts) Stores one ordered state sequence per fixture job.
	sub new
	{
	return bless({ scripts => $_[1], reads => { } }, $_[0]);
	}

	# get(self, id) - Handles validation, then advances each progress poll.
	sub get
	{
	my ($self, $id) = @_;
	my $script = $self->{'scripts'}->{$id};
	die "Unknown fixture job $id" if (!$script || !@$script);
	my $state = ++$self->{'reads'}->{$id} <= 1
		? $script->[0]
		: shift(@$script);
	return { id => $id, name => "Image $id", updated => time(),
		 source => 'download', volume => "$id.qcow2",
		 pool_name => 'default', %$state };
	}
	}

# render(scripts, [method], [fields]) Executes the CGI with GET by default and
# optional request field overrides. scripts maps job IDs to ordered states;
# omitted fields use those IDs only.
sub render
{
my ($scripts, $method, $fields) = @_;
# Reset import counts and callbacks so each request is checked independently.
$fixture = ProgressJobs->new($scripts);
%in = ( job => join(',', sort keys %$scripts), %{$fields || { }} );
@callbacks = ();
$imports_started = 0;
# Both HTTP methods execute the same CGI with the fixture's parsed fields.
local $ENV{'REQUEST_METHOD'} = $method || 'GET';
local $ENV{'CONTENT_LENGTH'} = 0;
local $INC{'./server-manager-lib.pl'} = 1;
my $html = '';
open(my $output, '>', \$html) || die $!;
{
	local *STDOUT = $output;
	do "$Bin/../setup_image.cgi";
	die $@ if ($@);
	}
close($output);
$raw_progress = $html;
# Keep sequence checks readable while exercising the real print callbacks.
$html =~ s{$first_tag|$second_tag|</span>\s*|$spacer_tag}{}g;
$html =~ s{$br_tag}{<br>}g;
$html =~ s/\n{2,}/\n/g;
return $html;
}

# The storage counter starts at zero, but must never enter HTTP progress.
my $html = render({ a => [
	{ state => 'queued', bytes => 0 },
	{ state => 'downloading', bytes => 0, total => 1000 },
	{ state => 'downloading', bytes => 400, total => 1000 },
	{ state => 'verifying', bytes => 1000, total => 1000 },
	{ state => 'importing', bytes => 1000, transferred => 0 },
	{ state => 'importing', bytes => 1000, transferred =>
						       600 },
	{ state => 'ready', bytes => 1000, transferred => 1000 },
] });
is_deeply([ map { $_->[2] } grep { $_->[1] == 3 } @callbacks ], [ 400, 1000 ],
	  'download bytes finish at 100% and never reset for storage');
like($html,
     qr/Received 1000 bytes\n\.\. download complete${br_tag}\nVerifying vendor SHA-256 checksum and checking disk image/,
     'download completes before verification is displayed');
like($raw_progress,
     qr{${second_tag}\.\. download complete</span>\s*${br_tag}${spacer_tag}\n+${first_tag}Verifying vendor SHA-256 checksum and checking disk image \.\.</span>\s*},
     'download completion leaves a blank line before verification');
unlike($html, qr/Saving to storage.*(?:Received|download complete)/s,
       'HTTP progress does not leak into storage or readiness');
unlike($html, qr/<a\b/, 'no extra return link at the top');
like($html, qr{<footer>Return to image manager</footer>},
     'footer has one Return to prefix');
like($html, qr{</header>\nDownloading Image a \(1000 bytes\) \.\.},
     'progress begins with the image name and download size');
like($html,
     qr{Verifying vendor SHA-256 checksum and checking disk image \.\.${br_tag}\n\.\. done${br_tag}\nSaving to storage \.\.${br_tag}\n\.\. done${br_tag}},
     'checking and storage each have a separate success result');
unlike($html, qr/Queued|Downloading image|Ready|is saved in|<h3>/,
       'internal states, headings and redundant completion details are omitted');
like($raw_progress,
     qr{${first_tag}Verifying vendor SHA-256 checksum and checking disk image \.\.</span>\s*${br_tag}\n${second_tag}\.\. done</span>\s*${br_tag}${spacer_tag}\n+${first_tag}Saving to storage \.\.</span>\s*},
     'checking completion leaves a blank line before storage');
like($raw_progress, qr/${second_tag}\.\. done<\/span>/,
     'results use the second_print API');
unlike($raw_progress, qr/<ul\b|<\/ul>/,
       'single-image progress is not indented');
unlike($html, qr/Processing .* image/,
       'single-image progress needs no parent step');

# Local imports retain their step results without any HTTP download output.
for my $state (qw(verifying importing copying)) {
	$html = render({ a => [ { state => $state, source => 'local',
				  bytes => 1000, transferred => 0 },
				{ state => 'ready', source => 'local',
				  bytes => 1000 } ] });
	is(scalar(@callbacks), 0, "$state never emits HTTP download progress");
	like($html, qr{Saving to storage \.\.${br_tag}\n\.\. done${br_tag}},
	     "$state shows storage completion");
	}

# Progress names the checksum source and algorithm when a checksum is available.
# Without one, it describes only the disk image check.
for my $case (
	[ { source => 'download', checksum_algorithm => 'sha512' },
	  'Verifying vendor SHA-512 checksum and checking disk image' ],
	[ { source => 'upload', sha256 => 'a' x 64 },
	  'Verifying supplied SHA-256 checksum and checking disk image' ],
	[ { source => 'local' }, 'Checking disk image' ],
) {
	my ($fields, $label) = @$case;
	$html = render({ a => [ { %$fields, state => 'ready',
		bytes => 100 } ] });
	like($html, qr/\Q$label\E \.\.${br_tag}\n\.\. done/,
	     'completed progress describes the actual checks');
	my $status = get_image_job_status({ %$fields, state => 'verifying',
					    updated => time(),
					    name => 'Fixture',
					    pool_name =>
						    'default',
					    bytes => 100 });
	is($status->{'label'}, $label, 'live status describes the same checks');
	}

# Polling may skip fast phases, but every batch member keeps its own total.
$html = render({
	a => [ { state => 'downloading', bytes => 50, total => 100 },
	       { state => 'ready', bytes => 100 } ],
	b => [ { state => 'downloading', bytes => 25 },
	       { state => 'importing', bytes => 200, transferred => 0 },
	       { state => 'ready', bytes => 200 } ],
});
is_deeply([ map { $_->[2] } grep { $_->[1] == 3 } @callbacks ],
	  [ 50, 100, 25, 200 ],
	  'batch downloads and unknown totals retain separate byte progress');
is(scalar(() = $html =~ /\.\. download complete/g), 2,
   'each completed download ends once');
like($html,
     qr{Saving to storage \.\.${br_tag}\n\.\. done${br_tag}\n</ul>\n\.\. done${br_tag}\nProcessing <tt\b[^>]*>Image b</tt>\s* image \.\.${br_tag}\n${indent_tag}\nDownloading Image b},
     'the first image completes outside its block before the next parent step');
like($raw_progress,
     qr{${first_tag}Processing <tt\b[^>]*>Image a</tt>\s* image \.\.</span>\s*${br_tag}\n${indent_tag}},
     'a named parent step introduces the first indented image');
my @blocks = $raw_progress =~ m{${indent_tag}\n(.*?)</ul>}sg;
is(scalar(@blocks), 2, 'each batch image has a separate indented block');
like($blocks[0], qr/\A(?!.*data-x-br).*Downloading Image a.*Saving to storage/s,
     'first block contains its image steps without blank gaps');
like($blocks[1], qr/\A(?!.*data-x-br).*Downloading Image b.*Saving to storage/s,
     'second block contains its image steps without blank gaps');

# Batch results must reflect failure or waiting, even if
# earlier steps succeeded.
for my $case (
	[ { state => 'failed', failure_state => 'verifying',
	    error => 'Bad checksum' }, '.. failed' ],
	[ { state => 'deleted' }, '.. failed' ],
	[ { state => 'importing', updated => time() - 4000 }, '.. failed' ],
	[ { state => 'waiting', source => 'upload' }, 'Waiting for upload' ],
) {
	my ($fields, $result) = @$case;
	$html = render({ a => [ { %$fields, name => '<image>', bytes => 100 } ],
			 b => [ { state => 'ready', bytes => 200 } ] });
	like($raw_progress,
	     qr{Processing <tt\b[^>]*>&lt;image&gt;</tt>\s* image \.\.</span>\s*${br_tag}\n${indent_tag}.*?</ul>\n${second_tag}\Q$result\E</span>\s*${br_tag}${spacer_tag}\n+${first_tag}Processing <tt\b[^>]*>Image b</tt>\s*}s,
	     "$fields->{'state'} closes the image block with its actual result");
	}

# A second batch member may finish before its first progress poll.
$html = render({ b => [ { state => 'ready', bytes => 200 } ] });
like($html,
     qr{Downloading Image b \(200 bytes\).*Verifying vendor SHA-256 checksum and checking disk image \.\.${br_tag}\n\.\. done${br_tag}\nSaving to storage \.\.${br_tag}\n\.\. done${br_tag}}s,
     'already finished downloads retain the full step sequence');

# An aborted download must not get a misleading completion message.
for my $state (qw(failed deleted)) {
	$html = render({ a => [ { state => 'downloading', bytes => 50,
				  total => 100 },
				{ state => $state, bytes => 50,
				  error => 'Stopped' } ] });
	unlike($html, qr/download complete/,
	       "$state download is not reported complete");
	like($html, qr/\.\. failed : /, "$state reports an unsuccessful step");
	}

# Persisted failure phases locate errors even when polling misses a fast step.
for my $phase (qw(verifying importing)) {
	$html = render({ a => [ { state => 'downloading', bytes => 50,
				  total => 100 },
				{ state => 'failed', failure_state => $phase,
				  bytes => 100,
				  error => 'Cannot use <image>' } ] });
	my $label = $phase eq 'verifying'
		? 'Verifying vendor SHA-256 checksum and checking disk image ..'
		: 'Saving to storage ..';
	like($html,
	     qr{\Q$label\E${br_tag}\n\.\. failed : cannot use &lt;image&gt;${br_tag}},
	     "$phase shows its escaped failure on a separate line");
	unlike($html, qr{\Q$label\E${br_tag}\n\.\. done},
	       "$phase does not claim success");
	unlike($html, qr/Ready/, "$phase failure has no Ready line");
	}

# Dead workers must not appear successful, and upload/copy labels retain names.
$html = render({ a => [ { state => 'importing', updated => time() - 4000,
			  bytes => 100 } ] });
like($html, qr{Saving to storage \.\.${br_tag}\n\.\. failed : the import stopped},
     'interruption is reported against the active step');
$html = render({ a => [ { state => 'ready', source => 'upload',
			  bytes => 100 } ] });
like($html, qr/Uploading <tt\b[^>]*>Image a<\/tt>\s*/,
     'uploads are identified without a download heading');
is(scalar(@callbacks), 0, 'completed uploads have no HTTP download output');

# Theme progress links may use POST with no form token after a completed upload.
for my $method (qw(GET POST)) {
	$html = render({ a => [ { state => 'ready', source => 'upload',
				  format => 'iso', bytes => 100 } ] }, $method);
	like($html, qr/Uploading <tt\b[^>]*>Image a<\/tt>\s*.*Saving to storage.*done/s,
	     "$method reconnects to the uploaded ISO");
	is($imports_started, 0,
	   "$method progress does not start another import");
	}

# Supplying a job ID must not bypass validation of a new import submission.
for my $fields ( { job => undef }, { install_type => 'upload' },
		 { install_type => 'download', token => 'invalid' } ) {
	eval { render({ a => [ { state => 'ready' } ] }, 'POST', $fields); };
	like($@, qr/This form has expired/,
	     'new import still requires a valid token');
	is($imports_started, 0, 'rejected submission starts no work');
	}
# A valid new-import POST must still create work and stream the resulting job.
$html = render({ a => [ { state => 'ready', source => 'local',
			  bytes => 100 } ] },
	       'POST',
	       { job => undef, install_type => 'local',
		 token => 'fixture-token' });
is($imports_started, 1, 'authorized form submission still starts its import');
like($html, qr/Copying <tt\b[^>]*>Image a<\/tt>\s*/,
     'new import streams its progress');
done_testing();
