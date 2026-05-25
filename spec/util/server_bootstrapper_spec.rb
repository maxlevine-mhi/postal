# frozen_string_literal: true

require "rails_helper"

describe ServerBootstrapper do
  let!(:owner) { create(:user, email_address: "ops@example.com") }

  let(:env) do
    {
      "POSTAL_BOOTSTRAP_ORG_NAME" => "Acme Charity",
      "POSTAL_BOOTSTRAP_SERVER_NAME" => "Transactional",
      "POSTAL_BOOTSTRAP_SMTP_CREDENTIAL_NAME" => "Primary SMTP",
      "POSTAL_BOOTSTRAP_SMTP_PASSWORD" => "abcdefghijklmnopqrstuvwx",
      "POSTAL_BOOTSTRAP_OWNER_EMAIL" => "ops@example.com"
    }
  end

  before { stub_const("ENV", ENV.to_hash.merge(env)) }

  describe ".start (happy path)" do
    it "creates an organization, server and SMTP credential in one pass" do
      expect { described_class.start }
        .to change(Organization, :count).by(1)
        .and change(Server, :count).by(1)
        .and change(Credential, :count).by(1)

      org = Organization.find_by(name: "Acme Charity")
      expect(org.owner).to eq(owner)

      server = org.servers.find_by(name: "Transactional")
      expect(server.mode).to eq("Development")

      credential = server.credentials.find_by(name: "Primary SMTP")
      expect(credential.type).to eq("SMTP")
      expect(credential.key).to eq("abcdefghijklmnopqrstuvwx")
    end

    it "honours POSTAL_BOOTSTRAP_SERVER_MODE=Live when set" do
      stub_const("ENV", ENV.to_hash.merge(env).merge("POSTAL_BOOTSTRAP_SERVER_MODE" => "Live"))
      described_class.start
      expect(Server.last.mode).to eq("Live")
    end
  end

  describe ".start (idempotency)" do
    it "is a no-op on a second pass with identical env" do
      described_class.start
      expect {
        described_class.start
      }.not_to change { [Organization.count, Server.count, Credential.count] }
    end

    it "leaves the existing credential key untouched and warns when the password env changes" do
      described_class.start
      original_key = Credential.last.key

      stub_const("ENV", ENV.to_hash.merge(env)
        .merge("POSTAL_BOOTSTRAP_SMTP_PASSWORD" => "zzzzzzzzzzzzzzzzzzzzzzzz"))

      expect {
        expect { described_class.start }
          .to output(/Postal does not permit/).to_stderr
      }.not_to change { Credential.count }

      expect(Credential.last.key).to eq(original_key)
    end

    # The Postal Server model has a non-trivial `mode` invariant; if the
    # existing server is Live and the env asks for Development, we must NOT
    # silently downgrade the live server's mode (that would invalidate
    # delivery routing for in-flight messages). Pin the warn-and-keep
    # behaviour.
    it "warns and preserves existing mode when POSTAL_BOOTSTRAP_SERVER_MODE differs" do
      described_class.start
      original_mode = Server.last.mode

      stub_const("ENV", ENV.to_hash.merge(env).merge("POSTAL_BOOTSTRAP_SERVER_MODE" => "Live"))

      expect { described_class.start }.to output(/ignored/).to_stderr
      expect(Server.last.mode).to eq(original_mode)
    end
  end

  describe ".start (validation)" do
    it "exits non-zero and reports each missing var when env is partial" do
      stub_const("ENV", ENV.to_hash.merge(env).merge(
        "POSTAL_BOOTSTRAP_SMTP_PASSWORD" => "",
        "POSTAL_BOOTSTRAP_OWNER_EMAIL" => ""
      ))

      expect {
        expect { described_class.start }
          .to output(/POSTAL_BOOTSTRAP_SMTP_PASSWORD.*POSTAL_BOOTSTRAP_OWNER_EMAIL/m).to_stderr
      }.to raise_error(SystemExit)
    end

    it "exits non-zero when POSTAL_BOOTSTRAP_OWNER_EMAIL points at a non-existent user" do
      stub_const("ENV", ENV.to_hash.merge(env)
        .merge("POSTAL_BOOTSTRAP_OWNER_EMAIL" => "ghost@example.com"))

      expect {
        expect { described_class.start }
          .to output(/owner user not found.*postal make-user/m).to_stderr
      }.to raise_error(SystemExit)
    end

    it "exits non-zero when POSTAL_BOOTSTRAP_SERVER_MODE is not one of Postal's accepted modes" do
      stub_const("ENV", ENV.to_hash.merge(env)
        .merge("POSTAL_BOOTSTRAP_SERVER_MODE" => "Staging"))

      expect {
        expect { described_class.start }
          .to output(/invalid POSTAL_BOOTSTRAP_SERVER_MODE.*Staging/m).to_stderr
      }.to raise_error(SystemExit)
    end

    # The credential model enforces 24+ chars... actually no, only key
    # presence + uniqueness. But the SMTP-AUTH flow uses the key verbatim,
    # so a value with embedded NULL bytes would corrupt
    # Credential#to_smtp_plain. We don't validate here in the bootstrapper
    # — we surface Postal's own model validation errors via save_or_die!.
    # This spec pins that path.
    it "surfaces Postal's own validation errors when the credential cannot be saved" do
      # Duplicate-key triggers Postal's `uniqueness: { case_sensitive: false }`
      # validation on Credential.
      other_server = create(:server)
      create(:credential, server: other_server, key: "abcdefghijklmnopqrstuvwx", type: "SMTP")

      expect {
        expect { described_class.start }
          .to output(/credential validation failed/m).to_stderr
      }.to raise_error(SystemExit)
    end
  end

  describe ".start (case-insensitive lookup pins)" do
    # The Organization model declares case-insensitive uniqueness on
    # permalink. If a future change loosens that — or switches the DB
    # collation to case-sensitive — the find_by(permalink:) here could
    # spuriously miss an existing org and try to insert a second one. Pin
    # the lookup behaviour with a regression test mirroring the one in
    # user_creator_spec.rb.
    it "matches an existing organization whose name differs only in case" do
      existing = create(:organization, name: "acme charity", owner: owner, permalink: "acme-charity")

      expect { described_class.start }.not_to change(Organization, :count)
      expect(Server.last.organization).to eq(existing)
    end
  end
end
