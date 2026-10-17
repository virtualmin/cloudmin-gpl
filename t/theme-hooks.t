use strict;
use warnings;

use FindBin qw($Bin);
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use WebminCore;

# Load hooks as Webmin does: the module imports first, then the theme loads.
our (%text);
require "$Bin/../cloudmin-pages.pl";

my $vm = { 'uuid' => '0f9c2b7e-3a1d-4c5e-9b8a-7d6e5f4c3b2a',
	'name' => 'web-01' };

# capture(code)
# Returns everything the code prints.
sub capture
{
my ($code) = @_;
my $out = '';
open(my $fh, '>', \$out) or die $!;
my $old = select($fh);
$code->();
select($old);
close($fh);
return $out;
}

# Themes without guest navigation need no selection or refresh output.
is(capture(sub { select_theme_server($vm) }), '',
	'guest selection is optional when the theme has no hook');
is(capture(sub { notify_theme_save($vm, 'create') }), '',
	'guest changes are optional when the theme has no hook');

# Load named subs through Webmin's loader so the exported aliases stay intact.
our (@selected, @saved, $markers);
my $theme_dir = tempdir(CLEANUP => 1);
open(my $theme, '>', "$theme_dir/theme.pl") or die $!;
print $theme <<'THEME';
# theme_select_server(server)
# Records selection and emits the fixture's current output format.
sub theme_select_server
{
push(@main::selected, @_);
print $main::markers ? "<!--\ntheme_select_server=$_[0]->{'id'}\n-->\n"
	: "select-hook\n";
}

# theme_post_save_server(server, action)
# Records guest changes and emits the fixture's current output format.
sub theme_post_save_server
{
push(@main::saved, @_);
print $main::markers ? "<!--\ntheme_post_save=$_[0]->{'id'}\n-->\n"
	: "save-hook\n";
}
1;
THEME
close($theme) or die $!;
{
	local $WebminCore::current_theme = 'hook-test';
	local $WebminCore::loaded_theme_library = 0;
	local @WebminCore::theme_root_directories = ($theme_dir);
	local @WebminCore::theme_configs = ({ functions => 'theme.pl' });
	load_theme_library();
	}

{
	# Hooks loaded after the module imports WebminCore must still be called.
	is(capture(sub { select_theme_server($vm) }), "select-hook\n",
		'guest selection calls the theme hook');
	is_deeply(\@selected, [ { 'id' => $vm->{'uuid'}, 'host' => 'web-01' } ],
		'the selection hook receives the Cloudmin 9 id and host keys');
	is(capture(sub { notify_theme_save($vm, 'create') }), "save-hook\n",
		'guest changes call the theme hook');
	is_deeply(\@saved,
		[ { 'id' => $vm->{'uuid'}, 'host' => 'web-01' }, 'create' ],
		'the change hook receives the guest record and action');
	@saved = ();
	is(capture(sub { notify_theme_save($vm, 'delete') }), "save-hook\n",
		'the same hook supports guest deletion');
	is($saved[1], 'delete', 'the deletion action is passed unchanged');

	# A marker-based theme owns its output, just like a frame-based theme.
	$markers = 1;
	is(capture(sub { select_theme_server($vm) }),
		"<!--\ntheme_select_server=$vm->{'uuid'}\n-->\n",
		'the theme hook supplies its own selection marker');
	is(capture(sub { notify_theme_save($vm, 'create') }),
		"<!--\ntheme_post_save=$vm->{'uuid'}\n-->\n",
		'the theme hook supplies its own change marker');
	}
done_testing();
