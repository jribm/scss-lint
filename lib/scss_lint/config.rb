require 'yaml'

module SCSSLint
  # Loads and manages application configuration.
  class Config
    FILE_NAME = '.scss-lint.yml'
    DEFAULT_FILE = File.join(SCSS_LINT_HOME, 'config', 'default.yml')

    attr_reader :options, :warnings

    class << self
      def default
        load(DEFAULT_FILE, merge_with_default: false)
      end

      # Loads a configuration from a file, merging it with the default
      # configuration.
      def load(file, options = {})
        config_options = load_options_hash_from_file(file)

        config = new(config_options)

        # Need to call this before merging with the default configuration so
        # that plugins can override the default configuration while still being
        # overridden by the repo's configuration.
        config.load_plugins

        if options.fetch(:merge_with_default, true)
          config = default.extend(config)
        end

        config
      end

      # Returns the location of the user-wide scss-lint configuration.
      #
      # This needs to be a method instead of a constant so that we can change
      # the user's home directory in tests.
      def user_file
        File.join(Dir.home, FILE_NAME)
      end

      def linter_name(linter)
        linter = linter.is_a?(Class) ? linter : linter.class
        linter.name.split('::')[2..-1].join('::')
      end

    private

      def default_options_hash
        @default_options_hash ||= load_options_hash_from_file(DEFAULT_FILE)
      end

      # Recursively load config files, fetching files specified by `include`
      # directives and merging the file's config with the files specified.
      def load_options_hash_from_file(file)
        file_contents = load_file_contents(file)

        begin
          options =
            if yaml = YAML.load(file_contents)
              yaml.to_hash
            else
              {}
            end
        rescue => ex
          raise SCSSLint::Exceptions::InvalidConfiguration,
                "Invalid configuration: #{ex.message}"
        end

        options = convert_single_options_to_arrays(options)
        options = merge_wildcard_linter_options(options)
        options = ensure_exclude_paths_are_absolute(options, file)
        options = ensure_linter_exclude_paths_are_absolute(options, file)
        options
      end

      # Convert any config options that accept a single value or an array to an
      # array form so that merging works.
      def convert_single_options_to_arrays(options)
        options = options.dup

        if options['exclude']
          # Ensure exclude is an array, since we allow user to specify a single
          # string.
          options['exclude'] = [options['exclude']].flatten
        end

        options
      end

      # Merge options from wildcard linters into individual linter configs
      def merge_wildcard_linter_options(options)
        options = options.dup

        options.fetch('linters', {}).keys.each do |class_name|
          next unless class_name.include?('*')

          wildcard_options = options['linters'].delete(class_name)
          apply_options_to_matching_linters(class_name, options, wildcard_options)
        end

        options
      end

      def apply_options_to_matching_linters(class_name_glob, current_options, linter_options)
        linter_names_matching_glob(class_name_glob).each do |linter_name|
          old_options = current_options['linters'].fetch(linter_name, {})
          current_options['linters'][linter_name] = smart_merge(old_options, linter_options)
        end
      end

      def linter_names_matching_glob(class_name_glob)
        class_name_regex = /#{class_name_glob.gsub('*', '[^:]+')}/

        LinterRegistry.linters.map { |linter_class| linter_name(linter_class) }
                      .select { |linter_name| linter_name.match(class_name_regex) }
      end

      def ensure_linter_exclude_paths_are_absolute(options, original_file)
        options = options.dup

        options['linters'] ||= {}

        options['linters'].keys.each do |linter_name|
          options['linters'][linter_name] =
            ensure_exclude_paths_are_absolute(options['linters'][linter_name], original_file)
        end

        options
      end

      # Ensure all excludes are absolute paths
      def ensure_exclude_paths_are_absolute(options, original_file)
        options = options.dup

        if options['exclude']
          excludes = [options['exclude']].flatten

          options['exclude'] = excludes.map do |exclusion_glob|
            if exclusion_glob.start_with?('/')
              exclusion_glob
            else
              # Expand the path assuming it is relative to the config file itself
              File.expand_path(exclusion_glob, File.expand_path(File.dirname(original_file)))
            end
          end
        end

        options
      end

      def path_relative_to_config(relative_include_path, base_config_path)
        if relative_include_path.start_with?('/')
          relative_include_path
        else
          path = File.join(File.dirname(base_config_path), relative_include_path)
          # Remove double backslashes appearing in Windows paths.
          path.gsub(%r{^//}, File::SEPARATOR)
        end
      end

      # For easy stubbing in tests
      def load_file_contents(file)
        File.open(file, 'r').read
      end

      # Merge two hashes, concatenating lists and further merging nested hashes.
      def smart_merge(parent, child)
        parent.merge(child) do |_key, old, new|
          case old
          when Hash
            smart_merge(old, new)
          else
            new
          end
        end
      end
    end

    def initialize(options)
      @options = options
      @warnings = []

      validate_linters
    end

    def [](key)
      @options[key]
    end

    # Compares this configuration with another.
    #
    # @param other [SCSSLint::Config]
    # @return [true,false]
    def ==(other)
      super || @options == other.options
    end
    alias_method :eql?, :==

    # Extend this {Config} with another configuration.
    #
    # @return [SCSSLint::Config]
    def extend(config)
      @options = self.class.send(:smart_merge, @options, config.options)
      @warnings += config.warnings
      self
    end

    def load_plugins
      load_plugins_and_merge_config.tap { ensure_plugins_have_default_options }
    end

    def enabled_linters
      LinterRegistry.extract_linters_from(@options['linters'].keys).select do |linter|
        linter_options(linter)['enabled']
      end
    end

    def linter_enabled?(linter)
      linter_options(linter)['enabled']
    end

    def enable_linter(linter)
      linter_options(linter)['enabled'] = true
    end

    def disable_linter(linter)
      linter_options(linter)['enabled'] = false
    end

    def disable_all_linters
      @options['linters'].values.each do |linter_config|
        linter_config['enabled'] = false
      end
    end

    def linter_options(linter)
      @options['linters'][self.class.linter_name(linter)]
    end

    def excluded_file?(file_path)
      abs_path = File.expand_path(file_path)

      @options.fetch('exclude', []).any? do |exclusion_glob|
        File.fnmatch(exclusion_glob, abs_path)
      end
    end

    def exclude_patterns
      @options.fetch('exclude', [])
    end

    def excluded_file_for_linter?(file_path, linter)
      abs_path = File.expand_path(file_path)

      linter_options(linter).fetch('exclude', []).any? do |exclusion_glob|
        File.fnmatch(exclusion_glob, abs_path)
      end
    end

    def exclude_file(file_path)
      abs_path = File.expand_path(file_path)

      @options['exclude'] ||= []
      @options['exclude'] << abs_path
    end

    # @return Array
    def scss_files
      if path = @options['scss_files']
        Dir[path]
      else
        []
      end
    end

  private

    def validate_linters
      return unless linters = @options['linters']

      linters.keys.each do |name|
        begin
          Linter.const_get(name)
        rescue NameError
          @warnings << "Linter #{name} does not exist; ignoring"
        end
      end
    end

    def load_plugins_and_merge_config
      SCSSLint::Plugins.new(self).load.each do |plugin|
        # Have the plugin options be overrideable by the local configuration
        @options = self.class.send(:smart_merge, plugin.config.options, @options)
      end
    end

    def ensure_plugins_have_default_options
      LinterRegistry.linters.each do |linter|
        if linter_options(linter).nil?
          @options['linters'].merge!(default_plugin_options(linter))
        end
      end
    end

    def default_plugin_options(linter)
      { self.class.linter_name(linter) => { 'enabled' => true } }
    end
  end
end
