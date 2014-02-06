#!/usr/local/bin/perl
# Updates or deletes a system image

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&error_if_cloudmin_replica();
&ReadParse();
@images = &list_server_images();
($img) = grep { $_->{'id'} eq $in{'id'} } @images;
$img || &error($text{'dimage_egone'});
&obtain_lock_anything();

if ($in{'delete'}) {
	# Just delete
	&delete_server_image($img);
	&webmin_log("delete", "image", $img->{'id'});
	&redirect("list_images.cgi?mode=$in{'mode'}&search=".
		  &urlize($in{'search'}));
	}
elsif ($in{'convert'}) {
	# Redirect to conversion form
	&redirect("convert_image_form.cgi?id=$img->{'id'}&convto=$in{'convto'}".
		  "&search=".&urlize($in{'search'})."&mode=$in{'mode'}");
	}
else {
	# Update description and OS
	&error_setup($text{'eimage_err'});
	$in{'desc'} =~ /\S/ || &error($text{'eimage_edesc'});
	$img->{'desc'} = $in{'desc'};
	$img->{'type'} = $in{'type'};
	if (defined($in{'nodelete'})) {
		$img->{'nodelete'} = !$in{'nodelete'};
		}
	$img->{'default'} = $in{'default'};
	$img->{'postcmdon'} = $in{'postcmdon'};
	$img->{'postcmdoff'} = $in{'postcmdoff'};
	&save_server_image($img);
	if ($in{'default'}) {
		# Nobody else can be the default
		foreach $i (@images) {
			if ($i->{'manager'} eq $img->{'manager'} &&
			    $i->{'id'} ne $img->{'id'} &&
			    $i->{'default'}) {
				$i->{'default'} = 0;
				&save_server_image($i);
				}
			}
		}
	&webmin_log("modify", "image", $img->{'id'});
	&redirect("list_images.cgi?mode=$in{'mode'}&search=".
		  &urlize($in{'search'}));
	}
