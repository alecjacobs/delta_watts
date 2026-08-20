# frozen_string_literal: true

require "io/console"

module DeltaWatts
  class App
    DEFAULT_INTERVAL = 1.0
    FRAME_INTERVAL = 0.25
    HISTORY_SECONDS = 60

    def initialize(interval: DEFAULT_INTERVAL)
      @data_interval = interval
      @history = []
      @running = false
      @tick = 0
      @snapshot = nil
      @display_percent = nil
      @last_sample_at = 0.0
      @last_size = nil
      @restored = false
    end

    def run
      setup_terminal
      @running = true
      sample_battery(force: true)
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
      while (char = $stdin.read_nonblock(16, exception: false))
        return :quit if char.include?("q") || char.include?("\u0003")
      end
      nil
    rescue IO::WaitReadable
      nil
    end

    def sample_battery(force: false)
      now = monotonic_time
      return unless force || (now - @last_sample_at) >= @data_interval

      @snapshot = Battery.snapshot
      if force
        5.times do
          break unless current_watts(@snapshot).to_f < 0.05 && !@snapshot.fully_charged

          sleep 0.05
          @snapshot = Battery.snapshot
        end
      end
      @last_sample_at = monotonic_time
      track_history(@snapshot)
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
        display_percent: @display_percent
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

    def track_history(snapshot)
      watts = current_watts(snapshot)
      return if watts.nil?

      @history << watts
      @history.shift while @history.length > HISTORY_SECONDS
    end

    def current_watts(snapshot)
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
