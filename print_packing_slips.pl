#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$ENV{HOME}/perl5/lib/perl5";
use lib "$FindBin::Bin";

use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);
use PDF::API2;
use File::Temp qw(tempfile);
use POSIX qw(strftime);

my $CONFIG = do "$FindBin::Bin/config.pl"
    or die "Failed to load config.pl: $@$!";

my $STATE_FILE       = "$FindBin::Bin/state/printed_orders.txt";
my $TOKEN_CACHE_FILE = "$FindBin::Bin/state/access_token_cache.json";
my $LOG_FILE         = "$FindBin::Bin/logs/print_packing_slips.log";

sub log_msg {
    my ($msg) = @_;
    open(my $fh, '>>', $LOG_FILE) or return;
    print $fh strftime('%Y-%m-%d %H:%M:%S', localtime), " $msg\n";
    close $fh;
}

sub load_printed_ids {
    my %ids;
    if (open(my $fh, '<', $STATE_FILE)) {
        while (my $line = <$fh>) {
            chomp $line;
            $ids{$line} = 1 if length $line;
        }
        close $fh;
    }
    return \%ids;
}

sub mark_printed {
    my ($order_id) = @_;
    open(my $fh, '>>', $STATE_FILE) or die "Can't write $STATE_FILE: $!";
    print $fh "$order_id\n";
    close $fh;
}

sub get_access_token {
    if (open(my $fh, '<', $TOKEN_CACHE_FILE)) {
        local $/;
        my $cached = eval { decode_json(<$fh>) };
        close $fh;
        if ($cached && $cached->{expires_at} > time() + 60) {
            return $cached->{access_token};
        }
    }

    my $ua  = HTTP::Tiny->new(timeout => 30);
    my $url = "https://$CONFIG->{shop_domain}/admin/oauth/access_token";
    my $resp = $ua->post_form(
        $url,
        {
            grant_type    => 'client_credentials',
            client_id     => $CONFIG->{client_id},
            client_secret => $CONFIG->{client_secret},
        }
    );

    unless ($resp->{success}) {
        die "Token exchange failed: $resp->{status} $resp->{reason}\n$resp->{content}\n";
    }

    my $data = decode_json($resp->{content});
    my $expires_at = time() + $data->{expires_in};

    open(my $out, '>', $TOKEN_CACHE_FILE) or die "Can't write $TOKEN_CACHE_FILE: $!";
    print $out encode_json({ access_token => $data->{access_token}, expires_at => $expires_at });
    close $out;
    chmod 0600, $TOKEN_CACHE_FILE;

    return $data->{access_token};
}

sub fetch_orders_to_print {
    my ($search_override) = @_;
    my $search = $search_override // $CONFIG->{order_query};

    my $query = <<'GRAPHQL';
query PackingSlipOrders($search: String!) {
  orders(first: 25, query: $search, sortKey: CREATED_AT) {
    edges {
      node {
        id
        name
        createdAt
        note
        shippingLine {
          title
        }
        shippingAddress {
          name
          address1
          address2
          city
          provinceCode
          zip
          countryCodeV2
          phone
        }
        lineItems(first: 100) {
          edges {
            node {
              title
              quantity
              sku
              variantTitle
            }
          }
        }
      }
    }
  }
}
GRAPHQL

    my $ua  = HTTP::Tiny->new(timeout => 30);
    my $url = "https://$CONFIG->{shop_domain}/admin/api/$CONFIG->{api_version}/graphql.json";
    my $resp = $ua->post(
        $url,
        {
            headers => {
                'Content-Type'           => 'application/json',
                'X-Shopify-Access-Token' => get_access_token(),
            },
            content => encode_json({
                query     => $query,
                variables => { search => $search },
            }),
        }
    );

    unless ($resp->{success}) {
        die "Shopify API request failed: $resp->{status} $resp->{reason}\n$resp->{content}\n";
    }

    my $data = decode_json($resp->{content});
    if ($data->{errors}) {
        die "Shopify API returned errors: " . encode_json($data->{errors}) . "\n";
    }

    my @orders = map { $_->{node} } @{ $data->{data}{orders}{edges} };
    return @orders;
}

sub numeric_order_id {
    my ($gid) = @_;
    my ($id) = $gid =~ m{/(\d+)$};
    return $id;
}

sub draw_text {
    my ($page, $font, $size, $x, $y, $string, %opts) = @_;
    my $text = $page->text();
    $text->font($font, $size);
    $text->fillcolor($opts{color}) if $opts{color};
    $text->position($x, $y);
    $text->text($string);
}

my $MARGIN = 18;
my $BOTTOM = 30; # keep content above this y before forcing a new label

sub start_slip_page {
    my ($pdf, $order, $font, $font_bold, $page_num) = @_;

    my $page = $pdf->page();
    $page->mediabox(288, 432); # 4in x 6in at 72pt/in
    my $y = 432 - $MARGIN;

    if ($page_num == 1) {
        if ($CONFIG->{logo_path} && -e $CONFIG->{logo_path}) {
            my $img = $pdf->image_png($CONFIG->{logo_path});
            my $max_w = 288 - (2 * $MARGIN);
            my $max_h = 36;
            my $scale = $max_w / $img->width;
            my $draw_w = $img->width * $scale;
            my $draw_h = $img->height * $scale;
            if ($draw_h > $max_h) {
                my $scale2 = $max_h / $img->height;
                $draw_w = $img->width * $scale2;
                $draw_h = $max_h;
            }
            my $gfx = $page->gfx();
            $gfx->image($img, 288 - $MARGIN - $draw_w, $y - $draw_h, $draw_w, $draw_h);
            $y -= ($draw_h + 10);
        }

        draw_text($page, $font_bold, 14, $MARGIN, $y, "Order $order->{name}");
        $y -= 16;

        my ($date) = $order->{createdAt} =~ /^(\S+)T/;
        draw_text($page, $font, 9, $MARGIN, $y, "Date: $date");
        $y -= 16;
    }
    else {
        draw_text($page, $font_bold, 12, $MARGIN, $y, "Order $order->{name} (cont'd, label $page_num)");
        $y -= 16;
    }

    my $gfx = $page->gfx();
    $gfx->move($MARGIN, $y);
    $gfx->line(288 - $MARGIN, $y);
    $gfx->stroke();
    $y -= 14;

    return ($page, $y);
}

sub finish_slip_page_continued {
    my ($page, $font) = @_;
    draw_text($page, $font, 8, $MARGIN, $BOTTOM - 10, '--- continued on next label ---', color => '#777777');
}

sub build_packing_slip_pdf {
    my ($order) = @_;

    my $pdf = PDF::API2->new();
    my $font      = $pdf->corefont('Helvetica');
    my $font_bold = $pdf->corefont('Helvetica-Bold');

    my $page_num = 1;
    my ($page, $y) = start_slip_page($pdf, $order, $font, $font_bold, $page_num);

    # Ship to (first label only)
    draw_text($page, $font_bold, 10, $MARGIN, $y, "Ship To:");
    $y -= 13;

    my $addr = $order->{shippingAddress};
    if ($addr) {
        my @lines = (
            $addr->{name},
            $addr->{address1},
            $addr->{address2},
            join(', ', grep { defined && length } ($addr->{city}, $addr->{provinceCode}, $addr->{zip})),
            $addr->{countryCodeV2},
        );
        for my $line (@lines) {
            next unless defined $line && length $line;
            draw_text($page, $font, 9, $MARGIN, $y, $line);
            $y -= 12;
        }
    }
    $y -= 8;

    # Gift message / note (first label only)
    if ($order->{note} && length $order->{note}) {
        draw_text($page, $font_bold, 10, $MARGIN, $y, "Note:");
        $y -= 13;

        for my $line (wrap_text($order->{note}, 55)) {
            draw_text($page, $font, 9, $MARGIN, $y, $line);
            $y -= 12;
        }
        $y -= 8;
    }

    # Divider
    my $gfx3 = $page->gfx();
    $gfx3->move($MARGIN, $y);
    $gfx3->line(288 - $MARGIN, $y);
    $gfx3->stroke();
    $y -= 14;

    # Line items header
    draw_text($page, $font_bold, 9, $MARGIN, $y, "Qty");
    draw_text($page, $font_bold, 9, $MARGIN + 30, $y, "Item");
    $y -= 12;

    for my $edge (@{ $order->{lineItems}{edges} }) {
        my $item = $edge->{node};

        my $label = $item->{title};
        $label .= " ($item->{variantTitle})" if $item->{variantTitle} && $item->{variantTitle} ne 'Default Title';
        my @wrapped = wrap_text($label, 40);

        my $has_sku  = $CONFIG->{show_sku} && $item->{sku} && length $item->{sku};
        my $needed_h = 11 * scalar(@wrapped) + ($has_sku ? 11 : 0) + 3;

        if ($y - $needed_h < $BOTTOM) {
            finish_slip_page_continued($page, $font);
            $page_num++;
            ($page, $y) = start_slip_page($pdf, $order, $font, $font_bold, $page_num);
            draw_text($page, $font_bold, 9, $MARGIN, $y, "Qty");
            draw_text($page, $font_bold, 9, $MARGIN + 30, $y, "Item");
            $y -= 12;
        }

        draw_text($page, $font, 9, $MARGIN, $y, $item->{quantity});
        draw_text($page, $font, 9, $MARGIN + 30, $y, $wrapped[0] // '');
        $y -= 11;

        for my $extra (@wrapped[1 .. $#wrapped]) {
            draw_text($page, $font, 9, $MARGIN + 30, $y, $extra);
            $y -= 11;
        }

        if ($has_sku) {
            draw_text($page, $font, 7, $MARGIN + 30, $y, "SKU: $item->{sku}", color => '#555555');
            $y -= 11;
        }
        $y -= 3;
    }

    # Prominent shipping-method callout for expedited/special carriers
    my $ship_method = $order->{shippingLine} && $order->{shippingLine}{title};
    if ($ship_method && $ship_method =~ /Priority|DHL/i) {
        my @lines = wrap_text(uc($ship_method), 26);
        my $line_h  = 14;
        my $box_pad = 6;
        my $box_h   = $box_pad * 2 + $line_h * scalar(@lines);

        if ($y - 8 - $box_h < $BOTTOM) {
            finish_slip_page_continued($page, $font);
            $page_num++;
            ($page, $y) = start_slip_page($pdf, $order, $font, $font_bold, $page_num);
        }

        $y -= 8;
        my $gfx4 = $page->gfx();
        $gfx4->linewidth(1.5);
        $gfx4->rect($MARGIN, $y - $box_h, 288 - 2 * $MARGIN, $box_h);
        $gfx4->stroke();

        my $line_y = $y - $box_pad - 10;
        for my $line (@lines) {
            draw_text($page, $font_bold, 12, $MARGIN + $box_pad, $line_y, $line);
            $line_y -= $line_h;
        }
        $y -= ($box_h + 10);
    }

    my ($fh, $tmpfile) = tempfile(SUFFIX => '.pdf');
    close $fh;
    $pdf->saveas($tmpfile);
    $pdf->end();
    return $tmpfile;
}

sub wrap_text {
    my ($str, $width) = @_;
    my @words = split /\s+/, $str;
    my @lines;
    my $cur = '';
    for my $w (@words) {
        if (length($cur) + length($w) + 1 > $width) {
            push @lines, $cur if length $cur;
            $cur = $w;
        } else {
            $cur = length($cur) ? "$cur $w" : $w;
        }
    }
    push @lines, $cur if length $cur;
    return @lines;
}

sub print_pdf {
    my ($pdf_path) = @_;
    my @cmd = ('lpr', '-P', $CONFIG->{printer_name}, '-o', 'media=4x6', $pdf_path);
    system(@cmd) == 0 or die "lpr failed (exit " . ($? >> 8) . ") for $pdf_path\n";
}

sub main {
    my $printed = load_printed_ids();

    my @orders = eval { fetch_orders_to_print() };
    if ($@) {
        log_msg("ERROR fetching orders: $@");
        die $@;
    }

    for my $order (@orders) {
        my $id = numeric_order_id($order->{id});
        next if $printed->{$id};

        log_msg("Printing packing slip for order $order->{name} (id $id)");

        my $pdf_path = eval { build_packing_slip_pdf($order) };
        if ($@) {
            log_msg("ERROR building PDF for order $id: $@");
            next;
        }

        my $ok = eval { print_pdf($pdf_path); 1 };
        unlink $pdf_path;

        if ($ok) {
            mark_printed($id);
            log_msg("Printed order $order->{name} (id $id)");
        } else {
            log_msg("ERROR printing order $id: $@");
        }
    }
}

main() unless caller;

1;
