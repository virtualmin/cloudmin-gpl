use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use WebminCore;
our (%text, %access, $root_directory, $module_root_directory);
$root_directory = $CloudminTest::webmin_root;
$module_root_directory = "$Bin/..";
# Load the same labels as the real pages without initializing a Webmin host.
open(my $lang, '<', "$Bin/../lang/en") || die $!;
while (<$lang>) { chomp; $text{$1} = $2 if /^([^=]+)=(.*)$/; }
close($lang);
require "$Bin/../cloudmin-access-lib.pl";
require "$Bin/../cloudmin-ssh-pages.pl";
%access = (admin => 1);
my @keys = ({id=>'a'x32,name=>'Admins <one>',public=>'ssh-ed25519 AAAA admins&co',fingerprint=>'SHA256:one',
        type=>'ssh-ed25519',private=>'never-show-this',addnew=>0});
# The widget reads the library through the shared Pro accessor.
{
    no warnings 'once';
    # get_ssh_key_manager() supplies a library without reading host storage.
    *main::get_ssh_key_manager = sub { bless {}, 'LibraryFixture' };
}
# LibraryFixture::list(self) returns the current public-key widget fixtures.
sub LibraryFixture::list { \@keys }

# Check both editions independently of the installed Pro extension.
local $module_root_directory = tempdir(CLEANUP => 1);
my $plain = ssh_public_key_input('ssh-rsa BBBB');
like($plain, qr/<textarea[^>]*name="ssh_keys"/, 'GPL renders the public key textarea');
unlike($plain, qr/ui_dropdown|ssh-keys\.js/, 'GPL has no saved-key menu');
# Installing the extension adds the menu to the same field.
make_path("$module_root_directory/pro");
open(my $pro, '>', "$module_root_directory/pro/SSHKeys.pm") || die $!;
close($pro);
my $html = ssh_public_key_input('ssh-rsa BBBB');
like($html, qr/<textarea[^>]*name="ssh_keys"[^>]*>ssh-rsa BBBB/, 'Pro keeps the textarea and its value');
like($html, qr/<details[^>]*ui_dropdown/, 'saved keys open from a menu');
like($html, qr/<button(?=[^>]*type="button")(?=[^>]*data-ssh-key-insert="ssh-ed25519 AAAA admins&amp;co")[^>]*>/,
    'entries carry the escaped public text and never submit the form');
# Escape untrusted key labels and attributes without exposing private data.
@keys = ({%{$keys[0]}, public => 'ssh-ed25519 AAAA say "hi"'});
like(ssh_public_key_input(''), qr/data-ssh-key-insert="ssh-ed25519 AAAA say &quot;hi&quot;"/,
    'quotes in key comments cannot break the entry');
like($html, qr/Admins &lt;one&gt;/, 'entry names escaped');
like($html, qr/SHA256:one/, 'entries show the fingerprint');
unlike($html, qr/pro\/list_keys\.cgi|ui_dropdown_sep/, 'saved-key menu contains only keys');
like($html, qr/ssh-keys\.js\?\d+/, 'page script loaded with a cache key');
unlike($html, qr/never-show-this/, 'private material never reaches the form');
# Automatic keys stay visible without offering duplicate insertion.
push(@keys, {%{$keys[0]}, name => 'Auto <admins>', public => 'ssh-ed25519 BBBB automatic', addnew => 1});
my $mixed = ssh_public_key_input('');
my @entries = $mixed =~ m{(<button\b[^>]*>.*?</button>)}sg;
is(scalar(@entries), 2, 'mixed library displays both saved keys');
unlike($entries[0], qr/disabled|ui_badge/, 'ordinary key stays enabled without an automatic badge');
like($entries[0], qr/data-ssh-key-insert=/, 'ordinary key retains insertion data');
like($entries[1], qr/<button[^>]*\bdisabled\b/, 'automatic key cannot be selected');
like($entries[1], qr/Auto &lt;admins&gt;.*ui_badge.*Automatic/s, 'automatic key shows its escaped name and badge');
unlike($entries[1], qr/data-ssh-key-insert|ssh-ed25519 BBBB/, 'automatic key carries no insertion data');
# Automatic-only libraries still explain which keys will be added.
@keys = ($keys[1]);
my $automatic = ssh_public_key_input('');
like($automatic, qr/ui_dropdown.*Automatic/s, 'an automatic-only library still shows its key');
unlike($automatic, qr/data-ssh-key-insert|pro\/list_keys\.cgi/, 'automatic-only menu offers no insertion or management link');
# Locked fields cannot insert keys or open the library through this widget.
my $disabled = ssh_public_key_input('ssh-rsa BBBB', 1);
like($disabled, qr/<textarea[^>]*disabled/, 'disabled template fields render a disabled textarea');
unlike($disabled, qr/ui_dropdown|list_keys\.cgi/, 'disabled template fields get no menu');
# An empty library links to management without displaying an empty menu.
@keys = ();
my $none = ssh_public_key_input('');
unlike($none, qr/ui_dropdown/, 'an empty library shows no menu');
like($none, qr/pro\/list_keys\.cgi/, 'an empty library still links to the manager');
# A damaged library reports its error without blocking the creation form.
{
    no warnings qw(redefine once);
    # list(self) simulates a rejected library read.
    local *LibraryFixture::list = sub { die "Unsafe SSH key file <x>\n" };
    # error_message(error) preserves the fixture diagnostic for escaping.
    local *main::error_message = sub { $_[0] };
    my $broken = ssh_public_key_input('ssh-rsa BBBB');
    like($broken, qr/<textarea[^>]*name="ssh_keys"[^>]*>ssh-rsa BBBB/, 'a damaged library keeps the key field');
    like($broken, qr/Unsafe SSH key file &lt;x&gt;/, 'the library error is shown escaped');
    unlike($broken, qr/ui_dropdown/, 'a damaged library offers no menu');
}
# Guest delegation alone must not expose the host library.
%access = (admin => 0, vms => 'x');
unlike(ssh_public_key_input(''), qr/list_keys\.cgi|ui_dropdown/, 'delegated users get the plain field');
done_testing();
