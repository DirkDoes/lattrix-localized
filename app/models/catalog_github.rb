require "net/http"
require "openssl"
require "base64"

# GitHub App installation credentials, never the user's login OAuth client secret.
class CatalogGithub
  class Error < StandardError; end
  attr_reader :project
  def self.configured? = GithubAppConfiguration.current.configured?
  def initialize(project)
    @project = project
  end
  def token
    @token ||= begin
      encode = ->(value) { Base64.urlsafe_encode64(value, padding: false) }
      configuration = GithubAppConfiguration.current
      raise Error, 'Configure the shared GitHub App in Administration first' unless configuration.configured?
      payload = [encode.call({alg: "RS256", typ: "JWT"}.to_json), encode.call({iat: Time.now.to_i - 60, exp: Time.now.to_i + 540, iss: configuration.app_id}.to_json)].join(".")
      signature = OpenSSL::PKey::RSA.new(configuration.private_key.gsub('\\n', "\n")).sign("SHA256", payload)
      request(:post, "/app/installations/#{Integer(project.installation_id)}/access_tokens", {}, auth: "#{payload}.#{encode.call(signature)}").fetch("token")
    end
  end
  def request(method, path, data = nil, auth: nil)
    uri = URI("https://api.github.com#{path}")
    req = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
    req["Authorization"] = "Bearer #{auth || token}"
    req["Accept"] = "application/vnd.github+json"
    req["X-GitHub-Api-Version"] = "2022-11-28"
    req["User-Agent"] = "Lattrix-Localized"
    req["Content-Type"] = "application/json"
    req.body = data.to_json if data
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(req) }
    raise Error, "GitHub returned #{response.code}; check the App installation and permissions" unless response.is_a?(Net::HTTPSuccess)
    response.body.present? ? JSON.parse(response.body) : {}
  rescue Timeout::Error, SocketError, IOError => error
    raise Error, "GitHub is temporarily unavailable (#{error.class.name})"
  end
  def repo_path = "/repos/#{project.repository}"
  def escape(value) = ERB::Util.url_encode(value)
  def repository = request(:get, repo_path)
  def incoming(page)
    pulls = request(:get, "#{repo_path}/pulls?state=open&base=#{escape(project.git_branch)}&per_page=10&page=#{page}")
    relevant = pulls.reject { |pull| pull['number'] == project.pull_request_number }.select do |pull|
      file_page = 1
      loop do
        files = request(:get, "#{repo_path}/pulls/#{pull.fetch('number')}/files?per_page=100&page=#{file_page}")
        break true if files.any? { |file| [file['filename'], file['previous_filename']].compact.any? { |path| locale_path?(path) } }
        break false if files.size < 100
        raise Error, "PR ##{pull['number']} exceeds GitHub's changed-file listing limit" if file_page == 30
        file_page += 1
      end
    end
    [relevant, pulls.size == 10]
  end

  def locale_path?(path)
    prefix = "#{project.locale_directory}/"
    path.start_with?(prefix) && path.delete_prefix(prefix).match?(/\A[^\/]+\.ya?ml\z/)
  end
  def snapshot(ref = project.git_branch)
    commit = request(:get, "#{repo_path}/commits/#{escape(ref)}")
    tree = request(:get, "#{repo_path}/git/trees/#{commit.fetch('commit').fetch('tree').fetch('sha')}?recursive=1")
    raise Error, "Repository tree is too large for a complete snapshot" if tree["truncated"]
    prefix = "#{project.locale_directory}/"
    entries = tree.fetch("tree").select { |entry| entry["path"].start_with?(prefix) && entry["path"].delete_prefix(prefix).match?(/\A[^\/]+\.ya?ml\z/) }
    raise Error, "Locale files exceed the project limit of #{project.max_locale_files} files" if entries.size > project.max_locale_files
    raise Error, "Locale files exceed the project limit of #{project.max_locale_total_mb} MB combined" if entries.sum { |entry| entry.fetch("size", 0) } > project.max_locale_total_mb.megabytes
    files = entries.to_h do |entry|
      raise Error, "Locale files must be regular files no larger than #{project.max_locale_file_mb} MB" unless entry["type"] == "blob" && entry["mode"] == "100644" && entry.fetch("size", 0) <= project.max_locale_file_mb.megabytes
      blob = request(:get, "#{repo_path}/git/blobs/#{entry.fetch('sha')}")
      [File.basename(entry.fetch("path"), ".yml"), Base64.decode64(blob.fetch("content"))]
    end
    [commit, files]
  end
  def publish!(commit, contents, existing)
    entries = contents.filter_map do |locale, content|
      next if existing[locale] == content
      {path: "#{project.locale_directory}/#{CatalogYaml.filename(locale)}", mode: "100644", type: "blob", content: content}
    end
    return if entries.empty?
    tree = request(:post, "#{repo_path}/git/trees", {base_tree: commit.fetch("commit").fetch("tree").fetch("sha"), tree: entries})
    new_commit = request(:post, "#{repo_path}/git/commits", {message: "Update translations from Lattrix", tree: tree.fetch("sha"), parents: [commit.fetch("sha")]})
    pr = project.pull_request_number && request(:get, "#{repo_path}/pulls/#{project.pull_request_number}")
    if pr && pr["state"] == "open" && pr.dig("head", "repo", "full_name") == project.repository && pr.dig("head", "ref").start_with?("lattrix/")
      request(:patch, "#{repo_path}/git/refs/heads/#{escape(pr.fetch('head').fetch('ref'))}", {sha: new_commit.fetch("sha"), force: true})
    else
      branch = "lattrix/update-translations_#{SecureRandom.hex(6)}"
      request(:post, "#{repo_path}/git/refs", {ref: "refs/heads/#{branch}", sha: new_commit.fetch("sha")})
      pr = request(:post, "#{repo_path}/pulls", {title: "Update translations", head: branch, base: project.git_branch, body: "Valid pending translations from Lattrix. Conflicted and incomplete drafts are excluded."})
    end
    project.update!(pull_request_number: pr.fetch("number"), last_published_at: Time.current)
  end
end
