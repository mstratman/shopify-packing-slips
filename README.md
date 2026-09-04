# Shopify Packing Slips

Polls a Shopify store for paid, unfulfilled orders and automatically
prints a 4x6 packing slip for each to a thermal label printer via `lpr`.

No third-party Shopify apps involved — connects directly to the Admin API using a
custom app (client credentials grant).

Runs as a macOS launchd job (`com.maseffects.packingslips.plist`) polling every
2 minutes.

## Setup

1. `cp config.pl.example config.pl` and fill in your shop domain, client ID/secret
   (from the Shopify Dev Dashboard), and printer name.
2. `cp com.maseffects.packingslips.plist ~/Library/LaunchAgents/`
3. `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.maseffects.packingslips.plist`

## Files

- `print_packing_slips.pl` — main polling/printing script
- `preview_slip.pl <order-name> <out.pdf>` — render one order's slip to a PDF without printing
- `config.pl` — credentials and settings (gitignored)
- `state/` — printed-order dedup list + cached API token (gitignored)
- `logs/` — runtime logs (gitignored)
