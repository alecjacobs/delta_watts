# frozen_string_literal: true

require "io/console"

module DeltaWatts
  class App
    DEFAULT_INTERVAL = 1.0
    FRAME_INTERVAL = 0.25
    HISTORY_SECONDS = 60
    # Extra lookback so the leftmost chart column is not culled before the
    # integer slot grid advances (dt can be a few seconds in a narrow terminal).
    HISTORY_SLACK = 5.0
    EMA_ALPHA = 0.35

    def initialize(interval: DEFAULT_INTERVAL)
      @data_interval = interval
      @history = []
      @running = false
      @tick = 0
      @snapshot = nil
      @power_watts = nil
      @display_percent = nil
      @last_sample_at = 0.0
      @last_size = nil
      @restored = false
      @sampler = nil
    end

    def run
      @sampler = PowerSampler.start
      setup_terminal
      @running = true
      sample_battery(force: true)
      sample_power
      refresh

      next_frame = monotonic_time + FRAME_INTERVAL

      loop do
        break unless @running

        timeout = [next_frame - monotonic_time, 0].max
        ready = IO.select([$stdin], nil, nil, timeout)
        break if ready && drain_stdin == :quit

        now = monotonic_time
        if now >= next_frame
          sample_battery if (now - @last_sample_at) >= @data_interval
          sample_power
          @tick += 1
          refresh
          next_frame += FRAME_INTERVAL
        end
      end
    ensure
      restore_terminal
    end

    private

    def setup_terminal
      Process.setproctitle("watts")
      @old_winch = trap("WINCH") { @resized = true }
      @old_int = trap("INT") { @running = false }
      @old_term = trap("TERM") { @running = false }
      if $stdin.tty?
        @stty_state = `stty -g`.chomp
        $stdin.raw!
      end
      print Ansi::SET_TITLE
      print Ansi::ALT_SCREEN_ON
      print Ansi::HIDE_CURSOR
      print Ansi::WRAP_OFF
      print Ansi::CLEAR
    end

    def restore_terminal
      return if @restored

      @restored = true
      begin
        print Ansi::SHOW_CURSOR
        print Ansi::WRAP_ON
        print Ansi::ALT_SCREEN_OFF
        print Ansi::RESET_TITLE
        $stdout.flush
      rescue StandardError
        nil
      end
      restore_signals
      restore_tty
      @sampler&.stop
    end

    def restore_signals
      trap("WINCH", @old_winch || "DEFAULT")
      trap("INT", @old_int || "DEFAULT")
      trap("TERM", @old_term || "DEFAULT")
    rescue StandardError
      nil
    end

    def restore_tty
      return unless $stdin.tty?

      if @stty_state && !@stty_state.empty?
        system("stty", @stty_state, exception: false)
      elsif $stdin.respond_to?(:cooked!)
        $stdin.cooked!
      end
    rescue StandardError
      system("stty", "sane", exception: false)
    end

    def drain_stdin
      loop do
        chunk = $stdin.read_nonblock(16, exception: false)
        break if chunk.nil? || chunk == :wait_readable

        return :quit if chunk.include?("q") || chunk.include?("\u0003")
      end
      nil
    end

    def sample_battery(force: false)
      now = monotonic_time
      return unless force || (now - @last_sample_at) >= @data_interval

      @snapshot = Battery.snapshot
      if force
        5.times do
          break unless battery_watts(@snapshot).to_f < 0.05 && !@snapshot.fully_charged

          sleep 0.05
          @snapshot = Battery.snapshot
        end
      end
      @last_sample_at = monotonic_time
    end

    def sample_power
      watts = @sampler&.sample
      watts = battery_watts(@snapshot) if watts.nil?
      return if watts.nil?

      now = monotonic_time
      @power_watts = blend(watts)
      @history << [now, @power_watts]
      cutoff = now - HISTORY_SECONDS - HISTORY_SLACK
      @history.shift while @history.any? && @history.dig(0, 0) < cutoff
    end

    def refresh
      return unless @snapshot

      ease_toward(@snapshot.percent)

      rows, cols = terminal_size
      size = [rows, cols]
      resized = @resized || @last_size != size

      renderer = Renderer.new(width: cols, height: rows)
      frame = renderer.render(
        snapshot: @snapshot,
        history: @history,
        interval_sec: HISTORY_SECONDS,
        tick: @tick,
        display_percent: @display_percent,
        power_watts: @power_watts
      )

      print Ansi::HOME
      print Ansi::CLEAR if resized
      frame.split("\n").each_with_index do |line, index|
        print Ansi.cursor_at(index + 1)
        print Ansi::ERASE_LINE_FULL
        print line
      end
      print Ansi.cursor_at(frame.count("\n") + 2)
      print Ansi::ERASE_DOWN
      $stdout.flush
      @last_size = size
      @resized = false
    end

    def ease_toward(target_percent)
      @display_percent ||= target_percent.to_f
      delta = target_percent - @display_percent
      @display_percent += delta * 0.35
      @display_percent = target_percent if delta.abs < 0.2
    end

    def blend(watts)
      return watts if @power_watts.nil?

      @power_watts + (watts - @power_watts) * EMA_ALPHA
    end

    def battery_watts(snapshot)
      return nil unless snapshot

      watts =
        if snapshot.on_ac_power?
          snapshot.watts_into_battery
        else
          snapshot.watts_out_of_battery
        end

      return nil unless watts.finite? && watts.between?(0.0, 400.0)
      return nil if watts < 0.05 && !snapshot.fully_charged

      watts
    end

    def terminal_size
      $stdout.winsize
    rescue StandardError
      [24, 80]
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
