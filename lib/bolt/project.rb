# frozen_string_literal: true

require 'pathname'
require 'bolt/config'
require 'bolt/pal'
require 'bolt/module'

module Bolt
  class Project
    BOLTDIR_NAME = 'Boltdir'
    PROJECT_SETTINGS = {
      "name"  => "The name of the project",
      "plans" => "An array of plan names to show, if they exist in the project."\
                 "These plans are included in `bolt plan show` output",
      "tasks" => "An array of task names to show, if they exist in the project."\
                 "These tasks are included in `bolt task show` output"
    }.freeze

    attr_reader :path, :data, :config_file, :inventory_file, :modulepath, :hiera_config,
                :puppetfile, :rerunfile, :type, :resource_types, :logs, :project_file,
                :deprecations, :downloads, :plans_path, :managed_moduledir

    def self.default_project(logs = [])
      create_project(File.expand_path(File.join('~', '.puppetlabs', 'bolt')), 'user', logs)
    # If homedir isn't defined use the system config path
    rescue ArgumentError
      create_project(Bolt::Config.system_path, 'system', logs)
    end

    # Search recursively up the directory hierarchy for the Project. Look for a
    # directory called Boltdir or a file called bolt.yaml (for a control repo
    # type Project). Otherwise, repeat the check on each directory up the
    # hierarchy, falling back to the default if we reach the root.
    def self.find_boltdir(dir, logs = [])
      dir = Pathname.new(dir)

      if (dir + BOLTDIR_NAME).directory?
        create_project(dir + BOLTDIR_NAME, 'embedded', logs)
      elsif (dir + 'bolt.yaml').file? || (dir + 'bolt-project.yaml').file?
        create_project(dir, 'local', logs)
      elsif dir.root?
        default_project(logs)
      else
        logs << { debug: "Did not detect Boltdir, bolt.yaml, or bolt-project.yaml at '#{dir}'. "\
                  "This directory won't be loaded as a project." }
        find_boltdir(dir.parent, logs)
      end
    end

    def self.create_project(path, type = 'option', logs = [])
      fullpath = Pathname.new(path).expand_path

      if type == 'user'
        begin
          # This is already expanded if the type is user
          FileUtils.mkdir_p(path)
        rescue StandardError
          logs << { warn: "Could not create default project at #{path}. Continuing without a writeable project. "\
                    "Log and rerun files will not be written." }
        end
      end

      if type == 'option' && !File.directory?(path)
        raise Bolt::Error.new("Could not find project at #{path}", "bolt/project-error")
      end

      if !Bolt::Util.windows? && type != 'environment' && fullpath.world_writable?
        raise Bolt::Error.new(
          "Project directory '#{fullpath}' is world-writable which poses a security risk. Set "\
          "BOLT_PROJECT='#{fullpath}' to force the use of this project directory.",
          "bolt/world-writable-error"
        )
      end

      project_file = File.join(fullpath, 'bolt-project.yaml')
      data = Bolt::Util.read_optional_yaml_hash(File.expand_path(project_file), 'project')
      default = type =~ /user|system/ ? 'default ' : ''
      exist = File.exist?(File.expand_path(project_file))
      logs << { info: "Loaded #{default}project from '#{fullpath}'" } if exist
      new(data, path, type, logs)
    end

    def initialize(raw_data, path, type = 'option', logs = [])
      @path = Pathname.new(path).expand_path

      @project_file = @path + 'bolt-project.yaml'

      @logs = logs
      @deprecations = []
      if (@path + 'bolt.yaml').file? && project_file?
        msg = "Project-level configuration in bolt.yaml is deprecated if using bolt-project.yaml. "\
          "Transport config should be set in inventory.yaml, all other config should be set in "\
          "bolt-project.yaml."
        @deprecations << { type: 'Using bolt.yaml for project configuration', msg: msg }
      end

      @inventory_file    = @path + 'inventory.yaml'
      @modulepath        = [(@path + 'modules').to_s, (@path + 'site-modules').to_s, (@path + 'site').to_s]
      @hiera_config      = @path + 'hiera.yaml'
      @puppetfile        = @path + 'Puppetfile'
      @rerunfile         = @path + '.rerun.json'
      @resource_types    = @path + '.resource_types'
      @type              = type
      @downloads         = @path + 'downloads'
      @plans_path        = @path + 'plans'
      @managed_moduledir = (@path + '.modules').to_s

      tc = Bolt::Config::INVENTORY_OPTIONS.keys & raw_data.keys
      if tc.any?
        msg = "Transport configuration isn't supported in bolt-project.yaml. Ignoring keys #{tc}"
        @logs << { warn: msg }
      end

      @data = raw_data.reject { |k, _| Bolt::Config::INVENTORY_OPTIONS.include?(k) }

      # Once bolt.yaml deprecation is removed, this attribute should be removed
      # and replaced with .project_file in lib/bolt/config.rb
      @config_file = if (Bolt::Config::BOLT_OPTIONS & @data.keys).any?
                       if (@path + 'bolt.yaml').file?
                         msg = "bolt-project.yaml contains valid config keys, bolt.yaml will be ignored"
                         @logs << { warn: msg }
                       end
                       @project_file
                     else
                       @path + 'bolt.yaml'
                     end
      validate if project_file?
    end

    def to_s
      @path.to_s
    end

    # This API is used to prepend the project as a module to Puppet's internal
    # module_references list. CHANGE AT YOUR OWN RISK
    def to_h
      { path: @path.to_s,
        name: name,
        load_as_module?: load_as_module? }
    end

    def eql?(other)
      path == other.path
    end
    alias == eql?

    def project_file?
      @project_file.file?
    end

    def load_as_module?
      !name.nil?
    end

    def name
      @data['name']
    end

    def tasks
      @data['tasks']
    end

    def plans
      @data['plans']
    end

    def modules
      @data['modules']
    end

    def validate
      if name
        if name !~ Bolt::Module::MODULE_NAME_REGEX
          raise Bolt::ValidationError, <<~ERROR_STRING
          Invalid project name '#{name}' in bolt-project.yaml; project name must begin with a lowercase letter
          and can include lowercase letters, numbers, and underscores.
          ERROR_STRING
        elsif Dir.children(Bolt::PAL::BOLTLIB_PATH).include?(name)
          raise Bolt::ValidationError, "The project '#{name}' will not be loaded. The project name conflicts "\
            "with a built-in Bolt module of the same name."
        end
      else
        message = "No project name is specified in bolt-project.yaml. Project-level content will not be available."
        @logs << { warn: message }
      end

      %w[tasks plans].each do |conf|
        unless @data.fetch(conf, []).is_a?(Array)
          raise Bolt::ValidationError, "'#{conf}' in bolt-project.yaml must be an array"
        end
      end

      if @data['modules']
        unless @data['modules'].is_a?(Array)
          raise Bolt::ValidationError, "'modules' in bolt-project.yaml must be an array"
        end

        @data['modules'].each do |mod|
          next if mod.is_a?(Hash) && mod.key?('name')
          raise Bolt::ValidationError, "Module declaration #{mod.inspect} must be a hash with a name key"
        end

        unknown_keys = data['modules'].flat_map(&:keys).uniq - %w[name version_requirement]
        if unknown_keys.any?
          @logs << { warn: "Ignoring unknown keys in module declarations: #{unknown_keys.join(', ')}." }
        end
      end
    end

    def check_deprecated_file
      if (@path + 'project.yaml').file?
        msg = "Project configuration file 'project.yaml' is deprecated; use 'bolt-project.yaml' instead."
        Bolt::Logger.deprecation_warning('Using project.yaml instead of bolt-project.yaml', msg)
      end
    end
  end
end
