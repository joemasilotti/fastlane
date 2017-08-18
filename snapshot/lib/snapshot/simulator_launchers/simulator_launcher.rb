require 'snapshot/simulator_launchers/simulator_launcher_base'

module Snapshot
  class SimulatorLauncher < SimulatorLauncherBase
    # With Xcode 9's ability to run tests on multiple concurrent simulators,
    # this method sets the maximum number of simulators to run simultaneously
    # to avoid overloading your machine.
    def default_number_of_simultaneous_simulators
      cpu_count = CPUInspector.cpu_count
      if cpu_count <= 2
        return cpu_count
      end

      return cpu_count - 1
    end

    def take_screenshots_simultaneously
      languages_finished = {}
      launcher_config.launch_args_set.each do |launch_args|
        launcher_config.languages.each_with_index do |language, language_index|
          locale = nil
          if language.kind_of?(Array)
            locale = language[1]
            language = language[0]
          end

          # Clear logs so subsequent xcodebuild executions dont append to old ones
          log_path = xcodebuild_log_path(language: language, locale: locale)
          File.delete(log_path) if File.exist?(log_path)

          # Break up the array of devices into chunks that can
          # be run simultaneously.
          if launcher_config.concurrent_simulators?
            device_batches = launcher_config.devices.each_slice(default_number_of_simultaneous_simulators).to_a
          else
            # Put each device in it's own array to run tests one at a time
            device_batches = launcher_config.devices.map { |d| [d] }
          end

          device_batches.each do |devices|
            languages_finished[language] = launch_simultaneously(devices, language, locale, launch_args)
          end
        end
      end
      launcher_config.devices.each_with_object({}) do |device, results_hash|
        results_hash[device] = languages_finished
      end
    end

    def launch_simultaneously(devices, language, locale, launch_arguments)
      prepare_for_launch(language, locale, launch_arguments)

      add_media(devices, :photo, launcher_config.add_photos) if launcher_config.add_photos
      add_media(devices, :video, launcher_config.add_videos) if launcher_config.add_videos

      command = TestCommandGenerator.generate(
        devices: devices,
        language: language,
        locale: locale,
        log_path: xcodebuild_log_path(language: language, locale: locale)
      )

      UI.important("Running snapshot on: #{devices.join(', ')}")

      execute(command: command, language: language, locale: locale, launch_args: launch_arguments, devices: devices)

      return copy_screenshots(language: language, locale: locale, launch_args: launch_arguments)
    end

    def execute(command: nil, language: nil, locale: nil, launch_args: nil, devices: nil)
      prefix_hash = [
        {
          prefix: "Running Tests: ",
          block: proc do |value|
            value.include?("Touching")
          end
        }
      ]
      FastlaneCore::CommandExecutor.execute(command: command,
                                          print_all: true,
                                      print_command: true,
                                             prefix: prefix_hash,
                                            loading: "Loading...",
                                              error: proc do |output, return_code|
                                                self.collected_errors.concat(failed_devices.map do |device, messages|
                                                  "#{device}: #{messages.join(', ')}"
                                                end)

                                                copy_screenshots(language: language, locale: locale, launch_args: launch_args)

                                                UI.important("Tests failed while running on: #{devices.join(', ')}")
                                                UI.important("For more detail about the test failures, check the logs here:")
                                                UI.important(xcodebuild_log_path(language: language, locale: locale))
                                                UI.important(" ")
                                                UI.important("You can also find the test result data here:")
                                                UI.important(test_results_path)
                                                UI.important(" ")
                                                UI.important("You can find the incomplete screenshots here:")
                                                UI.important(SCREENSHOTS_DIR)
                                                UI.important(launcher_config.output_directory)

                                                # no exception raised... that means we need to retry
                                                UI.error "Caught error... #{return_code}"

                                                self.current_number_of_retries_due_to_failing_simulator += 1
                                                if self.current_number_of_retries_due_to_failing_simulator < 20 && return_code != 65
                                                  launch_simultaneously(devices, language, locale, launch_args)
                                                else
                                                  # It's important to raise an error, as we don't want to collect the screenshots
                                                  UI.crash!("Too many errors... no more retries...") if launcher_config.stop_after_first_error
                                                end
                                              end)
    end

    def copy_screenshots(language: nil, locale: nil, launch_args: nil)
      raw_output = File.read(xcodebuild_log_path(language: language, locale: locale))
      dir_name = locale || language
      return Collector.fetch_screenshots(raw_output, dir_name, '', launch_args.first)
    end

    def test_results_path
      derived_data_path = TestCommandGenerator.derived_data_path
      return File.join(derived_data_path, 'Logs/Test')
    end

    # This method returns a hash of { device name => [failure messages] }
    # {
    #   'iPhone 7': [], # this empty array indicates success
    #   'iPhone 7 Plus': ["No tests were executed"],
    #   'iPad Air': ["Launch session expired", "Array out of bounds"]
    # }
    def failed_devices
      test_summaries = Dir["#{test_results_path}/*_TestSummaries.plist"]
      test_summaries.each_with_object({}) do |plist, hash|
        summary = FastlaneCore::TestParser.new(plist)
        name = summary.data.first[:run_destination_name]
        if summary.data.first[:number_of_tests] == 0
          hash[name] = ["No tests were executed"]
        else
          hash[name] = Array(summary.data.first[:failures]).map(&:failure_message)
        end
      end
    end

    def xcodebuild_log_path(language: nil, locale: nil)
      name_components = [Snapshot.project.app_name, Snapshot.config[:scheme]]

      if Snapshot.config[:namespace_log_files]
        name_components << launcher_config.devices.join('-') if launcher_config.devices.count >= 1
        name_components << language if language
        name_components << locale if locale
      end

      file_name = "#{name_components.join('-')}.log"

      containing = File.expand_path(Snapshot.config[:buildlog_path])
      FileUtils.mkdir_p(containing)

      return File.join(containing, file_name)
    end
  end

  class CPUInspector
    def self.hwprefs_available?
      `which hwprefs` != ''
    end

    def self.cpu_count
      @cpu_count ||=
        case RUBY_PLATFORM
        when /darwin9/
          `hwprefs cpu_count`.to_i
        when /darwin10/
          (hwprefs_available? ? `hwprefs thread_count` : `sysctl -n hw.physicalcpu_max`).to_i
        when /linux/
          UI.user_error!("We detected that you are running snapshot on Linux, but snapshot is only supported on macOS")
        when /freebsd/
          UI.user_error!("We detected that you are running snapshot on FreeBSD, but snapshot is only supported on macOS")
        else
          if RbConfig::CONFIG['host_os'] =~ /darwin/
            (hwprefs_available? ? `hwprefs thread_count` : `sysctl -n hw.physicalcpu_max`).to_i
          else
            UI.crash!("Cannot find the machine's processor count.")
          end
        end
    end
  end
end
