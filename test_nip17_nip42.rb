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
end

NostrRelayAuthTest.instance_methods(false).grep(/^test_/).each do |test|
  NostrRelayAuthTest.new.public_send(test)
end
puts 'NIP-17/NIP-42 tests passed'
