require 'pty'
require 'uri'
require 'net/http'
require 'fileutils'
require 'time'
require 'dg/version'

module DG
  class Docker
    SUDO = !!ENV['USE_SUDO']
    BASEPATH = Dir.pwd

    FIG_YML_PATH = "#{BASEPATH}/fig.yml"
    FIG_GEN_PATH = "#{BASEPATH}/fig_gen.yml"
    CACHE_FILES = %w(
      bower.json
      Gemfile
      Gemfile.lock
      package.json
    )

    class << self

      def build
        reset_mtimes
        build_docker_image_with_tag
      end

      def debug
        generate_fig_yaml
        debug_app
      end

      def purge
        run_with_output("docker rm $(docker ps -a -q) && docker rmi $(docker images -q)")
      end

      def push
        run_with_output("docker push #{git_image_name}")
        run_with_output("docker push #{latest_image_name}")
      end

      def deploy_check
        required_envs = %w(GO_HOST GO_USER GO_PWD)
        unless required_envs.reduce{ |acc, e| acc && ENV[e] }
          error!(
            RuntimeError.new("Environment variables {#{required_envs.join(', ')}} must be set"),
            'checking if pipeline exists'
          )
        end

        puts "Checking existance of pipeline docker-#{project_name}-{#{deploy_stages.join('|')}}"

        deploy_stages.each do |deploy_stage|
          pipeline_check(project_name, deploy_stage)
        end
      end

      def deploy
        required_envs = %w(GO_HOST GO_USER GO_PWD)
        unless required_envs.reduce{ |acc, e| acc && ENV[e] }
          error!(
            RuntimeError.new("Environment variables {#{required_envs.join(', ')}} must be set"),
            'triggering pipeline'
          )
        end

        puts "Triggering deploys for: #{deploy_stages.inspect}"

        deploy_stages.each do |deploy_stage|
          schedule_pipeline(project_name, deploy_stage, git_image_name)
        end
      end

      def deploy_stages
        @@deploy_stages_cached ||=
          begin
            generate_fig_yaml
            branch = ENV['GIT_BRANCH'] ||
              `git symbolic-ref --short -q HEAD`.strip

            run_with_output(
              %(docker run --entrypoint=ruby -e GIT_BRANCH=#{branch} #{git_image_name} /u/app/deploy-to.rb), capture = true
            ).strip.split(',')
          end
      end

      def run
        generate_fig_yaml
        run_app
      end

      def test
        generate_fig_yaml
        run_tests
      end

      def version
        puts "v#{DG::VERSION}"
      end
      alias_method :v, :version

    private

      def fig_binary
        @@fig_binary_cached ||= %w(docker-compose fig).detect do |binary|
          run_with_output(%(which #{binary}), false, return_hash = true)[:status_code] == 0
        end
      end

      def error!(e, step = "executing")
        STDERR.puts "An error occurred while #{step}: #{e.message}"
        exit 1
      end

      def run_with_output(command, capture = false, return_hash = false)
        sudo_command = SUDO ? "sudo -E bash -c '#{command}'" : command
        puts "Running `#{sudo_command}` #{return_hash ? '(quietly)' : ''} in #{Dir.pwd}"

        begin
          buffer = ''
          PTY.spawn(sudo_command) do |stdout, stdin, pid|
            callback = (capture || return_hash) ?
              ->(char) {
                print char unless return_hash
                buffer << char
              } :
              ->(char) { print char }
            stdout.each_char(&callback) rescue Errno::EIO
            Process.wait(pid)
          end
          status_code = $?.exitstatus

          error!(
            RuntimeError.new("exit code was #{status_code}"),
            "executing #{command}"
          ) if !return_hash && status_code != 0

          return { stdout: buffer, status_code: status_code } if return_hash
          return capture ? buffer : status_code
        rescue PTY::ChildExited
          puts "The child process exited!"
        end
      end

      def fig_yml
        @@fig_yml ||= File.read(FIG_YML_PATH)
      rescue => e
        error!(e, "reading fig.yml from #{FIG_YML_PATH}")
      end

      def project_name
        @@project_name ||= ENV['GO_PIPELINE_NAME'] || image_name.split('/').last
      end

      # Infer the project name from the image specified in the fig.yml
      def image_name
        @@image_name ||= fig_yml.match(/\s+image: (.*)/)[1]
      end

      # Add the git commit hash to the image name
      def git_image_name
        @@git_image_name ||=
          "#{image_name}:#{ENV['GIT_COMMIT'] ||
          `git rev-parse HEAD`.strip}"
      end

      def latest_image_name
        "#{image_name}:latest"
      end

      def generate_fig_yaml
        File.write(
          FIG_GEN_PATH,
          fig_yml.sub(image_name, git_image_name)
        )
      rescue => e
        error!(e, "generating new fig.yml")
      end

      def reset_mtimes
        CACHE_FILES.each do |file|
          next unless File.exist?(file)
          revision = run_with_output(
            %(git rev-list -n 1 HEAD '#{file}'),
            capture = true,
            return_hash = true
          )
          if revision[:status_code] == 0
            # File exists, find out its last modified time from git
            # FileUtils.touch('example.txt', mtime: Time.now)
            time = Time.parse(
              run_with_output(
                %(git show --pretty=format:%ai --abbrev-commit #{
                revision[:stdout].strip} | head -n 1),
                capture = true,
                return_hash = true
              )[:stdout].strip
            )
            FileUtils.touch(file, mtime: time)
            puts "Setting mtime for #{file} to #{time}"
          end
        end
      end

      def build_docker_image_with_tag
        run_with_output("docker build -t #{git_image_name} #{BASEPATH}")
        run_with_output("docker tag #{git_image_name} #{latest_image_name}")
      rescue => e
        error!(e, "building docker image")
      end

      def run_tests
        run_with_output("#{fig_binary} -f #{FIG_GEN_PATH} run --rm test")
      rescue => e
        error!(e, "running tests")
      end

      def run_app
        run_with_output("#{fig_binary} -f #{FIG_GEN_PATH} up -d web")
      end

      def debug_app
        puts "docker run -it --entrypoint=/bin/bash #{git_image_name}"
      end

      def pipeline_check(project_name, deploy_stage)
        pipeline_name = "docker-#{project_name}-#{deploy_stage}"
        uri = URI("https://#{ENV['GO_HOST']}/go/api/pipelines/#{pipeline_name}/status")
        request = Net::HTTP::Get.new(uri.path)
        request.basic_auth ENV['GO_USER'], ENV['GO_PWD']

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          http.ssl_version = :SSLv3
          http.request(request)
        end

        if response.code.to_i == 200
          puts "Pipeline [#{pipeline_name}] exists"
        else
          error!(
            RuntimeError.new(
              "response code was #{response.code}: #{response.body.strip}"
            ),
            "checking pipeline status for [#{pipeline_name}]"
          )
        end
      end

      def schedule_pipeline(project_name, deploy_stage, image_id)
        pipeline_name = "docker-#{project_name}-#{deploy_stage}"
        puts "Triggering pipeline: #{pipeline_name} on #{ENV['GO_HOST']}"
        uri = URI("https://#{ENV['GO_HOST']}/go/api/pipelines/#{pipeline_name}/schedule")
        request = Net::HTTP::Post.new(uri.path)
        request.basic_auth ENV['GO_USER'], ENV['GO_PWD']
        request.set_form_data({ 'variables[IMAGE_ID]' => git_image_name })

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          http.ssl_version = :SSLv3
          http.request(request)
        end

        if response.code.to_i == 202
          puts response.body.strip
        else
          error!(
            RuntimeError.new(
              "response code was #{response.code}: #{response.body.strip}"
            ),
            "scheduling pipeline"
          )
        end
      end

      def help
        puts "Usage: dg COMMAND

        A helper for building, testing, and running docker images via docker & fig.

        Commands:
            build     Build an image based on your fig.yml (tags with the project's Git commit hash)
            debug     Debug a previously built image (!) THIS MUST BE RUN IN A SUBSHELL: `$(dg debug)`
            deploy    Trigger the GoCD pipeline for this project
            help      Display this help text
            purge     Remove ALL docker containers and images (not just for this project!)
            push      Push the image to your docker registry
            run       Run the image using your fig.yml's `web` config
            test      Run the image using your fig.yml's `test` config
            version   Display the current dg version
        ".gsub(/^ {6}/,'')
      end
      alias_method :h, :help
    end

  end
end
