require 'pty'
require 'uri'
require 'net/http'

class Docker
  MATERIAL_NAME = ENV['MATERIAL_NAME'] || 'BITBUCKET'
  SUDO = !!ENV["GO_REVISION_#{MATERIAL_NAME}"]
  BASEPATH = Dir.pwd
  GIT_COMMIT = ENV['GO_REVISION_BITBUCKET'] || `git rev-parse HEAD`.strip

  FIG_YML_PATH = "#{BASEPATH}/fig.yml"
  FIG_GEN_PATH = "#{BASEPATH}/fig_gen.yml"

  class << self

    def build
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
      run_with_output("docker push #{git_image_name.tr(':',' ')}")
    end

    def deploy
      required_envs = %w(GO_HOST GO_USER GO_PWD)
      unless required_envs.reduce{ |acc, e| acc && ENV[e] }
        error!(
          RuntimeError.new("Environment variables {#{required_envs.join(', ')}} must be set"),
          'triggering pipeline'
        )
      end
      deploy_stages.each do |deploy_stage|
        schedule_pipeline(project_name, deploy_stage, git_image_name)
      end
    end

    def deploy_stages
      candidates = Dir['deploy-to*']
      if candidates.size == 1
        script = candidates.first
        if File.executable?(script)
          branch = ENV['GIT_BRANCH'] ||
            `git symbolic-ref --short -q HEAD`.strip
          return `./#{script} #{branch}`.strip.split(',')
        else
          error!(
            RuntimeError.new(
              %(Deploy-to script: "#{script}" must be executable! (e.g. chmod +x #{script}))
            ),
            "determining stage to deploy to"
          )
        end
      else
        error!(
          RuntimeError.new(
            "There must be a deploy-to* script " +
            "(e.g. deploy-to.{rb|sh|js}): #{candidates.size} found"
          ),
          "determining stage to deploy to"
        )
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
      puts "v#{VERSION}"
    end
    alias_method :v, :version

  private

    def error!(e, step = "executing")
      STDERR.puts "An error occurred while #{step}: #{e.message}"
      exit 1
    end

    def run_with_output(command)
      sudo_command = SUDO ? "sudo -E bash -c '#{command}'" : command
      puts "Running `#{sudo_command}` in #{Dir.pwd}"
      PTY.spawn(sudo_command) do |stdin, stdout, pid|
        stdin.each { |line| print line } rescue Errno::EIO
        Process.wait(pid)
      end
      status_code = $?.exitstatus

      error!(RuntimeError.new("exit code was #{status_code}"), "executing #{command}") if status_code != 0
    rescue PTY::ChildExited
      puts "The child process exited!"
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
      @@git_image_name ||= "#{image_name}:#{GIT_COMMIT}"
    end

    def generate_fig_yaml
      File.write(
        FIG_GEN_PATH,
        fig_yml.sub(image_name, git_image_name)
      )
    rescue => e
      error!(e, "generating new fig.yml")
    end

    def build_docker_image_with_tag
      run_with_output("docker build -t #{git_image_name} #{BASEPATH}")
    rescue => e
      error!(e, "building docker image")
    end

    def run_tests
      run_with_output("fig -f #{FIG_GEN_PATH} run test")
    rescue => e
      error!(e, "running tests")
    end

    def run_app
      run_with_output("fig -f #{FIG_GEN_PATH} up -d web")
    end

    def debug_app
      puts "docker run -it --entrypoint=/bin/bash #{git_image_name}"
    end

    def schedule_pipeline(project_name, deploy_stage, image_id)
      pipeline_name = "docker-#{project_name}-#{deploy_stage}"

      uri = URI("https://#{ENV['GO_HOST']}/go/api/pipelines/#{pipeline_name}/schedule")
      request = Net::HTTP::Post.new(uri.path)
      request.basic_auth ENV['GO_USER'], ENV['GO_PWD']
      request.set_form_data({ 'variables[IMAGE_ID]' => git_image_name.gsub('/','\/') })

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
          debug     Debug a previously built image (!) THIS MUST BE RUN IN A SUBSHELL: `$(dim debug)`
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

