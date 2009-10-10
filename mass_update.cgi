#!/usr/local/bin/perl
# Install selected packages on multiple systems

require './server-manager-lib.pl';
&ReadParse();
%d = map { $_, 1 } split(/\0/, $in{'d'});
@servers = grep { $d{$_->{'id'}} } &list_managed_servers();
@servers || &error($text{'mass_enone'});
&can_action_error(\@servers, "update");
if (@servers == 1) {
	&ui_print_header(&server_in($servers[0]), $text{'update_title'}, "");
	}
else {
	&ui_print_header(undef, $text{'update_title'}, "");
	}

# Find selected servers with updates, limiting to those we want
@upservers = ( );
$pos = 0;
%wantids = map { $_, 1 } split(/\0/, $in{'p'});
foreach $s (@servers) {
	$info = &get_server_collected($s);
	@poss = @{$info->{'allposs'}};
	@poss = @{$info->{'poss'}} if (!@poss);
	@poss = grep { $wantids{$_->{'system'}.'/'.$_->{'name'}} } @poss;
	if (@poss) {
		push(@upservers, $s);
		$pos += scalar(@poss);
		}
	foreach $pkg (@poss) {
		$k = $pkg->{'system'}."/".$pkg->{'name'};
		$pkgs{$k} ||= $pkg;
		}
	}

# Run them in parallel, and report on updates done
print &text('mass_updoing', scalar(@upservers), $pos),"<br>\n";
&obtain_lock_server(\@upservers);
print "<ul>\n";
@rv = &parallel_install_package_updates(\@upservers, [ values %pkgs ]);
for($i=0; $i<@rv; $i++) {
	$s = $upservers[$i];
	if (@{$rv[$i]}) {
		print &text('mass_upserver',
			"<tt>$s->{'host'}</tt>"),"<br>\n";
		print "<ul>\n";
		foreach $p (@{$rv[$i]}) {
			print &text('update_pkg',
				    "<tt>$p->{'name'}</tt>",
				    $p->{'version'}),"<br>\n";
			if (!$p->{'status'}) {
				print &text('mass_upfailed',
					    $p->{'error'});
				}
			elsif (@{$p->{'updates'}}) {
				print &text('mass_uplist', 
					join(" ", map { "<tt>$_</tt>" }
						@{$p->{'updates'}}));
				}
			else {
				print $text{'mass_upnone'};
				}
			print "<br>\n";
			}
		print "</ul>\n";
		}
	else {
		print &text('mass_upservernone',
			    "<tt>$s->{'host'}</tt>"),"<br>\n";
		}
	}
print "</ul>\n";
&release_lock_server(\@upservers);
print $text{'mass_updone'},"<p>\n";
&webmin_log("update", "servers", scalar(@servers),
	    { 'hosts' => \@hostnames });

if (defined(&theme_post_save_server)) {
	&theme_post_save_server();
	&theme_select_server($servers[0]) if (@servers == 1);
	}

&ui_print_footer("", $text{'index_return'});

