# frozen_string_literal: true

require "sinatra/base"
require "openssl"
require "json"
require "securerandom"

require_relative "shared_state"

# The app to listen to incoming webhook events.
class CIOrchestratorApp < Sinatra::Base
  configure do
    set :sessions, expire_after: 28800, same_site: :lax, skip: true
    set :session_store, Rack::Session::Pool
  end

  set(:require_auth) do |enabled|
    return unless enabled

    condition do
      request.session_options[:skip] = false

      if settings.development?
        session[:username] = "localhost"
        return
      end

      state = SharedState.instance

      if session[:github_access_token] && (session[:github_access_token][:expires] - Time.now.to_i) >= 300
        if session[:auth_validated_at] && (Time.now.to_i - session[:auth_validated_at]) < 600
          return if session[:username]

          halt 403, "Forbidden."
        end

        client = Octokit::Client.new(access_token: session[:github_access_token][:token])
        user_info = begin
          client.user
        rescue Octokit::Error => e
          if e.response_status >= 500 || (Time.now.to_i - session[:github_access_token][:issued]) < 30
            halt 500, "Auth failed."
          end

          nil
        end

        unless user_info.nil?
          username = user_info.login
          begin
            org_member = state.github_client.organization_member?(state.config.github_organisation, username)
          rescue Octokit::Error
            halt 500, "Auth failed."
          end

          session[:auth_validated_at] = Time.now.to_i
          if org_member
            session[:username] = username
            return
          end

          session[:username] = nil
          halt 403, "Forbidden"
        end
      end

      client_id = state.config.github_client_id
      auth_state = SecureRandom.hex(32)
      session[:auth_state] = auth_state
      url = "https://github.com/login/oauth/authorize?client_id=#{client_id}&state=#{auth_state}&allow_signup=false"
      redirect url, 302
    end
  end

  get "/auth/github" do
    request.session_options[:skip] = false

    halt 400, "Invalid state." if params["state"] != session[:auth_state]

    state = SharedState.instance
    client = Octokit::Client.new(client_id:     state.config.github_client_id,
                                 client_secret: state.config.github_client_secret)

    begin
      token_response = client.exchange_code_for_token(params["code"])
    rescue Octokit::Error => e
      halt e.response_status, "Auth failed."
    end

    session[:github_access_token] = {
      token:   token_response.access_token,
      issued:  Time.now.to_i,
      expires: Time.now.to_i + token_response.expires_in,
    }

    redirect "/", 302
  end

  get "/", require_auth: true do
    erb :index, locals: { state: SharedState.instance, username: session[:username] }
  end

  get "/robots.txt" do
    content_type :txt
    <<~TEXT
      User-agent: *
      Disallow: /
    TEXT
  end

  post "/hooks/github" do
    payload_body = request.body.read
    verify_webhook_signature(payload_body)
    payload = JSON.parse(payload_body)

    event = request.env["HTTP_X_GITHUB_EVENT"]
    return if %w[ping installation github_app_authorization].include?(event)

    halt 400, "Unsupported event \"#{event}\"!" if event != "workflow_job"

    state = SharedState.instance
    workflow_job = payload["workflow_job"]
    case payload["action"]
    when "queued"
      workflow_job["labels"].each do |label|
        next if label !~ Job::NAME_REGEX

        # If we've seen this job before, don't queue again.
        next if state.expired_jobs.include?(label)

        job = Job.new(label, payload["repository"]["name"])
        state.jobs << job
        state.orka_start_processor.queue << job
      end
    when "in_progress"
      runners_for_job(workflow_job).each do |runner|
        job = state.job(runner)
        if job.nil?
          expire_missed_job(runner)
          next
        end

        job.github_state = :in_progress if job.github_state != :completed
      end
    when "completed"
      runners_for_job(workflow_job).each do |runner|
        job = state.job(runner)
        if job.nil?
          expire_missed_job(runner)
          next
        end

        job.github_state = :completed
        state.orka_stop_processor.queue << job unless job.orka_vm_id.nil?
      end
    end

    "Accepted"
  end

  private

  def verify_webhook_signature(payload_body)
    secret = SharedState.instance.config.github_webhook_secret
    signature = "sha256=#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("sha256"), secret, payload_body)}"
    return if Rack::Utils.secure_compare(signature, request.env["HTTP_X_HUB_SIGNATURE_256"])

    halt 400, "Signatures didn't match!"
  end

  def runners_for_job(workflow_job)
    if workflow_job["runner_name"]
      [workflow_job["runner_name"]]
    else
      workflow_job["labels"].grep(Job::NAME_REGEX)
    end
  end

  def expire_missed_job(runner)
    return if runner !~ Job::NAME_REGEX

    state = SharedState.instance
    return if state.expired_jobs.include?(runner)

    state.expired_jobs << ExpiredJob.new(runner, expired_at: Time.now.to_i)
  end
end
