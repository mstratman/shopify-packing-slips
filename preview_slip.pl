#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;

my $order_ref = shift @ARGV or die "Usage: preview_slip.pl <order-name-or-number> <output.pdf>\n";
my $out_path  = shift @ARGV or die "Usage: preview_slip.pl <order-name-or-number> <output.pdf>\n";

do "$FindBin::Bin/print_packing_slips.pl";
die $@ if $@;

my @orders = fetch_orders_to_print("name:$order_ref");
die "No order found matching '$order_ref'\n" unless @orders;

my $pdf_path = build_packing_slip_pdf($orders[0]);
rename($pdf_path, $out_path) or die "Can't move PDF to $out_path: $!";

print "Saved preview PDF for order $orders[0]{name} to $out_path\n";
