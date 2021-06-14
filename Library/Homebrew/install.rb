# typed: true
# frozen_string_literal: true

require "diagnostic"
require "fileutils"
require "hardware"
require "development_tools"

module Homebrew
  # Helper module for performing (pre-)install checks.
  #
  # @api private
  module Install
    module_function

    def perform_preinstall_checks(all_fatal: false, cc: nil)
      check_prefix
      check_cpu
      attempt_directory_creation
      check_cc_argv(cc)
      Diagnostic.checks(:supported_configuration_checks, fatal: all_fatal)
      Diagnostic.checks(:fatal_preinstall_checks)
    end
    alias generic_perform_preinstall_checks perform_preinstall_checks
    module_function :generic_perform_preinstall_checks

    def perform_build_from_source_checks(all_fatal: false)
      Diagnostic.checks(:fatal_build_from_source_checks)
      Diagnostic.checks(:build_from_source_checks, fatal: all_fatal)
    end

    def check_prefix
      if (Hardware::CPU.intel? || Hardware::CPU.in_rosetta2?) &&
         HOMEBREW_PREFIX.to_s == HOMEBREW_MACOS_ARM_DEFAULT_PREFIX
        if Hardware::CPU.in_rosetta2?
          odie <<~EOS
            Cannot install under Rosetta 2 in ARM default prefix (#{HOMEBREW_PREFIX})!
            To rerun under ARM use:
                arch -arm64 brew install ...
            To install under x86_64, install Homebrew into #{HOMEBREW_DEFAULT_PREFIX}.
          EOS
        else
          odie "Cannot install on Intel processor in ARM default prefix (#{HOMEBREW_PREFIX})!"
        end
      elsif Hardware::CPU.arm? && HOMEBREW_PREFIX.to_s == HOMEBREW_DEFAULT_PREFIX
        odie <<~EOS
          Cannot install in Homebrew on ARM processor in Intel default prefix (#{HOMEBREW_PREFIX})!
          Please create a new installation in #{HOMEBREW_MACOS_ARM_DEFAULT_PREFIX} using one of the
          "Alternative Installs" from:
            #{Formatter.url("https://docs.brew.sh/Installation")}
          You can migrate your previously installed formula list with:
            brew bundle dump
        EOS
      end
    end

    def check_cpu
      return unless Hardware::CPU.ppc?

      odie <<~EOS
        Sorry, Homebrew does not support your computer's CPU architecture!
        For PowerPC Mac (PPC32/PPC64BE) support, see:
          #{Formatter.url("https://github.com/mistydemeo/tigerbrew")}
      EOS
    end
    private_class_method :check_cpu

    def attempt_directory_creation
      Keg::MUST_EXIST_DIRECTORIES.each do |dir|
        FileUtils.mkdir_p(dir) unless dir.exist?

        # Create these files to ensure that these directories aren't removed
        # by the Catalina installer.
        # (https://github.com/Homebrew/brew/issues/6263)
        keep_file = dir/".keepme"
        FileUtils.touch(keep_file) unless keep_file.exist?
      rescue
        nil
      end
    end
    private_class_method :attempt_directory_creation

    def check_cc_argv(cc)
      return unless cc

      @checks ||= Diagnostic::Checks.new
      opoo <<~EOS
        You passed `--cc=#{cc}`.
        #{@checks.please_create_pull_requests}
      EOS
    end
    private_class_method :check_cc_argv

    def install_formula?(
      f,
      head: false,
      fetch_head: false,
      only_dependencies: false,
      force: false,
      quiet: false
    )
      # head-only without --HEAD is an error
      if !head && f.stable.nil?
        odie <<~EOS
          #{f.full_name} is a head-only formula.
          To install it, run:
            brew install --HEAD #{f.full_name}
        EOS
      end

      # --HEAD, fail with no head defined
      odie "No head is defined for #{f.full_name}" if head && f.head.nil?

      installed_head_version = f.latest_head_version
      if installed_head_version &&
         !f.head_version_outdated?(installed_head_version, fetch_head: fetch_head)
        new_head_installed = true
      end
      prefix_installed = f.prefix.exist? && !f.prefix.children.empty?

      if f.keg_only? && f.any_version_installed? && f.optlinked? && !force
        # keg-only install is only possible when no other version is
        # linked to opt, because installing without any warnings can break
        # dependencies. Therefore before performing other checks we need to be
        # sure --force flag is passed.
        if f.outdated?
          return true unless Homebrew::EnvConfig.no_install_upgrade?

          optlinked_version = Keg.for(f.opt_prefix).version
          onoe <<~EOS
            #{f.full_name} #{optlinked_version} is already installed.
            To upgrade to #{f.version}, run:
              brew upgrade #{f.full_name}
          EOS
        elsif only_dependencies
          return true
        elsif !quiet
          opoo <<~EOS
            #{f.full_name} #{f.pkg_version} is already installed and up-to-date.
            To reinstall #{f.pkg_version}, run:
              brew reinstall #{f.name}
          EOS
        end
      elsif (head && new_head_installed) || prefix_installed
        # After we're sure that --force flag is passed for linked to opt
        # keg-only we need to be sure that the version we're attempting to
        # install is not already installed.

        installed_version = if head
          f.latest_head_version
        else
          f.pkg_version
        end

        msg = "#{f.full_name} #{installed_version} is already installed"
        linked_not_equals_installed = f.linked_version != installed_version
        if f.linked? && linked_not_equals_installed
          msg = if quiet
            nil
          else
            <<~EOS
              #{msg}.
              The currently linked version is: #{f.linked_version}
            EOS
          end
        elsif !f.linked? || f.keg_only?
          msg = <<~EOS
            #{msg}, it's just not linked.
            To link this version, run:
              brew link #{f}
          EOS
        elsif only_dependencies
          msg = nil
          return true
        else
          msg = if quiet
            nil
          else
            <<~EOS
              #{msg} and up-to-date.
              To reinstall #{f.pkg_version}, run:
                brew reinstall #{f.name}
            EOS
          end
        end
        opoo msg if msg
      elsif !f.any_version_installed? && (old_formula = f.old_installed_formulae.first)
        msg = "#{old_formula.full_name} #{old_formula.any_installed_version} already installed"
        msg = if !old_formula.linked? && !old_formula.keg_only?
          <<~EOS
            #{msg}, it's just not linked.
            To link this version, run:
              brew link #{old_formula.full_name}
          EOS
        elsif quiet
          nil
        else
          "#{msg}."
        end
        opoo msg if msg
      elsif f.migration_needed? && !force
        # Check if the formula we try to install is the same as installed
        # but not migrated one. If --force is passed then install anyway.
        opoo <<~EOS
          #{f.oldname} is already installed, it's just not migrated.
          To migrate this formula, run:
            brew migrate #{f}
          Or to force-install it, run:
            brew install #{f} --force
        EOS
      else
        # If none of the above is true and the formula is linked, then
        # FormulaInstaller will handle this case.
        return true
      end

      # Even if we don't install this formula mark it as no longer just
      # installed as a dependency.
      return false unless f.opt_prefix.directory?

      keg = Keg.new(f.opt_prefix.resolved_path)
      tab = Tab.for_keg(keg)
      unless tab.installed_on_request
        tab.installed_on_request = true
        tab.write
      end

      false
    end

    def install_formula(
      f,
      build_bottle: false,
      force_bottle: false,
      bottle_arch: nil,
      ignore_deps: false,
      only_deps: false,
      include_test_formulae: [],
      build_from_source_formulae: [],
      cc: nil,
      git: false,
      interactive: false,
      keep_tmp: false,
      force: false,
      debug: false,
      quiet: false,
      verbose: false
    )
      f.print_tap_action
      build_options = f.build

      if !Homebrew::EnvConfig.no_install_upgrade? && f.outdated? && !f.head?
        outdated_formulae = [f, *f.old_installed_formulae]
        version_upgrade = "#{f.linked_version} -> #{f.pkg_version}"

        oh1 <<~EOS
          #{f.name} #{f.linked_version} is installed and outdated
            Upgrading #{Formatted.identifier(f.name)} #{version_upgrade}
        EOS
        outdated_kegs = outdated_formulae.map(&:linked_keg).select(&:directory?).map { |k| Keg.new(k.resolved_path) }
        linked_kegs = outdated_kegs.select(&:linked)
      end

      fi = FormulaInstaller.new(
        f,
        options:                    build_options.used_options,
        build_bottle:               build_bottle,
        force_bottle:               force_bottle,
        bottle_arch:                bottle_arch,
        ignore_deps:                ignore_deps,
        only_deps:                  only_deps,
        include_test_formulae:      include_test_formulae,
        build_from_source_formulae: build_from_source_formulae,
        cc:                         cc,
        git:                        git,
        interactive:                interactive,
        keep_tmp:                   keep_tmp,
        force:                      force,
        debug:                      debug,
        quiet:                      quiet,
        verbose:                    verbose,
      )
      fi.prelude
      fi.fetch

      outdated_kegs.each(&:unlink) if outdated_kegs.present?

      fi.install
      fi.finish
    rescue FormulaInstallationAlreadyAttemptedError
      # We already attempted to install f as part of the dependency tree of
      # another formula. In that case, don't generate an error, just move on.
      nil
    rescue CannotInstallFormulaError => e
      ofail e.message
    ensure
      # Re-link kegs if upgrade fails
      linked_kegs.each(&:link) unless f.latest_version_installed?
    end
  end
end

require "extend/os/install"
