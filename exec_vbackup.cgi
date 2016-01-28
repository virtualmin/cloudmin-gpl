#!/usr/local/bin/perl
# Run one virtualmin backup manually and print output

require './server-manager-lib.pl';
&ReadParse();
$vbackup = &get_virtualmin_backup($in{'id'});
$vbackup || &error($text{'vbackup_egone'});
&can_virtualmin_backup($vbackup) || &error($text{'vbackup_ecannot'});

&ui_print_unbuffered_header(undef, $text{'vbackup_title3'}, "");

# Tell the user what's happening
@doms = split(/\s+/, $vbackup->{'doms'});
@tmpls = split(/\s+/, $vbackup->{'tmpls'});
@srcs = &get_virtualmin_backup_srcs($vbackup);
@dests = split(/\s+/, $vbackup->{'dest'});
print "<b>",&text('vbackup_running',
		  scalar(@doms),
		  scalar(@tmpls),
		  join(", ", map { "<tt>$_->{'host'}</tt>" } @srcs),
		  join(", ", map { "<tt>$_</tt>" } @dests))."</b><p>\n";

&$indent_print();
$ok = &backup_virtualmin_domains($vbackup);
&$outdent_print();

if ($ok) {
	print "<b>$text{'vbackup_allok'}</b><p>\n";
	}
else {
	print "<b>$text{'vbackup_failed'}</b><p>\n";
	}
&webmin_log("exec", "vbackup", $srcs[0]->{'host'}, { 'doms' => \@doms });

&ui_print_footer("list_vbackups.cgi", $text{'vbackups_return'});

