# Ruby Nostr Relay

A lightweight, high-performance Nostr relay implementation for Ruby 3.0+.

## NIP Support

This relay supports the following Nostr Implementation Possibilities (NIPs):

- **NIP-01**: Basic protocol flow
- **NIP-02**: Contact List and Petnames
- **NIP-04**: Encrypted Direct Messages (relay side)
- **NIP-09**: Event deletion (kind 5)
- **NIP-11**: Relay Information Document
- **NIP-12**: Generic tag queries (#e, #p, etc)
- **NIP-15**: Marketplace
- **NIP-16**: Event Treatment (ephemeral events 20000-29999)
- **NIP-20**: Command results (OK messages)
- **NIP-22**: Event created_at limits (timestamp validation)
- **NIP-28**: Public Chat
- **NIP-33**: Parameterized Replaceable Events (kind 30000-39999)
- **NIP-40**: Expiration Timestamp
- **NIP-62**: Request to vanish (complete data removal)
- **NIP-70**: Protected Events (rejects events with "-" tag)

## Usage

```bash
bundle exec ruby main.rb
```

The relay will start on `ws://localhost:8080` by default.

## Installation

```bash
git clone <repository-url>
cd ruby-nostr-relay

bundle install
```

## Requirements

- Ruby 3.0 or higher
- PostgreSQL
- Bundler

## License

MIT License

## Author

Yasuhiro Matsumoto (a.k.a. mattn)
