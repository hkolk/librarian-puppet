require 'uri'
require 'net/https'
require 'open-uri'
require 'json'

require 'librarian/puppet/version'

module Librarian
  module Puppet
    module Source
      class GitHubTarball
        class Repo
          include Librarian::Puppet::Util

          TOKEN_KEY = 'GITHUB_API_TOKEN'

          attr_accessor :source, :name
          private :source=, :name=

          def initialize(source, name)
            self.source = source
            self.name = name
          end

          def versions
            return @versions if @versions
            data = api_call("/repos/#{source.uri}/tags")
            if data.nil?
              raise Error, "Unable to find module '#{source.uri}' on https://github.com"
            end

            all_versions = data.map { |r| r['name'].gsub(/^v/, '') }.sort.reverse

            all_versions.delete_if do |version|
              version !~ /\A\d\.\d(\.\d.*)?\z/
            end

            @versions = all_versions.compact
            debug { "  Module #{name} found versions: #{@versions.join(", ")}" }
            @versions
          end

          def manifests
            versions.map do |version|
              Manifest.new(source, name, version)
            end
          end

          def install_version!(version, install_path)
            if environment.local? && !vendored?(source.uri.to_s, version)
              raise Error, "Could not find a local copy of #{source.uri} at #{version}."
            end

            vendor_cache(source.uri.to_s, version) unless vendored?(source.uri.to_s, version)

            cache_version_unpacked! version

            if install_path.exist?
              install_path.rmtree
            end

            unpacked_path = version_unpacked_cache_path(version).children.first
            cp_r(unpacked_path, install_path)
          end

          def environment
            source.environment
          end

          def cache_path
            @cache_path ||= source.cache_path.join(name)
          end

          def version_unpacked_cache_path(version)
            cache_path.join('version').join(hexdigest(version.to_s))
          end

          def hexdigest(value)
            Digest::MD5.hexdigest(value)
          end

          def cache_version_unpacked!(version)
            path = version_unpacked_cache_path(version)
            return if path.directory?

            path.mkpath

            target = vendored?(source.uri.to_s, version) ? vendored_path(source.uri.to_s, version) : name

            Librarian::Posix.run!(%W{tar xzf #{target} -C #{path}})
          end

          def vendored?(name, version)
            vendored_path(name, version).exist?
          end

          def vendored_path(name, version)
            environment.vendor_cache.mkpath
            environment.vendor_cache.join("#{name.sub("/", "-")}-#{version}.tar.gz")
          end

          def vendor_cache(name, version)
            clean_up_old_cached_versions(name)

            url = "https://api.github.com/repos/#{name}/tarball/#{version}"
            url << "?access_token=#{ENV['GITHUB_API_TOKEN']}" if ENV['GITHUB_API_TOKEN']

            File.open(vendored_path(name, version).to_s, 'wb') do |f|
              begin
                debug { "Downloading <#{url}> to <#{f.path}>" }
                open(url,
                  "User-Agent" => "librarian-puppet v#{Librarian::Puppet::VERSION}") do |res|
                  while buffer = res.read(8192)
                    f.write(buffer)
                  end
                end
              rescue OpenURI::HTTPError => e
                raise e, "Error requesting <#{url}>: #{e.to_s}"
              end
            end
          end

          def clean_up_old_cached_versions(name)
            Dir["#{environment.vendor_cache}/#{name.sub('/', '-')}*.tar.gz"].each do |old_version|
              FileUtils.rm old_version
            end
          end

        private

          def api_call(path)
            tags = []
            url = "https://api.github.com#{path}?page=1&per_page=100"
            while true do
              debug { "  Module #{name} getting tags at: #{url}" }
              url << "&access_token=#{ENV[TOKEN_KEY]}" if ENV[TOKEN_KEY]
              response = http_get(url, :headers => {
                "User-Agent" => "librarian-puppet v#{Librarian::Puppet::VERSION}"
              })

              code, data = response.code.to_i, response.body

              if code == 200
                tags.concat JSON.parse(data)
              else
                begin
                  message = JSON.parse(data)['message']
                  if code == 403 && message && message.include?('API rate limit exceeded')
                    raise Error, message + " -- increase limit by authenticating via #{TOKEN_KEY}=your-token"
                  elsif message
                    raise Error, "Error fetching #{url}: [#{code}] #{message}"
                  end
                rescue JSON::ParserError
                  # response does not return json
                end
                raise Error, "Error fetching #{url}: [#{code}] #{response.body}"
              end

              # next page
              break if response["link"].nil?
              next_link = response["link"].split(",").select{|l| l.match /rel=.*next.*/}
              break if next_link.empty?
              url = next_link.first.match(/<(.*)>/)[1]
            end
            return tags
          end

          def http_get(url, options)
            uri = URI.parse(url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true
            request = Net::HTTP::Get.new(uri.request_uri)
            options[:headers].each { |k, v| request.add_field k, v }
            http.request(request)
          end
        end
      end
    end
  end
end
