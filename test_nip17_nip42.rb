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
end

NostrRelayAuthTest.instance_methods(false).grep(/^test_/).each do |test|
  NostrRelayAuthTest.new.public_send(test)
end
puts 'NIP-17/NIP-42 tests passed'
