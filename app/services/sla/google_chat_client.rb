# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Sla
  # Step 7.1 — the only thing in this plugin that performs outbound HTTP.
  #
  # Kept as its own object (rather than inlined into the job) for the same reason as
  # `Sla::AtRiskNotifier`: it is the single seam every test injects a fake through, so no test ever
  # touches the network. It is also the only place timeouts are configured, so a slow or hanging
  # webhook can never pin a job thread indefinitely.
  class GoogleChatClient
    # Deliberately short. This runs on a background thread of the in-process :async queue adapter;
    # a webhook that is not answering should free the thread quickly rather than hold it for the
    # library default (60s), since a burst of issue creations would otherwise queue up behind it.
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10

    class DeliveryError < StandardError; end

    # POST +payload+ as JSON to +url+. Returns nothing on success and raises DeliveryError on any
    # non-2xx response, so the job's rescue produces exactly one log line whether the failure was a
    # connection error (raised by Net::HTTP) or an HTTP-level rejection (raised here).
    def post(url, payload)
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json; charset=UTF-8'
      request.body = payload.to_json

      response = Net::HTTP.start(uri.host, uri.port,
                                 use_ssl: uri.scheme == 'https',
                                 open_timeout: OPEN_TIMEOUT,
                                 read_timeout: READ_TIMEOUT) { |http| http.request(request) }

      return if response.is_a?(Net::HTTPSuccess)

      # The body carries Google's own error detail (bad webhook key, deleted space, quota) and is
      # what makes a failed delivery diagnosable from the log alone; truncated so a stray HTML
      # error page can't flood it.
      raise DeliveryError, "HTTP #{response.code}: #{response.body.to_s[0, 200]}"
    end
  end
end
