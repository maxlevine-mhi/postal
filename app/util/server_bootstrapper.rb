# frozen_string_literal: true

# Idempotent provisioning of an Organization + Mail Server + SMTP Credential
# from environment variables. Intended for first-boot bootstrap inside Docker
# Compose, after `postal initialize` + `postal make-user` (non-interactive
# mode). Unlike `postal make-user`, this command is env-only — there is no
# interactive prompt fallback because the workflow this enables is automation
# (compose-up, CI, fresh-machine quickstart), not first-time hand-installs.
#
# Required env (all must be set):
#   - POSTAL_BOOTSTRAP_ORG_NAME             -> Organization name
#   - POSTAL_BOOTSTRAP_SERVER_NAME          -> Server name (per-org)
#   - POSTAL_BOOTSTRAP_SMTP_CREDENTIAL_NAME -> Credential display name
#   - POSTAL_BOOTSTRAP_SMTP_PASSWORD        -> SMTP credential `key`
#                                              (24+ chars; alphanumeric
#                                              matches Postal's own
#                                              SecureRandom.alphanumeric(24)
#                                              auto-generation format)
#   - POSTAL_BOOTSTRAP_OWNER_EMAIL          -> existing User email; this
#                                              user becomes the Org owner
#
# Optional env:
#   - POSTAL_BOOTSTRAP_SERVER_MODE          -> "Development" (default) or
#                                              "Live". Pilot/prod should
#                                              flip to "Live" once DNS +
#                                              MX records are configured;
#                                              the default keeps local
#                                              compose stacks from
#                                              attempting external
#                                              delivery.
#
# Idempotency:
#   - Organization: find_by(permalink:) before insert. Permalink derives
#     from the name via Organization.find_unique_permalink.
#   - Server: find_by(organization_id:, permalink:). Permalink mirrors
#     org-level derivation logic.
#   - Credential: find_by(server_id:, type: "SMTP", name:). The
#     Postal model declares `key cannot be changed` after first save
#     (see Credential#validate_key_cannot_be_changed), so a re-run with a
#     different POSTAL_BOOTSTRAP_SMTP_PASSWORD logs a warn and leaves the
#     existing key intact. Rotate via the admin UI or Rails console.
module ServerBootstrapper

  ENV_PREFIX = "POSTAL_BOOTSTRAP_"
  REQUIRED_ENV_VARS = %w[ORG_NAME SERVER_NAME SMTP_CREDENTIAL_NAME SMTP_PASSWORD OWNER_EMAIL]
                      .map { |s| "#{ENV_PREFIX}#{s}" }.freeze
  DEFAULT_SERVER_MODE = "Development"
  VALID_SERVER_MODES = Server::MODES

  class << self

    def start
      puts "\e[32mPostal Server Bootstrapper\e[0m"

      missing = REQUIRED_ENV_VARS.reject { |k| ENV[k].to_s.strip != "" }
      unless missing.empty?
        warn "\e[31mFailed to bootstrap\e[0m"
        warn " * missing required environment variables: #{missing.join(', ')}"
        exit 1
      end

      owner_email = ENV.fetch("#{ENV_PREFIX}OWNER_EMAIL")
      owner = User.find_by(email_address: owner_email)
      if owner.nil?
        warn "\e[31mFailed to bootstrap\e[0m"
        warn " * owner user not found: #{owner_email}"
        warn "   Run `postal make-user` (or set POSTAL_INITIAL_USER_*) before bootstrap-server."
        exit 1
      end

      server_mode = (ENV["#{ENV_PREFIX}SERVER_MODE"].to_s.strip.presence || DEFAULT_SERVER_MODE)
      unless VALID_SERVER_MODES.include?(server_mode)
        warn "\e[31mFailed to bootstrap\e[0m"
        warn " * invalid POSTAL_BOOTSTRAP_SERVER_MODE: #{server_mode.inspect} " \
             "(must be one of #{VALID_SERVER_MODES.join(', ')})"
        exit 1
      end

      org_name = ENV.fetch("#{ENV_PREFIX}ORG_NAME")
      org = upsert_organization(name: org_name, owner: owner)

      server_name = ENV.fetch("#{ENV_PREFIX}SERVER_NAME")
      server = upsert_server(organization: org, name: server_name, mode: server_mode)

      credential_name = ENV.fetch("#{ENV_PREFIX}SMTP_CREDENTIAL_NAME")
      smtp_password = ENV.fetch("#{ENV_PREFIX}SMTP_PASSWORD")
      upsert_smtp_credential(server: server, name: credential_name, key: smtp_password)

      puts "\e[32mPostal bootstrap complete\e[0m"
    end

    private

    def upsert_organization(name:, owner:)
      permalink = Organization.find_unique_permalink(name) || name.parameterize
      existing = Organization.find_by(permalink: permalink) ||
                 Organization.where("LOWER(name) = ?", name.downcase).first
      if existing
        puts " * organization \e[34m#{existing.name}\e[0m (permalink=#{existing.permalink}) already exists"
        return existing
      end

      org = Organization.new(name: name, owner: owner)
      save_or_die!(org, label: "organization")
      puts " * organization \e[32m#{org.name}\e[0m (permalink=#{org.permalink}) created"
      org
    end

    def upsert_server(organization:, name:, mode:)
      existing = organization.servers.find_by(name: name) ||
                 organization.servers.find_by(permalink: name.parameterize)
      if existing
        puts " * server \e[34m#{existing.name}\e[0m (permalink=#{existing.permalink}) already exists"
        if existing.mode != mode
          warn "   note: existing server mode is #{existing.mode.inspect}, " \
               "POSTAL_BOOTSTRAP_SERVER_MODE=#{mode.inspect} ignored " \
               "(change via the admin UI to avoid losing message history)"
        end
        return existing
      end

      server = organization.servers.new(name: name, mode: mode)
      save_or_die!(server, label: "server")
      puts " * server \e[32m#{server.name}\e[0m (permalink=#{server.permalink}, mode=#{server.mode}) created"
      server
    end

    def upsert_smtp_credential(server:, name:, key:)
      existing = server.credentials.find_by(type: "SMTP", name: name)
      if existing
        if existing.key != key
          warn " * credential \e[34m#{existing.name}\e[0m already exists with a different key"
          warn "   POSTAL_BOOTSTRAP_SMTP_PASSWORD ignored — Postal does not permit"
          warn "   updating an existing credential's key. Rotate via the admin UI"
          warn "   (delete + recreate) if you need a new password."
        else
          puts " * credential \e[34m#{existing.name}\e[0m already exists (key unchanged)"
        end
        return existing
      end

      credential = server.credentials.new(type: "SMTP", name: name, key: key)
      # Credential's `before_validation :generate_key` callback overwrites
      # `self.key` with a fresh `SecureRandom.alphanumeric(24)` on every new
      # (un-persisted) record, ignoring the value we passed in. Suppress it
      # on just this record so the env-supplied key is what gets persisted.
      # We do this with a singleton-method override rather than skipping
      # callbacks globally so the rest of the model (validations etc.)
      # still runs normally.
      credential.define_singleton_method(:generate_key) { nil }
      save_or_die!(credential, label: "credential")
      puts " * credential \e[32m#{credential.name}\e[0m created (type=SMTP)"
      credential
    end

    def save_or_die!(record, label:)
      return if record.save

      warn "\e[31mFailed to bootstrap\e[0m"
      warn " * #{label} validation failed:"
      record.errors.full_messages.each { |msg| warn "   - #{msg}" }
      exit 1
    end

  end

end
