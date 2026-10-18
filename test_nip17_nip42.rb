require_relative 'main'

class NostrRelayAuthTest
  class VerifiedRelay < NostrRelay
    def verify_event(_event)
      true
    end
  end

  def initialize
    @relay = VerifiedRelay.new
    @client = {challenge: 'challenge-value', authenticated_pubkeys: {}}
    @event = {
      'id' => 'a' * 64,
      'pubkey' => 'b' * 64,
      'created_at' => Time.now.to_i,
      'kind' => 22242,
      'tags' => [
        ['relay', 'wss://relay.example.com/'],
        ['challenge', 'challenge-value']
      ],
      'content' => '',
      'sig' => 'c' * 128
    }
  end

  def assert(value, message = 'assertion failed')
    raise message unless value
  end

  def refute(value, message = 'refutation failed')
    raise message if value
  end

  def test_authenticates_matching_challenge_and_relay
    success, message = @relay.send(:handle_auth, @event, @client, 'wss://relay.example.com')

    assert success, message
    assert @client[:authenticated_pubkeys][@event['pubkey']]
  end

  def test_uses_http2_authority_for_relay_url
    request = Struct.new(:headers, :authority).new({}, 'relay.example.com')

    assert @relay.send(:websocket_relay_url, request) == 'wss://relay.example.com'
  end

  def test_rejects_wrong_challenge
    @event['tags'][1][1] = 'wrong'

    refute @relay.send(:handle_auth, @event, @client, 'wss://relay.example.com').first
  end

  def test_gift_wrap_is_visible_only_to_authenticated_recipient
    gift_wrap = {'kind' => 1059, 'tags' => [['p', @event['pubkey'], 'wss://relay.example.com']]}

    refute @relay.send(:gift_wrap_visible?, gift_wrap, @client)
    @client[:authenticated_pubkeys][@event['pubkey']] = true
    assert @relay.send(:gift_wrap_visible?, gift_wrap, @client)
  end

  def test_empty_filter_lists_match_nothing
    event = {'id' => 'a' * 64, 'pubkey' => 'b' * 64, 'created_at' => 1, 'kind' => 1, 'tags' => [], 'content' => ''}

    assert @relay.send(:match_filters?, event, [{'limit' => 3}])
    [{'ids' => []}, {'authors' => []}, {'kinds' => []}, {'#e' => []}].each do |f|
      assert @relay.send(:unsatisfiable_filter?, f), "#{f} should be unsatisfiable"
      refute @relay.send(:match_filters?, event, [f]), "#{f} should match nothing"
    end
    refute @relay.send(:unsatisfiable_filter?, {'kinds' => [1], 'limit' => 3})
  end

  # NIP-01: filters are ORed, each limit applies to its own filter and an event
  # matching several filters is sent (and counted) once. Needs DATABASE_URL.
  def test_multiple_filters_are_ored
    return unless DB

    ids = %w[1 2 3].map { |c| c * 64 }
    ids.each_with_index do |id, i|
      DB[:event].insert(id: id, pubkey: 'd' * 64, created_at: 100 + i, kind: 1,
                        tags: Sequel.pg_jsonb([]), content: '', sig: 'e' * 128)
    end
    begin
      received = lambda do |filters|
        client = {outbox: [], authenticated_pubkeys: {}}
        @relay.send(:send_events, client, 's', filters)
        client[:outbox].map { |m| JSON.parse(m) }.select { |m| m[0] == 'EVENT' }.map { |m| m[2]['id'] }
      end
      counted = lambda do |filters|
        client = {outbox: [], authenticated_pubkeys: {}}
        @relay.send(:send_count, client, 'c', filters)
        JSON.parse(client[:outbox].first)[2]['count']
      end

      assert received.call([{'ids' => [ids[0]]}, {'ids' => [ids[1]]}]).sort == ids[0, 2].sort, 'filters must be ORed'
      assert received.call([{'ids' => ids}]).sort == ids.sort, 'every id must count'
      assert received.call([{'ids' => ids, 'limit' => 1}, {'ids' => [ids[0]], 'limit' => 5}]).sort == [ids[0], ids[2]].sort,
             'each limit applies to its own filter'
      assert received.call([{'ids' => [ids[0]]}, {'ids' => [ids[0]]}]) == [ids[0]], 'an event is sent once'
      assert counted.call([{'ids' => ids[0, 2]}, {'ids' => ids[1, 2]}]) == 3, 'COUNT counts the union'
    ensure
      DB[:event].where(id: ids).delete
    end
  end

  # NIP-01: #x needs a tag named x with one of the values, and different tag
  # conditions in one filter are ANDed. Needs DATABASE_URL for the stored path.
  def test_tag_filters_check_the_tag_name
    x = 'f' * 64
    e_tagged = {'id' => '4' * 64, 'tags' => [['e', x]]}
    p_tagged = {'id' => '5' * 64, 'tags' => [['p', x]]}
    both = {'id' => '6' * 64, 'tags' => [['e', x], ['t', 'nostr']]}
    events = [e_tagged, p_tagged, both].each_with_index.map do |ev, i|
      ev.merge('pubkey' => 'd' * 64, 'created_at' => 200 + i, 'kind' => 1, 'content' => '', 'sig' => 'e' * 128)
    end

    live = lambda { |f| events.select { |ev| @relay.send(:match_filters?, ev, [f]) }.map { |ev| ev['id'] }.sort }
    assert live.call({'#e' => [x]}) == [e_tagged['id'], both['id']].sort, 'live #e must ignore p tags'
    assert live.call({'#e' => [x], '#t' => ['nostr']}) == [both['id']], 'live tag conditions are ANDed'

    return unless DB

    events.each do |ev|
      DB[:event].insert(id: ev['id'], pubkey: ev['pubkey'], created_at: ev['created_at'], kind: 1,
                        tags: Sequel.pg_jsonb(ev['tags']), content: '', sig: ev['sig'])
    end
    begin
      received = lambda do |filters|
        client = {outbox: [], authenticated_pubkeys: {}}
        @relay.send(:send_events, client, 's', filters)
        client[:outbox].map { |m| JSON.parse(m) }.select { |m| m[0] == 'EVENT' }.map { |m| m[2]['id'] }.sort
      end
      counted = lambda do |filters|
        client = {outbox: [], authenticated_pubkeys: {}}
        @relay.send(:send_count, client, 'c', filters)
        JSON.parse(client[:outbox].first)[2]['count']
      end

      assert received.call([{'#e' => [x]}]) == [e_tagged['id'], both['id']].sort, '#e must not match a p tag'
      assert received.call([{'#p' => [x]}]) == [p_tagged['id']], '#p must not match an e tag'
      assert received.call([{'#e' => [x], '#t' => ['nostr']}]) == [both['id']], 'tag conditions are ANDed'
      assert counted.call([{'#e' => [x]}]) == 2, 'COUNT checks the tag name'
    ensure
      DB[:event].where(id: events.map { |ev| ev['id'] }).delete
    end
  end
end

NostrRelayAuthTest.instance_methods(false).grep(/^test_/).each do |test|
  NostrRelayAuthTest.new.public_send(test)
end
puts 'NIP-17/NIP-42 tests passed'
