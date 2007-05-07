#!/usr/local/bin/perl
# Show a table of available features and the servers they can be used on

require './server-manager-lib.pl';
&ReadParse();
&ui_print_header(undef, $text{'features_title'}, "", "features");

# Get servers and features
@vservers = grep { $_->{'status'} eq 'virt' } &list_managed_servers();
@allfeatures = ( );
foreach $s (sort { $a->{'host'} cmp $b->{'host'} } @vservers) {
	$info = &get_server_collected($s);
	foreach $f ($info->{'features'} ? @{$info->{'features'}}
					: @standard_virtualmin_features) {
		if ($f->{'enabled'}) {
			($allf) = grep { $_->{'feature'} eq $f->{'feature'} } 
					@allfeatures;
			if (!$allf) {
				push(@allfeatures, $allf = $f);
				}
			push(@{$allf->{'servers'}}, $s);
			}
		}
	}
%defs = map { $_, 1 } split(/\s+/, $config{'defs'});

# Show the table
print $text{'features_topdesc'},"<p>\n";
@tds = ( "width=5" );
print &ui_form_start("save_features.cgi", "post");
print &ui_radio("def", %defs ? 0 : 1,
		[ [ 1, $text{'features_def1'} ],
		  [ 0, $text{'features_def0'} ] ]),"\n";
print &ui_columns_start([ "",
			  $text{'feature_desc'},
			  $text{'feature_type'},
			  $text{'feature_users'} ], 100, undef, \@tds);
foreach $f (@allfeatures) {
	@s = @{$f->{'servers'}};
	$users = @s == 0 ? $text{'feature_none'} :
		 @s == @vservers ? $text{'feature_all'} :
		 @s > 4 ? &text('feature_many', scalar(@s)) :
			join(", ", map { "<tt>$_->{'host'}</tt>" } @s);
	print &ui_checked_columns_row([
		$f->{'desc'},
		$f->{'plugin'} ? $text{'feature_plugin'}
			       : $text{'feature_core'},
		$users
		], \@tds, "features", $f->{'feature'}, $defs{$f->{'feature'}});
	}
print &ui_columns_end();
print &ui_form_end([ [ undef, $text{'save'} ] ]);

&ui_print_footer("", $text{'index_return'});

